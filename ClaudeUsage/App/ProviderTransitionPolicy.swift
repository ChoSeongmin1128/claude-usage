import Foundation

enum ProviderEnabledTransitionDecision {
    case refreshNow
    case clearAndPromptAuth
    case clearStateOnly
}

enum ProviderTransitionPolicy {
    static func shouldRefreshOnTabSwitch(
        service: PopoverService,
        refreshInterval: TimeInterval,
        claudeLastUpdated: Date?,
        codexLastUpdated: Date?,
        hasClaudeUsage: Bool,
        hasCodexUsage: Bool,
        claudeError: APIError?,
        codexError: APIError?
    ) -> Bool {
        let threshold = max(refreshInterval * 2, 60)

        switch service {
        case .claude:
            let stale = claudeLastUpdated.map { Date().timeIntervalSince($0) >= threshold } ?? true
            return !hasClaudeUsage || claudeError != nil || stale
        case .codex:
            let stale = codexLastUpdated.map { Date().timeIntervalSince($0) >= threshold } ?? true
            return !hasCodexUsage || codexError != nil || stale
        }
    }

    static func enabledChangeDecision(
        service: PopoverService,
        enabled: Bool,
        hasClaudeSessionKey: Bool,
        isCodexAuthenticated: Bool
    ) -> ProviderEnabledTransitionDecision {
        switch service {
        case .claude:
            guard enabled else { return .clearStateOnly }
            return hasClaudeSessionKey ? .refreshNow : .clearAndPromptAuth
        case .codex:
            guard enabled else { return .clearStateOnly }
            return isCodexAuthenticated ? .refreshNow : .clearAndPromptAuth
        }
    }
}
