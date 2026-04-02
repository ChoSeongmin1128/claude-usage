# ClaudeUsage 작업 계획

최종 갱신: 2026-04-02 (45차)

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
- 같은 통합에서 [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 성공 조회 직후 cached profile metadata를 읽어 현재 Claude 알림 정책으로 연결하기 시작했습니다.
- 2026-04-02 38차 통합에서 [PopoverView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/PopoverView.swift) 의 상단 service selector에 `lineLimit(1)`, `fixedSize`, `layoutPriority` 를 넣어 경고 점이 붙을 때 provider 이름이 두 줄로 감기던 레이아웃 버그를 고쳤습니다.
- 같은 통합에서 [SetupWizardView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/Components/SetupWizardView.swift), [SetupWizardWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SetupWizardWindowView.swift), [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 `Chrome 열기` 와 `웹 로그인 열기` CTA를 분리해, 단계 설명과 실제 동작이 어긋나던 wizard 흐름을 정리하기 시작했습니다.
- 2026-04-02 39차 통합에서 [RuntimeProviderModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/RuntimeProviderModels.swift) 에 `RuntimeProviderRefreshContext`, `RuntimeProviderDescriptor`, `RuntimeProviderRegistry` 를 추가했고, [ServiceSelectionHelper.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ServiceSelectionHelper.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 refresh 가능 조건과 `setup complete` 전환 판단을 service별 하드코딩보다 runtime registry를 통해 읽기 시작했습니다.
- 2026-04-02 40차 통합에서 [SetupWizardWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SetupWizardWindowView.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 독립 setup wizard에서 바로 `Organization` 설정 화면으로 진입할 수 있는 버튼을 추가해, 인증 후 다음 행동이 막히던 first-run 흐름을 조금 더 메웠습니다.
- 2026-04-02 41차 통합에서 [AppSettings.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/AppSettings.swift) 는 `claudeEnabled`, `codexEnabled`, `menuBarActiveService` 를 저장 중심 `@Published` 필드에서 계산형 compatibility layer로 내렸고, `providerStates` 변경 시에만 legacy `UserDefaults` 키를 갱신하도록 단순화했습니다. 이로써 provider 상태의 단일 원천이 더 명확해졌고, 다음 단계인 runtime registry 일반화와 Gemini 연결 전에 가장 큰 이중 저장 병목을 줄였습니다.
- 2026-04-02 42차 통합에서 [RuntimeProviderModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/RuntimeProviderModels.swift), [RuntimeRefreshHandlerRegistry.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/RuntimeRefreshHandlerRegistry.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 refresh 전략(`Claude`, `Codex`)을 runtime descriptor 쪽으로 끌어올리고, 실제 handler 배선을 별도 registry로 분리했습니다. 아직 결과 타입은 서비스별로 유지하지만, 다음 단계에서 `Gemini` 전략을 추가할 자리는 이 단계에서 확보했습니다.
- 2026-04-02 43차 통합에서 [SettingsView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SettingsView.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift) 는 first-run 완료 조건을 `자격 확보`만이 아니라 `첫 성공 조회`까지 포함하도록 보수적으로 강화했습니다. 세션 키를 저장했다고 바로 setup 완료로 치지 않게 바꿨고, organization 체크리스트도 성공 조회 전에는 완료로 보이지 않게 정리했습니다.
- 2026-04-02 44차 통합에서 [ProviderStateModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/ProviderStateModels.swift), [RuntimeProviderModels.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Models/RuntimeProviderModels.swift), [ServiceSelectionHelper.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/ServiceSelectionHelper.swift) 는 provider descriptor가 `runtimeService + refreshStrategy` 를 함께 들고, `RuntimeProviderRegistry` 가 이를 직접 읽도록 맞췄습니다. 동시에 지원하지 않는 runtime service에 대해 조용히 기본 descriptor를 만들어주던 fallback을 제거해, 이후 `Gemini` 를 붙일 때 descriptor 누락이 감춰지지 않도록 정리했습니다.
- 2026-04-02 45차 통합에서 [SetupCompletionPolicy.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/SetupCompletionPolicy.swift), [AppDelegate.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/App/AppDelegate.swift), [SetupWizardWindowView.swift](/Users/seongmin/Personal/ClaudeUsage/ClaudeUsage/Views/SetupWizardWindowView.swift) 는 `setup 완료`를 단순 refresh 액션 진입이 아니라 실제 Claude 성공 조회와 organization readiness 기준으로만 올리도록 바꿨습니다. 자동 organization 모드에서는 첫 성공 조회로 완료되지만, 특정 organization을 고른 경우에는 wizard가 `Organization 열기`를 마지막 우선 CTA로 내세우도록 조정해 first-run 흐름을 더 닫았습니다.

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
- 아직 남음
- `진단` / `업데이트` 섹션을 팝오버 메인 정보 흐름에서 얼마나 분리할지 추가 조정이 필요합니다.
- preset 체계와 provider 추가 시 카드 구조 일관성은 아직 남아 있습니다.
- `claude-code`의 `reset-aware` 문구 생성처럼 metadata 기반 경고 문구를 더 정교하게 만들고, `extra usage`, `team/enterprise`, `warning suppression` 정책을 알림 프리셋에 연결해야 합니다.
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
- `CodexBar`는 README와 provider 문서에 `권한 이유`, `로컬만 읽는 데이터`, `브라우저별 제약`, `키체인 prompt 정책`을 분명히 적습니다. 현재 앱도 설정 설명과 README, 향후 Sparkle 배포 문서에서 이 수준의 설명 책임을 져야 합니다.

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

- `ClaudeRuntimeRefresher` / `CodexRuntimeRefresher` 를 `provider refresher registry` 로 한 단계 더 일반화하고 `Gemini`용 진입 자리를 만들기
- `PopoverService` 와 runtime capability를 분리한 descriptor/registry 위에 `Gemini` runtime 상태 shape를 얹을 수 있게 AppDelegate orchestration 남은 하드코딩을 줄이기
- `RuntimeProviderRefreshDriver` 수준의 최소 공통 인터페이스를 도입할지 검토하고, 도입 시에도 `Claude overage/profile metadata`, `Codex auth` 차이를 억지로 한 타입에 섞지 않도록 보수적으로 진행하기
- `AppSettings` 의 `claudeEnabled/codexEnabled/menuBarActiveService` legacy 브리지를 점진적으로 축소하고 `providerStates/providerSelectionState` 중심으로 읽히게 바꾸기
- 독립 `Setup Wizard` 를 첫 실행 전용 단계 라우팅으로 더 확장하고 Chrome/Keychain 권한 설명, organization 선택, 검증 완료 흐름을 완성하기
- metadata cache를 실제 알림 문구와 warning suppression 정책까지 더 넓혀 `fallback 빈도`, `팝오버 정책 문구`, `설정 요약`까지 연결하기
- README와 배포/업데이트 문서를 실제 구현 상태에 맞게 계속 갱신하기
