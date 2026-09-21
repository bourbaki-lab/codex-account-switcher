# Environment Report

이 문서는 공개 저장소용으로 개인정보와 계정별 사용량을 제거한 검증 결과입니다. 인증 파일 내용, token, cookie, API key, OAuth code, 비공개 Keychain 값은 읽거나 기록하지 않습니다.

## 검증 환경

| 항목 | 확인 결과 |
|---|---|
| 운영체제 | macOS 15 이상 |
| CPU architecture | Apple Silicon (`arm64`) |
| 도구체인 | Swift 6, Xcode 또는 Swift Package Manager |
| 공식 앱 | `/Applications/ChatGPT.app`, Bundle ID `com.openai.codex` |
| Codex 인증 저장소 | 기본 `~/.codex`, 파일 기반 `auth.json`, 권한 `0600` |
| 로컬 앱 서명 | 개발용 ad-hoc 서명 |

정확한 macOS·Xcode·Codex 버전은 변경될 수 있으므로 앱이 실행 시점에 직접 탐지합니다. 경로나 이름만으로 공식 앱을 결정하지 않고 `Info.plist`, Bundle Identifier, 번들 Codex 실행 파일을 함께 확인합니다.

## 공식 App Server 읽기 프로브

공식 프로토콜 순서인 `initialize` → `initialized` 후 다음 메서드를 확인했습니다.

| 메서드 | 공개 가능한 결과 |
|---|---|
| `account/read(refreshToken: false)` | ChatGPT 관리형 계정, 마스킹 이메일과 plan type 반환 |
| `account/rateLimits/read` | Codex bucket의 사용률·창 길이·절대 초기화 시각과 제공되는 경우 초기화권 수량·만료 시각 반환 |
| `account/usage/read` | 지원되는 환경에서 활동 summary 반환 |

앱은 허용된 필드만 파싱하고 이메일은 일반 로그에 기록하기 전에 마스킹합니다. 계정별 사용량 숫자는 이 공개 문서에 저장하지 않습니다.

공식 프로토콜 근거: [Codex App Server documentation](https://developers.openai.com/codex/app-server/)

## 프로세스 안전장치

- 공식 앱과 그 자식 App Server는 정상 종료·재실행 대상입니다.
- 별도 터미널이나 IDE에서 실행된 standalone Codex CLI는 논리 프로세스 트리 단위로 감지합니다.
- `Codex Computer Use.app` 같은 신뢰된 공식 helper는 standalone CLI blocker로 오인하지 않습니다.
- blocker가 있으면 사용자에게 목록을 보여주며, 명시적 승인 후 `SIGINT`와 `SIGTERM`으로만 정상 종료를 시도합니다.
- 정상 종료되지 않으면 인증 파일을 변경하기 전에 전환을 중단합니다.

## 공유 로컬 상태

전환 보호 대상은 다음 범주입니다.

- `history.jsonl`
- `sessions/`, `archived_sessions/`
- session/thread index와 상태 데이터베이스
- `config.toml`
- `skills/`, `rules/`, hooks
- projects와 worktrees의 존재 상태

실제 전환 스냅샷은 `auth.json`, log, cache, SQLite WAL/SHM과 임시 lock을 제외합니다. 보호 파일 삭제는 자동 롤백 조건이며, 공식 앱 종료·재실행 과정에서 생길 수 있는 비파괴 변경은 결과에 기록합니다.

## 구현 가능성 판정

| 기능 | 판정 |
|---|---|
| 공식 App Server account surface | 사용 가능 |
| ChatGPT browser/device-code 등록 | 사용 가능, 로그인과 MFA는 사용자 수행 |
| AES-GCM 암호화 프로필 | 사용 가능 |
| Keychain 256비트 키 | 사용 가능 |
| 프로세스 단위 Keychain 키 캐시 | 사용 가능 |
| 현재 인증·프로필별 남은 한도 표시 | 공유 `auth.json` 계정과 격리된 임시 `CODEX_HOME`의 App Server 응답이 있는 경우 사용 가능; 절대 초기화 일시와 초기화권 수량/사용기한 표시; 팝오버 열림 중 30초 자동 갱신; 만료 프로필은 갱신 필요 표시 |
| 인증만 교체하고 로컬 상태 공유 | 자동 테스트와 실제 전환에서 확인 |
| 동일 task 후속 작업 | 실제 두 계정 전환에서 확인 |

2026-08-18 재검증에서 공식 앱 26.814 계열은 `features.code_mode_host=true`로 실행됐고, 한 시도에서는 `auth.json` 교체 후 공식 데스크톱 계정이 바뀌지 않았습니다. 제품의 핵심 전환 흐름은 유지하되, 유효한 파일 인증이 확인된 경우에만 호환 모드로 `전환`을 허용하고 재실행 후 실제 계정 확인을 요구합니다. 적용되지 않았을 때는 `Guided Switch`를 사용합니다.

## 빌드·런타임 검증

| 검증 | 결과 |
|---|---|
| `scripts/test.sh` | 52 tests, 0 failures |
| 가짜 `CODEX_HOME` 10회 전환 | 통과 |
| coordinator 대상 검증·재실행·세션 삭제 실패 자동 롤백 | 통과 |
| 대상 적용 검증의 중복 refresh 금지 회귀 테스트 | 통과 |
| 인증 교체 조용한 구간 보호 상태 무변경 검사 | 통과 |
| skills 폴더 메타데이터 변화만 있을 때 전환 유지 | build 10 회귀 테스트 통과 |
| 실제 skill 파일 변경과 보호 경로 추가·삭제·종류 변경 감지 | 통과 |
| 롤백 시 앱 종료 실패에서 인증 재기록 금지 | 통과 |
| wrapper/native CLI 종료 흐름 | 통과 |
| Keychain 원본 조회 중복 방지 | 통과 |
| `scripts/build.sh` Release | 통과 |
| 앱 번들 검증 | `codesign --verify --deep --strict` 통과 |
| 실제 A→B 계정 전환 | 파일 기반 인증 버전에서 통과; host-managed 26.814는 호환 모드이며 결과 확인 필요 |
| 공식 앱 재실행 | 통과 |
| 동일 task 대화 맥락과 후속 코드 작업 | 통과 |

ad-hoc 서명은 로컬 개발·실행용입니다. 제3자에게 바이너리를 배포하려면 Developer ID 서명과 notarization이 별도로 필요합니다.
