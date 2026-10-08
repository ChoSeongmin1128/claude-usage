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

    private func config(
        _ selection: MenuBarQuotaSelection?, style: MenuBarStyle = .batteryBar, gauges: MenuBarGaugeSelection? = nil
    )
        -> ProviderMenuBarDisplayConfig
    {
        ProviderMenuBarDisplayConfig(
            kind: .claude, showIcon: false, style: style, percentageDisplay: .fiveHour,
            showBatteryPercent: true, resetTimeDisplay: .fiveHour, timeFormat: .h24,
            circularDisplayMode: .usage, iconMetric: .fiveHour, basisOverride: .used,
            quotaSelection: selection, gaugeSelection: gauges)
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


extension MenuBarQuotaSelectionTests {
    func testThreeClaudeGaugesRenderIndependentlyAndThirdModelInvalidatesCache() throws {
        let current = try usage(31)
        let limits = UsageLimitCatalog.claude(current)
        let ids = limits.map(\.id)
        XCTAssertEqual(ids.count, 3)
        let selected = MenuBarQuotaSelection(gaugeIDs: ids)
        let snapshot = MenuBarStatusComposer.claudeSnapshot(
            config: config(selected, gauges: MenuBarGaugeSelection(ids: selected.gaugeIDs)), usage: current, error: nil,
            hasAuthError: false, hasCredential: true, secondaryColor: .secondaryLabelColor, icon: nil)
        let image = try XCTUnwrap(snapshot.styleIcon)
        XCTAssertGreaterThan(image.size.width, BatteryGeometry.Layout.sideBySide.size.width)
        XCTAssertEqual(image.size.height, BatteryGeometry.height)
        let attachment = XCTAttachment(
            image: MenuBarStatusComposer.singleProviderContent(
                snapshot: snapshot, secondaryColor: .secondaryLabelColor,
                appearance: try XCTUnwrap(NSAppearance(named: .darkAqua))
            ).image)
        attachment.name = "Claude-three-labeled-gauges"
        attachment.lifetime = .keepAlways
        add(attachment)
        let changed = MenuBarStatusComposer.claudeSnapshot(
            config: config(selected, gauges: MenuBarGaugeSelection(ids: selected.gaugeIDs)), usage: try usage(75),
            error: nil,
            hasAuthError: false, hasCredential: true, secondaryColor: .secondaryLabelColor, icon: nil)
        XCTAssertNotEqual(snapshot.renderKey, changed.renderKey)
        let missing = MenuBarQuotaProjection(
            selection: selected, limits: Array(limits.dropLast()), basis: .remaining, timeFormat: .h24)
        XCTAssertEqual(missing.gauges.map(\.id), ids)
        XCTAssertNil(missing.gauges.last?.percentage)
        var four = selected
        four.gaugeIDs.append("future-model-window")
        four.titles["future-model-window"] = "Future"
        let fourth = MenuBarStatusComposer.claudeSnapshot(
            config: config(four, gauges: MenuBarGaugeSelection(ids: four.gaugeIDs)), usage: current, error: nil,
            hasAuthError: false,
            hasCredential: true, secondaryColor: .secondaryLabelColor, icon: nil)
        XCTAssertGreaterThan(try XCTUnwrap(fourth.styleIcon).size.width, image.size.width)
        XCTAssertTrue(fourth.tooltip.contains("Future: 데이터 없음"))
    }

    func testGaugeOrderingPersistsWithoutReorderingNumbersAndLegacyLayoutsRemainStable() throws {
        let limits = UsageLimitCatalog.claude(try usage())
        let ids = limits.map(\.id)
        let selection = MenuBarQuotaSelection(percentageIDs: [ids[0]], resetIDs: [ids[1]], gaugeIDs: ids)
        var gauges = MenuBarGaugeSelection(ids: ids)
        gauges.move(ids[2], by: -1)
        let preferences = MenuBarQuotaPreferences(providers: ["claude": selection], gauges: ["claude": gauges])
        let decoded = try JSONDecoder().decode(MenuBarQuotaPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded, preferences)
        let resolved = config(selection, gauges: gauges).resolvedQuotaSelection(limits: limits)
        XCTAssertEqual(resolved.gaugeIDs, [ids[0], ids[2], ids[1]])
        XCTAssertEqual(resolved.percentageIDs, [ids[0]])
        XCTAssertEqual(resolved.resetIDs, [ids[1]])
        XCTAssertEqual(config(selection).resolvedQuotaSelection(limits: limits).gaugeIDs, [ids[0]])
        XCTAssertEqual(
            config(selection, style: .dualBattery).resolvedQuotaSelection(limits: limits).gaugeIDs, Array(ids.prefix(2))
        )
        XCTAssertTrue(config(selection, style: .none).resolvedQuotaSelection(limits: limits).gaugeIDs.isEmpty)
        XCTAssertEqual(MenuBarGaugeLayout.legacy(.dualBattery), .stacked)
        let legacyData = Data(#"{"version":1,"providers":{}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(MenuBarQuotaPreferences.self, from: legacyData).gauges)
    }

    func testGaugeOnlyStorageSurvivesReloadSnapshotAndResetWithoutCreatingTextSelection() throws {
        let suite = "MenuBarQuotaSelectionTests.gauge-only.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let ids = UsageLimitCatalog.claude(try usage()).map(\.id)
        settings.setMenuBarGaugeSelection(MenuBarGaugeSelection(ids: ids), for: .claude)
        XCTAssertNil(settings.menuBarDisplayConfig(for: .claude)?.quotaSelection)
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.menuBarDisplayConfig(for: .claude)?.gaugeSelection?.ids, ids)
        let snapshot = settings.createSnapshot()
        settings.applyMenuBarDisplayPreset(.basic, for: .claude)
        XCTAssertNil(settings.menuBarDisplayConfig(for: .claude)?.gaugeSelection)
        settings.restore(from: snapshot)
        XCTAssertEqual(settings.menuBarDisplayConfig(for: .claude)?.gaugeSelection?.ids, ids)
        settings.resetToDefaults()
        XCTAssertNil(AppSettings(defaults: defaults).menuBarDisplayConfig(for: .claude)?.gaugeSelection)
    }

    func testNoUsageKeepsKnownSelectedGaugeNameAndMissingValueInAccessibility() throws {
        let gauges = MenuBarGaugeSelection(ids: ["model/fable"], titles: ["model/fable": "Fable"])
        let claude = MenuBarStatusComposer.claudeSnapshot(
            config: config(nil, gauges: gauges), usage: nil, error: nil, hasAuthError: false,
            hasCredential: true, secondaryColor: .secondaryLabelColor, icon: nil)
        let codexConfig = ProviderMenuBarDisplayConfig(
            kind: .codex, showIcon: false, style: .batteryBar, percentageDisplay: .fiveHour,
            showBatteryPercent: true, resetTimeDisplay: .none, timeFormat: .h24,
            circularDisplayMode: .usage, iconMetric: .fiveHour, gaugeSelection: gauges)
        let codex = MenuBarStatusComposer.codexSnapshot(
            config: codexConfig, usage: nil, error: nil, hasAuthError: false,
            isAuthenticated: true, secondaryColor: .secondaryLabelColor, icon: nil)
        for snapshot in [claude, codex] {
            XCTAssertNotNil(snapshot.styleIcon)
            XCTAssertTrue(snapshot.tooltip.contains("Fable: 데이터 없음"))
            XCTAssertTrue(snapshot.accessibilityValue?.contains("Fable: 데이터 없음") == true)
            XCTAssertFalse(snapshot.tooltip.contains("0%"))
        }
    }

    func testKnownOneAndTwoGaugeLayoutsKeepTheSamePixelsWhenOptingIntoListStorage() throws {
        let usage = try usage()
        let ids = Array(UsageLimitCatalog.claude(usage).prefix(2).map(\.id))
        for style in [MenuBarStyle.batteryBar, .circular, .dualBattery, .sideBySideBattery, .concentricRings] {
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                let selection = MenuBarQuotaSelection(gaugeIDs: ids)
                let old = config(selection, style: style)
                let list = MenuBarGaugeSelection(
                    ids: Array(ids.prefix(style.isDualStyle ? 2 : 1)), layout: .legacy(style))
                let updated = config(selection, style: style, gauges: list)
                let images = [old, updated].map {
                    MenuBarStatusComposer.claudeSnapshot(
                        config: $0, usage: usage, error: nil, hasAuthError: false, hasCredential: true,
                        secondaryColor: .secondaryLabelColor, icon: nil, appearance: appearance
                    ).styleIcon
                }
                let raster = try images.map { image -> Data in
                    let tiff = try XCTUnwrap(image?.tiffRepresentation)
                    return try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                }
                XCTAssertEqual(raster[0], raster[1], "\(style) / \(appearanceName)")
            }
        }
    }

    func testFourObservedClaudeModelGaugesUseTheirOwnValues() throws {
        let usage = ClaudeUsageResponse(
            fiveHour: .init(utilization: 11, resetsAt: nil), sevenDay: .init(utilization: 22, resetsAt: nil),
            scopedLimits: [
                .init(kind: "weekly_scoped", percent: 33, resetsAt: nil, modelID: "fable", modelName: "Fable"),
                .init(kind: "weekly_scoped", percent: 44, resetsAt: nil, modelID: "sonnet", modelName: "Sonnet"),
            ])
        let limits = UsageLimitCatalog.claude(usage)
        let selection = MenuBarQuotaSelection(gaugeIDs: limits.map(\.id))
        let projection = MenuBarQuotaProjection(selection: selection, limits: limits, basis: .used, timeFormat: .h24)
        XCTAssertEqual(projection.gauges.map(\.percentage), [11, 22, 33, 44])
        let image = try XCTUnwrap(
            MenuBarStatusComposer.claudeSnapshot(
                config: config(nil, gauges: MenuBarGaugeSelection(ids: limits.map(\.id))), usage: usage, error: nil,
                hasAuthError: false, hasCredential: true, secondaryColor: .secondaryLabelColor, icon: nil
            ).styleIcon)
        XCTAssertEqual(image.size.height, BatteryGeometry.height)
        XCTAssertGreaterThan(image.size.width, BatteryGeometry.Layout.sideBySide.size.width)
    }

    func testCodexAdditionalModelIsTheThirdGaugeAndDoesNotUseBaseQuota() throws {
        let raw = """
            {"rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000},
            "secondary_window":{"used_percent":34,"limit_window_seconds":604800}},
            "additional_rate_limits":[{"limit_name":"Reserve","metered_feature":"gpt-reserve",
            "rate_limit":{"primary_window":{"used_percent":67,"limit_window_seconds":604800}}}]}
            """
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(raw.utf8))
        let limits = UsageLimitCatalog.codex(usage)
        XCTAssertEqual(limits.count, 3)
        let selection = MenuBarQuotaSelection(gaugeIDs: limits.map(\.id))
        let projection = MenuBarQuotaProjection(selection: selection, limits: limits, basis: .used, timeFormat: .h24)
        XCTAssertEqual(projection.gauges.map(\.percentage), [12, 34, 67])
        let display = ProviderMenuBarDisplayConfig(
            kind: .codex, showIcon: false, style: .batteryBar, percentageDisplay: .none,
            showBatteryPercent: true, resetTimeDisplay: .none, timeFormat: .h24,
            circularDisplayMode: .usage, iconMetric: .fiveHour, basisOverride: .used,
            quotaSelection: selection, gaugeSelection: MenuBarGaugeSelection(ids: selection.gaugeIDs))
        let snapshot = MenuBarStatusComposer.codexSnapshot(
            config: display, usage: usage, error: nil,
            hasAuthError: false, isAuthenticated: true, secondaryColor: .secondaryLabelColor, icon: nil)
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.styleIcon).size.width, BatteryGeometry.Layout.sideBySide.size.width)
        let attachment = XCTAttachment(
            image: MenuBarStatusComposer.singleProviderContent(
                snapshot: snapshot, secondaryColor: .secondaryLabelColor,
                appearance: try XCTUnwrap(NSAppearance(named: .aqua))
            ).image)
        attachment.name = "Codex-three-labeled-gauges"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
