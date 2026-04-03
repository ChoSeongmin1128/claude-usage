import Foundation

enum ProviderCredentialState: String, Sendable, Equatable {
    case missing
    case refreshable
    case usable
    case unknown

    var hasAnyCredential: Bool {
        switch self {
        case .refreshable, .usable:
            return true
        case .missing, .unknown:
            return false
        }
    }

    var canRefreshNow: Bool {
        switch self {
        case .usable, .refreshable:
            return true
        case .missing, .unknown:
            return false
        }
    }
}

enum RuntimeProviderFetchState: String, Sendable, Equatable {
    case idle
    case ready
    case loading
    case success
    case temporaryFailure
    case definitiveFailure
    case authFailure
    case blocked
}

enum PopoverLayoutRefreshReason: String, Sendable, Equatable {
    case serviceSelection
    case compactToggle
}

enum LocalProviderSummaryPhase: String, Sendable, Equatable {
    case disabled
    case loading
    case backoff
    case refreshingCredential
    case probingRuntime
    case waitingForApp
    case authRequired
    case temporaryError
    case ready
}

enum PopoverService: String, CaseIterable, Sendable {
    case claude
    case codex
    case gemini
    case antigravity

    nonisolated var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .gemini:
            return "Gemini"
        case .antigravity:
            return "Antigravity"
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
    case gemini(GeminiUsageResponse)
    case antigravity(AntigravityUsageResponse)
}

enum RuntimeRefreshStrategy: Sendable, Equatable {
    case claude
    case codex
    case gemini
    case antigravity
}

struct RuntimeProviderRefreshContext: Sendable, Equatable {
    let hasClaudeSessionKey: Bool
    let hasClaudeOAuthCredential: Bool
    let isCodexAuthenticated: Bool
    let geminiRuntimeReachability: Bool
    let antigravityRuntimeReachability: Bool
}

struct RuntimeProviderDescriptor: Sendable, Equatable {
    let service: PopoverService
    let refreshStrategy: RuntimeRefreshStrategy

    var kind: AppProviderKind {
        service.providerKind
    }

    func isRefreshable(using context: RuntimeProviderRefreshContext) -> Bool {
        switch refreshStrategy {
        case .claude:
            return context.hasClaudeSessionKey || context.hasClaudeOAuthCredential
        case .codex:
            return context.isCodexAuthenticated
        case .gemini:
            return context.geminiRuntimeReachability
        case .antigravity:
            return context.antigravityRuntimeReachability
        }
    }
}

enum RuntimeProviderRegistry {
    nonisolated static let supportedDescriptors: [RuntimeProviderDescriptor] = AppProviderKind.runtimeKinds.compactMap(descriptor(for:))

    nonisolated static let supportedServices: [PopoverService] = supportedDescriptors.map(\.service)

    nonisolated static func descriptor(for kind: AppProviderKind) -> RuntimeProviderDescriptor? {
        guard let service = kind.runtimeService, let refreshStrategy = kind.refreshStrategy else { return nil }
        return .init(
            service: service,
            refreshStrategy: refreshStrategy
        )
    }

    nonisolated static func descriptor(for service: PopoverService) -> RuntimeProviderDescriptor? {
        supportedDescriptors.first(where: { $0.service == service })
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

    var geminiUsage: GeminiUsageResponse? {
        guard case let .gemini(usage)? = payload else { return nil }
        return usage
    }

    var antigravityUsage: AntigravityUsageResponse? {
        guard case let .antigravity(usage)? = payload else { return nil }
        return usage
    }

    var fetchState: RuntimeProviderFetchState {
        if isLoading {
            return .loading
        }
        if payload != nil {
            return .success
        }
        if let error {
            if error.isDefinitiveAuthFailure {
                return .authFailure
            }
            if error.isTemporaryFailure {
                return .temporaryFailure
            }
            return .definitiveFailure
        }
        return .idle
    }
}

struct RuntimeProviderStateCatalog {
    private var states: [PopoverService: RuntimeProviderState] = [
        .claude: RuntimeProviderState(),
        .codex: RuntimeProviderState(),
        .gemini: RuntimeProviderState(),
        .antigravity: RuntimeProviderState(),
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
    let nextRefreshAllowedAt: Date?
    let credentialState: ProviderCredentialState
    let isDetected: Bool
    let canAttemptRefresh: Bool
    let hasAuthError: Bool

    var kind: AppProviderKind { service.providerKind }
    var hasContent: Bool { payload != nil }
    var hasCredential: Bool { credentialState.hasAnyCredential }
    var runtimeReachability: Bool { canAttemptRefresh }
    var hasBackoff: Bool { RefreshExecutionPolicy.remainingBackoffSeconds(until: nextRefreshAllowedAt) != nil }
    var fetchState: RuntimeProviderFetchState {
        if isLoading {
            return .loading
        }
        if payload != nil {
            return .success
        }
        if let error {
            if error.isDefinitiveAuthFailure {
                return .authFailure
            }
            if error.isTemporaryFailure {
                return .temporaryFailure
            }
            return .definitiveFailure
        }
        if hasCredential && canAttemptRefresh {
            return .ready
        }
        if isDetected || hasCredential {
            return .blocked
        }
        return .idle
    }

    var claudeUsage: ClaudeUsageResponse? {
        guard case let .claude(usage)? = payload else { return nil }
        return usage
    }

    var codexUsage: CodexUsageResponse? {
        guard case let .codex(usage)? = payload else { return nil }
        return usage
    }

    var geminiUsage: GeminiUsageResponse? {
        guard case let .gemini(usage)? = payload else { return nil }
        return usage
    }

    var antigravityUsage: AntigravityUsageResponse? {
        guard case let .antigravity(usage)? = payload else { return nil }
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
}
