# ClaudeUsage

`Claude`를 중심으로 `Codex`, `Gemini`, `Antigravity`까지 확장할 수 있는 macOS 메뉴바 사용량 추적 앱입니다.

현재 구현 기준으로는 `Claude`, `Codex`, `Gemini`, `Antigravity`가 모두 런타임 provider로 연결되어 있습니다. 다만 완성도는 `Claude`가 가장 높고, 나머지는 provider별 환경 의존성과 UX 마감이 더 남아 있습니다.

## 현재 방향

- Claude 중심 multi-provider menubar app
- 기본 노출은 `Claude만 활성화`
- 사용자가 원할 때 다른 provider를 추가 활성화
- `Web(sessionKey/cookie)`와 `OAuth`를 함께 다루는 Claude 중심 인증 구조
- `ClaudeSetupPresentation + RuntimeProviderSnapshot` 기반의 공통 setup/runtime truth
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
- Sparkle 패키지 통합 + appcast 미설정 시 GitHub Release fallback
- notarization용 release 스크립트 골격 추가
- Claude 인증 탭의 단계형 빠른 시작 wizard
- provider별 refresh/backoff/loading/error 상태를 runtime catalog로 통합
- `Gemini`, `Antigravity`의 `감지됨 / 갱신 가능 / 연결 가능 / 첫 성공 조회` 상태 분리
- `ClaudeUsageTests` 단위 테스트 타깃 추가

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

앱 안에서 처음 시도할 순서는 아래와 같습니다.

1. `Chrome 가져오기`
   - Chrome에서 `claude.ai` 로그인 상태일 때 sessionKey 자동 추출
2. `웹 로그인`
   - 내장 로그인 창에서 sessionKey 자동 추출
3. `수동 sessionKey`
   - 고급 설정의 마지막 수단

장기적으로 더 안정적인 경로는 아래입니다.

1. `Claude Code CLI OAuth`
   - `brew install --cask claude-code`
   - `claude login`
   - 앱의 `설정 > Claude > 인증 > 상태 새로고침`
2. `Chrome 가져오기`
3. `웹 로그인`
4. `수동 sessionKey`

세션키 경로는 Cloudflare/429/서버 상태의 영향을 받을 수 있습니다. 따라서 sessionKey만으로 충분히 동작하더라도, 장기적으로는 `CLI OAuth`를 같이 준비하는 편이 더 안정적입니다.

`설정`, `standalone wizard`, `메뉴바`, `팝오버`는 이제 같은 setup truth를 공유합니다. 즉 Claude의 완료 상태는 `자격 준비 -> 첫 성공 조회 -> organization readiness` 순서로만 올라가고, 한 화면만 따로 완료처럼 보이는 경로를 줄이는 방향으로 정리했습니다.

## 로컬 데이터와 권한

이 앱은 가능한 한 로컬 우선으로 동작합니다. 다만 provider별로 읽는 위치와 이유를 사용자가 이해할 수 있어야 합니다.

- `Claude sessionKey`
  - Chrome 쿠키 DB 또는 내장 로그인 창에서 읽습니다.
  - 세션키 값은 Keychain에 저장합니다.
- `Claude Code OAuth`
  - `~/.claude` 자격 파일과 Keychain에 있는 Claude Code 자격을 읽습니다.
  - OAuth 토큰과 profile metadata를 이용해 `organization`, `subscription`, `rate limit tier`를 판단합니다.
- `Gemini`
  - `~/.gemini/oauth_creds.json`, `settings.json`, 설치된 Gemini CLI 경로를 읽습니다.
  - 필요 시 Google Cloud project를 탐색해 quota 요청의 정확도를 높입니다.
  - 감지는 하되 자동 활성화하지 않습니다.
- `Antigravity`
  - 로컬 language server 프로세스와 connect 포트를 찾고, 로컬 API에 연결합니다.
  - 실행 중이지만 연결 토큰이나 포트가 없으면 바로 그 상태를 표시합니다.
  - 감지는 하되 자동 활성화하지 않습니다.

즉, 브라우저 쿠키와 CLI credential은 “로그인 대행”이 아니라 “이미 로그인된 로컬 상태를 읽어 menubar에서 빠르게 신호를 주기 위한 입력”입니다.

## 현재 업데이트 상태

- 현재 앱은 `Sparkle 패키지`를 이미 포함합니다.
- 현재 구현은 `Sparkle 앱내 확인 + GitHub Release fallback` 구조입니다.
- 여기서 `Sparkle 준비됨`의 기준은 `유효한 SUFeedURL + 유효한 SUPublicEDKey` 입니다.
- `NOTARY_PROFILE` 은 런타임 readiness가 아니라 release 스크립트 실행 전제입니다.
- `appcast(feed)`와 `공개키`가 준비되지 않은 개발 빌드에서는 `GitHub Release fallback`으로 동작합니다.
- 설정 화면의 `업데이트` 섹션에서 지금 빌드가 `Sparkle 통합`, `appcast 준비`, `공개키 준비` 중 어디까지 와 있는지 직접 볼 수 있습니다.
- 릴리즈 산출물은 [build-notarize-release.sh](/Users/seongmin/Personal/ClaudeUsage/Scripts/build-notarize-release.sh) 로 `archive -> zip -> notarize -> staple -> stapled zip 재생성` 흐름을 실행할 수 있습니다.
- Sparkle 채널용 appcast는 [generate-sparkle-appcast.sh](/Users/seongmin/Personal/ClaudeUsage/Scripts/generate-sparkle-appcast.sh) 로 생성할 수 있고, `DOWNLOAD_BASE_URL` 을 주지 않으면 `SUFeedURL` 의 디렉토리에서 유도합니다.
- Release 빌드는 [Release.xcconfig](/Users/seongmin/Personal/ClaudeUsage/Config/Release.xcconfig) 를 기본으로 읽고, 로컬 비밀값은 `Config/Sparkle.release.local.xcconfig` 에서 덮어씁니다. 이 로컬 파일에는 `SUFeedURL`, `SUPublicEDKey`, `NOTARY_PROFILE` 을 함께 둘 수 있습니다.

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
  - 일반 로그인 경로와 고급/진단 분리
  - `현재 인증 상태`, `상태 새로고침`, `웹 로그인 다시 열기`, `로그아웃`
  - `상세 인증 상태`, `수동 sessionKey`, `복구 및 도움말`은 고급 설정 안쪽
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
  - 환경 감지 / refresh 가능 여부 / 첫 성공 조회 상태를 구분해서 표시
  - 자동 활성화는 하지 않고, 사용자가 직접 켜는 정책 유지
  - provider별 UX 마감은 Claude보다 덜 끝난 상태

## 테스트

현재 레포에는 `ClaudeUsageTests` 타깃이 포함되어 있고, 아래 범위를 단위 테스트로 검증합니다.

- `SetupCompletionPolicy`
- `ClaudeSourcePlanner`
- `RefreshOrchestration` / `RuntimeProviderRefreshCoordinator`
- `ProviderEnvironmentDetector` signal 해석

CLI 기준으로는 `build-for-testing` 과 테스트 번들 직접 실행이 가장 안정적입니다. 이 앱은 메뉴바 앱 특성 때문에 `xcodebuild test` 가 macOS host runner에서 대기할 수 있으므로, 자동화에서는 테스트 번들 실행 경로를 우선 쓰는 편이 안전합니다.

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

- Sparkle 패키지는 이미 통합됐지만, 현재 구현은 `앱 내부 Sparkle 확인 + GitHub Release fallback` 기준입니다.
- appcast/feed와 공개키가 없는 개발 빌드에서는 GitHub Release 엔진으로 fallback됩니다.
- `Sparkle 준비됨`은 `feed + 공개키` 기준이고, notarization 계정 프로필은 배포 스크립트 전제이므로 설정 화면의 readiness와 별개입니다.
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
