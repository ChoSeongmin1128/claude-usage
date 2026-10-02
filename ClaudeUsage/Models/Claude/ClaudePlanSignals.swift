import Foundation

/// 조직 요금제 판정. 부분 일치("org" 등)는 흔한 글자라 오판하므로 서버가 쓰는 정해진 값만 본다.
/// 모르는 값이면 조직 요금제로 보지 않는다(기본 동작).
nonisolated enum ClaudePlanSignals {
    private static let organizationPlanValues: Set<String> = [
        "team", "enterprise", "claude_team", "claude_enterprise",
    ]
    private static let organizationTierPrefixes = ["default_raven", "team_", "enterprise_"]

    static func isOrganizationPlan(planValue: String?) -> Bool {
        guard let value = normalized(planValue) else { return false }
        return organizationPlanValues.contains(value)
    }

    static func isOrganizationTier(_ tier: String?) -> Bool {
        guard let value = normalized(tier) else { return false }
        return organizationTierPrefixes.contains { value.hasPrefix($0) }
    }

    /// claude.ai 조직의 capabilities에 "raven"이 있으면 Team/Enterprise 조직이다(2026-10-02 실측).
    static func hasOrganizationCapability(_ capabilities: [String]?) -> Bool {
        capabilities?.contains { normalized($0) == "raven" } == true
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
