import Foundation

enum ProviderEnabledTransitionDecision {
    case refreshNow
    case clearAndPromptAuth
    case clearStateOnly
}

enum ProviderTransitionPolicy {
    static func shouldRefreshOnTabSwitch(
        state: RuntimeProviderPresentationState,
        now: Date = Date()
    ) -> Bool {
        // 서비스를 바꾸거나 팝오버를 열면 보관한 값을 먼저 보여주고, 2분보다 오래된 것만 다시 조회한다.
        let stale = AdaptiveRefreshPolicy.isStale(lastUpdatedAt: state.lastUpdated, now: now)
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
