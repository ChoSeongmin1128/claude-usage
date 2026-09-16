import Dispatch
import Foundation

extension AppDelegate {
    func withRuntimeState<T>(_ body: @MainActor (AppRuntimeStateFacade) -> T) -> T {
        // AppDelegate and this accessor are MainActor-isolated at the call site.
        body(runtimeState)
    }

    func runtimeProviderState(for service: PopoverService) -> RuntimeProviderState {
        withRuntimeState { $0[service] }
    }

    func setRuntimeProviderState(_ state: RuntimeProviderState, for service: PopoverService) {
        withRuntimeState { $0[service] = state }
        NotificationCenter.default.post(name: .runtimeProviderStateUpdated, object: service)
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

    var currentAntigravityRuntimeSnapshot:
        AntigravityRuntimeSnapshot
    {
        get {
            withRuntimeState {
                $0.antigravityRuntimeSnapshot
            }
        }
        set {
            withRuntimeState {
                $0.antigravityRuntimeSnapshot = newValue
            }
            NotificationCenter.default.post(
                name: .runtimeProviderStateUpdated,
                object: PopoverService.antigravity
            )
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

    var antigravityRuntimeReachability: Bool {
        runtimeProviderSnapshot(
            for: .antigravity
        ).canAttemptRefresh
    }

    var antigravityRefreshReachability: Bool {
        runtimeProviderSnapshot(
            for: .antigravity
        ).canAttemptRefresh
    }

    var refreshableServices: [PopoverService] {
        var services = ServiceSelectionHelper.refreshableServices(
            selectionState: AppSettings.shared.providerSelectionState,
            hasClaudeSessionKey: KeychainManager.shared.hasSessionKey,
            hasClaudeOAuthCredential: claudeCredentialAvailability.oauthCredentialAvailable,
            isCodexAuthenticated: CodexAuthManager.shared.isAuthenticated,
            antigravityRuntimeReachability: antigravityRuntimeReachability,
            antigravityRefreshReachability: antigravityRefreshReachability
        )
        // A CLI login can appear after startup. Permit a background file check
        // even when the last presentation snapshot had no native credential.
        if ServiceSelectionHelper.isEnabled(.codex, settings: .shared), !services.contains(.codex) {
            services.append(.codex)
        }
        return services
    }

    var hasRefreshableService: Bool {
        !refreshableServices.isEmpty
    }

    var shouldPollRuntimeProviders: Bool {
        hasRefreshableService || ServiceSelectionHelper.hasAnyEnabledService(settings: AppSettings.shared)
    }

    var isRunningUnitTests: Bool {
        AppRuntimeEnvironment.isRunningUnitTests
    }
}
