import XCTest
@testable import ClaudeUsage

@MainActor
final class LimitSettingsTableTests: XCTestCase {
    func testClaudeRowsJoinPopoverItemsMenuBarSlotsAndNotificationLimits() {
        let usage = ClaudeUsageResponse(
            fiveHour: .init(utilization: 10, resetsAt: nil),
            sevenDay: .init(utilization: 20, resetsAt: nil),
            scopedLimits: [.init(kind: "weekly_scoped", percent: 5, modelID: "fable", modelName: "Fable")])
        let rows = LimitSettingsTable.rows(
            service: .claude, popoverItems: ClaudeItemCatalog().defaultItems,
            limits: UsageLimitCatalog.claude(usage), displayName: ClaudeItemCatalog().displayName(for:))

        XCTAssertEqual(rows.map(\.title), ["5시간 한도", "주간 한도", "모델별 주간 한도", "Fable · 주간", "추가 사용량"])
        XCTAssertEqual(rows.map(\.menuBarSlot), [.fiveHour, .weekly, nil, nil, nil])
        XCTAssertEqual(rows[0].notificationLimit?.scope, "five_hour")
        XCTAssertTrue(rows[3].isChild)
        XCTAssertNil(rows[3].popoverItemID)
        XCTAssertNil(rows[4].notificationLimit)
        XCTAssertFalse(rows[4].takesNotification)
    }

    func testCodexRowsUseWindowSlotsAndKeepRowsBeforeFirstFetch() throws {
        let usage = try JSONDecoder().decode(
            CodexUsageResponse.self,
            from: Data(
                #"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":604800,"reset_after_seconds":3600,"reset_at":1790900000},"secondary_window":null}}"#
                    .utf8))
        let catalog = CodexItemCatalog()
        let rows = LimitSettingsTable.rows(
            service: .codex, popoverItems: catalog.defaultItems, limits: UsageLimitCatalog.codex(usage),
            displayName: catalog.displayName(for:))

        XCTAssertEqual(rows[0].title, "주간 한도")
        XCTAssertEqual(rows[0].notificationLimit?.windowSlot, "primary")
        XCTAssertEqual(rows[0].menuBarSlot, .fiveHour)
        XCTAssertEqual(rows[1].title, "보조 한도")
        XCTAssertNil(rows[1].notificationLimit)
        XCTAssertTrue(rows[1].takesNotification)
        XCTAssertTrue(rows.contains { $0.title == "월 크레딧 한도" })
    }

    func testMenuBarPercentageCombinesSlots() {
        XCTAssertEqual(PercentageDisplay.none.setting(.fiveHour, to: true), .fiveHour)
        XCTAssertEqual(PercentageDisplay.fiveHour.setting(.weekly, to: true), .dual)
        XCTAssertEqual(PercentageDisplay.dual.setting(.fiveHour, to: false), .weekly)
        XCTAssertEqual(PercentageDisplay.weekly.setting(.weekly, to: false), PercentageDisplay.none)
    }

    func testStoredTabsFromEarlierVersionsOpenTheNewPanels() {
        XCTAssertEqual(SettingsProviderPanel.resolve(storedValue: "display")?.panel, .display)
        XCTAssertEqual(SettingsProviderPanel.resolve(storedValue: "notifications")?.panel, .limits)
        let codex = SettingsProviderPanel.resolve(storedValue: "codex")
        XCTAssertEqual(codex?.panel, .accounts)
        XCTAssertEqual(codex?.provider, .codex)
        XCTAssertNil(SettingsProviderPanel.resolve(storedValue: "unknown"))
    }
}
