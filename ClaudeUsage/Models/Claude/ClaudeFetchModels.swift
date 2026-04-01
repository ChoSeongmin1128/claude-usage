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
