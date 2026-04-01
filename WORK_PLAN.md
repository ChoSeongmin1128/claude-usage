# ClaudeUsage 작업 계획

최종 갱신: 2026-04-02 (7차)

이 문서는 현재 레포의 실행 계획 문서입니다. 계획이 바뀌거나 조사 결과가 추가될 때마다 이 파일을 갱신합니다.

## 1. 현재 판단

- 제품 포지셔닝은 `multi-provider`입니다.
- 우선 지원 대상은 `Claude + Codex + Gemini + Antigravity`이며, 이 중 Claude가 메인입니다.
- `Antigravity`는 `Gemini`와 별개 provider로 취급합니다.
- 기본 노출은 Claude만 켜진 상태로 시작하고, 사용자가 필요 시 다른 provider를 추가하는 구조가 맞습니다.
- 현재 앱은 기능이 부족한 수준이 아니라 구조가 부실합니다.
- 핵심 책임이 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift), [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift), [ClaudeAPIService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/ClaudeAPIService.swift), [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift)에 과도하게 집중되어 있습니다.
- 현재 인증 UX는 사용자가 이해하기 어렵고 실패에 취약합니다. 특히 [LoginWebView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/LoginWebView.swift)는 웹 로그인, 쿠키 감시, 스토리지 추출, usage 페이지 강제 이동까지 한 화면에서 처리하고 있습니다.
- 보안 관점에서도 [KeychainManager.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/KeychainManager.swift)가 실제 Keychain이 아니라 `UserDefaults`에 세션 키를 저장하고 있어 설계가 부적절합니다.
- Claude 사용량 수집은 현재 `/api/oauth/usage`와 웹 세션 방식이 섞여 있으나, source planner, fallback policy, profile metadata cache가 빈약합니다.
- 2026-04-02 현재 6차 통합 결과로, 실제 코드에는 `ClaudeSourcePlanner`, `Messages header fallback fetcher`, profile metadata store, Keychain 마이그레이션, Chrome cookie import, 설정용/팝오버용 view model 분리, provider state catalog, settings provider registry, `ServiceSelectionHelper`가 들어갔고 macOS Debug 빌드가 통과합니다.
- Chrome browser import는 더 이상 탐지/안내 중심이 아니라, 실제 `Chrome Cookies DB` 임시 복사 + `Safe Storage` 기반 복호화 + `sessionKey` 추출 경로가 들어갔습니다.
- 설정 화면은 `Common / Claude / Codex / Gemini / Antigravity` registry 기반 shell로 바뀌었고, `Gemini` / `Antigravity`는 coming-soon 패널과 enable 상태 저장까지 들어갔습니다.
- `Claude` profile metadata는 더 이상 저장만 하지 않고 설정 화면에서 실제로 확인할 수 있습니다.
- `providerStates`는 단순 저장 shell이 아니라 실제 `AppDelegate`의 provider enable/disable 전환 감지 기준으로 들어오기 시작했습니다.
- `ClaudeProfileMetadataStore`는 actor + 내부 DTO 구조로 단순화했고, `ClaudeProfileMetadata` 자체는 `Codable`에서 분리해 Swift 6 경고를 제거했습니다.
- 설정의 `일반` 영역에는 provider별 실동작/설정 shell 상태를 한눈에 보여주는 overview 카드가 추가됐습니다.
- 메뉴바 조합 로직은 [MenuBarStatusComposer.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Utilities/MenuBarStatusComposer.swift) 로 분리됐고, provider별 표시 옵션도 [ProviderMenuBarDisplayConfig](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/ProviderStateModels.swift) 로 묶기 시작했습니다.
- `Gemini` / `Antigravity` 같은 shell provider가 메뉴바/타이머 런타임 서비스로 잘못 취급되던 경로는 [ServiceSelectionHelper.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ServiceSelectionHelper.swift) 에서 runtime-capable provider만 세도록 정리했습니다.
- 다만 팝오버의 하이브리드 구조와 multi-provider fetch/menu glue는 아직 더 분해해야 합니다.

## 2. 참고 레포에서 가져올 방향

### Claude-Usage-Tracker

- 가져올 것
- `UsageRefreshCoordinator` 같은 coordinator 분리
- `APIServiceProtocol` 기반 서비스 추상화
- `SetupWizardView`의 단계형 초기 설정 UX
- `ClaudeCodeSyncService`의 CLI credential 우선 탐색 체인
- 한계
- 최신 tracker의 `Messages header fallback`은 반드시 구현 대상으로 가져옵니다.
- 다만 기본 polling의 primary source로 둘지 여부는 별도 정책 문제로 다룹니다.

### CodexBar

- 가져올 것
- `ProviderFetchPlan` / `ProviderFetchPipeline`
- `ClaudeSourcePlanner`
- provider별 settings snapshot / source mode / prompt policy 분리
- OAuth, Web, CLI source를 동등한 전략으로 다루는 구조
- 한계
- 현재 앱에 그대로 이식하면 과한 범용화가 될 수 있으므로 Claude/Codex 공통 기반까지만 가져와야 합니다.

### claude-code

- 가져올 것
- OAuth profile metadata cache
- `organizationUuid`, `subscriptionType`, `rateLimitTier`, `hasExtraUsageEnabled`, `billingType` 저장 전략
- quota / rate-limit 해석 로직
- 429 대응 시 reset-aware retry 사고방식
- 한계
- CLI 앱 전제와 menubar 앱 전제가 다릅니다.
- synthetic API call 기반 quota probe는 보조 수단으로만 써야 합니다.

## 3. 핵심 설계 결정

### A. Claude 사용량 source 우선순위

- 기본값은 `Auto`
- `session key/web` 경로는 주경로입니다.
- `OAuth`도 주경로입니다.
- `CLI credential import`는 OAuth를 자동 연결하는 진입 경로로 취급합니다.
- 즉 Claude는 `Web(session key/cookie)`와 `OAuth`를 모두 1급 source로 다룹니다.
- `Messages header fallback`은 구현합니다.
- 기본 정책에서는 `OAuth fetch 실패 시 내부 보조 경로`로 취급합니다.
- 다만 고급 설정에서 사용자가 더 적극적으로 사용하도록 선택할 수 있게 열어둡니다.
- `session key`는 제거하지 않으며, 수동/보조 경로로 내리지 않습니다.
- `Auto`에서 어떤 주경로를 먼저 볼지는 사용자 환경과 설정에 따라 결정합니다.

### B. Messages header fallback 정책

- 목적
- `/api/oauth/usage` 실패 또는 포맷 붕괴 시 최소한의 세션/주간 사용률 복구
- 기본 동작
- 구현 자체는 반드시 해둠
- 기본값은 `꺼짐`
- 노출 방식
- 고급 설정에서 사용자가 허용 여부를 선택할 수 있게 둠
- 사용자가 켜면 `보조 경로`로만 사용
- 기본값은 확정적으로 `off`
- 자동 보조 복구 임계값 기본값은 `20%`
- 일반 설정이 아니라 고급 설정에만 둠
- 주의
- 실제 API 호출이므로 완전한 무비용은 아님
- 영구적인 채팅 세션/스레드를 조회하거나 삭제하는 방식은 아님
- stateless probe를 원칙으로 함
- web private endpoint를 이용한 대화 생성/삭제 기반 probe는 채택하지 않음

### C. 인증 UX 기본 원칙

- 첫 진입 시 웹 로그인 강요 금지
- Claude Code CLI 자격증명 자동 탐지 우선
- OAuth 토큰이 있으면 곧바로 추적 시작
- Web session 기반 로그인도 정식 경로로 유지
- 자격증명 저장은 실제 Keychain 또는 CLI credential 파일 연동 기반으로 정리
- 일반 Claude 웹 사용자도 1차 시나리오에 포함
- 따라서 `CLI/OAuth only`로 밀어붙이지 않고 browser cookie/session import 경로를 정식 지원
- browser import는 `Chrome 고정`을 기본 지원으로 삼음
- Chrome이 아니면 session key 추출 안내를 제공하는 방향으로 단순화

### D. 권장 아키텍처 방향

- 전면적인 “교과서형 클린 아키텍처”보다 `포트/어댑터 + 앱 서비스 + 얇은 UI 상태 계층`이 적합
- 즉, 방향은 헥사고날에 가깝게 가되 과도한 추상화는 피함
- 권장 분해
- Domain
- `UsageSnapshot`, `UsageWindow`, `CredentialSource`, `FetchPlan`, `ProviderStatus`
- Application
- `RefreshCoordinator`, `AuthCoordinator`, `UpdateCoordinator`, `ProviderOrchestrator`
- Ports
- `UsageFetching`, `CredentialStore`, `ProfileMetadataStore`, `UpdateChecking`, `NotificationSending`
- Adapters
- `ClaudeOAuthUsageFetcher`, `ClaudeWebUsageFetcher`, `ClaudeOAuthHeaderFallbackFetcher`, `ClaudeCLIImportService`
- UI
- `MenuBarViewModel`, `PopoverViewModel`, `SettingsViewModel`
- 판단
- 현재 앱 규모에서 Redux/TCA를 전면 도입하는 것보다 provider/fetch/auth 경계를 먼저 세우는 편이 효과가 큼
- 다만 설정 화면과 팝오버 상태가 계속 커지면 일부 화면에 reducer 패턴을 국소 도입하는 것은 가능

### E. 표시 UX 방향

- “현재 세션”, “주간”, “동시”는 텍스트 표시뿐 아니라 아이콘 표시 기준에도 동일하게 적용되어야 함
- 현재 설정 enum에는 `weekly`가 있으나, 단일 배터리/단일 원형 표시가 항상 해당 기준을 제대로 따르지 않는 경로가 존재함
- 주간 전용 수요를 정식 요구사항으로 반영
- 배터리 스타일에서도 `현재 세션 전용 배터리`와 `주간 전용 배터리`를 모두 지원
- 원형 스타일도 `현재 세션 전용 원형`과 `주간 전용 원형`을 모두 지원
- 동시 표시 스타일은 별도 유지
- 메뉴바 기본값은 `Claude만 + 아이콘 + 퍼센트`
- 상세 표시(배터리, 리셋 시간, 다중 provider)는 사용자가 선택해서 확장
- provider별 스타일/표시 자유도를 우선 보장
- 정보 밀도 충돌은 기본 preset에서만 관리하고, 사용자가 의도적으로 많이 켜는 것은 허용

### F. 팝오버 UX 방향

- 권장안은 `하이브리드`
- provider가 하나만 활성화된 경우: 해당 provider 집중형
- provider가 둘 이상 활성화된 경우: 상단 `Overview` + provider 전환 탭
- Claude는 항상 첫 진입 포커스를 갖고, Overview는 보조 탭으로 제공
- 현재 서비스의 강점인 상세 사용량/리셋/상태 가시성은 유지
- CodexBar의 장점인 `Overview`, provider 전환, 통일된 카드형 구조는 선택적으로 도입
- 진단/고급 정보는 별도 섹션 또는 설정으로 분리

### G. 리팩토링 범위 기준

- 전면 분해 대상
- `AppDelegate.swift`
- `ClaudeAPIService.swift`
- `AppSettings.swift`
- `SettingsView.swift`
- `PopoverView.swift`
- `LoginWebView.swift`
- 부분 정리 대상
- `UpdateService.swift`
- `NotificationManager.swift`
- provider별 서비스/뷰 연결부
- 유지 또는 최소 수정 대상
- `ColorProvider.swift`
- `TimeFormatter.swift`
- `MenuBarIconRenderer.swift`
- 비교적 독립적인 usage model / utility

### H. 하네스형 서브 에이전트 팀 구조

- `lead-architect`
- 계획 유지, 인터페이스 고정, 병합/통합 책임
- `auth-credential`
- OAuth, session key, Chrome cookie import, Keychain 마이그레이션
- `claude-fetch`
- Claude source planner, web/oauth dual primary source, messages fallback, metadata cache
- `ui-shell`
- Settings/Popover/MenuBar shell, 주간 전용 표시, 고급 설정 구조
- `provider-platform`
- multi-provider 토대, Claude 기본 노출 + provider enable 흐름
- `qa-review`
- 테스트, 회귀 검토, 문서/설정 일관성 확인
- 적용 방식
- 감독자 + 팬아웃/팬인 + 생성-검증 패턴 사용
- 초기 구현은 `auth-credential`, `claude-fetch`, `ui-shell`을 병렬 진행
- 이후 `provider-platform`과 `qa-review`로 수렴

## 4. 실행 단계

### Phase 0. 조사 정리 및 계획 문서 유지

- 상태: 진행 중
- 산출물
- [docs/2026-04-01-architecture-review.md](/Users/seongmin/Personal/ClaudeUsage/docs/2026-04-01-architecture-review.md)
- 이 계획 문서
- 완료 기준
- 설계 결정을 문서화하고 이후 변경 시 즉시 반영

### Phase 1. 인증/자격증명 계층 분리

- 목표
- 현재의 뒤섞인 인증 로직을 분해하고, 로그인 소스별 책임을 분리
- 작업
- `ClaudeCredentialStore` 계층 도입
- `ClaudeOAuthCredentialStore`
- `ClaudeWebSessionStore`
- `ClaudeCLIImportService`
- `BrowserCookieImportService` 추가 검토
- Chrome cookie import를 우선 지원
- Chrome 외 브라우저는 자동 import보다 manual session key 안내를 우선
- `KeychainManager`를 실제 Keychain 구현으로 교체
- `UserDefaults` 저장 세션키 마이그레이션 처리
- `LoginWebView`를 로그인 UI 전용으로 축소
- 쿠키/세션 추출 로직을 별도 extractor로 이동
- 참고
- `ClaudeCodeSyncService`
- `CodexBar`의 Claude OAuth credential handling
- 현재 반영
- [KeychainManager.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/KeychainManager.swift) 를 실제 Keychain 기반으로 교체했고, 기존 `UserDefaults` 저장값을 마이그레이션합니다.
- [ClaudeKeychainStore.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Auth/ClaudeKeychainStore.swift) 를 추가했습니다.
- [ClaudeAuthModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Auth/ClaudeAuthModels.swift), [ClaudeChromeCookieImportService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Auth/ClaudeChromeCookieImportService.swift) 를 추가했습니다.
- 아직 남음
- [ClaudeChromiumCookieReader.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Auth/ClaudeChromiumCookieReader.swift) 를 추가해 Chrome `Cookies` DB를 임시 복사하고 `-wal` / `-shm`까지 함께 읽도록 분리했습니다.
- [ClaudeChromeCookieImportService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Auth/ClaudeChromeCookieImportService.swift) 는 실제 `sessionKey` 추출과 수동 안내 생성 책임만 갖도록 정리했습니다.
- [LoginWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/LoginWindowView.swift) 에 `Chrome에서 가져오기` 진입점을 추가했습니다.
- [LoginWebView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/LoginWebView.swift) 는 session key 추출 규칙을 [ClaudeSessionKeyExtractor.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Auth/ClaudeSessionKeyExtractor.swift) 로 분리했습니다.
- 아직 남음
- `LoginWebView`의 popup/window 제어와 상태 보고를 더 잘게 나누는 작업은 남아 있습니다.
- 완료 기준
- 로그인 방식별 실패 원인이 UI와 저장소에서 분리됨

### Phase 2. Claude fetch pipeline 재설계

- 목표
- source planner, fetch strategy, fallback policy를 구조적으로 재구성
- 작업
- `ClaudeSourcePlanner` 도입
- `ClaudeUsageFetcher`를 coordinator로 축소
- 세부 fetcher 분리
- `ClaudeOAuthUsageFetcher`
- `ClaudeOAuthHeaderFallbackFetcher`
- `ClaudeWebUsageFetcher`
- `ClaudeCLIUsageFetcher` 또는 CLI import adapter
- fetch attempt / source label / fallback reason 기록
- synthetic probe 허용 여부 설정 추가
- `보조 사용량 복구` 활성 시 자동 fallback 허용
- 단, 사용자 임계값 이하에서는 자동 fallback을 막는 옵션 추가
- 현재 반영
- [ClaudeSourcePlanner.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/Claude/ClaudeSourcePlanner.swift), [ClaudeFetchModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/Claude/ClaudeFetchModels.swift), [ClaudeMessagesHeaderFallbackFetcher.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/Claude/ClaudeMessagesHeaderFallbackFetcher.swift) 를 추가했습니다.
- [ClaudeAPIService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/ClaudeAPIService.swift) 에 `web + oauth` 주경로, recent-success 기반 `Auto`, OAuth 실패 시 자동 fallback, threshold 정책을 배선했습니다.
- `Messages header fallback` 기본값은 `off`, 자동 threshold 기본값은 `20%`로 설정되어 있습니다.
- 완료 기준
- source별 성공/실패와 fallback 경로가 코드에서 명확해짐

### Phase 3. OAuth profile metadata cache 도입

- 목표
- 사용량 수치 외에 org/profile 정보를 독립적으로 보관
- 작업
- 캐시 필드
- `organizationUuid`
- `subscriptionType`
- `rateLimitTier`
- `hasExtraUsageEnabled`
- `billingType`
- `accountCreatedAt`
- `subscriptionCreatedAt`
- 토큰 refresh 또는 profile fetch 시 metadata 갱신
- 경고 문구와 플랜 표시를 이 캐시에 의존하도록 전환
- 현재 반영
- [ClaudeProfileMetadataStore.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/Claude/ClaudeProfileMetadataStore.swift) 를 추가했고, OAuth credential 파일/키체인에서 읽을 수 있는 metadata를 캐시에 저장하도록 [ClaudeAPIService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/ClaudeAPIService.swift) 에 연결했습니다.
- [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 에 `감지된 계정 메타데이터` 카드를 추가해 `organization`, `subscription`, `rate limit tier`, `billing`, `extra usage` 상태를 노출합니다.
- 아직 남음
- 경고 문구, overage 정책, 메뉴바/팝오버 요약까지 이 캐시를 더 적극적으로 소비하도록 바꾸는 작업은 남아 있습니다.
- 완료 기준
- UI와 fetcher가 org/profile 정보를 임시 파싱 없이 일관되게 사용

### Phase 4. 설정 UX 및 온보딩 재설계

- 목표
- 지금의 복잡한 설정 화면을 단계형 UX로 단순화
- 작업
- 초기 설정 마법사 도입
- `CLI 감지됨`
- `OAuth 사용 가능`
- `수동 웹 로그인`
- 고급 설정과 일반 설정 분리
- source 선택은 일반 사용자에게 `Auto` 중심으로 제공
- 진단/실험 옵션은 고급 섹션으로 이동
- `Messages header fallback 허용`은 고급 설정에 배치
- `자동 보조 사용량 복구 허용`
- `특정 사용량 이하에서는 자동 보조 복구 비활성화`
- 자동 보조 복구 비활성화 임계값 기본값은 `20%`
- provider 기본 노출은 Claude만 활성화
- 나머지 provider는 선택 시 추가 활성화
- fallback 설정 라벨은 기술 용어만 쓰지 말고 설명 툴팁을 함께 제공
- 현재 반영
- [SettingsViewModel.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/SettingsViewModel.swift) 를 추가했고, [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 에 `보조 사용량 복구`, threshold, Chrome 안내, 주간 표시 도움말을 넣었습니다.
- [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 의 Claude 인증 탭에는 `빠른 시작` 단계 카드가 들어가 Chrome import → 웹 로그인 → 수동 sessionKey 순서를 명시합니다.
- [SetupWizardView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/Components/SetupWizardView.swift) 를 추가했고, Claude 인증 탭의 빠른 시작을 별도 컴포넌트로 분리했습니다.
- [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift) 에 `hasCompletedSetupWizard` 를 추가해 온보딩 표시 상태를 저장합니다.
- `수동 보조` 또는 `자동 보조` 사용 시 설정 화면에서 직접 `보조 복구 테스트`를 실행할 수 있습니다.
- [ProviderSettingsRegistry.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/ProviderSettingsRegistry.swift) 를 추가했고, 설정 사이드바를 `Common / Claude / Codex / Gemini / Antigravity` registry 기반으로 바꿨습니다.
- `Gemini` 와 `Antigravity` 는 아직 shell 수준이지만, 설정 패널과 활성화 상태 저장은 먼저 열어두었습니다.
- [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 Claude 인증 탭을 `일반 흐름` 과 `고급 및 진단` 으로 실제 분리했고, 설정 overview 카드도 추가됐습니다.
- 아직 남음
- 초기 설정 마법사의 완료도 판단과 provider별 온보딩 연결은 더 다듬어야 합니다.
- 완료 기준
- 로그인과 설정 변경의 의미를 사용자가 이해할 수 있음

### Phase 5. App 구조 및 상태 관리 정리

- 목표
- 현재 거대 파일 구조 해체
- 작업
- `AppDelegate`에서 메뉴, 스케줄링, refresh orchestration 분리
- `PopoverView`의 뷰 모델 도입
- `AppSettings`를 provider settings와 UI settings로 분리
- usage snapshot store 도입
- 현재 반영
- [ServiceSelectionHelper.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ServiceSelectionHelper.swift) 를 추가했고, [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 의 반복적인 service selection / enabled check / settings auth 진입 분기를 일부 분리했습니다.
- [ProviderStateModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/ProviderStateModels.swift) 와 [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift) 에 `AppProviderStateCatalog` 기반 provider 상태 저장을 추가했고, 기존 `claudeEnabled` / `codexEnabled` / `menuBarActiveService` 와 브리지합니다.
- 6차 통합에서 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 `providerStates` 변화 자체를 받아 Claude/Codex enable 흐름을 처리하도록 옮기기 시작했습니다.
- 사용되지 않던 [MenuBarViewModel.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/MenuBarViewModel.swift) 와 [PopoverShellViewModel.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/PopoverShellViewModel.swift) 는 삭제해 죽은 추상화를 정리했습니다.
- [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift) 는 선택 서비스 상태/로딩/에러 접근을 helper로 묶어 중복을 줄였습니다.
- [MenuBarStatusComposer.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Utilities/MenuBarStatusComposer.swift) 를 추가해 메뉴바 상태 계산과 합성 렌더링을 `AppDelegate` 밖으로 옮겼습니다.
- [ProviderMenuBarDisplayConfig](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/ProviderStateModels.swift) 와 [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift) 의 `menuBarDisplayConfig(for:)` 로 provider별 표시 옵션을 한 묶음으로 읽기 시작했습니다.
- [ServiceSelectionHelper.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ServiceSelectionHelper.swift) 는 shell provider를 제외한 `runtime-enabled service` 기준으로 메뉴바/타이머 판단을 하도록 수정했습니다.
- 아직 남음
- `AppDelegate`의 refresh/timer composition, `PopoverView`의 provider shell, `AppSettings`의 presentation profile 분리는 아직 완료 전입니다.
- 완료 기준
- 핵심 파일이 역할별로 나뉘고 테스트 가능한 단위가 생김

### Phase 6. UI/UX, 성능, 무게 점검

- 목표
- 앱이 무겁고 복잡하게 느껴지는 원인을 제거
- 점검 항목
- refresh마다 전체 UI 재계산 여부
- 불필요한 타이머/중복 네트워크 요청
- 큰 SwiftUI view의 상태 전파 범위
- 설정 화면 정보 밀도 과다
- 메뉴바/팝오버 진입 시 초기 렌더 비용
- 주간 전용 메뉴바 표시 부재
- provider 추가 시 UI 통일성 유지
- 개선 방향
- snapshot 기반 렌더링
- refresh throttling
- diagnostics lazy loading
- 고급 정보 접기
- 아이콘 표시 기준을 `현재/주간/동시`로 일관화
- 퍼센트, 배터리, 아이콘, 리셋 시간의 시각 언어 통일
- 기본 메뉴바 preset과 확장 preset을 분리
- 현재 반영
- [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift) 에 Claude/Codex용 `IconMetric` 설정을 추가했습니다.
- [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 와 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 에 단일 배터리/단일 원형이 `현재 세션` 또는 `주간`을 따르도록 연결했습니다.
- [PopoverViewModel.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/PopoverViewModel.swift) 로 팝오버 상태 객체를 뷰 파일에서 분리했습니다.
- [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift) 에 Overview 섹션과 helper 기반 상태 접근을 추가해 하이브리드 구조로 옮기는 중입니다.
- [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 의 `일반` 섹션에는 provider overview 카드를 추가해 `실동작/설정 shell` 상태를 구분해 보여줍니다.
- [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 의 Claude 인증 탭은 `일반 흐름`과 `고급 및 진단` 섹션을 실제 UI로 나누기 시작했습니다.
- [MenuBarStatusComposer.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Utilities/MenuBarStatusComposer.swift) 와 `ProviderMenuBarDisplayConfig` 도입으로 메뉴바 표시 로직의 시각 규칙과 설정 해석을 한 층 더 분리했습니다.
- 아직 남음
- 팝오버 하이브리드 구조, preset 체계, provider 추가 시 일관된 카드 구조는 아직 남아 있습니다.
- 완료 기준
- 체감 반응성과 설정 이해도가 개선됨

### Phase 7. 문서/진단/테스트 보강

- 목표
- 현재 구현 상태와 문서 상태를 맞추고 회귀를 막음
- 작업
- README를 실제 제품 방향에 맞게 재작성
- source/fallback/auth 상태를 보여주는 debug 화면 정리
- planner / fetcher / parser 테스트 추가
- 현재 반영
- [README.md](/Users/seongmin/Personal/ClaudeUsage/README.md) 는 Claude 중심 multi-provider 제품 방향과 현재 구현 범위를 반영하도록 갱신했습니다.
- `ClaudeProfileMetadataStore` 관련 Swift 6 경고를 제거해 빌드 출력이 더 깨끗해졌습니다.
- 완료 기준
- 문서와 구현이 어긋나지 않음

### Phase 8. 배포/업데이트 체계 재구성

- 목표
- Apple Developer 계정 기반으로 설치/업데이트 경험을 정상화
- 작업
- `Developer ID + notarization` 도입
- 베타 채널 `TestFlight` 검토
- 정식 채널 `Sparkle` 기반 자동업데이트 설계
- 기존 GitHub Releases 수동 다운로드 흐름 정리
- 참고 문서
- [apple-developer-update.md](/Users/seongmin/Personal/ClaudeUsage/apple-developer-update.md)
- 완료 기준
- 수동 설명 없이 설치 가능한 signed/notarized 배포물과 자동업데이트 경로가 정의됨

## 5. 질문에 대한 현재 답변

### Messages fallback은 어떤 모델로 시도하는가

- 참고 구현인 `Claude-Usage-Tracker`는 `claude-haiku-4-5-20251001`로 최소 요청을 보냅니다.
- 현재 우리 앱에 반영한다면 고정 문자열 하드코딩보다는 `가장 저렴하고 빠른 지원 모델`을 내부 정책으로 추상화하는 편이 맞습니다.
- 이 호출은 `max_tokens: 1` 수준의 최소 probe여야 합니다.

### 이 시도는 채팅 세션/스레드를 확인하고 삭제하는가

- 아닙니다.
- `v1/messages` 호출은 stateless API 요청입니다.
- 다만 호출 자체는 실제 inference 요청이므로 완전한 공짜 호출은 아닙니다.
- 따라서 주기적 polling의 기본 경로로 쓰는 것은 부적절합니다.

### 사용자가 선택할 수 있는 옵션이어야 하는가

- 구현은 해둡니다.
- 다만 기본 사용자용 주 설정으로 올릴 필요는 없습니다.
- 고급 설정에서 `OAuth fallback probe 허용` 또는 `Messages header fallback 허용` 같은 형태로 노출하는 쪽이 맞습니다.
- 기본값은 `꺼짐`

### claude-code의 실제 로직을 보면 이 방식이 적합한가

- 부분적으로는 적합합니다.
- `claude-code`도 unified rate-limit header와 profile metadata를 적극적으로 사용합니다.
- 다만 CLI는 실제 작업 트래픽이 이미 존재하는 환경이라 synthetic probe의 부담이 상대적으로 덜합니다.
- 반대로 menubar 추적 앱은 polling 자체가 제품이므로, 기본값을 어떻게 둘지는 별도 정책으로 다뤄야 합니다.
- 결론적으로 이 방식은 구현 대상이며, 기본값과 사용자 노출 수준만 신중하게 결정하면 됩니다.

## 6. 추가 개선 포인트

### 인증/로그인

- 현재 구조는 로그인 실패 시 사용자가 무엇을 해야 하는지 이해하기 어렵습니다.
- CLI credential auto-detect를 1순위로 올려야 합니다.
- WebView 기반 수동 로그인은 유지하되, 보조 경로로 내려야 합니다.
- 세션 키 저장 방식은 반드시 수정해야 합니다.
- browser cookie/session import를 정식 기능으로 끌어올릴 가치가 큽니다.
- Chrome/Safari 등 실제 로그인 상태를 읽는 경로를 수동 DevTools 복사보다 우선 검토합니다.

### UI/UX

- 현재 설정과 상태 표시가 개발자 시점 정보 위주라 사용자 행동으로 이어지지 않습니다.
- 일반 사용자용 화면과 진단 화면을 분리해야 합니다.
- source 상태, 로그인 상태, 플랜 상태를 한 문맥에서 이해할 수 있게 보여줘야 합니다.
- 주간 세션만 보고 싶은 사용자 요구를 메뉴바 아이콘/퍼센트/리셋 시간 모두에서 일관되게 지원해야 합니다.
- 특히 단일 배터리 아이콘이 현재 세션 전용처럼 동작하는 경로를 수정해야 합니다.
- Claude가 기본이고 다른 provider는 opt-in이라는 제품 방향이 UI에서도 드러나야 합니다.
- Chrome 유도와 manual session key 안내를 UX 흐름으로 정리해야 합니다.
- 현재 앱의 상세 정보 강점은 유지하고, CodexBar의 Overview/전환 구조를 가져와 정보 구조만 개선하는 방향이 적합합니다.

### 성능/무게

- 파일 크기와 책임 집중도를 보면 현재 앱은 구조적으로 무겁습니다.
- 전체 화면이 큰 상태 객체에 과도하게 의존할 가능성이 높습니다.
- refresh, notification, menu update, settings observe를 coordinator 단위로 쪼개야 합니다.

### 제품 방향

- 현재 README와 실제 구현 상태가 어긋납니다.
- 제품 서사는 `Claude 중심 multi-provider menubar app`으로 재정의합니다.
- 기본 제공값은 Claude only, 나머지 provider는 사용자가 추가 활성화하는 구조를 채택합니다.

### 외부 유사 앱에서 확인한 제품 방향 메모

- `TokenBar` 계열 제품은 `menu bar에서 live visibility`, `local-first`, `추가 대시보드 없음`을 전면에 둡니다.
- `ClaudeBar` 계열 제품은 `가볍고 빠른 네이티브 메뉴바 앱`이라는 메시지를 전면에 둡니다.
- 반면 현재 앱은 로그인과 설정 설명이 먼저 튀고, 핵심 가치인 `지금 얼마 남았는지 빠르게 본다`는 메시지가 약합니다.
- 따라서 제품 UX도 `설정 가능한 도구`보다 `바로 신호를 주는 메뉴바 유틸리티` 쪽으로 다시 정렬하는 편이 맞습니다.

## 7. 바로 다음 작업

- `providerStates`를 실제 메뉴바/팝오버/AppDelegate refresh 경로까지 더 연결해 `claude/codex` 하드코딩을 추가로 걷어내기
- 팝오버를 `Claude 집중형 + Overview/Provider 전환` 하이브리드로 마저 정리하기
- `Gemini`, `Antigravity`의 shell을 fetch/auth 플랫폼 레이어와 연결할 준비를 하기
- refresh/timer 경로도 runtime-capable provider 기준으로 더 분리하기
- README와 배포/업데이트 문서를 실제 구현 상태에 맞게 계속 갱신하기
