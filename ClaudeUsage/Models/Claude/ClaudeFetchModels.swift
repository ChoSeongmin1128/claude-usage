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

enum ClaudeCredentialValidationState: String, Codable, Sendable, Equatable {
    case unavailable
    case detected
    case verified
    case failed
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
    var accountKind: ClaudeAccountKind?
    var sourcePreference: ClaudeSourcePreference
    var webSessionAvailable: Bool
    var oauthAvailable: Bool
    var webSessionValidationState: ClaudeCredentialValidationState
    var oauthValidationState: ClaudeCredentialValidationState
    var recentSuccessfulSource: ClaudeUsageSource?
    var currentUsagePercent: Double?
    var fallbackPolicy: ClaudeMessagesHeaderFallbackPolicy
    /// 활성 계정이 .webSession 일 때, 사용자가 직접 선택한 결과인지 여부.
    /// 레거시 마이그레이션으로 자동 생성된 web 계정은 false. 사용자가 설정 UI 에서
    /// 명시적으로 추가/선택한 web 계정은 true. account-scoped fallback 정책에서
    /// "암묵적인 web 계정이면 OAuth 로 자동 폴백" 같은 결정을 위해 사용한다.
    /// .claudeCodeExternal 또는 nil 계정에는 영향 없음.
    var webSessionExplicitlySelected: Bool
    /// 사용자가 설정에서 "Claude Code OAuth 우선 시도" 토글을 켰는지 여부.
    /// true 이고 OAuth 토큰이 사용 가능하면 planner 가 활성 계정과 무관하게 OAuth 를
    /// primary 후보로 잡는다. (web 활성이어도 OAuth 가 먼저 시도되고 실패 시 web 폴백)
    /// 활성 계정 = 진실의 출처라는 기존 원칙을 사용자가 명시적으로 뒤집는 길.
    var preferOAuthOverActiveAccount: Bool

    nonisolated init(
        accountKind: ClaudeAccountKind? = nil,
        sourcePreference: ClaudeSourcePreference = .auto,
        webSessionAvailable: Bool,
        oauthAvailable: Bool,
        webSessionValidationState: ClaudeCredentialValidationState? = nil,
        oauthValidationState: ClaudeCredentialValidationState? = nil,
        recentSuccessfulSource: ClaudeUsageSource? = nil,
        currentUsagePercent: Double? = nil,
        fallbackPolicy: ClaudeMessagesHeaderFallbackPolicy = .init(),
        webSessionExplicitlySelected: Bool = true,
        preferOAuthOverActiveAccount: Bool = false)
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
        self.webSessionExplicitlySelected = webSessionExplicitlySelected
        self.preferOAuthOverActiveAccount = preferOAuthOverActiveAccount
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
