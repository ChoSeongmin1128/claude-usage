import XCTest
@testable import ClaudeUsage

@MainActor
final class LimitSettingsTableTests: XCTestCase {
    func testClaudeRowsJoinPopoverItemsAndNotificationLimits() {
        let usage = ClaudeUsageResponse(
            fiveHour: .init(utilization: 10, resetsAt: nil),
            sevenDay: .init(utilization: 20, resetsAt: nil),
            scopedLimits: [.init(kind: "weekly_scoped", percent: 5, modelID: "fable", modelName: "Fable")])
        let rows = LimitSettingsTable.rows(
            service: .claude, popoverItems: ClaudeItemCatalog().defaultItems,
            limits: UsageLimitCatalog.claude(usage), displayName: ClaudeItemCatalog().displayName(for:))

        XCTAssertEqual(rows.map(\.title), ["5시간 한도", "주간 한도", "모델별 주간 한도", "Fable · 주간", "추가 사용량", "초기화권"])
        XCTAssertEqual(rows.map(\.controlsResetCreditMenuBar), [false, false, false, false, false, true])
        XCTAssertEqual(rows[0].notificationLimit?.scope, "five_hour")
        for row in rows.suffix(2) {
            XCTAssertNil(row.notificationLimit)
            XCTAssertFalse(row.takesNotification)
        }
    }

    func testCodexRowsDistinguishUnknownSupportFromAWeeklyOnlyPersonalResponse() throws {
        let catalog = CodexItemCatalog()
        let unknown = LimitSettingsTable.rows(
            service: .codex, popoverItems: catalog.settingsItems(from: catalog.defaultItems, usage: nil),
            limits: [], displayName: catalog.displayName(for:))
        XCTAssertTrue(unknown.contains { $0.id == "codexPrimary" && $0.notificationLimit == nil })
        XCTAssertTrue(unknown.contains { $0.id == "codexSecondary" && $0.notificationLimit == nil })
        XCTAssertFalse(unknown.contains { $0.id == "codexSpendLimit" })

        let usage = try JSONDecoder().decode(
            CodexUsageResponse.self,
            from: Data(
                """
                {"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":12,
                 "limit_window_seconds":604800,"reset_after_seconds":3600,"reset_at":1790900000},
                 "secondary_window":null},"spend_control":{},
                 "credits":{"has_credits":true,"unlimited":false,"balance":"125.50"}}
                """.utf8))
        let rows = LimitSettingsTable.rows(
            service: .codex, popoverItems: catalog.settingsItems(from: catalog.defaultItems, usage: usage),
            limits: UsageLimitCatalog.codex(usage), displayName: catalog.displayName(for:), codexUsage: usage)

        XCTAssertEqual(rows.map(\.id), ["codexSecondary", "codexCredits"])
        XCTAssertEqual(rows.map(\.title), ["주간 한도", "크레딧 잔액"])
        XCTAssertEqual(rows[0].notificationLimit?.windowSlot, "primary")
        XCTAssertTrue(rows[0].takesNotification)
        XCTAssertNil(rows[1].notificationLimit)
        XCTAssertFalse(rows[1].takesNotification)
    }

    func testCodexSwappedApiWindowsKeepSemanticTitlesAndOriginalNotificationIDs() throws {
        let usage = try JSONDecoder().decode(
            CodexUsageResponse.self,
            from: Data(
                """
                {"plan_type":"pro","rate_limit":{
                 "primary_window":{"used_percent":12,"limit_window_seconds":604800},
                 "secondary_window":{"used_percent":35,"limit_window_seconds":18000}}}
                """.utf8))
        let catalog = CodexItemCatalog()
        let limits = UsageLimitCatalog.codex(usage)
        let rows = LimitSettingsTable.rows(
            service: .codex, popoverItems: catalog.settingsItems(from: catalog.defaultItems, usage: usage),
            limits: limits, displayName: catalog.displayName(for:), codexUsage: usage)

        XCTAssertEqual(rows.map(\.id), ["codexPrimary", "codexSecondary"])
        XCTAssertEqual(rows.map(\.title), ["5시간 한도", "주간 한도"])
        XCTAssertEqual(rows.map { $0.notificationLimit?.windowSlot }, ["secondary", "primary"])
        XCTAssertEqual(rows[0].notificationLimit?.id, limits.first { $0.windowSlot == "secondary" }?.id)
        XCTAssertEqual(rows[1].notificationLimit?.id, limits.first { $0.windowSlot == "primary" }?.id)

        let monthlyWindow = try JSONDecoder().decode(
            CodexUsageResponse.self,
            from: Data(
                #"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":2592000}}}"#
                    .utf8))
        let monthlyRows = LimitSettingsTable.rows(
            service: .codex,
            popoverItems: catalog.settingsItems(from: catalog.defaultItems, usage: monthlyWindow),
            limits: UsageLimitCatalog.codex(monthlyWindow), displayName: catalog.displayName(for:),
            codexUsage: monthlyWindow)
        XCTAssertEqual(monthlyRows.map(\.title), ["30일 한도"])
    }

    func testCodexEffectiveMenuBarSelectionPreservesStorageUntilTheVisibleWindowIsToggled() throws {
        func response(primary: Int?, secondary: Int?) throws -> CodexUsageResponse {
            func window(_ period: Int?) -> String {
                guard let period else { return "null" }
                return #"{"used_percent":12,"limit_window_seconds":\#(period)}"#
            }
            return try JSONDecoder().decode(
                CodexUsageResponse.self,
                from: Data(
                    """
                    {"plan_type":"pro","rate_limit":{
                     "primary_window":\(window(primary)),"secondary_window":\(window(secondary))}}
                    """.utf8))
        }
        let weeklyOnly = try response(primary: 604_800, secondary: nil)
        let sessionOnly = try response(primary: 18_000, secondary: nil)
        let bothWindows = try response(primary: 18_000, secondary: 604_800)
        let noWindows = try response(primary: nil, secondary: nil)
        let suite = "LimitSettingsTableTests.codex-selection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, hasExistingAccountStorage: false)

        for raw in [PercentageDisplay.fiveHour, .dual] {
            settings.setProviderPercentageDisplay(raw, for: .codex)
            let saved = try XCTUnwrap(settings.menuBarDisplayConfig(for: .codex)?.percentageDisplay)
            let effective = saved.effectiveCodexSelection(usage: weeklyOnly)
            XCTAssertEqual(effective, .weekly)
            XCTAssertTrue(effective.contains(.weekly))
            XCTAssertFalse(effective.contains(.fiveHour))
            XCTAssertEqual(saved.effectiveCodexSelection(usage: bothWindows), raw)
            XCTAssertEqual(saved.effectiveCodexSelection(usage: nil), raw)
            XCTAssertEqual(settings.menuBarDisplayConfig(for: .codex)?.percentageDisplay, raw)
            let reloaded = AppSettings(defaults: defaults, hasExistingAccountStorage: false)
            XCTAssertEqual(reloaded.menuBarDisplayConfig(for: .codex)?.percentageDisplay, raw)
        }
        settings.setProviderPercentageDisplay(.none, for: .codex)
        let changed = try XCTUnwrap(settings.menuBarDisplayConfig(for: .codex)?.percentageDisplay)
        XCTAssertEqual(changed, PercentageDisplay.none)
        XCTAssertFalse(changed.effectiveCodexSelection(usage: weeklyOnly).contains(.weekly))
        XCTAssertEqual(changed.effectiveCodexSelection(usage: bothWindows), PercentageDisplay.none)
        XCTAssertEqual(PercentageDisplay.dual.effectiveCodexSelection(usage: sessionOnly), .fiveHour)
        XCTAssertEqual(PercentageDisplay.weekly.effectiveCodexSelection(usage: sessionOnly), PercentageDisplay.none)
        XCTAssertEqual(PercentageDisplay.dual.effectiveCodexSelection(usage: noWindows), PercentageDisplay.none)
    }

    func testStoredTabsFromEarlierVersionsOpenTheNewPanels() {
        XCTAssertEqual(SettingsProviderPanel.resolve(storedValue: "display")?.panel, .display)
        XCTAssertEqual(SettingsProviderPanel.resolve(storedValue: "notifications")?.panel, .common)
        let codex = SettingsProviderPanel.resolve(storedValue: "codex")
        XCTAssertEqual(codex?.panel, .codex)
        XCTAssertEqual(codex?.provider, .codex)
        XCTAssertEqual(SettingsProviderPanel.resolve(storedValue: "accounts", fallbackProvider: .codex)?.panel, .codex)
        XCTAssertEqual(
            SettingsProviderPanel.resolve(storedValue: "limits", fallbackProvider: .antigravity)?.panel, .antigravity)
        XCTAssertEqual(SettingsProviderPanel.resolve(storedValue: "welcome")?.panel, .welcome)
        XCTAssertNil(SettingsProviderPanel.resolve(storedValue: "unknown"))
    }
}
