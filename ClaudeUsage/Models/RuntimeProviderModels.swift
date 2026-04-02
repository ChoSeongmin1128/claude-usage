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

enum RuntimeRefreshStrategy: Sendable, Equatable {
    case claude
    case codex
}

struct RuntimeProviderRefreshContext: Sendable, Equatable {
    let hasClaudeSessionKey: Bool
    let hasClaudeOAuthCredential: Bool
    let isCodexAuthenticated: Bool
}

struct RuntimeProviderDescriptor: Sendable, Equatable {
    let service: PopoverService
    let refreshStrategy: RuntimeRefreshStrategy
    let marksSetupCompleteOnRefresh: Bool

    var kind: AppProviderKind {
        service.providerKind
    }

    func isRefreshable(using context: RuntimeProviderRefreshContext) -> Bool {
        switch refreshStrategy {
        case .claude:
            return context.hasClaudeSessionKey || context.hasClaudeOAuthCredential
        case .codex:
            return context.isCodexAuthenticated
        }
    }

    func shouldMarkSetupComplete(enabled: Bool, hasCredential: Bool) -> Bool {
        marksSetupCompleteOnRefresh && enabled && hasCredential
    }
}

enum RuntimeProviderRegistry {
    static let supportedDescriptors: [RuntimeProviderDescriptor] = [
        .init(service: .claude, refreshStrategy: .claude, marksSetupCompleteOnRefresh: true),
        .init(service: .codex, refreshStrategy: .codex, marksSetupCompleteOnRefresh: false),
    ]

    static let supportedServices: [PopoverService] = supportedDescriptors.map(\.service)

    static func descriptor(for service: PopoverService) -> RuntimeProviderDescriptor {
        supportedDescriptors.first(where: { $0.service == service })
            ?? .init(service: service, refreshStrategy: service == .claude ? .claude : .codex, marksSetupCompleteOnRefresh: false)
    }
}

struct RuntimeProviderState {
    var payload: RuntimeProviderPayload?
    var error: APIError?
    var isLoading: Bool
    var loadingStartedAt: Date?
    var nextRefreshAllowedAt: Date?
    var lastUpdated: Date?
    var hasAuthError: Bool
    var consecutiveErrorCount: Int

    init(
        payload: RuntimeProviderPayload? = nil,
        error: APIError? = nil,
        isLoading: Bool = false,
        loadingStartedAt: Date? = nil,
        nextRefreshAllowedAt: Date? = nil,
        lastUpdated: Date? = nil,
        hasAuthError: Bool = false,
        consecutiveErrorCount: Int = 0
    ) {
        self.payload = payload
        self.error = error
        self.isLoading = isLoading
        self.loadingStartedAt = loadingStartedAt
        self.nextRefreshAllowedAt = nextRefreshAllowedAt
        self.lastUpdated = lastUpdated
        self.hasAuthError = hasAuthError
        self.consecutiveErrorCount = consecutiveErrorCount
    }

    var claudeUsage: ClaudeUsageResponse? {
        guard case let .claude(usage)? = payload else { return nil }
        return usage
    }

    var codexUsage: CodexUsageResponse? {
        guard case let .codex(usage)? = payload else { return nil }
        return usage
    }
}

struct RuntimeProviderStateCatalog {
    private var states: [PopoverService: RuntimeProviderState] = [
        .claude: RuntimeProviderState(),
        .codex: RuntimeProviderState(),
    ]

    subscript(service: PopoverService) -> RuntimeProviderState {
        get { states[service] ?? RuntimeProviderState() }
        set { states[service] = newValue }
    }
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
