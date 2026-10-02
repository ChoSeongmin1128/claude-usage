import AppKit
import XCTest
@testable import ClaudeUsage

/// 요금제에 따라 Codex 사용량 응답에 창이 없거나 일부가 깨져도 응답 전체가 실패하지 않는지 확인한다.
@MainActor
final class CodexUsagePlanVariantTests: XCTestCase {
    func testCreditsOnlyFlexiblePlanDecodesWithoutWindows() throws {
        let usage = try decode("""
        {
          "account_id": "acct-fixture",
          "plan_type": "enterprise",
          "rate_limit": null,
          "credits": { "has_credits": true, "unlimited": false, "balance": "62500" }
        }
        """)

        XCTAssertNil(usage.sessionWindow)
        XCTAssertNil(usage.weeklyWindow)
        XCTAssertNil(usage.gaugePercentage)
        XCTAssertEqual(usage.credits?.balance, 62500)
        XCTAssertEqual(usage.usageSummaryText, "데이터 없음")
        XCTAssertEqual(menuBarText(usage, display: .fiveHour), "—")
        XCTAssertEqual(menuBarText(usage, display: .dual), "—")
    }

    func testPlanWithoutAnyLimitDecodesInsteadOfFailing() throws {
        let usage = try decode("""
        { "account_id": "acct-fixture", "plan_type": "edu",
          "rate_limit": { "primary_window": null, "secondary_window": null } }
        """)

        XCTAssertNil(usage.gaugePercentage)
        XCTAssertEqual(menuBarText(usage, display: .weekly), "—")
    }

    func testMalformedWindowDoesNotHideTheOtherWindow() throws {
        let usage = try decode("""
        {
          "account_id": "acct-fixture",
          "rate_limit": {
            "primary_window": { "used_percent": "unknown", "limit_window_seconds": 18000 },
            "secondary_window": { "used_percent": 41, "reset_at": 1790900000, "limit_window_seconds": 604800 }
          }
        }
        """)

        XCTAssertNil(usage.sessionWindow)
        XCTAssertEqual(usage.weeklyWindow?.utilization, 41)
        XCTAssertEqual(menuBarText(usage, display: .fiveHour), "41%")
    }

    func testMalformedLimitsWithNothingElseToShowAreAFormatError() {
        XCTAssertThrowsError(try decode("""
        { "account_id": "acct-fixture", "rate_limit": { "primary_window": { "used_percent": "unknown" } } }
        """))
        XCTAssertThrowsError(try decode(#"{ "account_id": "acct-fixture", "rate_limit": "unexpected" }"#))
    }

    private func decode(_ json: String) throws -> CodexUsageResponse {
        try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
    }

    private func menuBarText(_ usage: CodexUsageResponse, display: PercentageDisplay) -> String {
        MenuBarStatusComposer.codexSnapshot(
            config: ProviderMenuBarDisplayConfig(
                kind: .codex,
                showIcon: false,
                style: .none,
                percentageDisplay: display,
                showBatteryPercent: false,
                resetTimeDisplay: .none,
                timeFormat: .h24,
                circularDisplayMode: .usage,
                iconMetric: .fiveHour,
                colorMode: .always
            ),
            usage: usage,
            error: nil,
            hasAuthError: false,
            isAuthenticated: true,
            secondaryColor: .secondaryLabelColor,
            icon: nil
        ).text
    }
}
