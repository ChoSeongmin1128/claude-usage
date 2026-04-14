import Foundation

enum ClaudeUsageSource: String, CaseIterable, Sendable {
    case webSession = "web_session"
    case oauth = "oauth"
    case messagesHeaderFallback = "messages_header_fallback"

    var displayName: String {
        switch self {
        case .webSession:
            return "Web session"
        case .oauth:
            return "OAuth"
        case .messagesHeaderFallback:
            return "Messages header fallback"
        }
    }
}

enum ClaudeSourcePreference: String, CaseIterable, Sendable {
    case auto = "auto"
    case webSession = "web_session"
    case oauth = "oauth"
    case recentSuccess = "recent_success"
}

struct ClaudeMessagesHeaderFallbackPolicy: Equatable, Sendable {
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

struct ClaudeFetchContext: Equatable, Sendable {
    var sourcePreference: ClaudeSourcePreference
    var webSessionAvailable: Bool
    var oauthAvailable: Bool
    var recentSuccessfulSource: ClaudeUsageSource?
    var currentUsagePercent: Double?
    var fallbackPolicy: ClaudeMessagesHeaderFallbackPolicy

    nonisolated init(
        sourcePreference: ClaudeSourcePreference = .auto,
        webSessionAvailable: Bool,
        oauthAvailable: Bool,
        recentSuccessfulSource: ClaudeUsageSource? = nil,
        currentUsagePercent: Double? = nil,
        fallbackPolicy: ClaudeMessagesHeaderFallbackPolicy = .init())
    {
        self.sourcePreference = sourcePreference
        self.webSessionAvailable = webSessionAvailable
        self.oauthAvailable = oauthAvailable
        self.recentSuccessfulSource = recentSuccessfulSource
        self.currentUsagePercent = currentUsagePercent
        self.fallbackPolicy = fallbackPolicy
    }
}

struct ClaudeSourceCandidate: Equatable, Sendable {
    let source: ClaudeUsageSource
    let isAvailable: Bool
    let reason: String
}

struct ClaudeFetchPlan: Equatable, Sendable {
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

struct ClaudeProfileMetadata: Equatable, Sendable {
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

struct ClaudeNotificationPolicy: Equatable, Sendable {
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
        let haystacks = [subscriptionType, billingType, rateLimitTier]
            .compactMap { $0?.lowercased() }
        return haystacks.contains(where: { value in
            value.contains("team") || value.contains("enterprise") || value.contains("org")
        })
    }

    nonisolated var shouldSuppressLowUrgencyThresholds: Bool {
        isOrganizationPlan && hasExtraUsageEnabled == true
    }

    nonisolated var summaryLine: String? {
        if isOrganizationPlan && hasExtraUsageEnabled == true {
            return "조직 플랜 + 추가 사용량 활성화 상태라 Claude의 낮은 구간 알림은 자동으로 줄입니다"
        }

        if isOrganizationPlan && hasExtraUsageEnabled == false {
            return "조직 플랜이지만 추가 사용량이 꺼져 있어 Claude 알림에 관리자 확인 안내를 함께 표시합니다"
        }

        return nil
    }

    nonisolated var guidanceSuffix: String? {
        if isOrganizationPlan && hasExtraUsageEnabled == false {
            return "관리자에게 추가 사용량 설정을 확인해 주세요"
        }

        return nil
    }

    nonisolated func guidanceSuffix(
        threshold: Int,
        alertRemainingMode: Bool
    ) -> String? {
        if isOrganizationPlan && hasExtraUsageEnabled == true {
            let remainingThreshold = max(0, 100 - threshold)
            if threshold >= 95 || (alertRemainingMode && remainingThreshold <= 5) {
                return "조직 플랜이라도 상위 한도 근처에서는 관리자 정책을 다시 확인하는 편이 맞습니다"
            }
            return nil
        }

        if let guidanceSuffix {
            return guidanceSuffix
        }

        return nil
    }
}

struct ClaudeCredentialAvailability: Sendable, Equatable {
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
