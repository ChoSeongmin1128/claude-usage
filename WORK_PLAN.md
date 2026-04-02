# ClaudeUsage 작업 계획

최종 갱신: 2026-04-02 (91차)

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
- `Claude` 런타임 health snapshot은 `session credential`과 `OAuth credential` 가용성을 모두 노출하고, bootstrap / timer / refresh 가능 여부도 이를 기준으로 계산하기 시작했습니다.
- 메뉴바, 팝오버 overview, 설정 체크리스트는 `OAuth-only` 계정에서 더 이상 `세션 키 없음`만 보고 잘못 경고하지 않도록 맞추기 시작했습니다.
- 팝오버는 단일 runtime provider일 때 `현재 provider` 집중 카드, 다중 runtime provider일 때 `Provider overview` 전환 카드가 먼저 보이는 하이브리드 구조로 옮기기 시작했습니다.
- 설정의 Claude 인증 패널도 `일반 사용자 흐름`, `인증 상태`, `고급 설정`을 분리해 Chrome import / 웹 로그인과 수동 sessionKey / fallback 경계를 더 분명하게 드러내기 시작했습니다.
- [ProviderOverviewCardView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/Components/ProviderOverviewCardView.swift), [PopoverProviderCards.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/Components/PopoverProviderCards.swift) 를 추가해 `SettingsView` / `PopoverView` 의 순수 렌더링 블록을 별도 컴포넌트로 빼기 시작했습니다.
- [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift) 는 메뉴바 표시 관련 변경을 묶는 `menuBarDisplayChangePublisher` 를 노출하고, [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 이를 소비하도록 단순화했습니다.
- [RefreshScheduler.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/RefreshScheduler.swift) 를 추가해 `AppDelegate` 의 타이머 start/stop/sync 책임을 별도 객체로 빼기 시작했습니다.
- [LoginWebViewCoordinator.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/LoginWebViewCoordinator.swift) 를 추가해 `LoginWebView` 의 WKNavigation/WKUIDelegate 오케스트레이션을 별도 파일로 이동시키기 시작했습니다.
- 사용자 피드백 기준으로 팝오버는 다시 `사용량 중심`으로 단순화했고, provider overview / shell 정보는 설정 쪽으로 되돌리기 시작했습니다.
- 메뉴바는 provider 이름 텍스트(`Claude`, `Codex`)를 fallback으로 띄우지 않고, 최소 상태 점으로만 대체하도록 수정했습니다.
- Chrome 경로는 단순 DB 스캔 시도만 하던 상태에서, [LoginWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/LoginWindowView.swift) 에 `Chrome 열기` 경로를 추가해 사용자가 실제 Chrome에서 로그인한 뒤 재시도할 수 있게 했습니다.
- 내부 WebView의 session key 추출도 [ClaudeSessionKeyExtractor.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Auth/ClaudeSessionKeyExtractor.swift) 에서 `session_key` / `session-key` / 기타 session-like 쿠키명을 더 넓게 허용하도록 완화했고, [LoginWebViewCoordinator.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/LoginWebViewCoordinator.swift) 는 `WKHTTPCookieStore` 외에 `HTTPCookieStorage.shared` 도 함께 확인하도록 보강했습니다.
- 상태바 우클릭 메뉴 조립도 [StatusContextMenuBuilder.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/StatusContextMenuBuilder.swift) 로 분리해, `AppDelegate` 안의 메뉴 생성/section 조립 책임을 줄이기 시작했습니다.
- 팝오버 객체와 리사이즈 상태도 [AppPopoverCoordinator.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppPopoverCoordinator.swift) 로 분리해, `AppDelegate` 가 직접 `NSPopover` 생성/hosting controller 구성/resize work item 수명 관리를 하지 않도록 정리하기 시작했습니다.
- 설정/전원 상태 observer 구독도 [AppRuntimeObservationCoordinator.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppRuntimeObservationCoordinator.swift) 로 분리해, `AppDelegate` 가 `Combine` 구독과 cancellable 수명 관리를 직접 갖지 않도록 정리하기 시작했습니다.
- Claude 설정 적용과 session key 반영도 [ClaudeSettingsApplyCoordinator.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ClaudeSettingsApplyCoordinator.swift) 로 분리해, 설정 저장/로그아웃/로그인 완료 시 `Keychain -> APIService -> health snapshot` 순서를 `AppDelegate` 밖으로 옮기기 시작했습니다.
- 알림 설정은 provider별 임계값을 길게 늘어놓는 구조를 버리고, `공통 알림 프리셋 + 프리셋별 on/off` 구조로 단순화해야 합니다.
- [NotificationPresetModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/NotificationPresetModels.swift) 를 추가해 공통 알림 프리셋 모델을 도입했고, [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 provider별 임계값 편집 대신 `공통 프리셋 + provider별 on/off` 구조로 바꾸기 시작했습니다.
- [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift) 는 기존 Claude/Codex 임계값 배열을 마이그레이션 입력으로만 쓰고, 실제 런타임은 공통 프리셋 목록을 기준으로 계산하도록 정리하기 시작했습니다.
- [RefreshOrchestration.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/RefreshOrchestration.swift) 를 추가해 `refreshAll`, 탭 전환 refresh, provider enable 전환 시의 결정 로직을 공통 action planner로 묶기 시작했습니다.
- [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 이제 `performRuntimeAction` 을 통해 실제 부작용만 실행하고, refresh/clear/prompt 판단은 planner가 맡도록 줄이기 시작했습니다.
- [SettingsWindowCoordinator.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/SettingsWindowCoordinator.swift) 를 추가해 설정 창 생성, 재포커스, 스냅샷 복원, 종료 시 정리를 `AppDelegate` 밖으로 옮기기 시작했습니다.
- 설정 창의 취소/저장/로그아웃 흐름은 여전히 `AppDelegate` 가 액션을 결정하지만, 창 수명과 `NSWindowDelegate` 처리 자체는 coordinator가 맡도록 줄였습니다.
- [LoginWindowCoordinator.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/LoginWindowCoordinator.swift) 를 추가해 로그인 창 재포커스, 종료 시 정리, 창 생성 책임을 `AppDelegate` 밖으로 옮기기 시작했습니다.
- 로그인 완료 후 세션 키 활성화와 모니터링 시작 결정은 `AppDelegate` 에 남기되, 창 열기/닫기 자체는 coordinator가 맡도록 정리했습니다.
- [AppUpdateCoordinator.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppUpdateCoordinator.swift) 를 추가해 업데이트 주기 확인 타이머와 즉시 확인 실행을 `AppDelegate` 밖으로 옮기기 시작했습니다.
- [AppRuntimeObservationCoordinator.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppRuntimeObservationCoordinator.swift) 는 이제 `updateCheckInterval` 도 구독해, 설정 변경 시 업데이트 타이머가 즉시 재구성되도록 정리했습니다.
- provider 전환 시 stale refresh 판단과 enable/disable 정책도 [ProviderTransitionPolicy.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ProviderTransitionPolicy.swift) 로 분리해, `AppDelegate` 안의 서비스 전환 분기가 단순 결정 호출 위주로 바뀌기 시작했습니다.
- `Claude` / `Codex` refresh의 백오프 계산과 in-flight 고착 판단도 [RefreshExecutionPolicy.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/RefreshExecutionPolicy.swift) 로 분리해, `AppDelegate` 안의 중복된 retry/backoff 규칙을 줄이기 시작했습니다.
- 메뉴바 아이콘/색상 렌더링 세부 구현도 [MenuBarIconFactory.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Utilities/MenuBarIconFactory.swift) 로 분리해, `AppDelegate` 안에 남아 있던 이미지 합성/알파 트리밍/색상 선택 로직을 utility로 이동시켰습니다.
- [RuntimeProviderModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/RuntimeProviderModels.swift) 로 `PopoverService` 를 분리해, provider 선택 축을 뷰 파일 밖에서 재사용할 수 있게 정리하기 시작했습니다.
- [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift) 는 `popover pinned / compact / provider settings last tab` 을 provider kind 기준 helper 메서드로 읽고 쓰기 시작했습니다.
- [ServiceSelectionHelper.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ServiceSelectionHelper.swift), [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 이제 이 helper를 이용해 `claude/codex` 개별 필드명에 직접 매달리지 않도록 줄이기 시작했습니다.
- [RuntimeProviderModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/RuntimeProviderModels.swift) 는 `RuntimeProviderPresentationState` 와 `RuntimeProviderActivationState` 를 도입해, provider 정책 입력을 `Claude/Codex` 개별 파라미터 묶음에서 벗어나기 시작했습니다.
- [ProviderTransitionPolicy.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ProviderTransitionPolicy.swift), [RefreshOrchestration.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/RefreshOrchestration.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 이제 탭 전환 refresh / enable 변화 판단을 provider별 상태 struct 기준으로 다루기 시작했습니다.
- [StatusContextMenuBuilder.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/StatusContextMenuBuilder.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift), [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift) 는 상태바 우클릭 메뉴의 toggle / refresh / style 변경도 provider-generic selector와 helper 기준으로 맞추기 시작했습니다.
- [PopoverViewModel.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/PopoverViewModel.swift) 는 `RuntimeServiceState` 를 도입해, Claude/Codex의 summary / meta / loading / auth-required / warning-dot 판단을 뷰 파일 밖으로 모으기 시작했습니다.
- [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift) 는 overview / warning / loading / error / lastUpdated 접근을 이 runtime state accessor로 읽기 시작해 `Claude/Codex`별 switch를 더 줄였습니다.
- 다만 AppDelegate orchestration과 multi-provider fetch/menu glue는 아직 더 분해해야 합니다.
- 2026-04-02 참고 레포 재비교 결과, `CodexBar`의 descriptor/pipeline 구조와 비교하면 현재 최대 병목은 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 의 `Claude/Codex` 이중 상태 세트와 `refresh/menu/presentation` 하드코딩입니다.
- 같은 비교 기준으로, 현재 온보딩은 설정 내부 체크리스트 수준까지는 왔지만 최신 `Claude-Usage-Tracker`의 [SetupWizardView.swift](/Users/seongmin/Personal/Claude-Usage-Tracker/Claude%20Usage/Views/SetupWizardView.swift) 처럼 `CLI 감지 -> 권장 경로 제시 -> 수동 fallback`을 독립 플로우로 끝내는 완성도에는 아직 못 미칩니다.
- `claude-code`의 [rateLimitMessages.ts](/Users/seongmin/Personal/claude-code/src/services/rateLimitMessages.ts) 와 비교하면, 현재 앱은 `profile metadata`를 저장하기 시작했지만 이를 실제 `reset-aware warning`, `extra usage`, `team/enterprise suppress policy` 같은 문구/알림 정책까지 확장하지는 못했습니다.
- `CodexBar`의 [README.md](/Users/seongmin/Personal/CodexBar/README.md), [docs/provider.md](/Users/seongmin/Personal/CodexBar/docs/provider.md), [docs/claude.md](/Users/seongmin/Personal/CodexBar/docs/claude.md) 와 비교하면, 현재 앱은 `왜 Chrome/Keychain 권한이 필요한지`, `어떤 source를 어떤 순서로 시도하는지`, `어떤 데이터는 로컬만 읽는지`를 설명하는 제품 문서와 UI copy가 아직 약합니다.
- 2026-04-02 32차 통합에서 [RuntimeProviderModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/RuntimeProviderModels.swift) 에 `RuntimeProviderSnapshot` 을 추가했고, [PopoverViewModel.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/PopoverViewModel.swift) 는 이제 이 snapshot 컬렉션을 기준으로 런타임 상태를 계산하기 시작했습니다.
- 같은 통합에서 [MenuBarStatusComposer.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Utilities/MenuBarStatusComposer.swift) 는 `MenuBarProviderSnapshot` 기반 단일/다중 provider 렌더링 경로를 갖게 됐고, [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 이를 사용해 `claude/codex` 전용 입력보다 provider snapshot 배열을 우선 쓰기 시작했습니다.
- [RefreshOrchestration.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/RefreshOrchestration.swift) 의 `markSetupComplete` 결정도 더 이상 `.claude` 비교를 직접 갖지 않고 `RuntimeProviderActivationState` 입력으로 밀어내기 시작했습니다.
- 2026-04-02 33차 통합에서 [RuntimeProviderModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/RuntimeProviderModels.swift) 에 `RuntimeProviderState`, `RuntimeProviderStateCatalog` 를 추가했고, [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 `currentUsage/currentCodexUsage/currentError/...` 이중 필드를 이 카탈로그 위 computed wrapper로 바꿨습니다.
- 같은 통합에서 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 `runtimeRefreshHandlers` 를 도입해 `refresh(service:)` switch를 lookup 기반으로 줄였고, `clearRuntimeServiceState(_:)` 도 카탈로그 reset 중심으로 단순화했습니다.
- 2026-04-02 34차 통합에서 [ClaudeRuntimeRefresher.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ClaudeRuntimeRefresher.swift), [CodexRuntimeRefresher.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/CodexRuntimeRefresher.swift) 를 추가했고, [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 provider별 네트워크 fetch 세부를 직접 수행하지 않고 refresher를 통해 호출하기 시작했습니다.
- 2026-04-02 35차 통합에서 [ProviderStateModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/ProviderStateModels.swift) 에 `ProviderCapabilities`, `ProviderDescriptor` 를 도입했고, `AppProviderKind` 의 `runtime/browser-import/defaultEnabled/settings` 성격을 descriptor 기반으로 읽기 시작했습니다.
- 같은 통합에서 [ProviderSettingsRegistry.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/ProviderSettingsRegistry.swift), [ServiceSelectionHelper.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ServiceSelectionHelper.swift) 는 runtime service 판정과 settings shell descriptor를 더 이상 raw switch 조합에 의존하지 않고 provider descriptor를 통해 읽기 시작했습니다.
- 2026-04-02 36차 통합에서 [SetupWizardWindowCoordinator.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/SetupWizardWindowCoordinator.swift), [SetupWizardWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SetupWizardWindowView.swift) 를 추가했고, [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 최초 Claude 인증 유도가 더 이상 설정창 내부 카드에만 머물지 않고 독립 `빠른 시작` 창으로 진입하기 시작했습니다.
- 같은 통합에서 설정창 내부의 [SetupWizardView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/Components/SetupWizardView.swift) 는 보조 카드로 유지하되, 첫 실행 진입 책임은 별도 window coordinator로 이동시키기 시작했습니다.
- 2026-04-02 37차 통합에서 [ClaudeFetchModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/Claude/ClaudeFetchModels.swift) 에 `ClaudeNotificationPolicy` 를 도입했고, [NotificationManager.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/NotificationManager.swift) 는 `team/enterprise + extra usage` 계정의 저긴급 임계값을 자동 억제하고 billing/subscription 상태에 따라 안내 문구를 달리하기 시작했습니다.
- 2026-04-02 54차 통합에서 [AntigravityUsageModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AntigravityUsageModels.swift), [AntigravityAPIService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/AntigravityAPIService.swift), [AntigravityRuntimeRefresher.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AntigravityRuntimeRefresher.swift) 를 추가했고, `ps + lsof + local Connect API` 기반으로 Antigravity language server에 직접 연결해 quota를 읽는 최소 runtime provider 경로를 붙였습니다.
- 같은 통합에서 [RuntimeProviderModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/RuntimeProviderModels.swift), [ProviderStateModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/ProviderStateModels.swift), [RuntimeRefreshHandlerRegistry.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/RuntimeRefreshHandlerRegistry.swift), [ServiceSelectionHelper.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ServiceSelectionHelper.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 `Antigravity` 를 shell이 아니라 실제 runtime provider로 취급하기 시작했습니다.
- 같은 통합에서 [MenuBarStatusComposer.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Utilities/MenuBarStatusComposer.swift), [MenuBarIconFactory.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Utilities/MenuBarIconFactory.swift), [PopoverViewModel.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/PopoverViewModel.swift), [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift), [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 Antigravity의 메뉴바/팝오버/설정 패널을 runtime 기준으로 표시하기 시작했습니다.
- 2026-04-02 55차 통합에서 [KeychainManager.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/KeychainManager.swift), [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 세션키 저장 변경 알림을 공유하고, 로그인 직후 Claude 런타임 상태를 먼저 `조회 중`으로 올려 popover/menu bar 동기화가 어긋나는 경로를 줄였습니다.
- 같은 통합에서 [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift), [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 `Gemini` / `Antigravity`용 메뉴바 표시와 popover compact/pin 제어를 shell 토글 수준에서 runtime display 설정 수준으로 올리기 시작했습니다.
- 2026-04-02 56차 통합에서 [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift), [NotificationManager.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/NotificationManager.swift), [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 `Gemini` / `Antigravity` 알림 on/off를 공통 프리셋 위에 얹고, 각 provider runtime 갱신 시 실제 임계값 알림을 보내기 시작했습니다.
- 2026-04-02 57차 통합에서 [SetupCompletionPolicy.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/SetupCompletionPolicy.swift), [SetupWizardWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SetupWizardWindowView.swift), [ClaudeSettingsApplyCoordinator.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ClaudeSettingsApplyCoordinator.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 `세션키 저장 성공 = setup 완료`로 취급하던 경로를 제거하고, standalone wizard가 `자격 준비 -> 조회 검증 -> organization 확인 -> 완료` 단계를 실제 CTA로 드러내도록 정리했습니다.
- 같은 통합에서 wizard의 `나중에/닫기`는 더 이상 무조건 `hasCompletedSetupWizard = true`를 쓰지 않고 창만 닫으며, `완료`는 실제 `첫 성공 조회 + organization readiness`가 충족됐을 때만 노출하도록 보수적으로 바꿨습니다.
- 같은 통합에서 standalone wizard는 자격 확보 이후에도 계속 `Chrome 열기`를 고집하지 않고, `지금 조회 검증`과 `Organization 열기`를 다음 행동으로 직접 제시하므로 first-run 흐름이 더 닫혔습니다.
- 2026-04-02 58차 통합에서 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift), [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift), [LoginWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/LoginWindowView.swift), [SetupWizardView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/Components/SetupWizardView.swift) 는 `인증 창 누르자마자 사라짐` 경로를 줄이기 위해 웹 데이터 삭제 완료 후 로그인 창을 열도록 순서를 바꿨고, 인증/CLI OAuth/보조 복구 안내를 더 직접적인 사용자 흐름 기준으로 다시 정리했습니다.
- 같은 통합에서 Settings의 Claude 인증 상태는 더 이상 `세션키만 있으면 전부 초록색`처럼 보이지 않고, `세션키 단독/불안정 시 Claude Code CLI OAuth 권장`을 별도 체크리스트와 가이드 섹션으로 보여주기 시작했습니다.
- 같은 통합에서 `보조 사용량 복구`는 `자동 중지 기준`을 자동 모드에서만 숨기지 않고 항상 표시하되, 실제 자동 보조일 때만 활성화되도록 바꿨습니다. 이로써 `자동 보조 설정이 없는 것처럼 보인다`는 혼란을 줄입니다.
- 2026-04-02 59차 통합에서 [README.md](/Users/seongmin/Personal/ClaudeUsage/README.md), [docs/authentication-and-sources.md](/Users/seongmin/Personal/ClaudeUsage/docs/authentication-and-sources.md) 를 갱신해, 현재 구현 기준의 runtime provider 범위(`Claude/Codex/Gemini/Antigravity`), Claude 인증 권장 순서(`CLI OAuth -> Chrome -> 웹 로그인 -> 수동 sessionKey`), `Messages header fallback` 정책을 제품 문서에도 맞췄습니다.
- 같은 통합에서 README는 더 이상 `Gemini` / `Antigravity`를 shell-only 상태로 설명하지 않고, 런타임 연결은 됐지만 UX 마감이 덜 끝난 상태라고 명시합니다. 즉 문서가 코드보다 뒤처지는 문제를 줄입니다.
- 2026-04-02 60차 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift), [SettingsViewModel.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/SettingsViewModel.swift), [ClaudeMessagesHeaderFallbackFetcher.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/Claude/ClaudeMessagesHeaderFallbackFetcher.swift) 는 `Messages 헤더 기반 보조 조회` 섹션의 현재 동작 상태와 자동 중지 기준 값을 항상 보이게 정리했고, `Claude Code OAuth` 가 없을 때 테스트 버튼을 막고 이유를 바로 설명하도록 바꿨습니다.
- 같은 통합에서 fallback 테스트 오류는 더 이상 `ClaudeMessagesHeaderFallbackFetcherError error 0` 같은 raw enum 형태로 보이지 않고, `사용량 헤더 없음`, `OAuth 토큰 없음/만료`, `HTTP 상태 코드 실패` 같은 사용자 설명형 오류로 노출됩니다.
- 같은 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift), [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift) 의 provider 상태 subtitle을 `활성 / 실동작` 기준으로 맞춰, 이미 runtime provider가 된 `Gemini` / `Antigravity`를 여전히 `설정 shell` 또는 `준비 중` 문맥으로 읽게 만드는 혼란을 더 줄였습니다.
- 2026-04-02 61차 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 의 Claude 인증 기본 CTA를 `Chrome에서 가져오기` 와 `웹 로그인 열기`로 분리했습니다. 이제 settings 화면의 첫 행동 유도도 standalone setup wizard와 같은 순서로 읽히며, `브라우저를 여는 것`과 `가져오기를 실행하는 것`을 같은 버튼에 섞어놓던 혼란을 줄입니다.
- 2026-04-02 62차 통합에서 레퍼런스인 `Claude-Usage-Tracker` / `CodexBar` / `claude-code`를 다시 비교한 뒤, [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 의 Claude 인증 패널을 `행동` 중심으로 더 단순화했습니다. 일반 영역에서는 `빠른 시작`, `현재 인증 상태`, 기본 CTA만 먼저 보이고, `체크리스트`, `계정 메타데이터`, `Claude Code CLI OAuth 상세 가이드`는 `고급 설정 > 상세 인증 상태`로 내렸습니다.
- 같은 통합에서 현재 앱의 과한 문제는 단순히 카드 수가 많다는 것이 아니라 `처음 해야 할 행동`과 `진단/설명`이 같은 깊이에 섞여 있던 점이었습니다. 이번 정리는 그 층위를 다시 분리한 것입니다.
- 2026-04-02 63차 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift), [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift), [PopoverViewModel.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/PopoverViewModel.swift) 의 provider 문구를 runtime 구현 상태에 맞춰 다시 정리했습니다. `Gemini` / `Antigravity`는 더 이상 `설정 shell`, `준비 중`처럼 읽히지 않고, `활성`, `로그인 필요`, `연결 필요`, `감지됨`처럼 실제 다음 행동이 드러나는 표현을 우선 사용합니다.
- 2026-04-02 64차 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 의 Claude 인증 메인 영역을 한 번 더 줄였습니다. 저장된 sessionKey가 있어도 메인 화면에서는 키 조각을 직접 노출하지 않고, `현재 연결 상태`, `상태 새로고침`, `웹 로그인 다시 열기`, `로그아웃` 같은 즉시 행동만 남기며 실제 수동 입력과 세부 테스트는 고급 설정으로 보냈습니다. 같은 통합에서 [SetupWizardWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SetupWizardWindowView.swift) 도 `설정 열기`, `Organization`, `주요 CTA`가 한 번에 경쟁하던 구성을 줄여, 현재 단계에서 필요한 행동 하나와 보조 행동 하나만 남기도록 정리했습니다.
- 2026-04-02 65차 통합에서 [SetupCompletionPolicy.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/SetupCompletionPolicy.swift) 에 `shouldShowSetupFlow(...)` 를 추가해, standalone wizard 노출 여부와 settings 내부 setup 안내 노출 여부가 같은 policy를 보도록 맞췄습니다. 이에 따라 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 와 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 의 완료 판정 중복을 줄였고, settings가 임의 조건으로 `hasCompletedSetupWizard` 를 다시 뒤집는 경로를 정리했습니다.
- 2026-04-02 66차 통합에서 [LoginWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/LoginWindowView.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift), [SetupWizardWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SetupWizardWindowView.swift) 의 온보딩 연결을 더 닫았습니다. 로그인 창은 이제 `Chrome에서 가져오기`를 주 행동으로, `Chrome 로그인 열기`를 준비 행동으로 더 명확히 구분하고, 창 내부에서 바로 `고급 설정`으로 넘어갈 수 있습니다. wizard의 보조 버튼도 `다른 방법 보기` 같은 모호한 표현 대신 실제 목적지인 `고급 설정`으로 맞췄습니다.
- 2026-04-02 67차 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 의 Claude 고급 설정 안쪽도 한 번 더 층위를 나눴습니다. `Messages 헤더 기반 보조 조회`와 `FAQ`는 이제 `복구 및 도움말` 묶음 안에서 한 번 더 열어야 보이므로, 고급 설정 진입 직후에는 `상세 인증 상태`와 `수동 sessionKey` 같은 핵심 작업만 먼저 읽히게 됩니다.
- 2026-04-02 68차 통합에서 [README.md](/Users/seongmin/Personal/ClaudeUsage/README.md) 와 [docs/authentication-and-sources.md](/Users/seongmin/Personal/ClaudeUsage/docs/authentication-and-sources.md) 도 현재 UI 흐름에 맞게 다시 정리했습니다. 이제 문서는 `앱 안에서 처음 누를 기본 CTA는 Chrome 가져오기`이지만, `장기적으로 가장 안정적인 운영 경로는 Claude Code CLI OAuth`라는 점을 분리해서 설명합니다. 즉 제품 카피와 문서가 같은 의미를 다른 문장으로 말하던 어긋남을 줄였습니다.
- 2026-04-02 69차 통합에서 [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift) 는 runtime provider를 처음 켰을 때 메뉴바가 완전히 비어 보이지 않도록 기본 표시값을 더 일관되게 맞췄습니다. `Codex` 기본값도 `아이콘 + 현재 세션 퍼센트`로 올렸고, `Gemini` / `Antigravity` 처럼 새 runtime provider가 활성화될 때 사용자가 아직 표시 옵션을 손대지 않았다면 최소 visible preset(`showIcon = true`, `percentageDisplay = fiveHour`)을 자동으로 적용합니다.
- 같은 통합에서 이 보정은 사용자가 이미 표시 옵션을 명시적으로 바꾼 provider에는 적용하지 않으므로, `자유도 유지` 원칙은 그대로 두고 `켜졌는데 아무것도 안 보임` 문제만 줄입니다.
- 2026-04-02 70차 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 의 Claude 인증 기본 화면을 다시 줄였습니다. 더 이상 `현재 인증 상태` 카드 아래에 저장된 세션 전용 카드가 따로 공존하지 않고, 기본 화면은 `현재 상태`와 `다음 행동`만 보여줍니다.
- 같은 통합에서 자격이 이미 있으면 기본 화면에서 `상태 새로고침`, `Organization 열기`, `다시 로그인`만 우선 제공하고, `수동 sessionKey`, `보조 복구`, `FAQ`는 계속 고급 설정 안쪽에 남깁니다. 자격이 아직 없을 때도 기본 CTA는 `Chrome에서 가져오기`와 `웹 로그인 열기`만 남겨, 경로 설명보다 행동이 먼저 읽히게 했습니다.
- 2026-04-02 71차 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 settings 내부에 별도 `빠른 시작` wizard를 다시 그리지 않도록 바꿨습니다. 이제 first-run용 단계 플로우는 standalone [SetupWizardWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SetupWizardWindowView.swift) 가 맡고, settings의 Claude 인증 탭은 post-setup 상태 확인과 조정에 집중합니다.
- 같은 통합에서 이 정리로 settings 안에서 `first-run 단계 설명`과 `현재 인증 상태`가 같은 깊이에서 경쟁하던 중복을 줄였습니다. 즉 역할을 `wizard = 초기 연결`, `settings = 이후 조정`으로 더 분명히 나눈 것입니다.
- 2026-04-02 90차 통합에서 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 `메뉴바 표시 끔`인 runtime provider가 더 이상 로그인/연결 경고를 메뉴바에 다시 섞지 않도록 필터를 한 번 더 강화했습니다. `enabled runtime provider`와 `visible in menu bar`를 같은 조건으로 맞춰, 숨긴 provider는 메뉴바 요약과 경고 모두에서 빠집니다.
- 같은 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 `Gemini` / `Antigravity`의 `팝오버` / `알림` 탭명을 실제 역할 기준으로 `동작` / `알림 사용`으로 정리했습니다. `간소화 보기`는 runtime provider 공통값이고, 임계값 프리셋은 공통 알림이 원본이라는 점도 화면에 직접 적어 중복 설정처럼 읽히는 문제를 줄였습니다.
- 같은 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 의 `hasReadyClaudeCredential` 는 아직 저장하지 않은 수동 sessionKey 입력값을 `자격 준비 완료`로 치지 않도록 보수적으로 바뀌었습니다. 이제 first-run/설정의 준비 상태는 실제 저장된 sessionKey 또는 runtime health snapshot이 감지한 자격만 기준으로 계산합니다.
- 같은 통합에서 [UpdateService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/UpdateService.swift) 와 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 `Sparkle 내부 스케줄러`처럼 잘못 읽히던 설명을 제거하고, `Sparkle 앱내 확인 + 앱 타이머 기반 자동 확인`이라는 현재 구현 의미에 맞게 문구를 수정했습니다.
- 같은 통합에서 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 standalone wizard의 `자동 선택으로 전환` 경로에서 organization 상태 동기화와 snapshot 갱신이 끝난 뒤 창을 닫도록 순서를 바꿨습니다. 이로써 wizard를 닫자마자 settings 카드가 잠깐 이전 organization 기준으로 남는 경쟁 조건을 조금 더 줄였습니다.
- 2026-04-02 91차 통합에서 [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift) 안으로 `NotificationPreset` 타입을 직접 옮기고 별도 [NotificationPresetModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/NotificationPresetModels.swift) 파일을 제거했습니다. Xcode 동기화 상태에 따라 `Cannot find type 'NotificationPreset'`가 다시 뜨던 경로를 막기 위한 조치입니다.
- 같은 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 `Organization` 관련 진행 상태를 두 층으로 나눴습니다. 인증 카드와 체크리스트는 `현재 실제 적용된 preferredOrganizationID` 기준의 `appliedSetupProgress`를 사용하고, organization 화면의 수동 선택 편집 UI만 `selectedOrganizationID` 기준의 `pendingSetupProgress`를 사용합니다.
- 같은 통합에서 이 분리로 wizard를 닫은 직후나 settings에서 organization을 편집 중일 때, `현재 인증 상태` 카드가 아직 적용되지 않은 입력값 때문에 흔들리는 문제를 줄였습니다. 즉 `현재 상태`와 `편집 중인 값`을 더 이상 같은 진행도에 섞지 않습니다.
- 같은 통합에서 `Gemini` / `Antigravity` provider 탭의 알림 영역은 더 이상 공통 알림을 다시 편집하지 않습니다. provider 탭은 `공통 알림 대상인지`만 요약하고, 실제 프리셋/발송 대상 편집은 `공통 알림` 화면으로 바로 보내는 구조로 정리했습니다.
- 2026-04-02 72차 통합에서 [SetupWizardWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SetupWizardWindowView.swift) 도 같은 원칙으로 더 줄였습니다. 단계 요약 문구를 짧게 다듬고, checklist는 현재 단계에서 필요한 확인 위주로만 노출해 `설명 3개 + 체크 3개`가 동시에 경쟁하던 구조를 완화했습니다.
- 같은 통합에서 wizard는 이제 `현재 해야 할 행동 1개 + 남은 확인`에 더 가깝게 읽히므로, settings에서 빠진 first-run 설명의 빈자리를 과도한 텍스트로 다시 채우지 않습니다.
- 2026-04-02 73차 통합에서 [UpdateService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/UpdateService.swift) 는 `AppUpdateEngine` 추상화 뒤로 현재 GitHub Release 수동 업데이트를 넣기 시작했습니다. 이 단계에서 업데이트 코드는 `엔진 인터페이스 -> 현재 구현체(GitHub)` 구조를 갖추기 시작했으므로 Sparkle 래퍼를 같은 자리에 넣을 발판이 생겼습니다.
- 같은 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 현재 업데이트 엔진 모드를 직접 보여주기 시작했습니다. 사용자는 이제 설정에서 `지금은 GitHub 수동 업데이트`, 이후 `Sparkle 전환 예정`이라는 제품 상태를 더 명확히 이해할 수 있습니다.
- 2026-04-02 74차 통합에서 [ClaudeUsage.xcodeproj/project.pbxproj](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage.xcodeproj/project.pbxproj) 와 [ClaudeUsage.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) 에 Sparkle 2.8.1 Swift Package를 실제로 통합했습니다. 이제 앱은 Debug 빌드에서도 Sparkle.framework 를 정상 링크하며, `UpdateService` 와 설정 UI는 `Sparkle 가능 시 내부 확인`, `feed/appcast 미설정 시 GitHub Release fallback` 구조로 동작합니다.
- 같은 통합에서 [UpdateService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/UpdateService.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift), [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 Sparkle가 외부 스케줄러를 가질 때 앱 내부 업데이트 타이머를 멈추고, 설정 화면도 `Sparkle로 확인` 과 `수동 다운로드` UX를 엔진 상태에 따라 분기하도록 정리했습니다. appcast/feed 와 공개키가 준비되지 않은 현재 개발 빌드에서는 여전히 GitHub Release 엔진이 자동 fallback 되므로, Sparkle 패키지를 넣었다고 해서 개발 중 업데이트 흐름이 즉시 깨지지는 않습니다.
- 2026-04-02 69차 통합에서 [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift) 는 4개 이상 provider가 켜졌을 때 상단 selector를 가로 스크롤로 바꾸고, `last updated` 메타데이터를 접도록 수정했습니다. 이로써 `Claude/Codex/Gemini/Antigravity`를 모두 켠 상태에서도 상단 헤더가 잘리거나 줄바꿈으로 깨지는 문제가 줄었습니다.
- 같은 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 수동 sessionKey 테스트 성공 후 `키 저장 -> Claude 상태 동기화 -> 설정/팝오버 반영`을 순차적으로 기다리도록 바꿨습니다. 동시에 Claude 인증 기본 화면은 안정 상태에서는 `문제 해결 및 수동 입력`을 접어 두고, 실제 이슈가 있거나 수동 입력이 바뀐 경우에만 고급 인증 섹션을 기본 노출하도록 줄였습니다.
- 2026-04-02 70차 통합에서 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 설정 창을 열 때 더 이상 무조건 Claude 인증 탭으로만 보내지 않도록 수정했습니다. 이제 standalone setup wizard가 필요한 상태에서는 현재 진행 단계에 따라 `인증 -> 상태 -> Organization` 탭으로 진입점을 맞추므로, first-run과 settings가 서로 다른 단계를 가리키는 어색한 공존이 줄어듭니다.
- 2026-04-02 71차 통합에서 [UpdateService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/UpdateService.swift), [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 업데이트 엔진의 실제 준비 상태를 별도 모델로 노출하기 시작했습니다. 설정 화면은 이제 `Sparkle 통합 여부`, `appcast(feed) 설정 여부`, `공개키 설정 여부`를 직접 보여주므로, 왜 현재 빌드가 GitHub fallback으로 동작하는지 추론하지 않아도 됩니다.
- 2026-04-02 72차 통합에서 [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift), [ServiceSelectionHelper.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ServiceSelectionHelper.swift), [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 `provider 활성화`와 `메뉴바 표시`를 분리했습니다. 이제 provider는 popover/새로고침에는 참여하되 메뉴바에는 숨길 수 있고, 메뉴바 active service 선택도 실제로 보이는 provider만 대상으로 계산합니다.
- 2026-04-02 75차 통합에서 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 의 Claude refresh 성공 경로에서 남아 있던 `hasCompletedSetupWizard` 직접 대입도 `setClaudeSetupCompleted(...)` helper 경유로 바꿨습니다. 이제 runtime ownership 관점에서 setup 완료 상태 직접 대입은 사실상 `AppDelegate` helper 한 곳과 `AppSettings` 자체 보관 경로만 남아, `SettingsView` / refresh 경로 / login 경로가 각자 flag 를 뒤집는 구조는 정리된 상태입니다.
- 2026-04-02 76차 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 Claude 인증 기본 화면의 정보 밀도를 한 단계 더 줄였습니다. 기본 화면에는 `현재 인증 상태 + 다음 행동`만 남기고, `웹 로그인`, `수동 입력`, `복구 및 도움말`은 더 안쪽으로 밀어 `상태 카드와 진단 카드가 같은 깊이에서 경쟁`하던 구조를 줄였습니다.
- 같은 통합에서 [SetupWizardWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SetupWizardWindowView.swift), [SetupWizardView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/Components/SetupWizardView.swift), [LoginWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/LoginWindowView.swift) 는 `현재 단계 1개 + 보조 경로는 실패 시에만`이라는 원칙으로 문구와 CTA를 줄였습니다. 즉 first-run과 로그인창에서 `권장 경로`, `대체 경로`, `수동 입력`이 동시에 같은 무게로 보이던 상태를 완화했습니다.
- 같은 통합에서 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 `showInitialClaudeSetupFlow()` 진입과 setup wizard 완료 버튼 처리 직전에 현재 `credential + fetch + organization` 상태로 `hasCompletedSetupWizard` 를 다시 동기화하도록 보강했습니다. 이로써 stale setup flag 때문에 wizard/settings가 서로 다른 완료 상태를 보던 경로를 조금 더 줄였습니다.
- 2026-04-02 77차 통합에서 [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift) 의 `hasCompletedSetupWizard` 기본값은 더 이상 `sessionKey 존재 여부`로 올라가지 않게 바꿨습니다. 이제 setup 완료는 실제 `성공 조회 + organization readiness` 경로에서만 올라가며, 저장된 세션키만으로 wizard가 조용히 스킵되는 잘못된 기본값을 제거했습니다.
- 같은 통합에서 [SetupCompletionPolicy.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/SetupCompletionPolicy.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 standalone setup wizard 노출을 stale persisted flag보다 현재 progress 기준으로 보게 정리했습니다. 즉 현재 상태가 미완료면 wizard를 보여주고, 현재 상태가 완료면 과거 false flag 때문에 다시 띄우지 않게 바꿨습니다.
- 2026-04-02 78차 통합에서 [Info.plist](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Info.plist), [UpdateService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/UpdateService.swift), [Config/Sparkle.release.example.xcconfig](/Users/seongmin/Personal/ClaudeUsage/Config/Sparkle.release.example.xcconfig) 로 Sparkle 실제 배포 설정 경계를 코드에 올렸습니다. 개발 빌드는 `$(SUFeedURL)` / `$(SUPublicEDKey)` 같은 unresolved placeholder를 미설정으로 간주해 여전히 GitHub fallback을 쓰고, 서명 릴리즈에서는 release 전용 xcconfig로 feed/public key를 주입할 수 있습니다.
- 2026-04-02 79차 통합에서 [SetupCompletionPolicy.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/SetupCompletionPolicy.swift), [SetupWizardWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SetupWizardWindowView.swift), [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 `Organization` 흐름을 더 분명하게 정리했습니다. 자동 선택 사용자는 이제 `바로 사용 가능`으로 읽히고, wizard의 secondary CTA도 `자동 선택으로 완료`로 바뀌어 수동 organization 확인이 필요한 경우와 아닌 경우를 더 구분합니다.
- 2026-04-02 80차 통합에서 [Scripts/prepare-sparkle-release.sh](/Users/seongmin/Personal/ClaudeUsage/Scripts/prepare-sparkle-release.sh) 를 추가했습니다. 이 스크립트는 실제 서명이나 appcast 생성까지 하지는 않지만, `SUFeedURL` / `SUPublicEDKey` 환경과 release xcconfig 준비 상태를 먼저 점검하는 골격으로 사용합니다.
- 2026-04-02 81차 통합에서 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 최초 runtime provider 감지 시 `Gemini` / `Antigravity` 를 자동으로 활성화하지 않도록 바꿨습니다. 이제 초기 감지는 로컬 환경 존재 여부를 로그로만 남기고, 실제 활성화는 사용자가 직접 결정하므로 신규 설치에서도 bootstrap이 설정값을 덮지 않습니다.
- 같은 통합에서 [SetupWizardWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SetupWizardWindowView.swift), [LoginWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/LoginWindowView.swift) 는 현재 단계와 무관한 안내를 더 줄였습니다. setup wizard는 `credential` 단계에서만 인증 방법 카드를 보이고, `verification / organization` 단계에서는 현재 해야 할 행동만 남기도록 줄였습니다. 로그인 창도 `Chrome에서 가져오기`를 더 분명한 주 행동으로 두고 나머지 CTA를 보조 위치로 정리했습니다.
- 같은 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 업데이트 엔진 칩을 `Sparkle 통합 여부`가 아니라 `실제 동작 엔진` 기준으로 보여주도록 바꿨습니다. 이제 feed/public key가 빠져 GitHub fallback으로 도는 빌드에서는 `Sparkle 통합`이 실제 자동업데이트처럼 읽히지 않습니다.
- 2026-04-02 82차 통합에서 [build-notarize-release.sh](/Users/seongmin/Personal/ClaudeUsage/Scripts/build-notarize-release.sh) 를 추가했습니다. 이 스크립트는 실제 release xcconfig 와 `NOTARY_PROFILE` 이 준비된 상태에서 `xcodebuild archive -> ZIP 생성 -> notarytool 제출 -> stapler` 까지 한 번에 수행하는 골격입니다.
- 같은 통합에서 [apple-developer-update.md](/Users/seongmin/Personal/ClaudeUsage/apple-developer-update.md), [README.md](/Users/seongmin/Personal/ClaudeUsage/README.md) 도 이 스크립트를 기준으로 갱신했습니다. 따라서 현재 레포는 더 이상 Sparkle 배포를 문서 설명만으로 남겨두지 않고, 실제 릴리즈 직전에 필요한 로컬 실행 경로까지 포함합니다.
- 2026-04-02 83차 통합에서 [generate-sparkle-appcast.sh](/Users/seongmin/Personal/ClaudeUsage/Scripts/generate-sparkle-appcast.sh) 를 추가했습니다. 이 스크립트는 notarized ZIP 이 모인 디렉토리와 `DOWNLOAD_BASE_URL` 을 받아 `generate_appcast` 로 Sparkle appcast.xml 을 생성하는 골격입니다.
- 같은 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 Claude 고급 설정의 `복구 및 도움말` 노출을 더 줄였습니다. 이제 CLI OAuth 안내는 실제로 필요한 경우에만 보이고, FAQ도 실패/복구 상황이 아닐 때는 접혀 있어 기본 화면의 정보 밀도를 더 낮춥니다.
- 2026-04-02 84차 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 의 `Organization` 탭을 자동 선택 중심으로 다시 정리했습니다. 이제 기본 상태에서는 현재 모드 요약 카드만 먼저 보이고, 여러 organization을 직접 고를 때만 수동 선택 컨트롤과 미리보기 목록을 펼치도록 바꿨습니다.
- 2026-04-02 85차 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 의 `세션키 연결 테스트` 를 저장 경로와 분리했습니다. 이제 테스트는 연결 확인만 수행하고, 실제 Keychain 저장과 전역 반영은 `적용/저장` 시점에만 일어나므로 테스트만 눌러도 매번 키체인 저장이 반복되던 구조를 줄였습니다.
- 같은 통합에서 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 의 `onSessionKeyStored` 우회 동기화 경로도 제거해, 수동 sessionKey는 더 이상 `테스트 성공 = 저장 완료`처럼 읽히지 않게 정리했습니다.
- 2026-04-02 86차 통합에서 [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift) 의 persisted `hasCompletedSetupWizard` 상태를 제거했습니다. 이제 standalone setup wizard 노출과 완료 판정은 더 이상 stale UserDefaults flag에 기대지 않고, 현재 `credential + 성공 조회 + organization readiness` 상태와 [SetupCompletionPolicy.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/SetupCompletionPolicy.swift) 로만 계산됩니다.
- 같은 통합에서 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 setup 완료 동기화 helper와 직접 대입 경로를 제거했습니다. 이에 따라 로그인/로그아웃/refresh/settings 적용이 setup flag를 따로 밀어 넣지 않고, 런타임 상태 변화만으로 wizard/설정 흐름이 결정되도록 정리했습니다.
- 2026-04-02 87차 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 의 Claude 인증 기본 화면은 더 이상 문제 상황이라고 해서 고급 섹션을 자동으로 펼치지 않습니다. 이제 기본 화면은 `현재 상태 + 다음 행동`만 유지하고, `수동 sessionKey / 보조 복구 / CLI OAuth 안내 / FAQ`는 사용자가 직접 펼칠 때만 보이므로 정보 과밀도가 한 단계 더 내려갔습니다.
- 같은 통합에서 고급 인증 진입 버튼은 현재 문제의 성격을 `CLI OAuth 권장`, `복구 설정 있음`, `진단 필요`, `저장 전 수동 입력`처럼 짧게 요약해 보여줍니다. 즉 상세 내용을 기본 화면에 밀어넣지 않고도, 왜 고급 섹션이 필요한지는 첫 줄에서 바로 파악할 수 있도록 정리했습니다.
- 2026-04-02 88차 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 의 업데이트 섹션은 Sparkle이 아직 GitHub fallback으로 도는 경우 `왜 그런지`만 아니라 `다음에 뭘 해야 하는지`도 바로 보여주기 시작했습니다. 이제 설정 화면에서 `release xcconfig에 SUFeedURL/SUPublicEDKey 채우기 -> build-notarize-release.sh -> generate-sparkle-appcast.sh` 순서를 바로 확인할 수 있으므로, 배포 문서를 다시 찾아가야 하는 왕복이 줄어듭니다.
- 2026-04-02 104차 통합에서 [ProviderEnvironmentDetector.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ProviderEnvironmentDetector.swift), [AntigravityStatusProbe.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AntigravityStatusProbe.swift), [PopoverViewModel.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/PopoverViewModel.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 를 손봐 `Gemini`는 실제 OAuth 자격 기준으로, `Antigravity`는 `~/.antigravity` 와 `~/Library/Application Support/Antigravity` 및 앱 실행 상태 기준으로 더 정확하게 상태를 보여주도록 보강했습니다. 이전 실패 상태를 다시 켰을 때 그대로 들고 가던 `Gemini/Antigravity` auth error도 활성화 시 초기화해 false negative를 줄였습니다.
- 2026-04-02 105차 통합에서 [SetupWizardWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SetupWizardWindowView.swift) 와 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 의 organization 단계 흐름을 바로잡았습니다. 이제 `자동 선택으로 전환`은 실제로 `preferredOrganizationID` 를 비우고 wizard 를 닫으므로, 라벨과 동작이 어긋나지 않습니다.
- 2026-04-02 106차 통합에서 [Release.xcconfig](/Users/seongmin/Personal/ClaudeUsage/Config/Release.xcconfig) 를 추가하고 [ClaudeUsage.xcodeproj/project.pbxproj](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage.xcodeproj/project.pbxproj) Release 설정이 이 파일을 읽게 연결했습니다. 로컬 비밀값은 `.gitignore` 된 `Config/Sparkle.release.local.xcconfig` 에서 덮어쓰도록 바꿨고, [build-notarize-release.sh](/Users/seongmin/Personal/ClaudeUsage/Scripts/build-notarize-release.sh) 와 배포 문서도 이 경로 기준으로 맞췄습니다.
- 2026-04-02 89차 통합에서 [LoginWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/LoginWindowView.swift), [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 Keychain 프롬프트가 `연결 테스트`가 아니라 `실제 저장` 시점에만 뜬다는 점을 화면에 직접 명시하기 시작했습니다. 이로써 수동 sessionKey 경로에서 `테스트 성공`, `저장`, `macOS 확인 창`의 의미가 더 분리되고, 왜 어떤 시점에만 키체인 확인이 뜨는지 설명 책임도 코드 안으로 들어왔습니다.
- 2026-04-02 49차 통합에서 [GeminiUsageModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/GeminiUsageModels.swift), [GeminiAPIService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/GeminiAPIService.swift), [GeminiRuntimeRefresher.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/GeminiRuntimeRefresher.swift) 를 추가했고, `~/.gemini/oauth_creds.json` 과 Gemini CLI 설치 경로의 OAuth 설정을 직접 읽어 quota API를 호출하는 최소 runtime 경로를 붙였습니다.
- 같은 통합에서 [ProviderStateModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/ProviderStateModels.swift), [RuntimeProviderModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/RuntimeProviderModels.swift), [RuntimeRefreshHandlerRegistry.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/RuntimeRefreshHandlerRegistry.swift), [ServiceSelectionHelper.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ServiceSelectionHelper.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 `Gemini` 를 실제 runtime provider로 인식하고 refresh/backoff/state snapshot/menu bar/popup selection 경로에 포함하기 시작했습니다.
- 같은 통합에서 [MenuBarIconFactory.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Utilities/MenuBarIconFactory.swift), [MenuBarStatusComposer.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Utilities/MenuBarStatusComposer.swift), [PopoverViewModel.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/PopoverViewModel.swift), [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift), [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift) 는 `Gemini` 의 메뉴바 아이콘/요약/리셋 시간/compact·standard popover 렌더링과 기본 표시 설정 저장을 시작했습니다.
- 같은 통합에서 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 성공 조회 직후 cached profile metadata를 읽어 현재 Claude 알림 정책으로 연결하기 시작했습니다.
- 2026-04-02 50차 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift), [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift) 는 Claude 세션키 연결 테스트 성공 시 실제 런타임 credential 동기화를 바로 실행하고, 로그인 직후 메뉴바와 popover가 서로 다른 상태를 보이던 경로를 줄였습니다. popover는 이제 runtime snapshot을 우선 사용해 Claude 데이터를 그립니다.
- 2026-04-02 51차 통합에서 [ProviderStateModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/ProviderStateModels.swift), [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 `Gemini` 를 더 이상 `준비 상태` shell처럼 보이지 않게 정리했습니다. 설정 패널 상단 문구와 본문을 runtime provider 기준으로 바꿨고, `Antigravity` 만 여전히 coming-soon 경로로 남깁니다.
- 2026-04-02 52차 통합에서 [AntigravityStatusProbe.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AntigravityStatusProbe.swift), [ProviderEnvironmentDetector.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ProviderEnvironmentDetector.swift) 는 `Antigravity` 감지를 단순 상태 디렉토리 존재 여부에서 실제 `language_server_macos` 프로세스 기반으로 올렸습니다. 이제 `--app_data_dir antigravity` 또는 `/antigravity/` marker가 붙은 로컬 language server 실행 여부를 함께 보므로, 이후 runtime probe를 붙일 발판이 더 정확해졌습니다.
- 2026-04-02 53차 통합에서 [LoginWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/LoginWindowView.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 `세션키 추출 성공`과 `세션키 저장/반영 완료`를 분리했습니다. 이제 로그인 창은 실제 저장과 런타임 반영이 끝난 뒤에만 성공으로 표시하고 자동으로 닫히며, 실패 시 창을 유지한 채 오류를 보여주므로 `저장 안 된 것 같다`는 착시를 줄입니다.
- 2026-04-02 38차 통합에서 [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift) 의 상단 service selector에 `lineLimit(1)`, `fixedSize`, `layoutPriority` 를 넣어 경고 점이 붙을 때 provider 이름이 두 줄로 감기던 레이아웃 버그를 고쳤습니다.
- 같은 통합에서 [SetupWizardView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/Components/SetupWizardView.swift), [SetupWizardWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SetupWizardWindowView.swift), [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 `Chrome 열기` 와 `웹 로그인 열기` CTA를 분리해, 단계 설명과 실제 동작이 어긋나던 wizard 흐름을 정리하기 시작했습니다.
- 2026-04-02 39차 통합에서 [RuntimeProviderModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/RuntimeProviderModels.swift) 에 `RuntimeProviderRefreshContext`, `RuntimeProviderDescriptor`, `RuntimeProviderRegistry` 를 추가했고, [ServiceSelectionHelper.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ServiceSelectionHelper.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 refresh 가능 조건과 `setup complete` 전환 판단을 service별 하드코딩보다 runtime registry를 통해 읽기 시작했습니다.
- 2026-04-02 40차 통합에서 [SetupWizardWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SetupWizardWindowView.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 독립 setup wizard에서 바로 `Organization` 설정 화면으로 진입할 수 있는 버튼을 추가해, 인증 후 다음 행동이 막히던 first-run 흐름을 조금 더 메웠습니다.
- 2026-04-02 41차 통합에서 [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift) 는 `claudeEnabled`, `codexEnabled`, `menuBarActiveService` 를 저장 중심 `@Published` 필드에서 계산형 compatibility layer로 내렸고, `providerStates` 변경 시에만 legacy `UserDefaults` 키를 갱신하도록 단순화했습니다. 이로써 provider 상태의 단일 원천이 더 명확해졌고, 다음 단계인 runtime registry 일반화와 Gemini 연결 전에 가장 큰 이중 저장 병목을 줄였습니다.
- 2026-04-02 42차 통합에서 [RuntimeProviderModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/RuntimeProviderModels.swift), [RuntimeRefreshHandlerRegistry.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/RuntimeRefreshHandlerRegistry.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 refresh 전략(`Claude`, `Codex`)을 runtime descriptor 쪽으로 끌어올리고, 실제 handler 배선을 별도 registry로 분리했습니다. 아직 결과 타입은 서비스별로 유지하지만, 다음 단계에서 `Gemini` 전략을 추가할 자리는 이 단계에서 확보했습니다.
- 2026-04-02 43차 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 first-run 완료 조건을 `자격 확보`만이 아니라 `첫 성공 조회`까지 포함하도록 보수적으로 강화했습니다. 세션 키를 저장했다고 바로 setup 완료로 치지 않게 바꿨고, organization 체크리스트도 성공 조회 전에는 완료로 보이지 않게 정리했습니다.
- 2026-04-02 44차 통합에서 [ProviderStateModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/ProviderStateModels.swift), [RuntimeProviderModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/RuntimeProviderModels.swift), [ServiceSelectionHelper.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ServiceSelectionHelper.swift) 는 provider descriptor가 `runtimeService + refreshStrategy` 를 함께 들고, `RuntimeProviderRegistry` 가 이를 직접 읽도록 맞췄습니다. 동시에 지원하지 않는 runtime service에 대해 조용히 기본 descriptor를 만들어주던 fallback을 제거해, 이후 `Gemini` 를 붙일 때 descriptor 누락이 감춰지지 않도록 정리했습니다.
- 2026-04-02 45차 통합에서 [SetupCompletionPolicy.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/SetupCompletionPolicy.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift), [SetupWizardWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SetupWizardWindowView.swift) 는 `setup 완료`를 단순 refresh 액션 진입이 아니라 실제 Claude 성공 조회와 organization readiness 기준으로만 올리도록 바꿨습니다. 자동 organization 모드에서는 첫 성공 조회로 완료되지만, 특정 organization을 고른 경우에는 wizard가 `Organization 열기`를 마지막 우선 CTA로 내세우도록 조정해 first-run 흐름을 더 닫았습니다.
- 2026-04-02 46차 통합에서 [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift) 는 `providerStates` 저장 시 레거시 `claudeEnabled` / `codexEnabled` / `menuBarActiveService` 키를 매 변경마다 다시 쓰지 않도록 정리했습니다. 이제 레거시 키는 init 시 버전 가드가 있는 단방향 마이그레이션에서만 갱신되고, 런타임 단일 원천은 `providerStates` 로 더 분명해졌습니다.
- 2026-04-02 47차 통합에서 [ProviderEnvironmentDetector.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ProviderEnvironmentDetector.swift), [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 `Gemini` / `Antigravity` shell 패널에 로컬 환경 감지 상태를 추가했습니다. 이제 단순히 `준비 중`만 보여주지 않고, CLI 설치/OAuth 자격/로컬 상태 디렉토리 감지 여부를 바로 보여주므로 다음 행동을 추론하기 쉬워졌습니다.
- 2026-04-02 48차 통합에서 [PopoverViewModel.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/PopoverViewModel.swift), [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 shell provider overview와 footnote도 로컬 감지 상태를 그대로 반영하도록 정리했습니다. 활성화된 `Gemini` / `Antigravity` 는 이제 overview 카드, badge, footnote에서 `감지됨` / `로그인 필요` 같은 실제 상태를 보여주므로 shell UX의 정보 밀도가 더 일관됩니다.

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

### E-2. 알림 UX 방향

- provider별로 별도 퍼센트 임계값 세트를 복제하지 않음
- 알림 프리셋은 공통으로 유지
- 각 프리셋은 `사용`, `끄기`를 개별로 선택 가능하게 둠
- `현재 세션`, `주간 세션`은 프리셋 대상 윈도우를 고르는 축으로만 남기고, 임계값 편집 UI와 섞지 않음
- 설정 화면에서는 알림 프리셋을 짧게 요약하고, 과도한 설명/토글 중복을 제거
- `NotificationManager` 도 공통 프리셋 정의를 기준으로 provider별 상태만 추적하도록 단순화

### F. 팝오버 UX 방향

- 권장안은 `하이브리드`
- provider가 하나만 활성화된 경우: 해당 provider 집중형
- provider가 둘 이상 활성화된 경우: 상단 `Overview` + provider 전환 탭
- Claude는 항상 첫 진입 포커스를 갖고, Overview는 보조 탭으로 제공
- 현재 서비스의 강점인 상세 사용량/리셋/상태 가시성은 유지
- CodexBar의 장점인 `Overview`, provider 전환, 통일된 카드형 구조는 선택적으로 도입
- 진단/고급 정보는 별도 섹션 또는 설정으로 분리
- 현재 반영
- [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift) 는 단일 provider 집중형과 멀티 provider overview형 전환을 분리하기 시작했습니다.
- `Gemini` / `Antigravity`는 팝오버에서 `설정 전용 provider`로 더 명시적으로 표시합니다.

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
- [ClaudeChromeCookieImportService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Auth/ClaudeChromeCookieImportService.swift) 는 `sk-ant-` 전제만 보던 경로를 완화해, `sessionKey` 쿠키 이름과 일반 토큰 패턴도 함께 보도록 보강했습니다.
- [LoginWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/LoginWindowView.swift) 에 `Chrome에서 가져오기` 진입점을 추가했습니다.
- [LoginWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/LoginWindowView.swift) 는 `Chrome 열기` 경로도 제공해, 실제 Chrome 로그인 후 재가져오기를 할 수 있게 했습니다.
- [LoginWebView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/LoginWebView.swift) 는 session key 추출 규칙을 [ClaudeSessionKeyExtractor.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Auth/ClaudeSessionKeyExtractor.swift) 로 분리했습니다.
- [LoginWebViewCoordinator.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/LoginWebViewCoordinator.swift) 로 `LoginWebView` 의 coordinator를 분리해, 뷰 어댑터와 WKWebView delegate 책임을 파일 단위로 나누기 시작했습니다.
- [ClaudeSessionKeyExtractor.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Auth/ClaudeSessionKeyExtractor.swift) 는 exact `sessionKey=` 뿐 아니라 `session_key`, `session-key`, 기타 session-like 쿠키명과 헤더 조각도 더 넓게 해석하도록 완화했습니다.
- [LoginWebViewCoordinator.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/LoginWebViewCoordinator.swift) 는 `HTTPCookieStorage.shared` 쿠키도 함께 스캔하도록 보강했습니다.
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
- [ClaudeAPIService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/ClaudeAPIService.swift) 의 health snapshot은 이제 `credentialAvailability`를 포함하고, [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 이를 이용해 `OAuth-only` bootstrap / 설정 적용 / 로그아웃 후 재평가까지 처리합니다.
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
- `Claude-Usage-Tracker`의 독립 `SetupWizard` 수준으로 `CLI 감지`, `Chrome 권장`, `웹 로그인`, `수동 session key`를 단계형으로 끝내는 첫 실행 플로우를 별도 창/시트로 완성해야 합니다.
- `CodexBar` 수준으로 `Chrome Safe Storage`, `Claude CLI Keychain`, `Chrome만 지원하는 이유`, `수동 입력이 필요한 경우`를 UI와 문서 양쪽에서 명확히 설명해야 합니다.
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
- [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift) 의 `menuBarDisplayChangePublisher` 로 display observer를 한곳에 모으기 시작했습니다.
- [RefreshScheduler.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/RefreshScheduler.swift) 로 timer lifecycle 일부를 `AppDelegate` 밖으로 이동시켰습니다.
- [ServiceSelectionHelper.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ServiceSelectionHelper.swift) 는 shell provider를 제외한 `runtime-enabled service` 기준으로 메뉴바/타이머 판단을 하도록 수정했습니다.
- [ProviderStateModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/ProviderStateModels.swift) 는 runtime provider / shell provider 메타데이터와 `enabledRuntimeProviderKinds`, `enabledShellProviderKinds`, `activeRuntimeProviderKind` 를 갖게 됐고, [ProviderSettingsRegistry.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/ProviderSettingsRegistry.swift) 는 이를 기반으로 패널/셸 descriptor를 생성합니다.
- [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 `OAuth-only` Claude 계정도 refreshable service로 인정하도록 bootstrap / refresh / timer / settings-apply / logout 경로를 다시 맞췄습니다.
- [RuntimeProviderModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/RuntimeProviderModels.swift) 의 `RuntimeProviderSnapshot` 과 [PopoverViewModel.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/PopoverViewModel.swift) 의 snapshot 기반 `runtimeServiceState` 계산으로, 팝오버 입력이 `usage/codexUsage/error/...` 개별 인자보다 provider 단위 컬렉션에 조금 더 가까워졌습니다.
- [MenuBarStatusComposer.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Utilities/MenuBarStatusComposer.swift) 는 `MenuBarProviderSnapshot` 기반 `singleProviderContent` / `multipleProviderContent` 를 추가했고, [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 active provider 배열에서 snapshot을 만들어 메뉴바를 갱신하도록 바뀌었습니다.
- [RuntimeProviderModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/RuntimeProviderModels.swift) 의 `RuntimeProviderStateCatalog` 도입으로 `AppDelegate` 내부 이중 상태 세트가 하나의 저장소로 모이기 시작했습니다.
- [ClaudeRuntimeRefresher.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ClaudeRuntimeRefresher.swift) 와 [CodexRuntimeRefresher.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/CodexRuntimeRefresher.swift) 도입으로, `AppDelegate` 안의 provider별 fetch 본체가 분리되기 시작했습니다.
- 아직 남음
- `AppDelegate`의 refresh/backoff execution을 더 coordinator 성격으로 분리하고, `ServiceSelectionHelper`의 Claude/Codex 2-provider 전제를 더 걷어내야 합니다.
- 참고 레포 비교 기준 추가 체크리스트
- `CodexBar`의 provider descriptor / fetch strategy 구조처럼 `runtime service registry` 와 `provider refresher` lookup을 도입해야 합니다.
- [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 의 `currentUsage`, `currentCodexUsage`, `currentError`, `codexError`, `isLoading`, `isCodexLoading`, `lastUpdated`, `codexLastUpdated` 같은 이중 필드를 `provider runtime state catalog` 로 통합해야 합니다.
- [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 의 `refreshUsage(force:)`, `refreshCodexUsage(force:)`, `clearRuntimeServiceState(_:)`, `clearStateForAuthPrompt(_:)`, `runtimePresentationState(for:)`, `runtimeActivationState(for:enabled:)`, `updateMenuBar()` 는 `Gemini` 진입 전에 provider lookup 기반으로 바뀌어야 합니다.
- [RefreshOrchestration.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/RefreshOrchestration.swift) 의 `markSetupComplete: state.service == .claude` 는 provider policy로 옮겨야 합니다.
- `PopoverViewModel` 과 메뉴바 렌더러는 `Claude/Codex` 쌍 인자를 넘기는 방식이 아니라 `provider presentation snapshot` 컬렉션을 소비하도록 바뀌어야 합니다.
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
- [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 의 Claude 인증 탭은 이제 `일반 사용자 흐름`, `인증 상태`, `고급 설정`을 더 명확히 분리합니다.
- [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift) 는 단일 provider일 때 `현재 provider` 집중 카드, 멀티 provider일 때 `Provider overview`를 먼저 보여주는 하이브리드 구조를 반영합니다.
- 사용자 피드백 기준으로 [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift) 의 본문은 다시 사용량 중심으로 단순화하고, provider overview / shell 정보는 설정 쪽에서 보도록 되돌리기 시작했습니다.
- [ProviderOverviewCardView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/Components/ProviderOverviewCardView.swift) 와 [PopoverProviderCards.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/Components/PopoverProviderCards.swift) 로 순수 렌더링 블록을 별도 컴포넌트로 분리하기 시작했습니다.
- [MenuBarStatusComposer.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Utilities/MenuBarStatusComposer.swift) 와 `ProviderMenuBarDisplayConfig` 도입으로 메뉴바 표시 로직의 시각 규칙과 설정 해석을 한 층 더 분리했습니다.
- [MenuBarStatusComposer.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Utilities/MenuBarStatusComposer.swift) 의 provider snapshot 렌더링 도입으로, 다중 provider 메뉴바는 더 이상 `combinedContent(claude,codex)` 전용 입력만 바라보지 않습니다.
- [PopoverViewModel.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/PopoverViewModel.swift), [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift), [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 이제 `usageHealthSnapshot.runtime.credentialAvailability` 를 이용해 `OAuth-only` 계정에서 잘못된 인증 경고를 덜 띄우도록 맞추기 시작했습니다.
- [PopoverViewModel.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/PopoverViewModel.swift) 는 이제 `runtimeSnapshots` 를 저장하고, snapshot 기반으로 요약/메타/경고점을 계산합니다.
- [ClaudeFetchModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/Claude/ClaudeFetchModels.swift), [NotificationManager.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/NotificationManager.swift), [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 이제 Claude metadata를 공통 알림 프리셋 문구와 요약 설명에 연결하고, `남은 사용량` 모드에서도 올바른 알림 문구를 사용합니다.
- [SetupWizardView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/Components/SetupWizardView.swift) 는 권장 경로 1개를 먼저 보여주고 다른 인증 방법은 접어 두는 구조로 바뀌어, 온보딩 단계에서 경로가 과도하게 경쟁하지 않도록 줄였습니다.
- [ClaudeAPIService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/ClaudeAPIService.swift) 와 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 `OAuth 감지`, `OAuth 검증`, `OAuth 확인 필요`를 구분해 표시하고, 실제 현재 자격이 없을 때는 `OAuth(폴백)` 경로를 더 이상 활성처럼 보여주지 않습니다.
- [ClaudeChromeCookieImportService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Auth/ClaudeChromeCookieImportService.swift) 는 `Local State`의 프로필 목록을 함께 읽어 Chrome 프로필 탐색 범위를 넓혔고, 자동 import 실패 안내도 긴 경로 나열 대신 짧은 실패 요약 중심으로 줄였습니다.
- [ClaudeKeychainStore.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Auth/ClaudeKeychainStore.swift), [KeychainManager.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/KeychainManager.swift), [SettingsWindowCoordinator.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/SettingsWindowCoordinator.swift) 는 세션키 테스트 시 keychain 프롬프트 반복과 설정창 자동 종료를 줄이는 방향으로 정리했습니다.
- 아직 남음
- `진단` / `업데이트` 섹션을 팝오버 메인 정보 흐름에서 얼마나 분리할지 추가 조정이 필요합니다.
- preset 체계와 provider 추가 시 카드 구조 일관성은 아직 남아 있습니다.
- `claude-code`의 `reset-aware` 문구 생성처럼 metadata 기반 경고 문구를 더 정교하게 만들고, `extra usage`, `team/enterprise`, `warning suppression` 정책을 provider별 알림 전체에 더 넓혀야 합니다.
- `CodexBar`의 UI 문서처럼 `Overview`, `provider row`, `권한 설명`, `고급 표시 옵션`을 제품 copy 수준으로 정리해야 합니다.
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
- 인증/소스 문서와 README는 현재 `Chrome 가져오기 -> 웹 로그인 -> 수동 sessionKey` 흐름과 `CLI OAuth 권장` 서사를 반영하도록 갱신했습니다.
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

### 참고 레포 비교로 추가 확인된 보완점

- `CodexBar`는 provider 추가 기준이 `descriptor + strategy + UI hook` 단위라서 새 provider가 들어와도 host API만 재사용하면 됩니다. 현재 앱은 아직 `Claude/Codex` 이중 배선을 걷어내는 중이라 `Gemini`를 붙이기 전 `provider runtime registry`를 먼저 끝내야 합니다.
- `Claude-Usage-Tracker`는 setup wizard가 단순 입력 화면이 아니라 `CLI 감지`, `내장 브라우저`, `수동 fallback`, `조직 선택`, `마이그레이션`까지 한 흐름으로 묶여 있습니다. 현재 앱도 설정 내부 보조 카드가 아니라 독립 `first-run flow` 완성도가 더 필요합니다.
- `claude-code`는 metadata를 저장하는 데서 멈추지 않고 실제 경고 문구와 정책 판단까지 연결합니다. 현재 앱은 `organizationUuid`, `subscriptionType`, `hasExtraUsageEnabled`, `rateLimitTier`를 저장하기 시작했지만 아직 `알림 문구/표시 정책`까지 소비하지 못합니다.
- `Claude Code OAuth` 실패 원인은 구현 버그가 섞여 있었습니다. 실제 토큰은 살아 있는데 `Messages` probe에 `User-Agent` / `anthropic-beta` 헤더가 빠져 `OAuth authentication is currently not supported` 401을 유발하던 경로를 수정했습니다.
- `Claude Code OAuth` 읽기 경로는 `Claude-Usage-Tracker`처럼 `~/.claude` credentials 파일 우선, 키체인 후순위로 재정렬했고, 만료 시각과 메모리 캐시를 같이 보도록 보강했습니다.
- Claude 인증 기본 화면은 `빠른 시작`이 노출되는 동안 별도 상태 카드와 저장 자격 카드를 겹치지 않게 줄였고, 상세 상태는 접힌 `조회 상태`/`고급 설정` 안으로 더 밀어 넣기 시작했습니다.
- Claude 인증 고급 설정 안에서도 `CLI OAuth 안내`를 `복구 및 도움말`로 내려, `상세 인증 상태`에는 체크리스트와 메타데이터만 남기도록 층위를 한 번 더 분리했습니다.
- 독립 `Setup Wizard` 는 `Organization 열기`와 `자동 선택 유지`를 분리해, organization 단계에서 설정창을 억지로 다시 열지 않고도 완료로 넘어갈 수 있게 정리했습니다.
- `SetupCompletionPolicy` 에 credential step 선택 로직을 올려 `AppDelegate` 와 `SettingsView` 가 같은 기준으로 `Chrome -> 웹 로그인 -> 수동 sessionKey` 흐름을 고르도록 맞추기 시작했습니다.
- `CodexBar`는 README와 provider 문서에 `권한 이유`, `로컬만 읽는 데이터`, `브라우저별 제약`, `키체인 prompt 정책`을 분명히 적습니다. 현재 앱도 설정 설명과 README, 향후 Sparkle 배포 문서에서 이 수준의 설명 책임을 져야 합니다.
- `CodexBar`와의 직접 비교 결과, `Gemini`는 단순 `oauth_creds.json -> retrieveUserQuota`만으로 끝나지 않고 `loadCodeAssist`와 Cloud Resource Manager project 탐색을 함께 써서 quota 정확도와 즉시성을 높입니다. 현재 앱도 이 흐름을 일부 가져와 `project` body를 포함한 quota 요청으로 올렸습니다.
- 같은 비교에서 `CodexBar`는 앱 시작 시 `provider detection -> enabled state 반영 -> 첫 refresh`를 자동으로 수행합니다. 현재 앱도 `Gemini` / `Antigravity` 에 대해 1회 초기 자동 감지·활성화를 추가했지만, 이후에는 사용자가 끈 상태를 다시 덮어쓰지 않도록 bootstrap 소유권을 더 분명히 해야 합니다.
- 2026-04-02 추가 비교 반영으로 [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 `providerStates`가 이미 저장된 기존 사용자에게 자동 감지가 다시 enable 상태를 덮어쓰지 않도록 수정했습니다. 즉 자동 활성화는 신규 설치 bootstrap에만 한정됩니다.
- 같은 통합에서 [ProviderEnvironmentDetector.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ProviderEnvironmentDetector.swift), [AntigravityStatusProbe.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AntigravityStatusProbe.swift) 는 `Antigravity`를 단순 실행/미실행이 아니라 `실행 중이지만 CSRF/연결 토큰이 없음` 상태까지 구분하도록 올렸습니다. 이제 `바로 못 가져오는` 이유가 설정과 popover에서 더 직접 드러납니다.
- 2026-04-02 후속 통합으로 [ProviderEnvironmentDetector.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ProviderEnvironmentDetector.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift), [PopoverViewModel.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/PopoverViewModel.swift) 는 `Gemini` / `Antigravity` 의 환경 감지 실패를 곧바로 `조회 차단`으로 이어가던 경로를 완화했습니다. 이제 `canAttemptRefresh` 기준으로 조회 시도 가능 여부를 판단하고, false negative 때문에 `로그인 필요` / `연결 필요`로만 고정되던 경로를 줄였습니다.
- 같은 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 `Gemini` / `Antigravity` 패널도 `인증 / 표시 / 팝오버 / 알림` 탭 구조로 정리해 Claude/Codex와의 설정 구조 차이를 줄였습니다. provider별 설정 자유도는 유지하되, 정보 구조는 최대한 같은 규칙을 따르게 맞추는 방향입니다.
- [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift), [PopoverProviderCards.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/Components/PopoverProviderCards.swift) 는 provider 수가 늘 때 폭을 더 넓히고 compact 행에서 reset 텍스트를 단계적으로 접도록 바꿔, 4개 이상 provider 활성화 시 잘리던 문제를 완화했습니다.
- 2026-04-02 저녁 재검증에서 `Gemini`는 현재 로컬 환경에서 `loadCodeAssist`와 `retrieveUserQuota`가 모두 `200`으로 응답함을 직접 확인했습니다. 따라서 `로그인 필요` 표시는 외부 환경 문제가 아니라 앱의 stale 오류/상태 판정 버그였고, [PopoverViewModel.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/PopoverViewModel.swift), [MenuBarStatusComposer.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Utilities/MenuBarStatusComposer.swift), [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 에서 일시 실패를 인증 실패처럼 승격시키지 않도록 수정했습니다.
- 같은 재검증에서 `Antigravity`는 현재 사용자 환경에 `language_server_macos_arm`, 로컬 connect 포트, `globalStorage/state.vscdb` 의 인증 상태가 모두 존재함을 확인했습니다. 따라서 기존 `language_server` 단일 신호 의존은 실제 환경을 과소감지했습니다. [ProviderEnvironmentDetector.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ProviderEnvironmentDetector.swift) 는 SQLite 기반 인증 상태 fallback을 읽고, [AntigravityAPIService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/AntigravityAPIService.swift) 는 `GetUnleashData` 실패 시 `GetUserStatus` 로 connect 포트 검증을 한 번 더 시도하도록 보강했습니다.
- 같은 수정으로 [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift) 는 4개 provider 이상 활성화 시 헤더 selector가 더 넓은 폭을 확보하고 버튼 텍스트를 가로 고정해, compact/standard 모두에서 잘림을 한 번 더 줄였습니다.
- 2026-04-02 야간 후속 수정으로 local provider(`Gemini`, `Antigravity`)는 detector false negative 하나로 refresh 자체가 막히지 않도록 [RuntimeProviderModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/RuntimeProviderModels.swift), [ProviderTransitionPolicy.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ProviderTransitionPolicy.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 를 조정했습니다. 이제 enabled 상태이면 일단 실제 fetch를 먼저 시도하고, 실패는 서비스 응답 기준으로 처리합니다.
- 같은 축의 후속 정리로 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift), [PopoverViewModel.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/ViewModels/PopoverViewModel.swift) 는 local provider snapshot의 `hasCredential` 과 `isAuthRequired` 우선순위를 바로잡았습니다. 실제 usage가 이미 있거나 환경이 감지된 상태에서는 detector false negative 때문에 `인증 필요`가 먼저 뜨지 않게 하는 것이 목적입니다.
- 같은 후속 수정으로 [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift) 와 [AppPopoverCoordinator.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppPopoverCoordinator.swift) 는 4개 이상 provider일 때 헤더를 2줄 구조로 바꾸고, coordinator도 `PopoverView` 와 같은 폭 계산을 쓰게 맞췄습니다. 이전처럼 view는 넓게 계산했지만 coordinator가 다시 좁히는 경로를 제거하는 것이 목적입니다.
- 2026-04-02 심야 재수정으로 [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift) 는 4개 이상 provider에서 단순 가로 스크롤 대신 adaptive grid 헤더를 쓰고, 탭 전환/첫 노출 시 아직 비어 있는 local provider를 즉시 다시 조회하도록 보강했습니다. 이전처럼 헤더가 한 줄에 눌리면서 잘리고, `Gemini`/`Antigravity`가 일시 실패 뒤 그대로 멈춰 있는 상태를 줄이기 위한 변경입니다.
- 같은 재수정으로 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 monitoring 시작 시 `refreshAll(force: true)` 로 첫 수집을 강제하고, `Gemini` / `Antigravity` 는 아직 usage가 없는 상태에서는 임시 백오프를 무시하고 다시 시도하도록 조정했습니다. 또한 refresh 시작 시 stale auth error를 먼저 지워, 실제 자격이 살아 있는데 이전 오류 문구가 계속 남는 현상을 줄였습니다.
- 같은 축에서 [AntigravityAPIService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/AntigravityAPIService.swift) 는 `https connect port -> http fallback port` 외에 `같은 포트의 HTTP fallback` 까지 시도하도록 보강했습니다. 현재 사용자 환경은 `54377 HTTPS` 가 살아 있지만, 다른 워크스페이스나 포트 조합에서는 같은 포트의 HTTP만 열리는 경우가 있어 이 fallback이 필요합니다.
- 2026-04-02 늦은 밤 재조정으로 [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift), [AppPopoverCoordinator.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppPopoverCoordinator.swift) 는 4개 provider 헤더를 감싸기 위해 popover 전체 폭을 과도하게 넓히던 접근을 되돌렸습니다. 현재는 탭 자체는 다시 가로 스크롤을 쓰고, 전체 popover 폭은 compact 약 400 / standard 약 520 기준으로 더 보수적으로 유지합니다. 즉 `탭 길이 문제`를 `창 전체 확장`으로 해결하던 잘못된 방향을 수정한 것입니다.
- 세션키 저장 직후 메뉴바, 팝오버, 설정이 서로 다른 상태를 보이던 문제를 줄이기 위해 `claudeSessionKeyDidChange` 반응을 `AppDelegate` 중심으로 모으기 시작했습니다. `SettingsView`가 `health snapshot`을 기준으로 `hasCompletedSetupWizard`를 다시 쓰던 경로는 제거했고, 전역 반영은 `AppRuntimeObservationCoordinator -> AppDelegate -> refresh/updateMenuBar/updatePopover` 순서로 단일화하고 있습니다.
- 같은 축의 후속 수정으로 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 `claudeSessionKeyDidChange` 알림을 받으면 snapshot을 읽기 전에 먼저 `ClaudeAPIService` 의 session key / preferred organization 상태를 현재 keychain 값으로 동기화합니다. keychain 알림이 서비스 상태 업데이트보다 먼저 와서 메뉴바, popover, settings가 서로 다른 snapshot을 보는 경쟁 조건을 줄이기 위한 변경입니다.
- 같은 세션키를 다시 저장할 때는 Keychain 저장을 건너뛰도록 바꿔, 테스트/적용 과정에서 불필요한 키체인 쓰기와 프롬프트를 줄이기 시작했습니다. 빠른 시작도 자격이 준비된 뒤에는 `다른 인증 방법`을 다시 펼치지 않도록 줄여 first-run 정보 밀도를 낮추고 있습니다.
- Claude 인증 설정에서 `상세 인증 상태`는 `복구 및 진단` 안쪽으로 다시 내려, 기본 고급 화면에는 `수동 sessionKey`와 `복구/도움말`만 먼저 보이게 정리하고 있습니다.
- persisted `hasCompletedSetupWizard` 를 제거했으므로, setup 완료는 더 이상 별도 저장 플래그가 아니라 현재 런타임 상태와 `SetupCompletionPolicy` 로만 판단합니다.
- 2026-04-02 늦은 저녁 마감 작업으로 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 `Organization` 섹션에 현재 모드와 검증 상태를 분리해 보여주고, `Sparkle` 업데이트 섹션은 `현재 상태 + 다음 행동` 요약 카드와 접히는 상세 단계로 정리했습니다. 즉 설정 화면에서 마감 전제 조건은 바로 읽히되, 긴 절차 설명은 기본 노출에서 뺐습니다.
- 같은 마감 작업으로 [SetupWizardWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SetupWizardWindowView.swift) 는 자동 organization 모드의 완료 CTA를 더 직접적인 문구로 바꾸고, 수동 organization 단계는 “특정 organization을 직접 고를 때만 필요한 단계”라는 점을 더 분명히 드러내도록 정리했습니다.
- 후속 정리로 [UpdateService.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Services/UpdateService.swift) 의 `SparkleUpdateEngine` 도 의미를 맞췄습니다. Sparkle 경로는 더 이상 `checkForUpdates()` 에서 무조건 최신이라고 응답하지 않고, 현재는 `앱 내부 Sparkle 확인 + GitHub fallback 백그라운드 확인` 구조로 동작합니다. `SUFeedURL` 은 유효한 `http/https` URL과 placeholder 배제를 통과해야만 설정된 것으로 간주합니다.
- 같은 축의 후속 작업으로 [Scripts/prepare-sparkle-release.sh](/Users/seongmin/Personal/ClaudeUsage/Scripts/prepare-sparkle-release.sh), [Scripts/build-notarize-release.sh](/Users/seongmin/Personal/ClaudeUsage/Scripts/build-notarize-release.sh) 는 `Config/Sparkle.release.local.xcconfig` 와 환경변수에서 `SUFeedURL` / `SUPublicEDKey` 를 읽고, `example.com`, `REPLACE_WITH`, `CHANGE_ME` 같은 placeholder 값이면 초기에 실패하도록 보강했습니다. release 준비가 늦게 깨지는 대신 스크립트 시작 시점에 바로 잡는 것이 목적입니다.
- 2026-04-02 심야 마감 후속으로 [SetupWizardWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SetupWizardWindowView.swift) 는 credential 단계에서 `웹 로그인`과 `수동 입력`을 wizard 하단에서 바로 노출하도록 바뀌었습니다. 이전처럼 manual fallback이 “존재하지만 settings 안쪽에 숨어 있는” 상태를 줄여, Chrome 경로가 막혀도 첫 실행 창 안에서 바로 다음 행동으로 내려갈 수 있게 정리하는 것이 목적입니다.
- 같은 후속 정리로 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift), [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift), [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 wizard의 `수동 입력` CTA가 단순히 일반 설정 창만 여는 것이 아니라, Claude 인증 탭과 `문제 해결 및 수동 입력` 섹션을 즉시 펼친 상태로 연결되도록 보강했습니다.
- 같은 시점에 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 의 기본 인증 상태 카드도 `currentSetupProgress.stage` 기준으로 완료 전/완료 후 subtitle을 달리 써, 첫 실행 직후와 안정 상태를 같은 톤으로 보여주던 문제를 줄였습니다.
- 추가로 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift) 는 정상 상태에서는 `문제 해결 및 수동 입력 보기` teaser 자체를 숨기도록 조정했습니다. setup이 끝났고 복구가 필요 없는 상태인데도 계속 문제 해결 CTA가 남아 있으면 마감된 화면처럼 보이지 않기 때문입니다.
- 같은 마감 후속으로 [SetupWizardWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SetupWizardWindowView.swift) 는 완료 단계에서 더 이상 `자격 준비 / 조회 검증 / Organization 확인` 체크리스트를 다시 보여주지 않도록 바뀌었습니다. wizard가 끝났는데도 wizard 문법이 계속 남아 있으면 사용자는 아직 미완료라고 느끼기 쉽기 때문입니다.

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

- 세션키 저장, 삭제, 재검증 이후 `메뉴바 / popover / settings`가 같은 snapshot을 보도록 전역 동기화 순서를 더 단단히 만들기
- 독립 `Setup Wizard` 를 첫 실행 전용 단계 라우팅으로 더 확장하고 Chrome/Keychain 권한 설명, organization 선택, 검증 완료 흐름을 완성하기
- `Messages fallback` 수동 테스트와 자동 정책의 의미를 UI와 내부 경로에서 더 명확히 분리하고, 자동/수동 모드의 진단 문구를 정리하기
- Claude 인증 설정의 정보 밀도를 더 줄여 `현재 상태 + 다음 1개 행동` 중심으로 남기고, 상세 상태/복구/FAQ는 한 단계 더 안쪽으로 내리기
- `세션키 연결 테스트` 를 검증 경로와 저장 경로로 더 깔끔하게 분리하고, 설정창의 성공/실패 후속 동작을 덜 놀랍게 만들기
- `Antigravity` runtime provider의 연결 상태/오류 문구를 더 사용자 친화적으로 다듬고, 실제 환경에서 포트 probe fallback과 응답 파싱 회복력을 보강하기
- provider별 메뉴바/팝오버 표시 자유도는 유지하되, 기본 preset / 고급 preset / 고급 도움말 copy 를 더 정리하기
- `Organization` 섹션과 wizard 단계에서 자동 선택 모드의 CTA/보조 설명을 더 줄여, 현재 단계의 한 가지 행동만 먼저 보이게 다듬기
- `Sparkle` 실제 배선을 `AppUpdateEngine` 추상화 뒤에 연결하고, README와 배포/업데이트 문서를 실제 구현 상태에 맞게 계속 갱신하기
