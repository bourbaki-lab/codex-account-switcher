# Codex Account Switcher

[![macOS CI](https://github.com/wowhit11-source/codex-account-switcher/actions/workflows/ci.yml/badge.svg)](https://github.com/wowhit11-source/codex-account-switcher/actions/workflows/ci.yml)

A local macOS menu bar companion that switches between user-owned ChatGPT/Codex accounts while preserving the official app, local projects, and Codex task history.

Includes an experimental Claude desktop Code-tab dashboard and manual session-list carry-over between user-owned Claude accounts. It does not switch Claude credentials or convert Codex conversations into Claude conversations.

> **비공식 개인용 도구입니다.** 이 프로젝트는 OpenAI와 제휴·후원·승인 관계가 없으며 공식 ChatGPT/Codex 앱을 대체하거나 수정하지 않습니다. 본인이 소유하거나 정당하게 관리 권한을 가진 계정에만 사용하세요. 계정·인증정보 공유, 자동 계정 순환, 동시 다계정 실행 또는 서비스 사용량·요금제 제한 회피 목적의 사용을 지원하거나 권장하지 않습니다. OpenAI, ChatGPT, Codex 명칭은 호환 대상 식별을 위해서만 사용됩니다.

> **지원 환경:** macOS 15 이상이 설치된 **Apple Silicon(arm64) Mac 전용**입니다. 현재 빌드와 실환경 검증은 Apple Silicon에서만 완료했으며 Intel Mac(x86_64)은 지원하거나 검증하지 않았습니다.

## 주요 기능

- 공식 Codex App Server 로그인 흐름으로 여러 계정 등록·변경
- AES-GCM 암호화 프로필과 macOS Keychain 256비트 키
- 사용자 승인형 CLI 종료 후 원자적 인증 전환
- 파일 기반 인증 runtime preflight, keyring 차단과 host-managed 호환 모드
- 공식 앱 정상 종료·재실행
- 인증 교체 구간 무변경 검사, 세션 보호 스냅샷과 coordinator 자동 롤백
- 공식 App Server 기반 현재 `auth.json` 계정 및 프로필별 남은 한도·절대 초기화 일시·초기화권 수량/사용기한 표시, 팝오버가 열려 있는 동안 30초 자동 갱신
- 같은 task의 대화 맥락과 후속 작업 연속성 검증

## Claude 지원 (실험 기능)

메뉴 상단에서 `Codex | Claude` 탭을 선택할 수 있습니다. 목표는 공식 앱을 대체하지 않고 기존 프로젝트와 저장된 대화 맥락을 계속 사용하는 것입니다. 두 탭의 동작은 다릅니다.

| 항목 | Codex | Claude 데스크톱 Code 탭 |
| --- | --- | --- |
| 계정 변경 | 저장한 인증을 검증·교체하고 공식 앱 재실행 | 공식 Claude 앱에서 사용자가 직접 로그아웃·로그인 |
| 세션 유지 | 공유 Codex 홈과 기존 세션 보존 | 이전 계정의 로컬 세션 목록을 현재 계정으로 수동 가져오기 |
| 한도 표시 | 공식 App Server 응답 | Claude 앱이 남긴 마지막 로컬 사용률 기록과 기록 시각 |

Claude 사용 순서:

1. 전환 전에 스위처의 `Claude` 탭을 한 번 열어 계정 표시 정보를 확인합니다.
2. `계정 전환 안내`로 공식 Claude 앱을 열고 다른 본인 계정으로 로그인합니다.
3. 새 계정의 Code 세션을 하나 시작한 뒤 스위처에서 `새로고침`을 누릅니다.
4. 이전 계정 옆 `가져오기`를 누릅니다. 사용자 확인 후 Claude를 정상 종료하고 목록을 복사한 뒤 재실행합니다.

원본 대화 파일과 이전 계정 목록은 수정하지 않으며, 이미 존재하는 대상 목록은 건너뜁니다. `가져오기 되돌리기`는 가져온 뒤 내용이 바뀌지 않은 목록 파일만 제거합니다. **로그인만 바꿔서는 자동으로 가져오지 않습니다.** 계정 간 실제 후속 요청 성공은 아직 실환경 검증이 끝나지 않았습니다. 로컬 파일 형식이 바뀌면 동작하지 않을 수 있습니다.

Claude 인증 토큰을 저장·교체하거나 Anthropic API를 호출하지 않습니다. Anthropic/Claude와도 제휴·후원·승인 관계가 없는 비공식 도구입니다. Codex ↔ Claude 세션 변환이나 모델 내부 추론 상태 이전은 지원하지 않습니다.

## 최근 변경 및 검증 범위

- Codex의 새 `codex-cli/CodexCLI.app/Contents/MacOS/codex` 번들 경로를 탐지하며 packaged launcher와 기존 `Contents/Resources/codex`도 지원합니다.
- Claude 탭, 계정별 세션 목록 가져오기·되돌리기, 로컬 한도 기록 표시를 추가했습니다.
- 2026-09-30 통합 소스 기준 자동 테스트 60개 통과. 실제 설치된 Codex의 새 실행 경로 탐지도 확인했습니다.
- **현재 Codex 업데이트 환경의 계정 전환 end-to-end 검증은 미완료입니다.** 초기화 중 또는 인증 확인 실패 시 `원클릭 불가`가 표시될 수 있으며, 해당 화면의 지속 원인은 추가 확인이 필요합니다. 경로 수정이나 테스트 통과를 실제 전환 성공으로 간주하지 않습니다.

## 빠른 시작

요구 사항은 macOS 15 이상이 설치된 Apple Silicon(arm64) Mac과 Swift 6 도구체인입니다.

```bash
./scripts/test.sh
./scripts/build.sh
./scripts/install.sh
open "$HOME/Applications/Codex Account Switcher.app"
```

로컬 ad-hoc 서명 빌드는 최초 Keychain 승인을 요구할 수 있습니다. 같은 설치본에서 반복 승인을 피하려면 첫 창에서 `항상 허용`을 선택하세요.

## 문서

- [전체 한국어 사용 설명서](README_KO.md)
- [보안 정책](SECURITY.md)
- [아키텍처](docs/ARCHITECTURE.md)
- [공개 환경 검증 결과](docs/ENVIRONMENT_REPORT.md)
- [세션 연속성 검증](docs/SESSION_CONTINUITY_REPORT.md)
- [문제 해결](docs/TROUBLESHOOTING.md)
- [MIT 라이선스](LICENSE)

Codex의 `auth.json`은 계정 전환을 위해 읽고 암호화해 보관합니다. 브라우저 쿠키·MFA 코드와 공식 앱의 비공개 Keychain 항목은 읽거나 저장하지 않습니다.

> **중요:** 공식 데스크톱 앱이 `features.code_mode_host=true`로 호스트 관리 인증을 사용하는 버전에서는 호환 모드로 인증 전환을 시도합니다. 공식 호스트가 교체된 `auth.json`을 수용하지 않을 수 있으므로 재실행 후 실제 계정을 확인하고, 적용되지 않았을 때만 `Guided Switch`를 사용하세요.
