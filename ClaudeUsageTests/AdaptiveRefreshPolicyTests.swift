import XCTest
@testable import ClaudeUsage

final class AdaptiveRefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func interval(
        open: Bool = false, openedAgo: TimeInterval? = nil, activityAgo: TimeInterval? = nil, low: Bool = false
    ) -> TimeInterval {
        AdaptiveRefreshPolicy.interval(
            .init(
                now: now, isPopoverOpen: open,
                lastPopoverOpenedAt: openedAgo.map { now.addingTimeInterval(-$0) },
                lastActivityAt: activityAgo.map { now.addingTimeInterval(-$0) },
                hasLowRemainingLimit: low))
    }

    func testIntervalFollowsPopoverRecency() {
        XCTAssertEqual(interval(open: true), 120)
        XCTAssertEqual(interval(openedAgo: 4 * 60), 120)
        XCTAssertEqual(interval(openedAgo: 30 * 60), 300)
        XCTAssertEqual(interval(openedAgo: 3 * 3600), 900)
        XCTAssertEqual(interval(openedAgo: 5 * 3600), 1800)
        XCTAssertEqual(interval(), 1800)
    }

    func testActivityAndLowLimitsUseTheShortestInterval() {
        XCTAssertEqual(interval(openedAgo: 5 * 3600, activityAgo: 60), 120)
        XCTAssertEqual(interval(openedAgo: 5 * 3600, activityAgo: 600), 1800)
        XCTAssertEqual(interval(openedAgo: 5 * 3600, low: true), 120)
    }

    func testStaleAndQuietPeriods() {
        XCTAssertTrue(AdaptiveRefreshPolicy.isStale(lastUpdatedAt: nil, now: now))
        XCTAssertFalse(AdaptiveRefreshPolicy.isStale(lastUpdatedAt: now.addingTimeInterval(-100), now: now))
        XCTAssertTrue(AdaptiveRefreshPolicy.isStale(lastUpdatedAt: now.addingTimeInterval(-121), now: now))
        XCTAssertEqual(
            AdaptiveRefreshPolicy.manualRefreshBlockedUntil(
                lastCompletedAt: now.addingTimeInterval(-4), retryAllowedAt: nil, now: now),
            now.addingTimeInterval(6))
        XCTAssertNil(
            AdaptiveRefreshPolicy.manualRefreshBlockedUntil(
                lastCompletedAt: now.addingTimeInterval(-11), retryAllowedAt: nil, now: now))
        XCTAssertEqual(
            AdaptiveRefreshPolicy.manualRefreshBlockedUntil(
                lastCompletedAt: now.addingTimeInterval(-11), retryAllowedAt: now.addingTimeInterval(60), now: now),
            now.addingTimeInterval(60))
    }

    func testResetFollowUpSurvivesAnotherProviderRefreshDuringServerGracePeriod() {
        let reset = now
        let expected = reset.addingTimeInterval(5)
        for offset in [0.0, 1.0, 4.99] {
            XCTAssertEqual(
                AdaptiveRefreshPolicy.nextResetFollowUp(resetDates: [reset], now: reset.addingTimeInterval(offset)),
                expected)
        }
        XCTAssertNil(AdaptiveRefreshPolicy.nextResetFollowUp(resetDates: [reset], now: expected))
        XCTAssertNil(AdaptiveRefreshPolicy.nextResetFollowUp(resetDates: [reset], now: expected.addingTimeInterval(1)))
    }

    func testResetFollowUpTargetsTheNextReset() {
        let resets = [now.addingTimeInterval(-60), now.addingTimeInterval(900), now.addingTimeInterval(300)]
        XCTAssertEqual(
            AdaptiveRefreshPolicy.nextResetFollowUp(resetDates: resets, now: now), now.addingTimeInterval(305))
        XCTAssertEqual(
            AdaptiveRefreshPolicy.nextResetFollowUp(resetDates: [now.addingTimeInterval(-1)], now: now),
            now.addingTimeInterval(4))
    }
}
