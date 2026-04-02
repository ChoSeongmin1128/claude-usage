# ClaudeUsage

`Claude`를 중심으로 `Codex`, `Gemini`, `Antigravity`까지 확장할 수 있는 macOS 메뉴바 사용량 추적 앱입니다.

현재 구현 기준으로는 `Claude`, `Codex`, `Gemini`, `Antigravity`가 모두 런타임 provider로 연결되어 있습니다. 다만 완성도는 `Claude`가 가장 높고, 나머지는 provider별 환경 의존성과 UX 마감이 더 남아 있습니다.

## 현재 방향

- Claude 중심 multi-provider menubar app
- 기본 노출은 `Claude만 활성화`
- 사용자가 원할 때 다른 provider를 추가 활성화
- `Web(sessionKey/cookie)`와 `OAuth`를 함께 다루는 Claude 중심 인증 구조
- 메뉴바에서 퍼센트, 리셋 시간, 아이콘 스타일을 조합해 빠르게 상태 확인
- 팝오버에서 상세 사용량, 인증 상태, 경로 상태, organization 상태 확인

## 구현된 핵심 기능

- `Claude` 현재 세션 / 주간 사용량 표시
- `Codex` 현재 / 주간 / 크레딧 표시
- `Gemini` quota 기반 사용량 표시
- `Antigravity` local language server probe 기반 사용량 표시
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
- Claude 인증 상태의 `세션키 / OAuth / organization / metadata` 분리 표시
- `Messages header fallback` 수동/자동 보조 복구
- `Claude Code CLI OAuth` 안내와 상태 표시
- GitHub Releases 기반 수동 업데이트 확인
- Claude 인증 탭의 단계형 빠른 시작 wizard

## 인증 경로

Claude는 한 가지 방식만 쓰지 않습니다. 현재 앱은 아래 경로를 함께 가집니다.

- `Claude Code CLI OAuth`
  - `claude login` 이후 OAuth 토큰과 profile metadata를 읽음
  - 세션키 경로가 불안정할 때 권장되는 경로
- `Chrome import`
  - Chrome 로그인 상태에서 `Cookies` DB를 읽어 `sessionKey` 자동 추출
- `웹 로그인`
  - 내장 로그인 창에서 `claude.ai` 로그인 후 sessionKey 추출
- `수동 sessionKey 입력`
  - 고급 설정에서 값만 직접 입력
- `OAuth / CLI credential`
  - Claude Code 자격증명 파일 또는 키체인에서 OAuth 토큰과 profile metadata 감지

즉, `Web(session key/cookie)`와 `OAuth`를 모두 주경로로 다룹니다. sessionKey는 제거 대상이 아니라 주경로 중 하나이고, 세션 경로가 흔들릴 때 `CLI OAuth`를 같이 준비하는 방향을 권장합니다.

## Claude 인증 권장 순서

일반적으로는 아래 순서가 가장 안전합니다.

1. `Claude Code CLI OAuth`
   - `brew install --cask claude-code`
   - `claude login`
   - 앱의 `설정 > Claude > 인증 > 상태 새로고침`
2. `Chrome 가져오기`
   - Chrome에서 `claude.ai` 로그인 상태일 때 sessionKey 자동 추출
3. `웹 로그인`
   - 내장 로그인 창에서 sessionKey 자동 추출
4. `수동 sessionKey`
   - 고급 설정의 마지막 수단

세션키 경로는 Cloudflare/429/서버 상태의 영향을 받을 수 있습니다. 따라서 sessionKey만으로 충분히 동작하더라도, 장기적으로는 `CLI OAuth`를 같이 준비하는 편이 더 안정적입니다.

## 보조 사용량 복구

Claude는 `Messages header fallback` 기반 보조 사용량 복구를 지원합니다.

- 기본값은 `꺼짐`
- `수동 보조`
  - 사용자가 설정에서 직접 복구 테스트를 실행
- `자동 보조`
  - OAuth 사용량 조회가 실패할 때만 자동 시도
  - 기본 임계값은 `20%`
  - 현재 사용량이 이 값보다 낮으면 자동 보조를 시도하지 않음

이 기능은 인증 경로가 아니라 `복구 옵션`입니다. 기본 polling 경로를 대체하는 용도가 아닙니다.

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
  - 일반 로그인 경로 / Claude Code CLI OAuth / 고급 및 진단 분리
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
  - 런타임 provider 연결됨
  - 환경 감지 / 표시 / 팝오버 / 알림까지 연결됨
  - provider별 UX 마감은 Claude보다 덜 끝난 상태

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

- 자동 업데이트는 아직 Sparkle 전환 전입니다.
- 메뉴바와 refresh 경로는 runtime-capable provider 기준으로 많이 정리됐지만, 일부 내부 구조는 여전히 `Claude/Codex` 중심 흔적이 남아 있습니다.
- `Gemini`, `Antigravity`는 런타임 연결은 됐지만 provider별 UX, 오류 문구, 환경 안내는 Claude보다 덜 다듬어져 있습니다.
- first-run onboarding과 권한 설명은 아직 더 다듬어야 합니다.

## 문서

- 작업 계획: [WORK_PLAN.md](WORK_PLAN.md)
- 구조 분석: [docs/2026-04-01-architecture-review.md](docs/2026-04-01-architecture-review.md)
- 인증/소스 설명: [docs/authentication-and-sources.md](docs/authentication-and-sources.md)
- Apple Developer / 업데이트: [apple-developer-update.md](apple-developer-update.md)

## 라이선스

MIT License
