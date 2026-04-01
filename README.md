# ClaudeUsage

`Claude`를 중심으로 `Codex`, `Gemini`, `Antigravity`까지 확장할 수 있는 macOS 메뉴바 사용량 추적 앱입니다.

현재 구현 기준으로는 `Claude`와 `Codex`가 실동작 대상이고, `Gemini`와 `Antigravity`는 provider shell과 설정 진입점이 먼저 준비되어 있습니다.

## 현재 방향

- Claude 중심 multi-provider menubar app
- 기본 노출은 `Claude만 활성화`
- 사용자가 원할 때 다른 provider를 추가 활성화
- 메뉴바에서 퍼센트, 리셋 시간, 아이콘 스타일을 조합해 빠르게 상태 확인
- 팝오버에서 상세 사용량, 인증 상태, 경로 상태, organization 상태 확인

## 구현된 핵심 기능

- `Claude` 현재 세션 / 주간 사용량 표시
- `Codex` 현재 / 주간 / 크레딧 표시
- 메뉴바 아이콘 스타일
  - 배터리바
  - 원형
  - 동심원
  - 이중 배터리
  - 좌우 배터리
- `현재 세션 / 주간 / 동시` 기준 선택
- 팝오버 기본/간소화 모드
- provider overview + 전환 구조
- 사용량 임계치 알림
- Chrome cookie import 기반 `sessionKey` 자동 추출
- Web login 기반 `sessionKey` 추출
- Claude Code OAuth credential / metadata 탐지
- `Messages header fallback` 수동/자동 보조 복구
- GitHub Releases 기반 수동 업데이트 확인
- Claude 인증 탭의 단계형 빠른 시작 wizard

## 인증 경로

Claude는 한 가지 방식만 쓰지 않습니다.

- `Chrome import`
  - Chrome 로그인 상태에서 `Cookies` DB를 읽어 `sessionKey` 자동 추출
- `웹 로그인`
  - 내장 로그인 창에서 `claude.ai` 로그인 후 sessionKey 추출
- `수동 sessionKey 입력`
  - 고급 설정에서 값만 직접 입력
- `OAuth / CLI credential`
  - Claude Code 자격증명 파일 또는 키체인에서 OAuth 토큰과 profile metadata 감지

즉, `Web(session key/cookie)`와 `OAuth`를 모두 주경로로 다룹니다.

## 설치

### 릴리즈 다운로드

1. [ClaudeUsage.zip 다운로드](https://github.com/ChoSeongmin1128/claude-usage/releases/latest/download/ClaudeUsage.zip)
2. 압축 해제 후 `ClaudeUsage.app`을 원하는 위치로 이동
3. 처음 실행 시 우클릭 → 열기, 또는 시스템 설정 → 개인정보 보호 및 보안 → `그래도 열기`

### 소스에서 빌드

```bash
git clone https://github.com/ChoSeongmin1128/claude-usage.git
cd claude-usage
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Debug -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

## 설정

앱 실행 후 메뉴바 아이콘 클릭 → `설정`

- `공통`
  - 표시 방식
  - 새로고침 / 전원
  - 알림
  - 앱 설정
- `Claude`
  - 인증
  - 빠른 시작 wizard
  - 일반 / 고급 및 진단 분리
  - 표시
  - 상태
  - organization
  - 표시 항목
  - 알림
- `Codex`
  - 인증
  - 표시
  - 표시 항목
  - 알림
- `Gemini`, `Antigravity`
  - provider shell 준비됨
  - 현재는 coming-soon 패널

## 프로젝트 구조

```text
ClaudeUsage/
├── App/                    # AppDelegate, app shell, service selection helper
├── Auth/                   # Chrome import, sessionKey 추출, keychain store
├── Models/                 # Settings, usage, provider state, fetch models
├── Services/               # Claude/Codex API, notifications, updates
├── Utilities/              # 아이콘 렌더링, 색상, 시간 포맷, 로깅
├── ViewModels/             # Settings/Popover/MenuBar 상태 객체
└── Views/                  # Settings, Popover, Login, usage components
```

## 기술/설계 메모

- Swift 5
- macOS 14+
- SwiftUI + AppKit
- 기본 방향은 `포트/어댑터 + 앱 서비스 + 얇은 UI 상태 계층`
- 교과서형 클린 아키텍처보다는, provider/fetch/auth 경계를 먼저 세우는 방향

## 현재 한계

- `Gemini`, `Antigravity`는 아직 fetch/auth 구현 전입니다.
- 자동 업데이트는 아직 Sparkle 전환 전입니다.
- 메뉴바와 refresh 경로는 runtime-capable provider 기준으로 정리 중이지만, 일부 내부 구조는 여전히 `Claude/Codex` 하드코딩이 남아 있습니다.
- `Gemini`, `Antigravity`는 아직 설정 shell까지만 연결되어 있습니다.

## 문서

- 작업 계획: [WORK_PLAN.md](WORK_PLAN.md)
- 구조 분석: [docs/2026-04-01-architecture-review.md](docs/2026-04-01-architecture-review.md)
- Apple Developer / 업데이트: [apple-developer-update.md](apple-developer-update.md)

## 라이선스

MIT License
