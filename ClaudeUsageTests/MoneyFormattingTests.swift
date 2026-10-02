import XCTest
@testable import ClaudeUsage

final class MoneyFormattingTests: XCTestCase {
    func testCurrencyUsesCodeAndItsMinorUnits() {
        XCTAssertEqual(MoneyFormatter.string(minorUnits: 125_050, currency: "USD"), "$1,250.50")
        XCTAssertEqual(MoneyFormatter.string(minorUnits: 999, currency: "eur"), "€9.99")
        XCTAssertEqual(MoneyFormatter.string(minorUnits: 1_500, currency: "JPY"), "¥1,500")
        XCTAssertEqual(MoneyFormatter.string(minorUnits: 1_500, currency: "USD", decimalPlaces: 0), "$1,500")
    }

    func testClaudeOverageWithoutLimitSaysNoLimit() throws {
        let overage = try JSONDecoder().decode(
            OverageSpendLimitResponse.self,
            from: Data(
                """
                { "is_enabled": true, "monthly_credit_limit": null, "used_credits": 1250, "currency": "USD" }
                """.utf8))

        XCTAssertNil(overage.monthlyCreditLimit)
        XCTAssertNil(overage.usagePercentage)
        XCTAssertEqual(overage.formattedUsageLimitSummary, "$12.50 사용 / 한도 없음")
        XCTAssertEqual(overage.headlineText, "$12.50")
    }

    func testClaudeOverageFollowsServerCurrencyAndDecimalPlaces() throws {
        let overage = try JSONDecoder().decode(
            OverageSpendLimitResponse.self,
            from: Data(
                """
                { "is_enabled": true, "monthly_credit_limit": 5000, "used_credits": 1200, "currency": "EUR", "decimal_places": 2 }
                """.utf8))

        XCTAssertEqual(overage.formattedUsageLimitSummary, "€12.00 사용 / €50.00 한도")
        XCTAssertEqual(overage.headlineText, "24%")
    }

    func testClaudeOverageShowsOutOfCredits() {
        let overage = OverageSpendLimitResponse(
            monthlyCreditLimitCents: 10_000, usedCreditsCents: 10_000, isEnabled: true, outOfCredits: true,
            currency: "USD")

        XCTAssertEqual(overage.formattedUsageLimitSummary, "$100.00 사용 / $100.00 한도 · 크레딧 소진")
    }

    func testCodexCreditsAreCountsNotDollars() throws {
        let credits = try JSONDecoder().decode(
            CodexCredits.self,
            from: Data(
                """
                { "has_credits": true, "unlimited": false, "balance": "62500" }
                """.utf8))
        XCTAssertEqual(credits.formattedBalance, "62,500 크레딧")
        XCTAssertEqual(MoneyFormatter.credits(12.5), "12.5 크레딧")
    }
}
