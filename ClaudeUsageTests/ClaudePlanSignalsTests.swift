import XCTest
@testable import ClaudeUsage

final class ClaudePlanSignalsTests: XCTestCase {
    func testOrganizationPlanUsesExactServerValues() {
        XCTAssertTrue(ClaudePlanSignals.isOrganizationPlan(planValue: "team"))
        XCTAssertTrue(ClaudePlanSignals.isOrganizationPlan(planValue: " Claude_Enterprise "))
        XCTAssertFalse(ClaudePlanSignals.isOrganizationPlan(planValue: "pro"))
        XCTAssertFalse(ClaudePlanSignals.isOrganizationPlan(planValue: "teamwork_trial"))
        XCTAssertFalse(ClaudePlanSignals.isOrganizationPlan(planValue: nil))
    }

    func testCommonSubstringsAreNotOrganizationSignals() {
        let personal = ClaudeAPIService.OrganizationSummary(
            id: "org-personal", name: "me@example.com's Organization", planLabel: "pro",
            billingType: "stripe_subscription", rateLimitTier: "default_claude_max_5x", capabilities: ["chat"])
        XCTAssertFalse(personal.hasTeamPlanSignal)
    }

    func testTeamOrganizationIsRecognizedFromMeasuredFields() {
        let team = ClaudeAPIService.OrganizationSummary(
            id: "org-team", name: "Glorang", billingType: "stripe_subscription", rateLimitTier: "default_raven",
            capabilities: ["chat", "raven", "customer_terms:standard"])
        XCTAssertTrue(team.hasTeamPlanSignal)
        XCTAssertTrue(ClaudePlanSignals.isOrganizationTier("team_tier_1"))
        XCTAssertFalse(ClaudePlanSignals.isOrganizationTier("default_claude_ai"))
    }
}
