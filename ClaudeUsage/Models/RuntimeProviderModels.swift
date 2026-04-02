import Foundation

enum PopoverService: String, CaseIterable, Sendable {
    case claude
    case codex

    nonisolated var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        }
    }

    nonisolated var providerKind: AppProviderKind {
        AppProviderKind(rawValue: rawValue) ?? .claude
    }

    nonisolated init?(kind: AppProviderKind) {
        self.init(rawValue: kind.rawValue)
    }
}

enum RuntimeProviderPayload {
    case claude(ClaudeUsageResponse)
    case codex(CodexUsageResponse)
}

struct RuntimeProviderSnapshot {
    let service: PopoverService
    let payload: RuntimeProviderPayload?
    let error: APIError?
    let isLoading: Bool
    let lastUpdated: Date?
    let hasCredential: Bool
    let hasAuthError: Bool

    var kind: AppProviderKind { service.providerKind }
    var hasContent: Bool { payload != nil }

    var claudeUsage: ClaudeUsageResponse? {
        guard case let .claude(usage)? = payload else { return nil }
        return usage
    }

    var codexUsage: CodexUsageResponse? {
        guard case let .codex(usage)? = payload else { return nil }
        return usage
    }
}

struct RuntimeProviderPresentationState: Sendable {
    let service: PopoverService
    let lastUpdated: Date?
    let hasContent: Bool
    let error: APIError?
}

struct RuntimeProviderActivationState: Sendable {
    let service: PopoverService
    let enabled: Bool
    let hasCredential: Bool
    let shouldMarkSetupCompleteOnRefresh: Bool
}
