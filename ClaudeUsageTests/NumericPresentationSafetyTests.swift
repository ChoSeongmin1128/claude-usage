import XCTest
@testable import ClaudeUsage

final class NumericPresentationSafetyTests: XCTestCase {
    func testOutOfRangePercentagesCannotTrapOrFabricateZero() {
        for value in [Double.nan, .infinity, -.infinity, 1e30] {
            XCTAssertNil(PercentageText.wholeNumber(value))
            XCTAssertEqual(PercentageText.string(value), "—")
        }
        XCTAssertEqual(PercentageText.string(100.7), "101%")
        XCTAssertEqual(PercentageText.string(99.8), "99%")
        XCTAssertEqual(PercentageText.string(0.2), "1%")
    }

    func testUnrepresentableDatesAreUnknownOnEverySharedSurface() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for interval in [Double.nan, .infinity, -.infinity, 1e30] {
            let date = Date(timeIntervalSince1970: interval)
            XCTAssertNil(TimeFormatter.validatedResetDate(date))
            XCTAssertEqual(TimeFormatter.elapsed(since: date, now: now), "시간 정보 없음")
            XCTAssertEqual(TimeFormatter.formatRemaining(until: date, now: now, isWeekly: true), "시간 정보 없음")
            XCTAssertEqual(TimeFormatter.formatRemainingCompact(until: date, now: now), "시간 정보 없음")
            XCTAssertEqual(TimeFormatter.formatRelativeTime(until: date, now: now), "시간 정보 없음")
            XCTAssertEqual(
                TimeFormatter.formatUsageResetDetail(resetAt: date, isWeekly: true, now: now), "갱신 예상: 시간 정보 없음")
        }
        XCTAssertNotNil(TimeFormatter.validatedResetDate(now))
        XCTAssertEqual(
            TimeFormatter.formatRemaining(until: now.addingTimeInterval(3 * 86400), now: now, isWeekly: true), "3d")
    }

    func testMalformedServerTimestampDropsOnlyResetTime() throws {
        let claude = try JSONDecoder().decode(
            ClaudeUsageResponse.self,
            from: Data(
                #"{"five_hour":{"utilization":20,"resets_at":1e30}}"#.utf8))
        XCTAssertEqual(claude.fiveHour?.utilization, 20)
        XCTAssertNil(claude.fiveHour?.resetsAt)
        let codex = try JSONDecoder().decode(
            CodexUsageResponse.self,
            from: Data(
                #"{"rate_limit":{"primary_window":{"used_percent":20,"reset_at":"NaN","limit_window_seconds":18000}}}"#
                    .utf8))
        XCTAssertEqual(codex.sessionWindow?.utilization, 20)
        XCTAssertNil(codex.sessionWindow?.resetAt)
        XCTAssertNil(codex.sessionWindow?.resetAtISO)
    }

    func testSeparateSpendEndpointDoesNotInventMissingMoney() throws {
        for json in [
            #"{}"#, #"{"is_enabled":true,"monthly_credit_limit":1000}"#,
            #"{"is_enabled":true,"used_credits":100}"#,
            #"{"is_enabled":true,"monthly_credit_limit":1000,"used_credits":"NaN"}"#,
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(OverageSpendLimitResponse.self, from: Data(json.utf8)))
        }
        let disabled = try JSONDecoder().decode(
            OverageSpendLimitResponse.self, from: Data(#"{"is_enabled":false}"#.utf8))
        XCTAssertEqual(disabled, .notEnabled)
        let zero = try JSONDecoder().decode(
            OverageSpendLimitResponse.self,
            from: Data(
                #"{"is_enabled":true,"monthly_credit_limit":null,"used_credits":0}"#.utf8))
        XCTAssertEqual(zero.formattedUsageLimitSummary, "$0.00 사용 / 한도 없음")
    }

    func testCurrencyScaleIsIndependentFromDisplayPrecision() {
        XCTAssertEqual(MoneyFormatter.string(minorUnits: 1_234_567, currency: "USD", decimalPlaces: 5), "$12.3457")
        XCTAssertEqual(MoneyFormatter.string(minorUnits: 12_345_678, currency: "USD", decimalPlaces: 8), "$0.1235")
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(MoneyFormatter.string(minorUnits: value, currency: "USD"), "금액 알 수 없음")
            XCTAssertEqual(MoneyFormatter.credits(value), "크레딧 알 수 없음")
        }
        let overage = OverageSpendLimitResponse(
            monthlyCreditLimitCents: 1500, usedCreditsCents: 1250, isEnabled: true,
            outOfCredits: false, currency: "JPY")
        XCTAssertEqual(overage.formattedUsageLimitSummary, "¥12.50 사용 / ¥15.00 한도")
        let tiny = OverageSpendLimitResponse(
            monthlyCreditLimitCents: 1e-320, usedCreditsCents: 1, isEnabled: true,
            outOfCredits: false, currency: "USD")
        XCTAssertNil(tiny.usagePercentage)
    }

    func testMalformedOwnerWindowDurationPreservesOtherQuota() throws {
        for minutes in [Double.nan, .infinity, 1e30, -1, 0] {
            let response = try CodexHomeAccount.usageResponse(fromAppServer: [
                "rateLimits": [
                    "primary": ["usedPercent": 20, "windowDurationMins": minutes],
                    "secondary": ["usedPercent": 45, "windowDurationMins": 10080],
                ]
            ])
            XCTAssertNil(response.sessionWindow)
            XCTAssertEqual(response.weeklyWindow?.utilization, 45)
        }
        let response = try CodexHomeAccount.usageResponse(fromAppServer: [
            "rateLimits": ["primary": ["usedPercent": 20, "windowDurationMins": 1.5]]
        ])
        XCTAssertEqual(response.sessionWindow?.limitWindowSeconds, 90)
    }
}
