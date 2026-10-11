import Foundation

extension ClaudeAPIService {
    nonisolated struct OrganizationSummary: Sendable, Equatable, Identifiable, Codable {
        let id: String
        let name: String?
        let planLabel: String?
        let billingType: String?
        let rateLimitTier: String?
        let capabilities: [String]?

        nonisolated init(
            id: String,
            name: String?,
            planLabel: String? = nil,
            billingType: String? = nil,
            rateLimitTier: String? = nil,
            capabilities: [String]? = nil
        ) {
            self.id = id
            self.name = Self.normalized(name)
            self.planLabel = Self.normalized(planLabel)
            self.billingType = Self.normalized(billingType)
            self.rateLimitTier = Self.normalized(rateLimitTier)
            self.capabilities = capabilities
        }

        /// `/api/organizations` 항목과 `/api/account`의 membership 조직이 같은 모양이다.
        nonisolated init?(json organization: [String: Any]) {
            func firstNonEmptyString(_ values: Any?...) -> String? {
                values.compactMap { $0 as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty })
            }
            guard let uuid = organization["uuid"] as? String, !uuid.isEmpty else { return nil }
            self.init(
                id: uuid,
                name: firstNonEmptyString(
                    organization["name"], organization["display_name"], organization["company_name"]),
                planLabel: firstNonEmptyString(
                    organization["plan"], organization["plan_label"], organization["planLabel"],
                    organization["subscription_type"], organization["subscriptionType"]),
                billingType: firstNonEmptyString(organization["billing_type"], organization["billingType"]),
                rateLimitTier: firstNonEmptyString(organization["rate_limit_tier"], organization["rateLimitTier"]),
                capabilities: organization["capabilities"] as? [String])
        }

        /// UI 표시용 라벨. UUID 를 노출하지 않는다 — 사용자에게 UUID 는 노이즈일 뿐
        /// 디버그용으로 봐야 한다면 `idSuffixLabel` 을 별도 호출하면 된다.
        var displayName: String {
            if let name, !name.isEmpty {
                return name
            }
            return idSuffixLabel
        }

        /// 같은 이름의 조직이 여러 개인 경우 분간하기 위한 짧은 ID 꼬리표 (앞 8자).
        /// 일반 표시에서는 사용하지 않고, 동일 name 충돌 시에만 호출하는 게 안전.
        var idSuffixLabel: String {
            let trimmed = id.replacingOccurrences(of: "-", with: "")
            return "조직 \(String(trimmed.prefix(8)))"
        }

        var hasTeamPlanSignal: Bool {
            ClaudePlanSignals.hasOrganizationCapability(capabilities)
                || ClaudePlanSignals.isOrganizationPlan(planValue: planLabel)
                || ClaudePlanSignals.isOrganizationTier(rateLimitTier)
        }

        /// Claude의 개인 workspace는 현재 "<email>'s Organization" 형태로
        /// 노출될 수 있다. 명시적인 personal/individual metadata와 이 이름
        /// 패턴만 개인 신호로 사용하고, 일반 조직명은 추측하지 않는다.
        var hasPersonalAccountSignal: Bool {
            let normalizedName = name?.lowercased() ?? ""
            let hasPersonalWorkspaceName =
                normalizedName.contains("@")
                && (normalizedName.contains("'s organization")
                    || normalizedName.contains("’s organization"))
            if hasPersonalWorkspaceName {
                return true
            }

            let values = [planLabel, billingType, rateLimitTier]
                .compactMap { $0?.lowercased() }
            return values.contains { value in
                value.contains("personal")
                    || value.contains("individual")
                    || value.contains("consumer")
            }
        }

        private nonisolated static func normalized(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    struct OrganizationPreview: Sendable, Equatable, Identifiable {
        let organization: OrganizationSummary
        let fiveHourPercentage: Double?
        let weeklyPercentage: Double?
        let overage: OverageSpendLimitResponse?
        let usageErrorMessage: String?

        var id: String { organization.id }
    }

    struct AuthPathHealthSnapshot: Sendable, Equatable {
        let lastAttemptAt: Date?
        let lastSuccessAt: Date?
        let lastFailureAt: Date?
        let lastErrorMessage: String?
        let consecutiveFailures: Int
        let totalAttempts: Int
        let totalFailures: Int

        nonisolated var hasAttempt: Bool {
            lastAttemptAt != nil || lastSuccessAt != nil || lastFailureAt != nil
        }

        nonisolated var isUnstable: Bool {
            if consecutiveFailures >= 2 {
                return true
            }
            guard let lastFailureAt else { return false }
            guard let lastSuccessAt else { return true }
            return lastFailureAt > lastSuccessAt
        }

        nonisolated var failureRatePercent: Int? {
            guard totalAttempts > 0 else { return nil }
            let ratio = (Double(totalFailures) / Double(totalAttempts)) * 100
            return Int(ratio.rounded())
        }
    }

    struct RuntimeAuthSnapshot: Sendable, Equatable {
        enum ActivePath: String, Sendable {
            case unauthenticated
            case sessionPrimary
            case oauthPreferred
            case oauthFallback
        }

        let activePath: ActivePath
        let credentialAvailability: ClaudeCredentialAvailability
        let sessionValidationState: ClaudeCredentialValidationState
        let oauthValidationState: ClaudeCredentialValidationState
        let sessionCooldownRemaining: Int?
        let oauthPreferredRemaining: Int?
        var claudeCodeCredentialIssue: ClaudeCodeCredentialIssue? = nil
    }

    struct UsageHealthSnapshot: Sendable, Equatable {
        let lastOverallSuccessAt: Date?
        let session: AuthPathHealthSnapshot
        let oauth: AuthPathHealthSnapshot
        let runtime: RuntimeAuthSnapshot
        let accounts: [ClaudeAccount]
        let activeAccountID: String?

        init(
            lastOverallSuccessAt: Date?,
            session: AuthPathHealthSnapshot,
            oauth: AuthPathHealthSnapshot,
            runtime: RuntimeAuthSnapshot,
            accounts: [ClaudeAccount] = [],
            activeAccountID: String? = nil
        ) {
            self.lastOverallSuccessAt = lastOverallSuccessAt
            self.session = session
            self.oauth = oauth
            self.runtime = runtime
            self.accounts = accounts
            self.activeAccountID = activeAccountID
        }

        var activeAccount: ClaudeAccount? {
            guard let activeAccountID else { return nil }
            return accounts.first(where: { $0.id == activeAccountID })
        }
    }

    /// `/api/oauth/profile` 응답을 그대로 모델링한 가벼운 DTO.
    /// 외부에서 view 로 노출되기 전 ClaudeAccountIdentity / ClaudeProfileMetadata 로 매핑된다.
    struct ClaudeOAuthProfileResponse: Decodable, Sendable {
        struct Account: Decodable, Sendable {
            let uuid: String?
            let email: String?
            let fullName: String?
            let displayName: String?
            let hasClaudeMax: Bool?
            let hasClaudePro: Bool?

            enum CodingKeys: String, CodingKey {
                case uuid
                case email
                case fullName = "full_name"
                case displayName = "display_name"
                case hasClaudeMax = "has_claude_max"
                case hasClaudePro = "has_claude_pro"
            }
        }
        struct Organization: Decodable, Sendable {
            let uuid: String?
            let name: String?
            let organizationType: String?
            let billingType: String?
            let rateLimitTier: String?
            let hasExtraUsageEnabled: Bool?

            enum CodingKeys: String, CodingKey {
                case uuid
                case name
                case organizationType = "organization_type"
                case billingType = "billing_type"
                case rateLimitTier = "rate_limit_tier"
                case hasExtraUsageEnabled = "has_extra_usage_enabled"
            }
        }
        let account: Account?
        let organization: Organization?
    }
}
