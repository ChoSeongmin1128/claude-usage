import Foundation

nonisolated enum ClaudeUsageSource: String, CaseIterable, Sendable {
    case webSession = "web_session"
    case oauth = "oauth"
    case messagesHeaderFallback = "messages_header_fallback"

    nonisolated var displayName: String {
        switch self {
        case .webSession:
            return "브라우저 로그인"
        case .oauth:
            return "Claude Code"
        case .messagesHeaderFallback:
            return "Claude Code 보조 조회"
        }
    }
}

nonisolated enum ClaudeSourcePreference: String, CaseIterable, Sendable {
    case auto = "auto"
    case webSession = "web_session"
    case oauth = "oauth"
    case recentSuccess = "recent_success"
}

nonisolated enum ClaudeCredentialValidationState: String, Codable, Sendable, Equatable {
    case unavailable
    case detected
    case verified
    case failed
}

nonisolated struct ClaudeMessagesHeaderFallbackPolicy: Equatable, Sendable {
    var isEnabled: Bool
    var allowAutomaticFallback: Bool
    var minimumUsagePercent: Double

    nonisolated init(
        isEnabled: Bool = false,
        allowAutomaticFallback: Bool = false,
        minimumUsagePercent: Double = 20)
    {
        self.isEnabled = isEnabled
        self.allowAutomaticFallback = allowAutomaticFallback
        self.minimumUsagePercent = minimumUsagePercent
    }

    nonisolated func allowsAutomaticFallback(currentUsagePercent: Double?) -> Bool {
        guard self.isEnabled, self.allowAutomaticFallback else { return false }
        guard let currentUsagePercent else { return true }
        return currentUsagePercent >= self.minimumUsagePercent
    }
}

nonisolated struct ClaudeFetchContext: Equatable, Sendable {
    var accountKind: ClaudeAccountKind?
    var sourcePreference: ClaudeSourcePreference
    var webSessionAvailable: Bool
    var oauthAvailable: Bool
    var webSessionValidationState: ClaudeCredentialValidationState
    var oauthValidationState: ClaudeCredentialValidationState
    var recentSuccessfulSource: ClaudeUsageSource?
    var currentUsagePercent: Double?
    var fallbackPolicy: ClaudeMessagesHeaderFallbackPolicy

    nonisolated init(
        accountKind: ClaudeAccountKind? = nil,
        sourcePreference: ClaudeSourcePreference = .auto,
        webSessionAvailable: Bool,
        oauthAvailable: Bool,
        webSessionValidationState: ClaudeCredentialValidationState? = nil,
        oauthValidationState: ClaudeCredentialValidationState? = nil,
        recentSuccessfulSource: ClaudeUsageSource? = nil,
        currentUsagePercent: Double? = nil,
        fallbackPolicy: ClaudeMessagesHeaderFallbackPolicy = .init())
    {
        self.accountKind = accountKind
        self.sourcePreference = sourcePreference
        self.webSessionAvailable = webSessionAvailable
        self.oauthAvailable = oauthAvailable
        self.webSessionValidationState = webSessionValidationState ?? (webSessionAvailable ? .detected : .unavailable)
        self.oauthValidationState = oauthValidationState ?? (oauthAvailable ? .detected : .unavailable)
        self.recentSuccessfulSource = recentSuccessfulSource
        self.currentUsagePercent = currentUsagePercent
        self.fallbackPolicy = fallbackPolicy
    }
}

nonisolated struct ClaudeFetchAttempt: Sendable {
    let source: ClaudeUsageSource
    let wasAvailable: Bool
    let error: APIError?
}

nonisolated struct ClaudeFetchProvenance: Equatable, Sendable {
    let source: ClaudeUsageSource
    let accountID: String?
    let attemptedSources: [ClaudeUsageSource]
}

nonisolated struct ClaudeUsageFetchOutcome: Sendable {
    let usage: ClaudeUsageResponse
    let provenance: ClaudeFetchProvenance
    var identity: UsageAccountIdentity? = nil
    var credentialGeneration: Int? = nil
}

nonisolated struct ClaudeSourceCandidate: Equatable, Sendable {
    let source: ClaudeUsageSource
    let isAvailable: Bool
    let reason: String
}

nonisolated struct ClaudeFetchPlan: Equatable, Sendable {
    let context: ClaudeFetchContext
    let primaryCandidates: [ClaudeSourceCandidate]
    let fallbackPolicy: ClaudeMessagesHeaderFallbackPolicy

    nonisolated var preferredPrimarySource: ClaudeUsageSource? {
        self.primaryCandidates.first(where: { $0.isAvailable })?.source
    }

    nonisolated var fallbackSource: ClaudeUsageSource? {
        self.fallbackPolicy.isEnabled ? .messagesHeaderFallback : nil
    }

    nonisolated var shouldAttemptAutomaticFallback: Bool {
        self.fallbackPolicy.allowsAutomaticFallback(currentUsagePercent: self.context.currentUsagePercent)
    }
}

nonisolated struct ClaudeProfileMetadata: Equatable, Sendable {
    var organizationUUID: String?
    var subscriptionType: String?
    var rateLimitTier: String?
    var hasExtraUsageEnabled: Bool?
    var billingType: String?
    var accountCreatedAt: Date?
    var subscriptionCreatedAt: Date?
    var lastUpdatedAt: Date?

    nonisolated init(
        organizationUUID: String? = nil,
        subscriptionType: String? = nil,
        rateLimitTier: String? = nil,
        hasExtraUsageEnabled: Bool? = nil,
        billingType: String? = nil,
        accountCreatedAt: Date? = nil,
        subscriptionCreatedAt: Date? = nil,
        lastUpdatedAt: Date? = nil)
    {
        self.organizationUUID = organizationUUID
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
        self.hasExtraUsageEnabled = hasExtraUsageEnabled
        self.billingType = billingType
        self.accountCreatedAt = accountCreatedAt
        self.subscriptionCreatedAt = subscriptionCreatedAt
        self.lastUpdatedAt = lastUpdatedAt
    }

    /// 새 값이 있는 항목만 바꾼다. 자격 증명 파일과 프로필 응답이 서로 다른 항목을 알려 주므로 한쪽이
    /// 다른 쪽을 지우지 않게 한다. 조직이 다르면 다른 계정이라 통째로 바꾼다.
    nonisolated func merging(_ newer: ClaudeProfileMetadata) -> ClaudeProfileMetadata {
        if let current = organizationUUID, let next = newer.organizationUUID, current != next { return newer }
        return ClaudeProfileMetadata(
            organizationUUID: newer.organizationUUID ?? organizationUUID,
            subscriptionType: newer.subscriptionType ?? subscriptionType,
            rateLimitTier: newer.rateLimitTier ?? rateLimitTier,
            hasExtraUsageEnabled: newer.hasExtraUsageEnabled ?? hasExtraUsageEnabled,
            billingType: newer.billingType ?? billingType,
            accountCreatedAt: newer.accountCreatedAt ?? accountCreatedAt,
            subscriptionCreatedAt: newer.subscriptionCreatedAt ?? subscriptionCreatedAt,
            lastUpdatedAt: newer.lastUpdatedAt ?? lastUpdatedAt)
    }

    nonisolated var isEmpty: Bool {
        self.organizationUUID == nil &&
            self.subscriptionType == nil &&
            self.rateLimitTier == nil &&
            self.hasExtraUsageEnabled == nil &&
            self.billingType == nil &&
            self.accountCreatedAt == nil &&
            self.subscriptionCreatedAt == nil
    }
}

nonisolated struct ClaudeNotificationPolicy: Equatable, Sendable {
    let subscriptionType: String?
    let billingType: String?
    let hasExtraUsageEnabled: Bool?
    let rateLimitTier: String?
    let lastUpdatedAt: Date?

    init(metadata: ClaudeProfileMetadata) {
        self.subscriptionType = metadata.subscriptionType
        self.billingType = metadata.billingType
        self.hasExtraUsageEnabled = metadata.hasExtraUsageEnabled
        self.rateLimitTier = metadata.rateLimitTier
        self.lastUpdatedAt = metadata.lastUpdatedAt
    }

    nonisolated var isFreshEnoughForNotifications: Bool {
        guard let lastUpdatedAt else { return false }
        return abs(lastUpdatedAt.timeIntervalSinceNow) <= 60 * 60 * 24 * 7
    }

    nonisolated var isOrganizationPlan: Bool {
        ClaudePlanSignals.isOrganizationPlan(planValue: subscriptionType)
            || ClaudePlanSignals.isOrganizationTier(rateLimitTier)
    }

    nonisolated var shouldSuppressLowUrgencyThresholds: Bool {
        isOrganizationPlan && hasExtraUsageEnabled == true
    }

    /// 알림 동작이 달라질 때만 설정에 보인다.
    nonisolated var summaryLine: String? {
        shouldSuppressLowUrgencyThresholds ? "추가 사용량이 켜진 조직 플랜이라 낮은 구간 알림은 보내지 않습니다" : nil
    }

    /// 알림 본문 끝에 붙인다.
    nonisolated var guidanceSuffix: String? {
        isOrganizationPlan && hasExtraUsageEnabled == false ? "추가 사용량이 꺼져 있습니다. 관리자에게 문의하세요." : nil
    }
}

nonisolated struct ClaudeCredentialAvailability: Sendable, Equatable {
    let sessionCredentialAvailable: Bool
    let oauthCredentialAvailable: Bool

    nonisolated static func == (lhs: ClaudeCredentialAvailability, rhs: ClaudeCredentialAvailability) -> Bool {
        lhs.sessionCredentialAvailable == rhs.sessionCredentialAvailable &&
            lhs.oauthCredentialAvailable == rhs.oauthCredentialAvailable
    }

    nonisolated var hasAnyCredential: Bool {
        sessionCredentialAvailable || oauthCredentialAvailable
    }
}

/// Claude Code 자격 증명을 읽다가 확인한 문제. 앱의 사본이 오래돼 Keychain에서 다시 가져와야 하거나,
/// Claude Code 자체가 다시 로그인해야 하는 경우를 일반 로그인 필요와 구분해 안내한다.
nonisolated enum ClaudeCodeCredentialIssue: Sendable, Equatable {
    case reconnectRequired
    case reauthenticationRequired
    case executableNotFound

    static let executableNotFoundMessage = "Claude Code를 찾지 못해 로그인을 갱신하지 못했습니다."
    static let executableNotFoundGuidance = "터미널에서 `claude`가 실행되는지 확인한 뒤 앱을 다시 여세요."
    static var executableNotFoundExplanation: String {
        "\(executableNotFoundMessage) \(executableNotFoundGuidance)"
    }
}
