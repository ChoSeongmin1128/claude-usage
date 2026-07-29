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
    var antigravityRuntimeSnapshot = AntigravityRuntimeSnapshot.idle
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
        codexAuthenticated: Bool
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
                lastAttemptState: state.lastAttemptState,
                lastSuccessfulMetadata: state.lastSuccessfulMetadata,
                lastAttemptMetadata: state.lastAttemptMetadata
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
                lastAttemptState: state.lastAttemptState,
                lastSuccessfulMetadata: state.lastSuccessfulMetadata,
                lastAttemptMetadata: state.lastAttemptMetadata
            )
        case .antigravity:
            let snapshot = antigravityRuntimeSnapshot
            let canAttemptRefresh =
                Self.antigravityCanAttemptRefresh(
                    snapshot
                )
            return RuntimeProviderSnapshot(
                service: .antigravity,
                payload: nil,
                error: nil,
                isLoading: snapshot.isLoading,
                lastUpdated:
                    snapshot.lastSuccessfulAt,
                nextRefreshAllowedAt: nil,
                credentialState:
                    Self.antigravityCredentialState(
                        snapshot,
                        canAttemptRefresh:
                            canAttemptRefresh
                    ),
                isDetected:
                    snapshot.settings != nil
                        || !snapshot.accounts.isEmpty,
                canAttemptRefresh:
                    canAttemptRefresh,
                hasAuthError:
                    Self.antigravityHasAuthError(
                        snapshot.presentationState
                    ),
                lastAttemptState:
                    Self.antigravityAttemptState(
                        snapshot
                    ),
                lastSuccessfulMetadata: nil,
                lastAttemptMetadata: nil
            )
        }
    }

    private static func antigravityCanAttemptRefresh(
        _ snapshot: AntigravityRuntimeSnapshot
    ) -> Bool {
        guard snapshot.readiness == .ready,
              snapshot.settings != nil
        else {
            return false
        }
        return true
    }

    private static func antigravityCredentialState(
        _ snapshot: AntigravityRuntimeSnapshot,
        canAttemptRefresh: Bool
    ) -> ProviderCredentialState {
        if snapshot.activeAccountID != nil {
            return .usable
        }
        if canAttemptRefresh {
            return .refreshable
        }
        switch snapshot.readiness {
        case .idle, .bootstrapping:
            return .unknown
        case .ready, .blocked, .shuttingDown:
            return .missing
        }
    }

    private static func antigravityAttemptState(
        _ snapshot: AntigravityRuntimeSnapshot
    ) -> RuntimeProviderAttemptState {
        switch snapshot.readiness {
        case .bootstrapping:
            return .loading
        case .blocked:
            return .definitiveFailure
        case .idle, .ready, .shuttingDown:
            break
        }

        switch snapshot.presentationState {
        case .refreshing:
            return .loading
        case .stale:
            return .temporaryFailure
        case .accountMismatch:
            return .definitiveFailure
        case .failed(let failure):
            return Self.antigravityIsAuthFailure(
                failure
            )
                ? .authFailure
                : .definitiveFailure
        case .disabled,
             .setupRequired,
             .ready,
             .partial,
             .limited,
             .identityOnly:
            return .idle
        }
    }

    private static func antigravityHasAuthError(
        _ state: AntigravityPresentationState
    ) -> Bool {
        guard case .failed(let failure) = state
        else {
            return false
        }
        return antigravityIsAuthFailure(failure)
    }

    private static func antigravityIsAuthFailure(
        _ failure: AntigravityFailure
    ) -> Bool {
        switch failure {
        case .authenticationRequired,
             .selectedAccountUnavailable,
             .selectedAccountIdentityUnavailable:
            return true
        case .cancelled,
             .appShuttingDown,
             .invalidRefreshContext,
             .generationExhausted,
             .repositoryUnavailable,
             .repositoryRevisionChanged,
             .credentialCommitFailed,
             .credentialCommitAmbiguous,
             .noEligibleSource,
             .sourceUnavailable,
             .interactionRequired,
             .deadlineExceeded,
             .schemaChanged,
             .transportUnavailable,
             .sourceContractViolation,
             .numericQuotaUnavailable:
            return false
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
