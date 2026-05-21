# ClaudeUsage

`Claude`를 중심으로 `Codex`, `Gemini`, `Antigravity`까지 확장할 수 있는 macOS 메뉴바 사용량 추적 앱입니다.

현재 구현 기준으로는 `Claude`, `Codex`, `Gemini`, `Antigravity`가 모두 런타임 provider로 연결되어 있습니다. `Antigravity`는 앱 로컬 API, Google OAuth 원격 조회, CLI 감지, multi-account 설정 UX까지 런타임 provider 흐름에 맞춰 정리되어 있습니다.

## 현재 방향

- Claude 중심 multi-provider menubar app
- 기본 노출은 `Claude만 활성화`
- 사용자가 원할 때 다른 provider를 추가 활성화
- `Web(sessionKey/cookie)`와 `OAuth`를 함께 다루는 Claude 중심 인증 구조
- `ClaudeSetupPresentation + RuntimeProviderSnapshot` 기반의 공통 setup/runtime truth
- 메뉴바에서 퍼센트, 갱신 예상 시간, 아이콘 스타일을 조합해 빠르게 상태 확인
- 팝오버에서 상세 사용량, 인증 상태, 경로 상태, organization 상태 확인

## 구현된 핵심 기능

- `Claude` 현재 세션 / 주간 사용량 표시
- `Codex` 현재 / 주간 / 크레딧 표시
- `Gemini` quota 기반 사용량 표시
- `Antigravity` local language server / Google OAuth 원격 quota 기반 사용량 표시
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
- notarization + GitHub Release / Pages appcast 게시 스크립트 정리
- DMG/Downloads 실행 시 Applications 이동 안내
- 설치 후 남은 DMG 휴지통 이동 안내
- 기존 설치본 실행 중 이동 시 중복 실행 방지
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
  - 자동 모드는 로컬 API를 먼저 쓰되, 로컬 응답에 quota window가 없으면 Google OAuth 원격 조회로 보완합니다.
  - Antigravity CLI는 `agy` 바이너리의 실행 가능 여부, `~/.gemini/antigravity-cli` 상태 디렉터리, 공식 설정 파일인 `settings.json` 존재 여부를 분리해 감지합니다.
  - CLI 자체의 OS secure keyring은 직접 읽지 않고, ClaudeUsage 전용 Google OAuth 연결로 원격 quota API를 조회합니다.
  - Google OAuth client 정보는 환경변수를 우선하고, 없으면 설치된 `Antigravity.app`의 2.0 `language_server` 번들까지 탐색합니다.
  - OAuth 토큰은 `~/Library/Application Support/ClaudeUsage/Antigravity/oauth_creds.json`에 `0600` 권한으로 저장하고, 상위 디렉터리는 `0700`으로 맞춥니다.
  - 여러 Google 계정은 같은 디렉터리의 `oauth_accounts.json`에 `0600` 권한으로 보관하고, 선택한 계정은 기존 `oauth_creds.json`에도 반영해 기존 사용자/코드 경로와 호환합니다.
  - 기존에 잘못 저장된 Antigravity Keychain 항목은 앱 시작 시 사용자 프롬프트 없이 읽히는 경우에만 파일 저장소로 마이그레이션한 뒤 제거합니다. 상태 확인과 refresh 경로에서는 Keychain을 건드리지 않습니다.
  - 실행 중이지만 연결 토큰이나 포트가 없으면 바로 그 상태를 표시합니다.
  - 감지는 하되 자동 활성화하지 않습니다.

즉, 브라우저 쿠키와 CLI credential은 “로그인 대행”이 아니라 “이미 로그인된 로컬 상태를 읽어 menubar에서 빠르게 신호를 주기 위한 입력”입니다.

## 현재 업데이트 상태

- 현재 앱은 `Sparkle 패키지`를 이미 포함합니다.

- 현재 구현은 `Sparkle 백그라운드 다운로드/설치 준비 + GitHub Release fallback` 구조입니다.
- 여기서 `Sparkle 준비됨`의 기준은 `유효한 SUFeedURL + 유효한 SUPublicEDKey` 입니다.
- Sparkle 준비 경로에서는 업데이트 확인을 끌 수 없고 30분마다 자동 확인합니다.
- Sparkle 자동 업데이트는 다운로드/검증까지만 앱이 준비하고, 실제 교체와 재실행은 popover 설치 버튼을 누를 때 진행합니다.
- `NOTARY_PROFILE` 은 런타임 readiness가 아니라 release 스크립트 실행 전제입니다.
- `appcast(feed)`와 `공개키`가 준비되지 않은 개발 빌드에서는 `GitHub Release fallback`으로 동작합니다.
- release build는 채널별 `SUFeedURL` 을 앱에 넣기 때문에 staging 산출물을 prod에 그대로 재사용하지 않습니다.
- 2026-05-02 확인 기준 prod/staging appcast는 모두 `2.0.15` (`sparkle:version` `20015`) 를 가리킵니다.
- 설정 화면의 `업데이트` 섹션에서 지금 빌드가 `Sparkle 통합`, `appcast 준비`, `공개키 준비` 중 어디까지 와 있는지 직접 볼 수 있습니다.
- 릴리즈 산출물은 [build-notarize-release.sh](Scripts/build-notarize-release.sh) 로 `archive -> zip -> notarize -> staple -> DMG 생성/공증` 흐름을 실행할 수 있습니다. 사내 배포용 signed-only 산출물은 `RELEASE_DISTRIBUTION=internal` 로 같은 스크립트에서 생성합니다.
- Sparkle 채널용 appcast는 [generate-sparkle-appcast.sh](Scripts/generate-sparkle-appcast.sh) 로 생성합니다.
- GitHub Pages 채널 구조는 다음을 기준으로 합니다.
  - `prod`: `https://choseongmin1128.github.io/claude-usage/appcast.xml`
  - `staging`: `https://choseongmin1128.github.io/claude-usage/channels/staging/appcast.xml`
- `gh-pages` 브랜치는 코드 브랜치가 아니라 위 appcast를 배포하는 정적 호스팅 브랜치입니다.
- 현재 원격 코드 브랜치는 `main` 기준이고, `dev`/`stg` 코드 브랜치는 운용하지 않습니다. staging은 `vX.Y.Z-staging` prerelease와 staging appcast channel로 처리합니다.
- [publish-release.sh](Scripts/publish-release.sh) 는 stable 릴리스면 `prod`, prerelease 면 `staging` 채널을 기본값으로 잡고, GitHub Release 업로드 뒤 `gh-pages` 채널 appcast도 같이 갱신합니다.
- Release 빌드는 [Release.xcconfig](Config/Release.xcconfig) 를 기본으로 읽고, 로컬 비밀값은 `Config/Sparkle.release.local.xcconfig` 에서 덮어씁니다. 이 로컬 파일은 git에 올리지 않습니다.
- 배포/계정/브랜치 운영 규칙은 [프로젝트 작업 방식](docs/PROJECT_WORKFLOW.md) 문서가 기준입니다.

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

1. [ClaudeUsage.dmg 다운로드](https://github.com/ChoSeongmin1128/claude-usage/releases/latest/download/ClaudeUsage.dmg)
2. DMG를 열고 `ClaudeUsage.app`을 `Applications`로 이동
3. 처음 실행 시 우클릭 → 열기, 또는 시스템 설정 → 개인정보 보호 및 보안 → `그래도 열기`

DMG, Downloads, App Translocation 같은 불안정한 위치에서 실행하면 앱이 `Applications` 폴더로 이동할지 묻습니다. 앱 안의 이동 버튼을 사용하면 기존 설치본이 실행 중인지 먼저 확인하고, 중복 실행을 막기 위해 기존 앱 종료를 요청한 뒤 이동합니다. Finder에서 DMG의 앱을 직접 끌어다 놓는 경우에는 macOS 파일 복사만 일어나므로 새 앱이 자동 실행되지는 않습니다.

앱이 `Applications`에서 정상 실행되고 설치 DMG가 아직 마운트되어 있으면, 설치 파일을 휴지통으로 이동할지 묻습니다. DMG가 이미 언마운트되었거나 삭제된 경우에는 이 안내가 뜨지 않습니다.

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
- `Gemini`
  - 런타임 provider 연결됨
  - 환경 감지 / refresh 가능 여부 / 첫 성공 조회 상태를 구분해서 표시
  - 자동 활성화는 하지 않고, 사용자가 직접 켜는 정책 유지
  - provider별 UX 마감은 Claude보다 덜 끝난 상태
- `Antigravity`
  - 앱 로컬 API / Google OAuth 원격 조회 / 자동 fallback 모드를 분리
  - 자동 모드에서 로컬 앱이 연결됐지만 quota가 비어 있으면 OAuth 원격 조회로 보완
  - CLI 설치/설정 감지와 OAuth 연결 상태를 별도 badge로 표시
  - permission denied와 서버 장애를 구분해 표시
  - 자동 활성화는 하지 않고, 사용자가 직접 켜는 정책 유지

## 테스트

현재 레포에는 `ClaudeUsageTests` 타깃이 포함되어 있고, 아래 범위를 단위 테스트로 검증합니다.

- `SetupCompletionPolicy`
- `ClaudeSourcePlanner`
- `RefreshOrchestration` / `RuntimeProviderRefreshCoordinator`
- `ProviderEnvironmentDetector` signal 해석
- `UsageWindowAlertPolicy` 임계값 알림 정책
- `NotificationManager` 알림 발송 판단
- `TimeFormatter` 갱신 예상 시각 포맷
- `UpdateRuntimeState` 사용자 표시 문구
- 설치 위치 / DMG 정리 정책
- popover layout 안정성 정책

현재 기본 검증 명령은 아래와 같습니다.

```bash
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -destination 'platform=macOS' test
```

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

## 브랜치와 채널

- 현재 원격 코드 브랜치는 `main` 기준입니다.
- `gh-pages` 는 Sparkle appcast / Pages 용 브랜치라서, `stg` 역할로 보면 안 됩니다.
- staging은 브랜치가 아니라 release channel입니다. `main`의 최신 릴리스 후보를 `vX.Y.Z-staging` prerelease와 `/channels/staging/appcast.xml` 로 게시합니다.
- prod는 staging 검증이 끝난 버전만 `vX.Y.Z` stable release와 root `/appcast.xml` 로 게시합니다.
- 세부 절차와 `gh auth switch` 계정 기준은 [프로젝트 작업 방식](docs/PROJECT_WORKFLOW.md)을 따릅니다.

## 기술/설계 메모

- Swift 5
- macOS 14+
- SwiftUI + AppKit
- 기본 방향은 `포트/어댑터 + 앱 서비스 + 얇은 UI 상태 계층`
- 교과서형 클린 아키텍처보다는, provider/fetch/auth 경계를 먼저 세우는 방향

## 현재 한계

- release build는 Sparkle appcast를 기준으로 업데이트하며, 새 버전이 있으면 백그라운드에서 다운로드/검증 후 popover 설치 버튼만 노출합니다. 개발 빌드는 appcast/feed와 공개키가 없으면 GitHub Release 엔진으로 fallback됩니다.
- `Sparkle 준비됨`은 `feed + 공개키` 기준이고, notarization 계정 프로필은 배포 스크립트 전제이므로 런타임 readiness와 별개입니다.
- 메뉴바와 refresh 경로는 runtime-capable provider 기준으로 많이 정리됐지만, 일부 내부 구조는 여전히 `Claude/Codex` 중심 흔적이 남아 있습니다.
- `Gemini`은 런타임 연결은 됐지만 provider별 UX, 오류 문구, 환경 안내는 Claude/Antigravity보다 덜 다듬어져 있습니다.
- `Antigravity`는 로컬 앱 API와 Google OAuth 원격 quota 조회를 모두 지원하지만, 공식 API가 공개 안정화된 상태는 아니므로 원격 endpoint 변경 시 보강이 필요할 수 있습니다.
- first-run onboarding과 권한 설명은 아직 더 다듬어야 합니다.

## 문서

- 작업 계획: [WORK_PLAN.md](WORK_PLAN.md)
- 인증/소스 설명: [docs/authentication-and-sources.md](docs/authentication-and-sources.md)
- Antigravity 사용량 소스: [docs/antigravity-usage-sources.md](docs/antigravity-usage-sources.md)
- 프로젝트 작업 방식: [docs/PROJECT_WORKFLOW.md](docs/PROJECT_WORKFLOW.md)
- 배포 가이드: [docs/RELEASE.md](docs/RELEASE.md)
- Apple Developer / 업데이트: [apple-developer-update.md](apple-developer-update.md)

## 라이선스

MIT License
