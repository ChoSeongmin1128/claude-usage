import Dispatch
import Foundation

extension AppDelegate {
    func withRuntimeState<T>(_ body: @MainActor (AppRuntimeStateFacade) -> T) -> T {
        // SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor이므로 거의 항상 메인 스레드에서 호출됨.
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                body(runtimeState)
            }
        }

        // 비메인 스레드 fallback — MainActor-isolated async 컨텍스트에서는 호출하지 말 것
        // (DispatchQueue.main.sync + MainActor = 데드락 가능)
        Logger.warning("withRuntimeState가 비메인 스레드에서 호출됨 — main queue로 동기 전환")
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                body(runtimeState)
            }
        }
    }

    func runtimeProviderState(for service: PopoverService) -> RuntimeProviderState {
        withRuntimeState { $0[service] }
    }

    func setRuntimeProviderState(_ state: RuntimeProviderState, for service: PopoverService) {
        withRuntimeState { $0[service] = state }
    }

    func updateRuntimeProviderState(
        for service: PopoverService,
        _ update: (inout RuntimeProviderState) -> Void
    ) {
        var state = runtimeProviderState(for: service)
        update(&state)
        setRuntimeProviderState(state, for: service)
    }

    var currentOverage: OverageSpendLimitResponse? {
        get { withRuntimeState { $0.currentOverage } }
        set { withRuntimeState { $0.currentOverage = newValue } }
    }

    var currentClaudeNotificationPolicy: ClaudeNotificationPolicy? {
        get { withRuntimeState { $0.currentClaudeNotificationPolicy } }
        set { withRuntimeState { $0.currentClaudeNotificationPolicy = newValue } }
    }

    var currentClaudeProfileMetadata: ClaudeProfileMetadata? {
        get { withRuntimeState { $0.currentClaudeProfileMetadata } }
        set { withRuntimeState { $0.currentClaudeProfileMetadata = newValue } }
    }

    var lastOverageFetchAt: Date? {
        get { withRuntimeState { $0.lastOverageFetchAt } }
        set { withRuntimeState { $0.lastOverageFetchAt = newValue } }
    }

    var systemStatus: ClaudeSystemStatus? {
        get { withRuntimeState { $0.systemStatus } }
        set { withRuntimeState { $0.setSystemStatus(newValue, for: .claude) } }
    }

    func providerSystemStatus(for kind: AppProviderKind) -> ProviderSystemStatus? {
        withRuntimeState { $0.systemStatus(for: kind) }
    }

    func setProviderSystemStatus(_ status: ProviderSystemStatus?, for kind: AppProviderKind) {
        withRuntimeState { $0.setSystemStatus(status, for: kind) }
    }

    var setupWizardCredentialStepOverride: SetupWizardView.Step? {
        get { withRuntimeState { $0.setupWizardCredentialStepOverride } }
        set { withRuntimeState { $0.setupWizardCredentialStepOverride = newValue } }
    }

    var claudeCredentialAvailability: ClaudeCredentialAvailability {
        get { withRuntimeState { $0.claudeCredentialAvailability } }
        set { withRuntimeState { $0.claudeCredentialAvailability = newValue } }
    }

    var currentUsage: ClaudeUsageResponse? {
        get { runtimeProviderState(for: .claude).claudeUsage }
        set {
            updateRuntimeProviderState(for: .claude) { state in
                state.payload = newValue.map(RuntimeProviderPayload.claude)
            }
        }
    }

    var currentCodexUsage: CodexUsageResponse? {
        get { runtimeProviderState(for: .codex).codexUsage }
        set {
            updateRuntimeProviderState(for: .codex) { state in
                state.payload = newValue.map(RuntimeProviderPayload.codex)
            }
        }
    }

    var currentGeminiUsage: GeminiUsageResponse? {
        get { runtimeProviderState(for: .gemini).geminiUsage }
        set {
            updateRuntimeProviderState(for: .gemini) { state in
                state.payload = newValue.map(RuntimeProviderPayload.gemini)
            }
        }
    }

    var currentAntigravityUsage: AntigravityUsageResponse? {
        get { runtimeProviderState(for: .antigravity).antigravityUsage }
        set {
            updateRuntimeProviderState(for: .antigravity) { state in
                state.payload = newValue.map(RuntimeProviderPayload.antigravity)
            }
        }
    }

    var currentError: APIError? {
        get { runtimeProviderState(for: .claude).error }
        set {
            updateRuntimeProviderState(for: .claude) { state in
                state.error = newValue
            }
        }
    }

    var codexError: APIError? {
        get { runtimeProviderState(for: .codex).error }
        set {
            updateRuntimeProviderState(for: .codex) { state in
                state.error = newValue
            }
        }
    }

    var geminiError: APIError? {
        get { runtimeProviderState(for: .gemini).error }
        set {
            updateRuntimeProviderState(for: .gemini) { state in
                state.error = newValue
            }
        }
    }

    var antigravityError: APIError? {
        get { runtimeProviderState(for: .antigravity).error }
        set {
            updateRuntimeProviderState(for: .antigravity) { state in
                state.error = newValue
            }
        }
    }

    var isLoading: Bool {
        get { runtimeProviderState(for: .claude).isLoading }
        set {
            updateRuntimeProviderState(for: .claude) { state in
                state.isLoading = newValue
                state.lastAttemptState = newValue
                    ? .loading
                    : RuntimeProviderAttemptState.resolve(isLoading: false, error: state.error)
            }
        }
    }

    var isCodexLoading: Bool {
        get { runtimeProviderState(for: .codex).isLoading }
        set {
            updateRuntimeProviderState(for: .codex) { state in
                state.isLoading = newValue
                state.lastAttemptState = newValue
                    ? .loading
                    : RuntimeProviderAttemptState.resolve(isLoading: false, error: state.error)
            }
        }
    }

    var isGeminiLoading: Bool {
        get { runtimeProviderState(for: .gemini).isLoading }
        set {
            updateRuntimeProviderState(for: .gemini) { state in
                state.isLoading = newValue
                state.lastAttemptState = newValue
                    ? .loading
                    : RuntimeProviderAttemptState.resolve(isLoading: false, error: state.error)
            }
        }
    }

    var isAntigravityLoading: Bool {
        get { runtimeProviderState(for: .antigravity).isLoading }
        set {
            updateRuntimeProviderState(for: .antigravity) { state in
                state.isLoading = newValue
                state.lastAttemptState = newValue
                    ? .loading
                    : RuntimeProviderAttemptState.resolve(isLoading: false, error: state.error)
            }
        }
    }

    var loadingStartedAt: Date? {
        get { runtimeProviderState(for: .claude).loadingStartedAt }
        set {
            updateRuntimeProviderState(for: .claude) { state in
                state.loadingStartedAt = newValue
            }
        }
    }

    var codexLoadingStartedAt: Date? {
        get { runtimeProviderState(for: .codex).loadingStartedAt }
        set {
            updateRuntimeProviderState(for: .codex) { state in
                state.loadingStartedAt = newValue
            }
        }
    }

    var geminiLoadingStartedAt: Date? {
        get { runtimeProviderState(for: .gemini).loadingStartedAt }
        set {
            updateRuntimeProviderState(for: .gemini) { state in
                state.loadingStartedAt = newValue
            }
        }
    }

    var antigravityLoadingStartedAt: Date? {
        get { runtimeProviderState(for: .antigravity).loadingStartedAt }
        set {
            updateRuntimeProviderState(for: .antigravity) { state in
                state.loadingStartedAt = newValue
            }
        }
    }

    var nextUsageRefreshAllowedAt: Date? {
        get { runtimeProviderState(for: .claude).nextRefreshAllowedAt }
        set {
            updateRuntimeProviderState(for: .claude) { state in
                state.nextRefreshAllowedAt = newValue
            }
        }
    }

    var nextCodexRefreshAllowedAt: Date? {
        get { runtimeProviderState(for: .codex).nextRefreshAllowedAt }
        set {
            updateRuntimeProviderState(for: .codex) { state in
                state.nextRefreshAllowedAt = newValue
            }
        }
    }

    var nextGeminiRefreshAllowedAt: Date? {
        get { runtimeProviderState(for: .gemini).nextRefreshAllowedAt }
        set {
            updateRuntimeProviderState(for: .gemini) { state in
                state.nextRefreshAllowedAt = newValue
            }
        }
    }

    var nextAntigravityRefreshAllowedAt: Date? {
        get { runtimeProviderState(for: .antigravity).nextRefreshAllowedAt }
        set {
            updateRuntimeProviderState(for: .antigravity) { state in
                state.nextRefreshAllowedAt = newValue
            }
        }
    }

    var lastUpdated: Date? {
        get { runtimeProviderState(for: .claude).lastUpdated }
        set {
            updateRuntimeProviderState(for: .claude) { state in
                state.lastUpdated = newValue
            }
        }
    }

    var codexLastUpdated: Date? {
        get { runtimeProviderState(for: .codex).lastUpdated }
        set {
            updateRuntimeProviderState(for: .codex) { state in
                state.lastUpdated = newValue
            }
        }
    }

    var geminiLastUpdated: Date? {
        get { runtimeProviderState(for: .gemini).lastUpdated }
        set {
            updateRuntimeProviderState(for: .gemini) { state in
                state.lastUpdated = newValue
            }
        }
    }

    var antigravityLastUpdated: Date? {
        get { runtimeProviderState(for: .antigravity).lastUpdated }
        set {
            updateRuntimeProviderState(for: .antigravity) { state in
                state.lastUpdated = newValue
            }
        }
    }

    var hasAuthError: Bool {
        get { runtimeProviderState(for: .claude).hasAuthError }
        set {
            updateRuntimeProviderState(for: .claude) { state in
                state.hasAuthError = newValue
            }
        }
    }

    var hasCodexAuthError: Bool {
        get { runtimeProviderState(for: .codex).hasAuthError }
        set {
            updateRuntimeProviderState(for: .codex) { state in
                state.hasAuthError = newValue
            }
        }
    }

    var hasGeminiAuthError: Bool {
        get { runtimeProviderState(for: .gemini).hasAuthError }
        set {
            updateRuntimeProviderState(for: .gemini) { state in
                state.hasAuthError = newValue
            }
        }
    }

    var hasAntigravityAuthError: Bool {
        get { runtimeProviderState(for: .antigravity).hasAuthError }
        set {
            updateRuntimeProviderState(for: .antigravity) { state in
                state.hasAuthError = newValue
            }
        }
    }

    // ⚠️ 아래 4개 computed property 는 UI 경로(메뉴바 클릭, 우클릭 메뉴,
    // popover 렌더링)에서 호출되므로 반드시 staleWhileRevalidate 만 사용.
    // 내부적으로 subprocess 를 돌리는 `.status(for:)` 직접 호출 금지.
    // 캐시는 앱 시작 및 refresh 틱에서 백그라운드로 미리 갱신됨.

    var hasGeminiCredential: Bool {
        let status = ProviderEnvironmentDetector.staleWhileRevalidate(for: .gemini)
        return status?.credentialState.hasAnyCredential ?? false
    }

    var hasAntigravityCredential: Bool {
        let status = ProviderEnvironmentDetector.staleWhileRevalidate(for: .antigravity)
        return status?.credentialState.hasAnyCredential ?? false
    }

    var geminiRuntimeReachability: Bool {
        let status = ProviderEnvironmentDetector.staleWhileRevalidate(for: .gemini)
        return status?.runtimeReachability ?? false
    }

    var antigravityRuntimeReachability: Bool {
        let status = ProviderEnvironmentDetector.staleWhileRevalidate(for: .antigravity)
        return status?.runtimeReachability ?? false
    }

    var refreshableServices: [PopoverService] {
        ServiceSelectionHelper.refreshableServices(
            selectionState: AppSettings.shared.providerSelectionState,
            hasClaudeSessionKey: KeychainManager.shared.hasSessionKey,
            hasClaudeOAuthCredential: claudeCredentialAvailability.oauthCredentialAvailable,
            isCodexAuthenticated: CodexAuthManager.shared.isAuthenticated,
            geminiRuntimeReachability: geminiRuntimeReachability,
            antigravityRuntimeReachability: antigravityRuntimeReachability
        )
    }

    var hasRefreshableService: Bool {
        !refreshableServices.isEmpty
    }

    var shouldPollRuntimeProviders: Bool {
        hasRefreshableService || ServiceSelectionHelper.hasAnyEnabledService(settings: AppSettings.shared)
    }

    var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
