import XCTest
@testable import ClaudeUsage

final class UsageWindowAlertPolicyTests: XCTestCase {
    func testFirstCheckSeedsReachedThresholdsWithoutAlerting() {
        let decision = UsageWindowAlertPolicy.evaluate(
            previousPercentage: nil,
            currentPercentage: 91,
            resetAt: "2026-04-25T10:17:30Z",
            thresholds: [75, 90],
            alertedThresholds: [],
            isFirstCheck: true
        )

        XCTAssertNil(decision.thresholdToAlert)
        XCTAssertEqual(decision.alertedThresholds, [75, 90])
    }

    func testCrossingThresholdAlertsOnce() {
        let decision = UsageWindowAlertPolicy.evaluate(
            previousPercentage: 84,
            currentPercentage: 90,
            resetAt: nil,
            thresholds: [90],
            alertedThresholds: [],
            isFirstCheck: false
        )

        XCTAssertEqual(decision.thresholdToAlert, 90)
        XCTAssertEqual(decision.alertedThresholds, [90])
    }

    func testAlreadyAlertedThresholdDoesNotAlertAgain() {
        let decision = UsageWindowAlertPolicy.evaluate(
            previousPercentage: 91,
            currentPercentage: 92,
            resetAt: nil,
            thresholds: [90],
            alertedThresholds: [90],
            isFirstCheck: false
        )

        XCTAssertNil(decision.thresholdToAlert)
        XCTAssertEqual(decision.alertedThresholds, [90])
    }

    func testHysteresisKeepsThresholdArmedUntilUsageDropsMoreThanFivePoints() {
        let dipped = UsageWindowAlertPolicy.evaluate(
            previousPercentage: 92,
            currentPercentage: 86,
            resetAt: nil,
            thresholds: [90],
            alertedThresholds: [90],
            isFirstCheck: false
        )
        let returned = UsageWindowAlertPolicy.evaluate(
            previousPercentage: 86,
            currentPercentage: 91,
            resetAt: nil,
            thresholds: [90],
            alertedThresholds: dipped.alertedThresholds,
            isFirstCheck: false
        )

        XCTAssertNil(dipped.thresholdToAlert)
        XCTAssertNil(returned.thresholdToAlert)
        XCTAssertEqual(returned.alertedThresholds, [90])
    }

    func testHysteresisAllowsRealertAfterUsageDropsBelowRearmBand() {
        let dipped = UsageWindowAlertPolicy.evaluate(
            previousPercentage: 92,
            currentPercentage: 84,
            resetAt: nil,
            thresholds: [90],
            alertedThresholds: [90],
            isFirstCheck: false
        )
        let returned = UsageWindowAlertPolicy.evaluate(
            previousPercentage: 84,
            currentPercentage: 91,
            resetAt: nil,
            thresholds: [90],
            alertedThresholds: dipped.alertedThresholds,
            isFirstCheck: false
        )

        XCTAssertNil(dipped.thresholdToAlert)
        XCTAssertTrue(dipped.alertedThresholds.isEmpty)
        XCTAssertEqual(returned.thresholdToAlert, 90)
        XCTAssertEqual(returned.alertedThresholds, [90])
    }

    func testResetAtChangeAloneDoesNotClearAlertState() {
        let decision = UsageWindowAlertPolicy.evaluate(
            previousPercentage: 91,
            currentPercentage: 91,
            resetAt: "2026-04-25T15:17:30Z",
            thresholds: [90],
            alertedThresholds: [90],
            isFirstCheck: false
        )

        XCTAssertNil(decision.thresholdToAlert)
        XCTAssertEqual(decision.alertedThresholds, [90])
    }

    func testNilResetAtStillAllowsThresholdAlert() {
        let decision = UsageWindowAlertPolicy.evaluate(
            previousPercentage: 84,
            currentPercentage: 91,
            resetAt: nil,
            thresholds: [90],
            alertedThresholds: [],
            isFirstCheck: false
        )

        XCTAssertEqual(decision.thresholdToAlert, 90)
        XCTAssertEqual(decision.alertedThresholds, [90])
    }

    func testHigherThresholdAlertMarksLowerReachedThresholdsAsHandled() {
        let decision = UsageWindowAlertPolicy.evaluate(
            previousPercentage: 84,
            currentPercentage: 96,
            resetAt: nil,
            thresholds: [90, 95],
            alertedThresholds: [],
            isFirstCheck: false
        )

        XCTAssertEqual(decision.thresholdToAlert, 95)
        XCTAssertEqual(decision.alertedThresholds, [90, 95])
    }
}
