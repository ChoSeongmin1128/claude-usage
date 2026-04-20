import XCTest
@testable import ClaudeUsage

final class ClaudeSourcePlannerTests: XCTestCase {
    func testRecentSuccessPreferenceKeepsRecentOAuthFirst() {
        let planner = ClaudeSourcePlanner()
        let context = ClaudeFetchContext(
            sourcePreference: .recentSuccess,
            webSessionAvailable: true,
            oauthAvailable: true,
            recentSuccessfulSource: .oauth,
            currentUsagePercent: 72,
            fallbackPolicy: .init(isEnabled: true, allowAutomaticFallback: true, minimumUsagePercent: 50)
        )

        let plan = planner.makePlan(from: context)

        XCTAssertEqual(plan.primaryCandidates.map(\.source), [.oauth, .webSession])
        XCTAssertEqual(plan.preferredPrimarySource, .oauth)
        XCTAssertEqual(plan.fallbackSource, .messagesHeaderFallback)
        XCTAssertTrue(plan.shouldAttemptAutomaticFallback)
    }

    func testAutoPreferenceIgnoresMessagesFallbackAsRecentSuccess() {
        let planner = ClaudeSourcePlanner()
        let context = ClaudeFetchContext(
            sourcePreference: .auto,
            webSessionAvailable: true,
            oauthAvailable: true,
            recentSuccessfulSource: .messagesHeaderFallback
        )

        let plan = planner.makePlan(from: context)

        XCTAssertEqual(plan.primaryCandidates.map(\.source), [.webSession, .oauth])
        XCTAssertEqual(plan.primaryCandidates.map(\.reason), ["default-web-session-first", "default-oauth-fallback"])
        XCTAssertEqual(plan.preferredPrimarySource, .webSession)
    }

    func testAutomaticFallbackStaysDisabledBelowThreshold() {
        let planner = ClaudeSourcePlanner()
        let context = ClaudeFetchContext(
            sourcePreference: .auto,
            webSessionAvailable: false,
            oauthAvailable: true,
            recentSuccessfulSource: .oauth,
            currentUsagePercent: 19,
            fallbackPolicy: .init(isEnabled: true, allowAutomaticFallback: true, minimumUsagePercent: 20)
        )

        let plan = planner.makePlan(from: context)

        XCTAssertEqual(plan.preferredPrimarySource, .oauth)
        XCTAssertFalse(plan.shouldAttemptAutomaticFallback)
    }
}
