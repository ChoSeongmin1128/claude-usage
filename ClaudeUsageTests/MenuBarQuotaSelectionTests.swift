import AppKit
import XCTest
@testable import ClaudeUsage

@MainActor
final class MenuBarQuotaSelectionTests: XCTestCase {
    private func usage(_ model: Double = 31) throws -> ClaudeUsageResponse {
        ClaudeUsageResponse(
            fiveHour: .init(utilization: 8, resetsAt: "2030-01-01T01:00:00Z"),
            sevenDay: .init(utilization: 20, resetsAt: "2030-01-03T04:00:00Z"),
            scopedLimits: [
                .init(
                    kind: "weekly_scoped", percent: model, resetsAt: "2030-01-04T05:00:00Z", modelID: "fable",
                    modelName: "Fable")
            ])
    }

    private func config(_ selection: MenuBarQuotaSelection?, style: MenuBarStyle = .batteryBar)
        -> ProviderMenuBarDisplayConfig
    {
        ProviderMenuBarDisplayConfig(
            kind: .claude, showIcon: false, style: style, percentageDisplay: .fiveHour,
            showBatteryPercent: true, resetTimeDisplay: .fiveHour, timeFormat: .h24,
            circularDisplayMode: .usage, iconMetric: .fiveHour, basisOverride: .used,
            quotaSelection: selection)
    }

    func testModelNumbersResetAndGaugeUseTheSameQuotaInsteadOfBaseWindow() throws {
        let usage = try usage()
        let limits = UsageLimitCatalog.claude(usage)
        let model = try XCTUnwrap(limits.first(where: \.isModelScoped))
        let selection = MenuBarQuotaSelection(
            percentageIDs: [model.id], resetIDs: [model.id], gaugeIDs: [model.id], titles: [model.id: model.title])
        let projection = MenuBarQuotaProjection(selection: selection, limits: limits, basis: .used, timeFormat: .h24)
        XCTAssertEqual(projection.primary?.usedPercentage, 31)
        XCTAssertTrue(projection.percentageText.contains("31%"))
        XCTAssertFalse(projection.percentageText.contains("8%"))
        XCTAssertTrue(projection.resetText?.hasPrefix(model.shortTitle) == true)
        let actual = MenuBarStatusComposer.claudeSnapshot(
            config: config(selection), usage: usage, error: nil,
            hasAuthError: false, hasCredential: true, secondaryColor: .secondaryLabelColor, icon: nil)
        XCTAssertEqual(actual.text, projection.percentageText)
        XCTAssertEqual(actual.resetText, projection.resetText)
        XCTAssertNotNil(actual.styleIcon)
        let updated = MenuBarStatusComposer.claudeSnapshot(
            config: config(selection), usage: try self.usage(65), error: nil,
            hasAuthError: false, hasCredential: true, secondaryColor: .secondaryLabelColor, icon: nil)
        XCTAssertNotEqual(actual.renderKey, updated.renderKey)
    }

    func testMissingSelectedModelNeverSubstitutesBaseWindowOrZero() throws {
        let model = try XCTUnwrap(UsageLimitCatalog.claude(try usage()).first(where: \.isModelScoped))
        let selection = MenuBarQuotaSelection(
            percentageIDs: [model.id], resetIDs: [model.id], gaugeIDs: [model.id], titles: [model.id: model.title])
        let limits = UsageLimitCatalog.claude(
            ClaudeUsageResponse(fiveHour: .init(utilization: 8, resetsAt: nil), sevenDay: nil))
        let projection = MenuBarQuotaProjection(
            selection: selection, limits: limits, basis: .remaining, timeFormat: .h24)
        XCTAssertTrue(projection.percentageText.contains("데이터 없음"))
        XCTAssertFalse(projection.percentageText.contains("0%"))
        XCTAssertNil(projection.primary)
        XCTAssertNil(projection.resetText)
        var mutable = selection
        mutable.setSelected(false, id: model.id, surface: .percentage, limits: limits)
        XCTAssertTrue(mutable.percentageIDs.isEmpty)
        mutable.setSelected(true, id: model.id, surface: .percentage, limits: limits)
        XCTAssertTrue(mutable.percentageIDs.isEmpty)
    }

    func testLegacySelectionsAndRawKeysStayUntouchedUntilOptInAndResetRestoresLegacy() throws {
        let suite = "MenuBarQuotaSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("pct_weekly", forKey: "percentageDisplay")
        let settings = AppSettings(defaults: defaults)
        XCTAssertNil(settings.menuBarDisplayConfig(for: .claude)?.quotaSelection)
        let limits = UsageLimitCatalog.claude(try usage())
        var selection = try XCTUnwrap(settings.menuBarQuotaSelection(for: .claude, limits: limits))
        let model = try XCTUnwrap(limits.first(where: \.isModelScoped))
        selection.setSelected(true, id: model.id, surface: .percentage, limits: limits)
        settings.setMenuBarQuotaSelection(selection, for: .claude)
        XCTAssertEqual(defaults.string(forKey: "percentageDisplay"), "pct_weekly")
        XCTAssertEqual(AppSettings(defaults: defaults).menuBarDisplayConfig(for: .claude)?.quotaSelection, selection)
        let snapshot = settings.createSnapshot()
        settings.applyMenuBarDisplayPreset(.basic, for: .claude)
        XCTAssertNil(settings.menuBarDisplayConfig(for: .claude)?.quotaSelection)
        settings.restore(from: snapshot)
        XCTAssertEqual(settings.menuBarDisplayConfig(for: .claude)?.quotaSelection, selection)
        settings.resetToDefaults()
        XCTAssertNil(AppSettings(defaults: defaults).menuBarDisplayConfig(for: .claude)?.quotaSelection)
    }

    func testModelRowSupportsMenuBarIndependentlyOfPopoverVisibility() throws {
        let limits = UsageLimitCatalog.claude(try usage())
        let rows = LimitSettingsTable.rows(
            service: .claude, popoverItems: ClaudeItemCatalog().defaultItems,
            limits: limits, displayName: ClaudeItemCatalog().displayName(for:))
        let model = try XCTUnwrap(limits.first(where: \.isModelScoped))
        XCTAssertEqual(rows.first(where: { $0.quotaID == model.id })?.notificationLimit, model)
    }
}

extension MenuBarQuotaSelectionTests {
    func testCodexModelWindowsDriveNumbersTimeAndTwoGaugesWithTheirRealPeriods() throws {
        let usage = try JSONDecoder().decode(
            CodexUsageResponse.self,
            from: Data(
                #"{"rate_limit":{"primary_window":{"used_percent":8,"limit_window_seconds":18000}},"additional_rate_limits":[{"metered_feature":"spark","limit_name":"Spark","rate_limit":{"primary_window":{"used_percent":41,"limit_window_seconds":18000,"reset_at":1893492000},"secondary_window":{"used_percent":62,"limit_window_seconds":604800,"reset_at":1893664800}}}]}"#
                    .utf8))
        let limits = UsageLimitCatalog.codex(usage)
        let models = limits.filter(\.isModelScoped)
        XCTAssertEqual(models.count, 2)
        let selection = MenuBarQuotaSelection(
            percentageIDs: models.map(\.id), resetIDs: models.map(\.id), gaugeIDs: models.map(\.id))
        let config = ProviderMenuBarDisplayConfig(
            kind: .codex, showIcon: false, style: .concentricRings,
            percentageDisplay: .fiveHour, showBatteryPercent: true, resetTimeDisplay: .fiveHour, timeFormat: .h24,
            circularDisplayMode: .usage, iconMetric: .fiveHour, basisOverride: .used, quotaSelection: selection)
        let snapshot = MenuBarStatusComposer.codexSnapshot(
            config: config, usage: usage, error: nil,
            hasAuthError: false, isAuthenticated: true, secondaryColor: .secondaryLabelColor, icon: nil)
        XCTAssertTrue(snapshot.text.contains("Spark"))
        XCTAssertTrue(snapshot.text.contains("41%"))
        XCTAssertTrue(snapshot.text.contains("62%"))
        XCTAssertFalse(snapshot.text.contains("8%"))
        XCTAssertTrue(snapshot.resetText?.contains("Spark") == true)
        XCTAssertNotNil(snapshot.styleIcon)
        let projection = MenuBarQuotaProjection(selection: selection, limits: limits, basis: .used, timeFormat: .h24)
        XCTAssertEqual(projection.visualValues, [41, 62])
        XCTAssertNotEqual(models[0].id, models[1].id)
    }

    func testLegacyClaudeDoesNotSubstituteWeeklyResetAndExplicitEmptyGaugeHasNoIcon() throws {
        let usage = ClaudeUsageResponse(
            fiveHour: nil, sevenDay: .init(utilization: 20, resetsAt: "2030-01-03T04:00:00Z"))
        let legacy = MenuBarQuotaSelection.legacy(config: config(nil), limits: UsageLimitCatalog.claude(usage))
        XCTAssertEqual(legacy.percentageIDs.count, 1)
        XCTAssertTrue(legacy.resetIDs.isEmpty)
        let snapshot = MenuBarStatusComposer.claudeSnapshot(
            config: config(MenuBarQuotaSelection()), usage: usage,
            error: nil, hasAuthError: false, hasCredential: true, secondaryColor: .secondaryLabelColor, icon: nil)
        XCTAssertTrue(snapshot.text.isEmpty)
        XCTAssertNil(snapshot.styleIcon)
        XCTAssertNil(snapshot.resetText)
        XCTAssertTrue(snapshot.tooltip.contains("주간"))
    }
}

extension MenuBarQuotaSelectionTests {
    func testExplicitEmptySelectionDoesNotKeepAnInvisibleProviderActive() throws {
        let suite = "MenuBarQuotaSelectionTests.empty.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.setProviderShowIcon(false, for: .claude)
        settings.setMenuBarStyle(.batteryBar, for: .claude)
        settings.setMenuBarQuotaSelection(MenuBarQuotaSelection(), for: .claude)
        XCTAssertFalse(settings.isProviderVisibleInMenuBar(.claude))
    }
}
