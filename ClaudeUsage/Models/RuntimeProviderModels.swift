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

enum RuntimeProviderFreshness: String, Sendable, Equatable {
    case unavailable
    case loading
    case fresh
    case stale
}

enum RuntimeProviderAttemptState: String, Sendable, Equatable {
    case idle
    case loading
    case temporaryFailure
    case authFailure
    case definitiveFailure

    static func resolve(
        isLoading: Bool,
        error: APIError?
    ) -> RuntimeProviderAttemptState {
        if isLoading {
            return .loading
        }
        guard let error else {
            return .idle
        }
        if error.isDefinitiveAuthFailure {
            return .authFailure
        }
        if error.isTemporaryFailure {
            return .temporaryFailure
        }
        return .definitiveFailure
    }
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
    case antigravity

    nonisolated var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
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
}

/// 조회 결과의 출처와 계정 귀속 정보. payload와 같은 수명으로 보관해 화면이
/// "어느 계정의 어떤 연결에서 가져온 값인지"를 문자열 추측 없이 표시하게 한다.
struct RuntimeProviderFetchMetadata: Sendable, Equatable {
    let sourceLabel: String?
    let accountID: String?
    let attemptedSourceLabels: [String]

    nonisolated init(
        sourceLabel: String? = nil,
        accountID: String? = nil,
        attemptedSourceLabels: [String] = []
    ) {
        self.sourceLabel = sourceLabel
        self.accountID = accountID
        self.attemptedSourceLabels = attemptedSourceLabels
    }
}

enum RuntimeRefreshStrategy: Sendable, Equatable {
    case claude
    case codex
    case antigravity
}

struct RuntimeProviderRefreshContext: Sendable, Equatable {
    let hasClaudeSessionKey: Bool
    let hasClaudeOAuthCredential: Bool
    let isCodexAuthenticated: Bool
    let antigravityRuntimeReachability: Bool
    let antigravityRefreshReachability: Bool
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
        case .antigravity:
            return context.antigravityRefreshReachability
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
    private var lastSuccessfulPayloadStorage: RuntimeProviderPayload?
    private var lastSuccessfulAtStorage: Date?
    private var lastAttemptErrorStorage: APIError?
    private var lastSuccessfulMetadataStorage: RuntimeProviderFetchMetadata?
    private var lastAttemptMetadataStorage: RuntimeProviderFetchMetadata?
    var lastAttemptState: RuntimeProviderAttemptState
    var isLoading: Bool
    var loadingStartedAt: Date?
    var nextRefreshAllowedAt: Date?
    var hasAuthError: Bool

    init(
        payload: RuntimeProviderPayload? = nil,
        error: APIError? = nil,
        isLoading: Bool = false,
        loadingStartedAt: Date? = nil,
        nextRefreshAllowedAt: Date? = nil,
        lastUpdated: Date? = nil,
        hasAuthError: Bool = false,
        lastAttemptState: RuntimeProviderAttemptState? = nil,
        lastSuccessfulMetadata: RuntimeProviderFetchMetadata? = nil,
        lastAttemptMetadata: RuntimeProviderFetchMetadata? = nil
    ) {
        self.lastSuccessfulPayloadStorage = payload
        self.lastSuccessfulAtStorage = lastUpdated
        self.lastAttemptErrorStorage = error
        self.lastSuccessfulMetadataStorage = lastSuccessfulMetadata
        self.lastAttemptMetadataStorage = lastAttemptMetadata
        self.lastAttemptState = lastAttemptState ?? RuntimeProviderAttemptState.resolve(
            isLoading: isLoading,
            error: error
        )
        self.isLoading = isLoading
        self.loadingStartedAt = loadingStartedAt
        self.nextRefreshAllowedAt = nextRefreshAllowedAt
        self.hasAuthError = hasAuthError
    }

    var lastSuccessfulPayload: RuntimeProviderPayload? {
        get { lastSuccessfulPayloadStorage }
        set { lastSuccessfulPayloadStorage = newValue }
    }

    var lastSuccessfulAt: Date? {
        get { lastSuccessfulAtStorage }
        set { lastSuccessfulAtStorage = newValue }
    }

    var lastAttemptError: APIError? {
        get { lastAttemptErrorStorage }
        set {
            lastAttemptErrorStorage = newValue
            lastAttemptState = RuntimeProviderAttemptState.resolve(
                isLoading: isLoading,
                error: newValue
            )
            if newValue?.isDefinitiveAuthFailure == true {
                hasAuthError = true
            }
        }
    }

    var lastSuccessfulMetadata: RuntimeProviderFetchMetadata? {
        get { lastSuccessfulMetadataStorage }
        set { lastSuccessfulMetadataStorage = newValue }
    }

    var lastAttemptMetadata: RuntimeProviderFetchMetadata? {
        get { lastAttemptMetadataStorage }
        set { lastAttemptMetadataStorage = newValue }
    }

    var payload: RuntimeProviderPayload? {
        get { lastSuccessfulPayloadStorage }
        set { lastSuccessfulPayloadStorage = newValue }
    }

    var error: APIError? {
        get { lastAttemptErrorStorage }
        set {
            lastAttemptErrorStorage = newValue
            lastAttemptState = RuntimeProviderAttemptState.resolve(
                isLoading: isLoading,
                error: newValue
            )
            if newValue?.isDefinitiveAuthFailure == true {
                hasAuthError = true
            }
        }
    }

    var lastUpdated: Date? {
        get { lastSuccessfulAtStorage }
        set { lastSuccessfulAtStorage = newValue }
    }

    var claudeUsage: ClaudeUsageResponse? {
        guard case let .claude(usage)? = lastSuccessfulPayloadStorage else { return nil }
        return usage
    }

    var codexUsage: CodexUsageResponse? {
        guard case let .codex(usage)? = lastSuccessfulPayloadStorage else { return nil }
        return usage
    }

    var fetchState: RuntimeProviderFetchState {
        if isLoading {
            return .loading
        }
        if lastSuccessfulPayloadStorage != nil {
            switch lastAttemptState {
            case .temporaryFailure:
                return .temporaryFailure
            case .definitiveFailure:
                return .definitiveFailure
            case .authFailure:
                return .authFailure
            case .idle, .loading:
                return .success
            }
        }
        switch lastAttemptState {
        case .idle:
            return .idle
        case .loading:
            return .loading
        case .temporaryFailure:
            return .temporaryFailure
        case .authFailure:
            return .authFailure
        case .definitiveFailure:
            return .definitiveFailure
        }
    }
}

struct RuntimeProviderStateCatalog {
    private var states: [PopoverService: RuntimeProviderState] = [
        .claude: RuntimeProviderState(),
        .codex: RuntimeProviderState(),
        .antigravity: RuntimeProviderState(),
    ]

    subscript(service: PopoverService) -> RuntimeProviderState {
        get { states[service] ?? RuntimeProviderState() }
        set { states[service] = newValue }
    }
}

struct RuntimeProviderSnapshot {
    let service: PopoverService
    let displayPayload: RuntimeProviderPayload?
    let displayUpdatedAt: Date?
    let lastAttemptState: RuntimeProviderAttemptState
    let lastAttemptError: APIError?
    let isLoading: Bool
    let nextRefreshAllowedAt: Date?
    let credentialState: ProviderCredentialState
    let isDetected: Bool
    let canAttemptRefresh: Bool
    let hasAuthError: Bool
    let lastSuccessfulMetadata: RuntimeProviderFetchMetadata?
    let lastAttemptMetadata: RuntimeProviderFetchMetadata?

    init(
        service: PopoverService,
        payload: RuntimeProviderPayload? = nil,
        error: APIError? = nil,
        isLoading: Bool = false,
        lastUpdated: Date? = nil,
        nextRefreshAllowedAt: Date? = nil,
        credentialState: ProviderCredentialState,
        isDetected: Bool,
        canAttemptRefresh: Bool,
        hasAuthError: Bool,
        lastAttemptState: RuntimeProviderAttemptState? = nil,
        lastSuccessfulMetadata: RuntimeProviderFetchMetadata? = nil,
        lastAttemptMetadata: RuntimeProviderFetchMetadata? = nil
    ) {
        self.service = service
        self.displayPayload = payload
        self.displayUpdatedAt = lastUpdated
        self.lastAttemptError = error
        self.isLoading = isLoading
        self.nextRefreshAllowedAt = nextRefreshAllowedAt
        self.credentialState = credentialState
        self.isDetected = isDetected
        self.canAttemptRefresh = canAttemptRefresh
        self.hasAuthError = hasAuthError
        self.lastSuccessfulMetadata = lastSuccessfulMetadata
        self.lastAttemptMetadata = lastAttemptMetadata
        self.lastAttemptState = lastAttemptState ?? RuntimeProviderAttemptState.resolve(
            isLoading: isLoading,
            error: error
        )
    }

    var kind: AppProviderKind { service.providerKind }
    var payload: RuntimeProviderPayload? { displayPayload }
    var error: APIError? { lastAttemptError }
    var lastUpdated: Date? { displayUpdatedAt }
    var hasContent: Bool { displayPayload != nil }
    var hasCredential: Bool { credentialState.hasAnyCredential }
    var runtimeReachability: Bool { canAttemptRefresh }
    var hasBackoff: Bool { RefreshExecutionPolicy.remainingBackoffSeconds(until: nextRefreshAllowedAt) != nil }
    var isStaleRecoverable: Bool { displayPayload != nil && lastAttemptState == .temporaryFailure }
    var freshness: RuntimeProviderFreshness {
        if isLoading { return .loading }
        guard displayPayload != nil else { return .unavailable }
        return lastAttemptError == nil ? .fresh : .stale
    }

    var fetchState: RuntimeProviderFetchState {
        if isLoading {
            return .loading
        }
        if displayPayload != nil {
            switch lastAttemptState {
            case .temporaryFailure:
                return .temporaryFailure
            case .definitiveFailure:
                return .definitiveFailure
            case .authFailure:
                return .authFailure
            case .idle, .loading:
                return .success
            }
        }
        switch lastAttemptState {
        case .loading:
            return .loading
        case .temporaryFailure:
            return .temporaryFailure
        case .authFailure:
            return .authFailure
        case .definitiveFailure:
            return .definitiveFailure
        case .idle:
            break
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
        guard case let .claude(usage)? = displayPayload else { return nil }
        return usage
    }

    var codexUsage: CodexUsageResponse? {
        guard case let .codex(usage)? = displayPayload else { return nil }
        return usage
    }
}

struct RuntimeProviderPresentationState: Sendable {
    let service: PopoverService
    let lastUpdated: Date?
    let hasContent: Bool
    let error: APIError?
    let lastAttemptState: RuntimeProviderAttemptState
    let nextRefreshAllowedAt: Date?

    init(
        service: PopoverService,
        lastUpdated: Date?,
        hasContent: Bool,
        error: APIError?,
        lastAttemptState: RuntimeProviderAttemptState = .idle,
        nextRefreshAllowedAt: Date? = nil
    ) {
        self.service = service
        self.lastUpdated = lastUpdated
        self.hasContent = hasContent
        self.error = error
        self.lastAttemptState = lastAttemptState
        self.nextRefreshAllowedAt = nextRefreshAllowedAt
    }
}

struct RuntimeProviderActivationState: Sendable {
    let service: PopoverService
    let enabled: Bool
    let hasCredential: Bool
}
