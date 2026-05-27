import Foundation

enum ProviderEnabledTransitionDecision {
    case refreshNow
    case clearAndPromptAuth
    case clearStateOnly
}

enum ProviderTransitionPolicy {
    static func shouldRefreshOnTabSwitch(
        state: RuntimeProviderPresentationState,
        refreshInterval: TimeInterval,
    ) -> Bool {
        let threshold = max(refreshInterval * 2, 60)

        let stale = state.lastUpdated.map { Date().timeIntervalSince($0) >= threshold } ?? true
        let recoverableAttempt = state.lastAttemptState == .temporaryFailure || state.lastAttemptState == .loading
        let hasBackoff = RefreshExecutionPolicy.remainingBackoffSeconds(until: state.nextRefreshAllowedAt) != nil
        return !state.hasContent || recoverableAttempt || hasBackoff || stale
    }

    static func enabledChangeDecision(
        state: RuntimeProviderActivationState
    ) -> ProviderEnabledTransitionDecision {
        guard state.enabled else { return .clearStateOnly }
        switch state.service {
        case .antigravity:
            return .refreshNow
        case .claude, .codex:
            break
        }
        return state.hasCredential ? .refreshNow : .clearAndPromptAuth
    }
}
