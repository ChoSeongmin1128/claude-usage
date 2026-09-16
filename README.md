# ClaudeUsage

Claude, Codex, Antigravity 사용량을 확인하는 macOS 메뉴바 앱입니다. 서비스별 사용량 한도와 갱신 예상 시각을 한곳에서 확인할 수 있습니다.

Anthropic, OpenAI, Google과 제휴하지 않은 독립 프로젝트입니다.

## 설치

- [안정 버전 2.5.3 다운로드](https://github.com/ChoSeongmin1128/claude-usage/releases/latest) · [변경 사항](docs/release-notes/2.5.3.md)
- [staging 2.5.3-stg.4 다운로드](https://github.com/ChoSeongmin1128/claude-usage/releases/tag/v2.5.3-stg.4)
- macOS 14 이상, Apple Silicon 및 Intel Mac 지원

DMG에서 앱을 Applications로 옮긴 뒤 Finder에서 직접 실행합니다. staging은 `ClaudeUsage-stg.app`으로 구분됩니다. 검증 중에는 한 채널만 실행하면 메뉴바 항목과 계정 상태를 구분하기 쉽습니다.

## 주요 기능

- 서비스별 사용량·남은 양·갱신 예상 시각 표시
- 현재 사용량 창과 주간 한도, 서비스가 제공하는 추가 quota 표시
- 배터리·원형·동심원 등 메뉴바 아이콘과 팝오버 표시 항목 설정
- 계정별 조회 경로와 인증 상태 확인
- 사용량 임계치 알림과 배터리 사용 시 갱신 빈도 조절
- 서명된 업데이트 안내, 백그라운드 다운로드와 사용자 선택에 따른 설치

## 계정 연결

| 서비스 | 시작 방법 | 조회 방식 |
|---|---|---|
| Claude | 설정에서 Chrome 가져오기·웹 로그인 또는 Claude Code 계정 선택 | 웹 세션과 Claude Code OAuth |
| Codex | Codex CLI에 로그인한 뒤 서비스 활성화 | CLI의 OAuth 자격증명으로 사용량 조회 |
| Antigravity | 공식 Antigravity 앱 또는 AGY CLI에 로그인한 뒤 서비스 활성화 | 선택한 제품의 현재 로그인 계정. CLI와 독립 앱 사이의 자동 전환 없음 |

서비스를 활성화하고 계정을 선택한 뒤 새로고침합니다. 명시적으로 계정을 바꾸거나 응답 계정이 다르면 이전 계정의 수치를 표시하지 않습니다. 일시적인 조회 실패에는 마지막 성공 값과 확인 시각을 유지하며, 실패를 0%로 바꾸지 않습니다.

Antigravity는 ‘조회 대상’에서 AGY CLI 또는 Antigravity 독립 앱을 선택합니다. 로그인 계정은 읽기 전용으로 표시하며, 로그인 변경은 해당 제품에서 진행합니다. 새로고침하면 확인된 계정과 사용량을 함께 갱신합니다. Google 계정 연결과 Antigravity IDE는 지원하지 않습니다.

Antigravity는 응답에 있는 quota만 표시합니다. 계정마다 한도의 종류와 주기가 다를 수 있습니다. 공식 AGY 설치·업데이트는 다음 조회에서 재검증하며 앱 재시작 없이 복구를 시도합니다.

인증과 데이터 출처의 상세 계약은 [인증 안내](docs/authentication-and-sources.md)와 [Antigravity 소스 설명](docs/antigravity-usage-sources.md)을 참고하세요.

## 개인정보와 진단

자격증명은 로컬 Keychain 또는 해당 CLI의 저장소에서 읽습니다. 계정 선택과 자격증명의 출처를 대조하며, 자동 조회 중 인증 창을 반복해서 띄우지 않습니다. 사용자가 직접 요청한 연결·가져오기에는 인증이 필요할 수 있습니다.

관리되는 AGY의 CSRF 토큰은 실행별로 생성하여 메모리에서만 보관합니다. 프로세스·실행 파일·포트가 바뀌면 다시 검증하며 외부 앱이나 빌려 쓰는 AGY를 종료하지 않습니다.

운영 진단에는 고정 오류 코드, 조회 경로, 소요 시간만 기록합니다. 토큰·계정 주소·원본 인증 응답은 기록 대상이 아닙니다. 사용량 조회는 각 서비스의 서버 또는 검증된 로컬 프로세스에 직접 요청합니다.

2.5.3에는 Codex의 현재 로그인 확인과 공식 CLI를 통한 인증 갱신, 자동 조회 주기와 AGY 검사 오류 전달 개선이 포함됩니다. 인증 경계와 복구 안내는 [Codex 사용량 소스](docs/codex-usage-sources.md)를 참고하세요.

## 업데이트

새 staging 후보는 다음 운영 예정 버전의 검증 회차(`X.Y.Z-stg.N`)로 구분합니다. 운영 버전은 검증을 마친 뒤 게시하며, 기존 `-staging` 배포본의 업데이트도 지원합니다.

Sparkle이 30분마다 해당 채널의 업데이트를 확인하고 다운로드·검증을 준비합니다. 설치는 사용자가 선택할 때 적용됩니다. 설정 → 업데이트에서 버전별 변경 사항과 설치 상태를 확인할 수 있습니다.

업데이트 DMG와 feed의 서명을 확인하며, 별도 ZIP 다운로드는 서명된 feed의 SHA-256과 대조합니다. 서명 실패 시의 복구와 키 교체 절차는 [배포 가이드](docs/RELEASE.md)에 설명되어 있습니다.

과거 버전에서의 설정 이전과 초기 채널의 예외는 [업데이트 호환 안내](docs/upgrade-compatibility.md)를 참고하세요.

## 개발

- Swift 6 언어 모드, Complete 동시성 검사
- Swift 6.2 이상을 지원하는 Xcode. 현재 검증 도구체인: Xcode 27.0
- SwiftUI, AppKit, URLSession, Sparkle 2.10
- ShellCheck 0.11.0과 Xcode 내장 swift-format

```bash
git clone https://github.com/ChoSeongmin1128/claude-usage.git
cd claude-usage
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage   -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

로컬 실행·서명 배포에는 개발자의 서명 설정이 필요합니다. 공식 배포용 개인키나 로컬 계정 설정은 저장소에 포함하지 않습니다. 테스트와 기여 절차는 [프로젝트 작업 방식](docs/PROJECT_WORKFLOW.md)을 참고하세요.

## 알려진 제한

- 서비스의 인증·사용량 인터페이스가 바뀌면 추가 대응이 필요할 수 있습니다.
- AGY의 초기 인증이 지연되면 마지막 사용량을 유지하며 재조회를 안내합니다.
- macOS의 메뉴바 표시 정책은 앱별 표시 설정의 영향을 받습니다. 설치 앱은 Finder에서 직접 실행하세요.

## 문서

- [인증과 데이터 출처](docs/authentication-and-sources.md)
- [Codex 로그인 확인·인증 갱신·복구 계약](docs/codex-usage-sources.md)
- [Antigravity 실행·계정·복구 계약](docs/antigravity-usage-sources.md)
- [개발·기여·검증 절차](docs/PROJECT_WORKFLOW.md)
- [배포와 업데이트 복구](docs/RELEASE.md)
- [Homebrew 배포 설계](docs/homebrew-distribution.md) — 도입 검토 중이며 아직 설치 명령을 제공하지 않습니다.
- [유지보수 현황](HANDOFF.md)
- [로드맵](WORK_PLAN.md)

## 라이선스

원본 소스 코드와 문서는 [MIT License](LICENSE)로 제공합니다. 외부 구성 요소의 조건과 공급사 로고·상표의 권리 범위는 [Third-party notices](THIRD_PARTY_NOTICES.md)를 참고하세요.
