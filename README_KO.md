# Codex Account Switcher

Codex Account Switcher는 macOS 메뉴바에서 **사용자가 직접 선택한 ChatGPT/Codex 계정으로 인증을 전환**하는 로컬 보조 앱입니다. 새로운 Codex 클라이언트가 아니며, 공식 `/Applications/ChatGPT.app`의 하네스·프로젝트·터미널·Diff·샌드박스·승인·워크트리·세션 UI는 전혀 대체하지 않습니다.

공식 앱 번들, 바이너리, 코드 서명, 자동 업데이트 파일은 수정하지 않습니다. 브라우저 쿠키나 공식 앱의 비공개 Keychain 항목도 읽지 않습니다.

> **지원 환경:** macOS 15 이상이 설치된 **Apple Silicon(arm64) Mac 전용**입니다. 현재 빌드와 실환경 검증은 Apple Silicon에서만 완료했으며 Intel Mac(x86_64)은 지원하거나 검증하지 않았습니다.

## 현재 확인 상태

- macOS 15 이상, Apple Silicon 환경에서 빌드 및 자동 테스트 완료
- 공식 앱 `/Applications/ChatGPT.app`, 실제 Bundle Identifier `com.openai.codex` 탐지 완료
- 번들 Codex App Server의 `account/read`, `account/rateLimits/read`, `account/usage/read` 확인 완료
- 현재 설치 환경의 `~/.codex/auth.json` 파일 기반 인증과 권한 `0600` 확인 완료
- 가짜 `CODEX_HOME`에서 인증만 바꾸는 10회 전환, 공유 상태 해시 불변, 실패 복구 확인 완료
- 파일 기반 인증을 사용하던 공식 앱에서 실제 두 계정 전환, 앱 재실행, 동일 task 대화 맥락 유지와 후속 코드 작업 확인 완료
- 전체 자동 테스트 46개 통과

자세한 실환경 결과는 [환경 진단](docs/ENVIRONMENT_REPORT.md)과 [세션 연속성 보고서](docs/SESSION_CONTINUITY_REPORT.md)를 확인하세요.

## 빌드

요구 사항은 macOS 15 이상이 설치된 Apple Silicon(arm64) Mac과 Xcode 26 또는 Swift 6 도구체인입니다. 외부 패키지는 사용하지 않습니다.

```bash
./scripts/test.sh
./scripts/build.sh
```

빌드 결과는 다음 위치에 생성됩니다.

```text
dist/Codex Account Switcher.app
```

`CodexAccountSwitcher.xcodeproj`를 Xcode에서 열고 `Codex Account Switcher` scheme을 Build해도 같은 Release 앱이 생성됩니다. 프로젝트는 Swift Package를 호출하는 Xcode External Build target이므로 명령행과 Xcode가 동일한 산출물을 사용합니다.

## 설치와 실행

```bash
./scripts/install.sh
open "$HOME/Applications/Codex Account Switcher.app"
```

설치 스크립트는 사용자 전용 `~/Applications`만 사용합니다. `/Applications`에는 쓰지 않습니다. 첫 실행 후 메뉴바의 순환 화살표 아이콘을 누르세요.

## 계정 등록

등록 개수 제한 없이 여러 계정을 지원합니다. 계정 목록은 메뉴 안에서 스크롤됩니다.

1. `~/.codex/auth.json`에 저장된 계정을 등록하려면 `저장 인증 등록`을 누릅니다. 공식 앱이 호스트 관리 인증을 사용하면 앱 내부 계정과 이 파일의 계정이 다를 수 있습니다.
2. 앱은 `auth.json`을 검증한 뒤 즉시 AES-GCM으로 암호화합니다.
3. `계정 추가`를 누르면 별도 임시 `CODEX_HOME`에서 공식 App Server의 `account/login/start` 브라우저 흐름을 시작합니다.
4. 브라우저에서 사용자가 직접 추가할 계정의 로그인·MFA를 완료합니다.
5. App Server의 `account/login/completed`와 `account/read`가 성공한 경우에만 프로필로 저장합니다.

브라우저 callback이 불안정하면 `Device Code 추가`를 사용할 수 있습니다. 코드는 클립보드에 복사되고 공식 verification URL이 열립니다. 비밀번호, MFA 코드, 브라우저 쿠키는 앱이 보거나 저장하지 않습니다.

이미 등록된 계정으로 다시 로그인하면 중복 프로필을 만들지 않고 저장된 인증을 갱신합니다. 프로필 오른쪽 `…` 메뉴에서 `브라우저로 계정 변경` 또는 `Device Code로 계정 변경`을 선택하면 프로필 이름은 유지한 채 다른 계정의 인증으로 교체할 수 있습니다. 교체 후에는 해당 프로필의 `전환`을 눌러 현재 Codex 계정에 적용합니다.

## 계정 전환

1. 메뉴에서 비활성 프로필의 `전환`을 누릅니다. 호스트 관리 인증에서는 호환 모드 경고 후 전환을 허용합니다. `keyring`, 알 수 없는 저장소 또는 검증되지 않은 `auth.json` 환경에서는 버튼이 비활성화됩니다.
2. 경고 내용을 확인하고 사용자가 `전환`을 다시 누릅니다.
3. 별도 Codex CLI·IDE 프로세스가 실행 중이면 감지 목록을 보여주고 `CLI 종료 후 전환` 승인을 요청합니다.
4. 사용자가 승인하면 먼저 `SIGINT`, 남아 있으면 `SIGTERM`으로 정상 종료를 요청합니다. `SIGKILL`은 사용하지 않으며 종료되지 않으면 인증을 건드리기 전에 중단합니다.
5. `cli_auth_credentials_store`, 유효한 `auth.json`, 새 App Server의 실제 계정 응답을 확인합니다. `auto` 또는 미설정도 runtime 확인에 성공해야 합니다.
6. 세션·히스토리·설정·skills의 경로, 크기, 수정 시각, SHA-256 스냅샷을 만듭니다.
7. 현재 인증 캐시를 최신화해 현재 프로필에 다시 암호화 저장합니다.
8. 실제 Bundle Identifier로 공식 앱에 정상 종료를 요청합니다.
9. 정상 종료가 15초 안에 끝나지 않으면 사용자의 별도 승인 없이는 강제 종료하지 않습니다.
10. 기존 인증을 암호화된 긴급복구 백업으로 저장한 뒤 대상 인증을 임시 파일·`fsync`·원자적 rename으로 교체합니다.
11. 권한 `0600`, JSON 구조, `account/read(refreshToken: false)`, 실제 이메일 일치를 검증합니다. 저장 프로필과 공유 홈 사이에서 회전형 refresh token을 불필요하게 다시 갱신하지 않습니다.
12. 공식 앱이 멈춘 조용한 구간에서 인증 외 보호 상태의 경량 manifest가 하나라도 바뀌면 즉시 롤백합니다.
13. 공식 앱을 원래 설치 경로에서 다시 실행한 뒤 보호 상태를 비교합니다. 호스트 관리 인증 환경에서는 공식 앱의 실제 계정을 사용자가 확인해야 합니다.

실패하면 이전 인증으로 자동 롤백하고 공식 앱을 다시 실행합니다. `history.jsonl`, `sessions`, 설정, skills, rules, hooks, 작업 폴더, Git 저장소, 워크트리는 전환 대상이 아닙니다.

공식 앱이 `features.code_mode_host=true`로 실행되는 버전에서도 검증된 저장 프로필에는 `전환`을 표시하고 호환 모드로 인증 캐시 교체를 시도합니다. 다만 별도 App Server의 파일 인증 검증은 공식 데스크톱 호스트가 실제로 같은 계정을 수용했다는 증거가 아니므로 재실행 후 공식 앱 계정을 확인해야 합니다. 적용되지 않았을 때만 `Guided Switch`로 공식 로그아웃·로그인을 진행합니다.

## 사용량 표시

앱은 공식 App Server의 `account/rateLimits/read`가 반환한 Codex bucket을 읽어 `100 - usedPercent`를 남은 비율로 표시합니다. primary/secondary 각각의 `windowDurationMins`로 5시간·주간 같은 한도 이름을 표시하고 `resetsAt`은 상대 시간이 아닌 로컬 절대 날짜·시각으로 보여줍니다. 새 `rateLimitsByLimitId["codex"]` 응답을 우선 사용하고 기존 단일 `rateLimits` 응답도 지원합니다.

같은 응답의 `rateLimitResetCredits.availableCount`를 초기화권 보유 수량으로 사용합니다. 서버가 개별 내역을 제공하면 사용 가능한 `credits[].expiresAt` 중 가장 빠른 시각을 사용기한으로 표시합니다. 서버가 수량만 제공하면 수량은 표시하되 사용기한은 `미제공`으로 구분하며, 상세 배열 길이로 전체 수량을 추정하지 않습니다.

현재 `~/.codex/auth.json` 계정은 공유 `CODEX_HOME`의 새 App Server로 직접 조회해 상단과 일치하는 프로필 행에 한도를 표시합니다. 등록된 나머지 프로필은 공유 홈을 바꾸지 않고 소유자 전용 임시 홈에서 복호화·조회한 뒤 즉시 제거하며, 조회 과정에서 갱신된 인증은 다시 AES-GCM으로 봉인합니다. 공식 앱이 host-managed 인증을 쓰는 경우에도 이 값은 **auth.json 인증 기준**이라고 표시하며 공식 앱 내부 현재 계정과 같다고 주장하지 않습니다. 만료된 프로필은 숫자를 숨기는 대신 `인증 갱신 필요`로 표시합니다. 요청 실패는 `30초 후 자동 재시도`, 정상 응답에 한도 데이터가 없는 경우는 `서버가 이 계정의 한도 정보를 제공하지 않았습니다`로 구분하며 추정값을 만들지 않습니다. 이 정보는 표시와 수동 판단에만 사용하고 자동 계정 순환 조건으로 연결하지 않습니다.

메뉴바 팝오버를 열면 한도를 즉시 다시 확인하고, 열려 있는 동안 30초마다 현재 `auth.json` 계정과 모든 저장 프로필을 자동 갱신합니다. `Codex 남은 한도` 오른쪽의 시각으로 마지막 완료 시점을 확인할 수 있으며, 팝오버를 닫으면 자동 조회 작업도 중단됩니다. `계정 정보 새로고침`은 환경·계정·프로필 전체를 다시 검사하는 수동 경로로 유지됩니다.

`account/usage/read`가 성공하면 토큰 활동 요약도 내부 상태로 읽지만, 정확한 “작업 몇 회 남음”은 서버가 제공하지 않으므로 표시하지 않습니다.

## Claude 탭 (실험 기능)

팝오버 상단의 `Codex | Claude` 전환으로 Claude 데스크톱 앱 Code 탭의 계정별 세션 목록을 봅니다.

- Claude 데스크톱은 대화 원본을 `~/.claude/projects/<작업 폴더>/<세션 ID>.jsonl`에 계정과 무관하게 저장하지만, 사이드바 목록은 `~/Library/Application Support/Claude/claude-code-sessions/<계정 UUID>/<조직 UUID>/local_*.json`으로 계정별로 나눕니다. 그래서 로그인만 바꾸면 이전 계정의 세션이 사이드바에서 보이지 않습니다.
- 현재 계정은 Claude 앱의 `config.json`(`lastKnownAccountUuid`)으로, 표시 이메일·플랜은 `~/.claude.json`의 `oauthAccount`에서 마스킹해 스위처 전용 `Claude/accounts.json`에 기억합니다. 전환 전에 Claude 탭을 한 번 열어 두면 이전 계정도 이메일로 표시됩니다.
- 5시간·주간 한도는 Claude 앱이 조직별로 남기는 `plan-usage-history.json`의 마지막 기록을 표시합니다. 네트워크 요청은 하지 않습니다.
- `가져오기`는 Claude 앱을 정상 종료한 뒤 다른 계정의 목록 파일을 현재 계정 목록에 복사하고 앱을 다시 실행합니다. 원본 목록과 대화 파일은 수정하지 않고, 이미 있는 목록 파일은 덮어쓰지 않으며, 대화 파일이 사라진 세션은 건너뜁니다. 정상 종료가 20초 안에 끝나지 않으면 아무것도 바꾸지 않습니다.
- `가져오기 되돌리기`는 복사 이후 바뀌지 않은 목록 파일만 지웁니다. 새 계정에서 이어서 쓴 세션은 남깁니다.
- Claude 로그인 자체는 앱 내부 암호화 저장소에 있으므로 스위처가 바꾸지 않습니다. `계정 전환 안내`로 Claude 앱을 열고 사용자가 직접 로그아웃·로그인합니다.
- 새 계정으로 로그인한 직후에는 목록 폴더가 없을 수 있습니다. 이때는 Claude 앱에서 세션을 하나 시작한 뒤 새로고침하세요.
- 다른 계정에서 이어간 세션의 첫 요청은 프롬프트 캐시가 없어 사용량이 크게 잡힐 수 있습니다. 이전 계정에서 생성된 thinking 블록을 새 계정 API가 받아들이는지는 아직 실측 전입니다.

### Anthropic 약관 준수 조건

2026-09-29에 [소비자 약관](https://www.anthropic.com/legal/consumer-terms), [이용 정책](https://www.anthropic.com/legal/aup), [Claude Code 법률·준수 문서](https://code.claude.com/docs/en/legal-and-compliance)를 기준으로 설계했습니다.

- Claude 로그인 정보, OAuth 토큰, 세션 토큰을 읽거나 저장하거나 중개하지 않습니다. 로그인은 항상 Claude 앱의 공식 흐름으로 사용자가 직접 합니다.
- Anthropic 서버에 요청하지 않고 봇·스크립트로 서비스에 접근하지 않습니다. 사용자의 로컬 목록 파일만 읽고 복사합니다.
- Claude 앱 바이너리와 서명은 수정하지 않습니다.
- 본인 소유 계정 사이에서만 사용하세요. 계정·로그인 정보를 다른 사람과 공유하거나, 정지된 계정을 다른 계정으로 우회하는 데 쓰면 약관 위반입니다.
- 한도 표시는 수동 판단용입니다. 한도 도달 시 자동으로 계정을 바꾸는 기능은 넣지 않습니다. 요금제 한도는 일반적인 개인 사용을 전제로 하므로, 더 많은 사용량이 필요하면 상위 요금제나 추가 사용량이 공식 경로입니다.

## Session Continuity Test

1. `연속성 테스트 시작`을 누릅니다. `CAS-PROBE-<UUID>`가 클립보드에 복사됩니다.
2. 공식 앱에서 테스트용 로컬 프로젝트의 기존 대화에 마커를 붙여넣습니다.
3. 메뉴에서 `마커 찾기`를 눌러 로컬 session 파일과 thread/session ID를 기록합니다.
4. 계정 B로 전환합니다.
5. 같은 세션을 열고 `이 대화 앞부분에 기록된 CAS-PROBE 마커를 정확히 말해줘.`를 입력합니다.
6. 현재 계정을 새로고침해 B가 활성인지 확인합니다.
7. 실제 후속 작업까지 성공했으면 PASS, 로컬 목록만 남고 실행이 거부되거나 새 thread로 갈라지면 PARTIAL, 세션이 사라지거나 열리지 않으면 FAIL을 누릅니다.
8. 계정 A로 돌아가 같은 세션이 손상되지 않았는지 확인합니다.

세션 파일이 존재한다는 사실만으로 PASS 처리하지 마세요. PASS는 계정 B 인증으로 동일 thread/session에서 실제 후속 요청이 성공한 경우뿐입니다.

## 인증 데이터 보관

- 암호화: Apple CryptoKit AES-GCM
- 키: macOS Keychain의 이 앱 전용 generic-password 항목
- 키 캐시: 최초 Keychain 조회 후 Switcher 프로세스 메모리에서만 재사용
- 암호문: `~/Library/Application Support/CodexAccountSwitcher/Profiles/`
- 메타데이터: 표시 이름, 마스킹된 이메일, 플랜, 검증 시각만 저장
- 활성 인증: 공식 Codex가 사용하는 것으로 실환경 확인된 `~/.codex/auth.json`만 원자 교체
- 권한: 디렉터리 `0700`, 인증·암호문·메타데이터 `0600`

Keychain 또는 암호화가 실패하면 평문 fallback 없이 중단합니다. APFS/SSD에서는 덮어쓰기가 물리 블록 소거를 보장하지 않으므로 임시 평문 파일은 가능한 짧게 유지하고, 앱이 연 임시 파일을 best-effort로 덮어쓴 뒤 제거합니다.

로컬 ad-hoc 서명 빌드는 재빌드할 때 Keychain이 새 바이너리로 판단해 최초 승인을 다시 요구할 수 있습니다. 한 설치본에서는 첫 승인창의 `항상 허용`을 선택하면 이후 승인이 생략되며, `허용`만 선택해도 프로세스 키 캐시 덕분에 한 번의 실행 중 반복 승인창은 나타나지 않습니다.

## 필요한 권한

- Keychain: 프로필 암호화 키 저장
- 다른 앱 종료·실행: 공식 `com.openai.codex` 앱의 정상 종료 및 재실행
- 자동화: 사용자가 `Guided Switch`를 선택했을 때 공식 앱의 표준 `로그아웃` 메뉴 실행
- 파일 접근: 사용자의 공유 `CODEX_HOME`에서 인증 파일 교체와 보호 상태 읽기
- 로그인 시 실행(선택): 사용자가 설정에서 직접 켠 경우 `SMAppService`

Accessibility와 화면 녹화는 요구하지 않습니다. `Guided Switch`를 처음 실행하면 macOS가 `System Events` 자동화 권한을 한 번 요청할 수 있습니다. 브라우저 쿠키와 공식 앱의 비공개 Keychain 항목은 읽지 않습니다.

## 긴급 복구

메뉴의 `긴급 복구`를 누르거나 공식 앱을 먼저 정상 종료한 뒤 다음을 실행합니다.

```bash
./scripts/emergency-restore.sh
```

스크립트는 토큰을 출력하지 않습니다. 설치 앱의 `--emergency-restore` 모드가 Keychain 키로 마지막 백업을 복호화하고 권한 `0600`으로 복원한 뒤 공식 앱을 엽니다.

## 삭제

앱만 제거하고 암호화 프로필을 보존합니다.

```bash
./scripts/uninstall.sh
```

앱, 암호화 프로필, 복구 백업, 전용 Keychain 키를 모두 삭제합니다.

```bash
./scripts/uninstall.sh --purge-data
```

어느 경우에도 `~/.codex`, 기존 세션, 프로젝트, 작업 폴더는 삭제하지 않습니다.

## 현재 환경에서 확인된 한계

- 실제 계정 B 로그인·MFA는 자동화하지 않으며 사용자가 직접 완료해야 합니다.
- standalone CLI가 감지되면 사용자에게 종료 승인을 요청하며, 승인 없이 종료하거나 전환하지 않습니다.
- 공식 데스크톱 호스트가 `chatgptAuthTokens` 같은 호스트 관리형 토큰을 사용해도 private token을 읽거나 주입하지 않습니다. 검증된 `auth.json` 전환은 호환 모드로 시도하며, 공식 호스트가 이를 수용했는지는 전환 후 사용자가 확인해야 합니다.
- 공식 App Server에서 별도 데스크톱 호스트의 내부 토큰 상태를 가로채는 인터페이스는 사용하지 않습니다. 적용되지 않았을 때의 `Guided Switch`는 macOS가 노출한 공식 앱 메뉴의 `로그아웃` 동작만 실행합니다.
- 실제 두 계정 사이의 동일 task 재개와 후속 코드 작업은 **PASS**로 확인했습니다. 모델의 순간적인 비공개 추론 상태까지 복제된다는 뜻은 아니며, 저장된 대화·세션·프로젝트 맥락의 연속성을 뜻합니다.

## 설계와 문제 해결

- [아키텍처](docs/ARCHITECTURE.md)
- [보안 정책](SECURITY.md)
- [환경 진단](docs/ENVIRONMENT_REPORT.md)
- [세션 연속성 보고서](docs/SESSION_CONTINUITY_REPORT.md)
- [문제 해결](docs/TROUBLESHOOTING.md)
