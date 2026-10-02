import AppKit
import XCTest
@testable import ClaudeUsage

/// 요금제에 따라 Claude 사용량 응답에 없는 창이 있어도 응답 전체가 실패하지 않는지 확인한다.
@MainActor
final class ClaudeUsagePlanVariantTests: XCTestCase {
    func testUsageBasedPlanWithoutWindowsDecodesWithNothingToShow() throws {
        let usage = try decode("""
        {
          "five_hour": null,
          "seven_day": null,
          "limits": [],
          "extra_usage": { "is_enabled": true, "monthly_limit": null, "used_credits": 1250, "currency": "USD" }
        }
        """)

        XCTAssertNil(usage.fiveHour)
        XCTAssertNil(usage.sevenDay)
        XCTAssertNil(usage.gaugePercentage)
        XCTAssertEqual(usage.usageSummaryText, "데이터 없음")
        XCTAssertTrue(UsageLimitCatalog.claude(usage).isEmpty)
    }

    func testMissingFiveHourWindowFallsBackToWeekly() throws {
        let usage = try decode("""
        { "seven_day": { "utilization": 40, "resets_at": "2026-10-05T14:00:00Z" } }
        """)

        XCTAssertNil(usage.fiveHour)
        XCTAssertFalse(usage.hasSessionWindow)
        XCTAssertEqual(usage.gaugePercentage, 40)
        XCTAssertEqual(usage.usageSummaryText, "주간 40%")
        XCTAssertEqual(UsageLimitCatalog.claude(usage).map(\.scope), ["seven_day"])
        XCTAssertEqual(menuBarText(usage, display: .fiveHour), "40%")
        XCTAssertEqual(menuBarText(usage, display: .dual), "40%")
    }

    func testMalformedFiveHourWindowDoesNotHideWeekly() throws {
        let usage = try decode("""
        {
          "five_hour": { "utilization": "unknown" },
          "seven_day": { "utilization": 74, "resets_at": "2026-10-05T14:00:00Z" }
        }
        """)

        XCTAssertNil(usage.fiveHour)
        XCTAssertEqual(usage.sevenDay?.utilization, 74)
    }

    func testMalformedWindowsWithNothingElseToShowAreAFormatError() {
        XCTAssertThrowsError(try decode(#"{ "five_hour": { "utilization": -5 }, "seven_day": null }"#))
    }

    /// 2026-10-02 claude.ai 웹 응답(Team 좌석) 실측 구조. 수치 외 식별 정보 없음.
    func testMeasuredTeamSeatResponseKeepsAllWindows() throws {
        let usage = try decode("""
        {
          "five_hour": { "utilization": 24, "resets_at": "2026-10-02T05:50:00.224118+00:00",
                         "limit_dollars": null, "remaining_dollars": null, "used_dollars": null, "locked_reason": null },
          "seven_day": { "utilization": 74, "resets_at": "2026-10-05T14:00:00.224138+00:00",
                         "limit_dollars": null, "remaining_dollars": null, "used_dollars": null, "locked_reason": null },
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "cedar_ember": null,
          "limits": [
            { "group": "session", "is_active": false, "kind": "session", "percent": 24,
              "resets_at": "2026-10-02T05:50:00.224118+00:00", "scope": null, "severity": "normal" },
            { "group": "weekly", "is_active": true, "kind": "weekly_all", "percent": 74,
              "resets_at": "2026-10-05T14:00:00.224138+00:00", "scope": null, "severity": "normal" },
            { "group": "weekly", "is_active": false, "kind": "weekly_scoped", "percent": 0,
              "resets_at": "2026-10-05T14:00:00+00:00",
              "scope": { "model": { "display_name": "Fable", "id": null }, "surface": null }, "severity": "normal" }
          ]
        }
        """)

        XCTAssertEqual(usage.fiveHour?.utilization, 24)
        XCTAssertEqual(usage.sevenDay?.utilization, 74)
        XCTAssertEqual(usage.modelWeeklyWindows.map(\.modelName), ["Fable"])
        XCTAssertEqual(menuBarText(usage, display: .dual), "24%·74%")
    }

    private func decode(_ json: String) throws -> ClaudeUsageResponse {
        try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
    }

    private func menuBarText(_ usage: ClaudeUsageResponse, display: PercentageDisplay) -> String {
        MenuBarStatusComposer.claudeSnapshot(
            config: ProviderMenuBarDisplayConfig(
                kind: .claude,
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
            hasCredential: true,
            secondaryColor: .secondaryLabelColor,
            icon: nil
        ).text
    }
}
