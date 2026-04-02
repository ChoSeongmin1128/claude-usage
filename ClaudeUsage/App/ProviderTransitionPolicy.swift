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
        return !state.hasContent || state.error != nil || stale
    }

    static func enabledChangeDecision(
        state: RuntimeProviderActivationState
    ) -> ProviderEnabledTransitionDecision {
        guard state.enabled else { return .clearStateOnly }
        return state.hasCredential ? .refreshNow : .clearAndPromptAuth
    }
}
