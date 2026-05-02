import Foundation

@MainActor
final class AppRuntimeStateFacade {
    private var runtimeStateCatalog = RuntimeProviderStateCatalog()

    var currentOverage: OverageSpendLimitResponse?
    var currentClaudeNotificationPolicy: ClaudeNotificationPolicy?
    var currentClaudeProfileMetadata: ClaudeProfileMetadata?
    var activeClaudeAccountID: String?
    var lastOverageFetchAt: Date?
    var systemStatus: ClaudeSystemStatus?
    var providerSystemStatuses: [AppProviderKind: ProviderSystemStatus] = [:]
    var setupWizardCredentialStepOverride: SetupWizardView.Step?
    var claudeCredentialAvailability = ClaudeCredentialAvailability(
        sessionCredentialAvailable: false,
        oauthCredentialAvailable: false
    )

    subscript(service: PopoverService) -> RuntimeProviderState {
        get { runtimeStateCatalog[service] }
        set { runtimeStateCatalog[service] = newValue }
    }

    func snapshot(
        for service: PopoverService,
        codexAuthenticated: Bool,
        environmentStatus: ProviderEnvironmentStatus? = nil
    ) -> RuntimeProviderSnapshot {
        let state = self[service]

        switch service {
        case .claude:
            let hasCredential = claudeCredentialAvailability.hasAnyCredential
            return RuntimeProviderSnapshot(
                service: .claude,
                payload: state.payload,
                error: state.error,
                isLoading: state.isLoading,
                lastUpdated: state.lastUpdated,
                nextRefreshAllowedAt: state.nextRefreshAllowedAt,
                credentialState: hasCredential ? .usable : .missing,
                isDetected: hasCredential,
                canAttemptRefresh: hasCredential,
                hasAuthError: state.hasAuthError,
                lastAttemptState: state.lastAttemptState
            )
        case .codex:
            return RuntimeProviderSnapshot(
                service: .codex,
                payload: state.payload,
                error: state.error,
                isLoading: state.isLoading,
                lastUpdated: state.lastUpdated,
                nextRefreshAllowedAt: state.nextRefreshAllowedAt,
                credentialState: codexAuthenticated ? .usable : .missing,
                isDetected: codexAuthenticated,
                canAttemptRefresh: codexAuthenticated,
                hasAuthError: state.hasAuthError,
                lastAttemptState: state.lastAttemptState
            )
        case .gemini:
            return RuntimeProviderSnapshot(
                service: .gemini,
                payload: state.payload,
                error: state.error,
                isLoading: state.isLoading,
                lastUpdated: state.lastUpdated,
                nextRefreshAllowedAt: state.nextRefreshAllowedAt,
                credentialState: environmentStatus?.credentialState ?? .unknown,
                isDetected: environmentStatus?.isDetected ?? false,
                canAttemptRefresh: environmentStatus?.canAttemptRefresh ?? false,
                hasAuthError: state.hasAuthError,
                lastAttemptState: state.lastAttemptState
            )
        case .antigravity:
            return RuntimeProviderSnapshot(
                service: .antigravity,
                payload: state.payload,
                error: state.error,
                isLoading: state.isLoading,
                lastUpdated: state.lastUpdated,
                nextRefreshAllowedAt: state.nextRefreshAllowedAt,
                credentialState: environmentStatus?.credentialState ?? .unknown,
                isDetected: environmentStatus?.isDetected ?? false,
                canAttemptRefresh: environmentStatus?.canAttemptRefresh ?? false,
                hasAuthError: state.hasAuthError,
                lastAttemptState: state.lastAttemptState
            )
        }
    }

    @discardableResult
    func applyClaudeUsageHealthSnapshot(_ snapshot: ClaudeAPIService.UsageHealthSnapshot) -> Bool {
        let previousCredentialAvailability = claudeCredentialAvailability.hasAnyCredential
        if activeClaudeAccountID != snapshot.activeAccountID {
            runtimeStateCatalog[.claude] = RuntimeProviderState()
            currentOverage = nil
            lastOverageFetchAt = nil
        }
        activeClaudeAccountID = snapshot.activeAccountID
        claudeCredentialAvailability = snapshot.runtime.credentialAvailability
        return previousCredentialAvailability != claudeCredentialAvailability.hasAnyCredential
    }

    func clearClaudePresentationState() {
        runtimeStateCatalog[.claude] = RuntimeProviderState()
        currentOverage = nil
        currentClaudeProfileMetadata = nil
        currentClaudeNotificationPolicy = nil
        activeClaudeAccountID = nil
        lastOverageFetchAt = nil
    }

    func systemStatus(for kind: AppProviderKind) -> ProviderSystemStatus? {
        if kind == .claude {
            return providerSystemStatuses[.claude] ?? systemStatus
        }
        return providerSystemStatuses[kind]
    }

    func setSystemStatus(_ status: ProviderSystemStatus?, for kind: AppProviderKind) {
        if let status {
            providerSystemStatuses[kind] = status
        } else {
            providerSystemStatuses.removeValue(forKey: kind)
        }

        if kind == .claude {
            systemStatus = status
        }
    }
}
