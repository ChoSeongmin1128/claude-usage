import AppKit
import XCTest
@testable import ClaudeUsage

/// 요금제에 따라 Codex 사용량 응답에 창이 없거나 일부가 깨져도 응답 전체가 실패하지 않는지 확인한다.
@MainActor
final class CodexUsagePlanVariantTests: XCTestCase {
    func testCreditsOnlyFlexiblePlanDecodesWithoutWindows() throws {
        let usage = try decode(
            """
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
        let usage = try decode(
            """
            { "account_id": "acct-fixture", "plan_type": "edu",
              "rate_limit": { "primary_window": null, "secondary_window": null } }
            """)

        XCTAssertNil(usage.gaugePercentage)
        XCTAssertEqual(menuBarText(usage, display: .weekly), "—")
    }

    func testMalformedWindowDoesNotHideTheOtherWindow() throws {
        let usage = try decode(
            """
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
        XCTAssertThrowsError(
            try decode(
                """
                { "account_id": "acct-fixture", "rate_limit": { "primary_window": { "used_percent": "unknown" } } }
                """))
        XCTAssertThrowsError(try decode(#"{ "account_id": "acct-fixture", "rate_limit": "unexpected" }"#))
    }

    func testNegativeQuotaDropsOnlyItsWindowAndNeverCreatesAHealthyPopoverValue() throws {
        for invalid in [-1.0, -0.5] {
            let usage = try decode(
                #"{"account_id":"acct-fixture","rate_limit":{"primary_window":{"used_percent":\#(invalid),"limit_window_seconds":18000},"secondary_window":{"used_percent":41,"limit_window_seconds":604800}}}"#
            )
            XCTAssertNil(usage.sessionWindow)
            XCTAssertEqual(usage.weeklyWindow?.utilization, 41)
            XCTAssertTrue(usage.rateLimit?.hasMalformedWindow == true)
            XCTAssertEqual(menuBarText(usage, display: .fiveHour), "41%")
            let limits = UsageLimitCatalog.codex(usage)
            XCTAssertEqual(limits.count, 1)
            XCTAssertEqual(limits.first?.usedPercentage, 41)

            let suite = "CodexUsagePlanVariantTests.negative.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let context = UsageItemContext(
                density: .standard, settings: AppSettings(defaults: defaults), claudeUsage: nil,
                claudeOverage: nil, codexUsage: usage, codexError: nil)
            XCTAssertNil(CodexItemCatalog().section(for: "codexPrimary", context: context))
            guard case .usage(let row)? = CodexItemCatalog().section(for: "codexSecondary", context: context)?.payload
            else { return XCTFail("The valid weekly quota must remain visible.") }
            XCTAssertEqual(row.percentage, 41)
        }
    }

    func testNonfiniteQuotaDropsOnlyItsWindow() throws {
        for invalid in ["NaN", "Infinity", "-Infinity"] {
            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(
                positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
            let json =
                #"{"rate_limit":{"primary_window":{"used_percent":"\#(invalid)","limit_window_seconds":18000},"secondary_window":{"used_percent":41,"limit_window_seconds":604800}}}"#
            let usage = try decoder.decode(CodexUsageResponse.self, from: Data(json.utf8))
            XCTAssertNil(usage.sessionWindow)
            XCTAssertEqual(usage.weeklyWindow?.utilization, 41)
            XCTAssertTrue(usage.rateLimit?.hasMalformedWindow == true)
        }
    }

    func testInvalidBaseQuotaPreservesCreditsModelQuotaAndSpendControl() throws {
        let usage = try decode(
            #"{"plan_type":"business","rate_limit":{"primary_window":{"used_percent":-1,"limit_window_seconds":18000}},"credits":{"has_credits":true,"balance":123},"additional_rate_limits":[{"metered_feature":"model-fixture","rate_limit":{"primary_window":{"used_percent":35,"limit_window_seconds":604800}}}],"spend_control":{"individual_limit":{"used_percent":18}}}"#
        )
        XCTAssertNil(usage.sessionWindow)
        XCTAssertNil(usage.weeklyWindow)
        XCTAssertEqual(usage.credits?.balance, 123)
        XCTAssertEqual(usage.additionalRateLimits.first?.rateLimit?.primaryWindow?.utilization, 35)
        XCTAssertEqual(usage.spendControl?.individualLimit?.usedPercent, 18)
        XCTAssertEqual(UsageLimitCatalog.codex(usage).map(\.usedPercentage), [35])
        XCTAssertEqual(menuBarText(usage, display: .fiveHour), "—")
        XCTAssertThrowsError(
            try decode(#"{"rate_limit":{"primary_window":{"used_percent":-1}}}"#))
    }

    func testOverOneHundredQuotaRetainsItsExistingValueAndDisplayPolicy() throws {
        let usage = try decode(
            #"{"rate_limit":{"primary_window":{"used_percent":125.5,"limit_window_seconds":18000}}}"#)
        XCTAssertEqual(usage.sessionWindow?.utilization, 125.5)
        XCTAssertFalse(usage.rateLimit?.hasMalformedWindow == true)
        XCTAssertEqual(UsageLimitCatalog.codex(usage).first?.usedPercentage, 100)
        XCTAssertEqual(menuBarText(usage, display: .fiveHour), "100%")
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

@MainActor
final class CodexSpendControlTests: XCTestCase {
    func testSpendControlUsesOfficialStringAmountsAndShowsReachedReason() throws {
        let usage = try JSONDecoder().decode(
            CodexUsageResponse.self,
            from: Data(
                """
                {
                  "account_id": "acct-fixture",
                  "plan_type": "business",
                  "rate_limit": null,
                  "spend_control": {
                    "reached": true,
                    "individual_limit": { "source": "workspace", "limit": "1000", "used": "1000", "remaining": "0",
                                          "used_percent": 100, "remaining_percent": 0, "reset_after_seconds": 86400,
                                          "reset_at": 1793000000 }
                  },
                  "rate_limit_reached_type": { "type": "workspace_member_credits_depleted" }
                }
                """.utf8))

        XCTAssertEqual(usage.spendControl?.individualLimit?.limit, 1000)
        XCTAssertEqual(usage.spendControl?.individualLimit?.usedPercent, 100)
        XCTAssertEqual(usage.workspaceLimitNotice, "워크스페이스 크레딧 소진 · 소유자에게 추가 요청")
        XCTAssertNotNil(usage.spendControl?.individualLimit?.resetAtISO)
    }

    func testUnknownReachedTypeFallsBackToSpendControlFlag() throws {
        let usage = try JSONDecoder().decode(
            CodexUsageResponse.self,
            from: Data(
                """
                { "account_id": "acct-fixture", "spend_control": { "reached": false },
                  "rate_limit_reached_type": { "type": "something_new" } }
                """.utf8))
        XCTAssertNil(usage.workspaceLimitNotice)
    }

    func testRateCardLinkOnlyForWorkspacePlans() throws {
        func usage(_ plan: String?) throws -> CodexUsageResponse {
            let field = plan.map { #""plan_type": "\#($0)","# } ?? ""
            return try JSONDecoder().decode(
                CodexUsageResponse.self, from: Data(#"{ \#(field) "account_id": "acct-fixture" }"#.utf8))
        }
        XCTAssertNotNil(try usage("business").workspaceRateCardURL)
        XCTAssertNotNil(try usage("enterprise_cbp_usage_based").workspaceRateCardURL)
        XCTAssertNil(try usage("plus").workspaceRateCardURL)
        XCTAssertNil(try usage(nil).workspaceRateCardURL)
    }
}
