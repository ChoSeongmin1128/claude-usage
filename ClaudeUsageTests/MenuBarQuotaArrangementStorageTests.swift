import Combine
import Foundation
import XCTest
@testable import ClaudeUsage

@MainActor
final class MenuBarQuotaArrangementStorageTests: XCTestCase {
    private var selection: MenuBarQuotaSelection {
        MenuBarQuotaSelection(
            percentageIDs: ["weekly"], resetIDs: ["session"], gaugeIDs: ["session", "weekly", "fable"],
            titles: ["session": "5시간", "weekly": "주간", "fable": "Fable"],
            arrangement: MenuBarQuotaArrangement(
                orderedIDs: ["fable", "weekly", "session"], gaugeGroups: [["fable"], ["weekly", "session"]],
                gaugeLayout: .concentric))
    }

    func testLegacySelectionDecodePreservesArraysWithoutCreatingArrangement() throws {
        let data = Data(
            #"{"percentageIDs":["weekly"],"resetIDs":["session"],"gaugeIDs":["session","weekly"],"titles":{"weekly":"주간"}}"#
                .utf8)
        let decoded = try JSONDecoder().decode(MenuBarQuotaSelection.self, from: data)
        XCTAssertEqual(decoded.percentageIDs, ["weekly"])
        XCTAssertEqual(decoded.resetIDs, ["session"])
        XCTAssertEqual(decoded.gaugeIDs, ["session", "weekly"])
        XCTAssertEqual(decoded.titles, ["weekly": "주간"])
        XCTAssertNil(decoded.arrangement)
        XCTAssertNil(decoded.legacyPercentageDisplay)
        XCTAssertNil(decoded.legacyResetTimeDisplay)
    }

    func testMalformedOptionalArrangementDoesNotEraseOtherProviderSelections() throws {
        let invalid: [Any] = [
            "not-an-object", NSNull(),
            ["orderedIDs": ["session"], "gaugeGroups": [["session"]], "gaugeLayout": "future"],
            ["orderedIDs": ["session", "session"], "gaugeGroups": [["session"]], "gaugeLayout": "concentric"],
            [
                "orderedIDs": ["session", "weekly", "fable"], "gaugeGroups": [["session", "weekly", "fable"]],
                "gaugeLayout": "concentric",
            ],
            ["orderedIDs": ["session"], "gaugeGroups": [["unknown"]], "gaugeLayout": "concentric"],
        ]
        try withDefaults { defaults, _ in
            for value in invalid {
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: JSONEncoder().encode(selection)) as? [String: Any])
                object["arrangement"] = value
                let root: [String: Any] = ["version": 1, "providers": ["claude": object, "codex": object]]
                let data = try JSONSerialization.data(withJSONObject: root)
                defaults.set(data, forKey: MenuBarQuotaPreferences.key)
                let loaded = MenuBarQuotaPreferences.load(from: defaults)
                for provider in ["claude", "codex"] {
                    let decoded = try XCTUnwrap(loaded.providers[provider])
                    XCTAssertEqual(decoded.gaugeIDs, selection.gaugeIDs)
                    XCTAssertEqual(decoded.percentageIDs, selection.percentageIDs)
                    XCTAssertEqual(decoded.resetIDs, selection.resetIDs)
                    XCTAssertEqual(decoded.titles, selection.titles)
                    XCTAssertNil(decoded.arrangement)
                }
                XCTAssertEqual(defaults.data(forKey: MenuBarQuotaPreferences.key), data)
            }
        }
    }

    func testValidArrangementRoundTripsAndLegacyReaderCanStillReadSurfaces() throws {
        let data = try JSONEncoder().encode(selection)
        XCTAssertEqual(try JSONDecoder().decode(MenuBarQuotaSelection.self, from: data), selection)
        let legacy = try JSONDecoder().decode(LegacySelection.self, from: data)
        XCTAssertEqual(legacy.gaugeIDs, selection.gaugeIDs)
        XCTAssertEqual(legacy.percentageIDs, selection.percentageIDs)
        XCTAssertEqual(legacy.resetIDs, selection.resetIDs)
        XCTAssertEqual(legacy.titles, selection.titles)
    }

    func testOpeningAndResolvingLegacyPreferencesDoesNotRewriteTheirBytes() throws {
        try withDefaults { defaults, _ in
            var legacy = selection
            legacy.arrangement = nil
            let preferences = MenuBarQuotaPreferences(providers: ["claude": legacy])
            let data = try JSONEncoder().encode(preferences)
            defaults.set(data, forKey: MenuBarQuotaPreferences.key)
            let settings = makeSettings(defaults)
            let config = try XCTUnwrap(settings.menuBarDisplayConfig(for: .claude))
            let resolved = config.resolvedQuotaSelection(limits: [])
            XCTAssertNil(resolved.arrangement)
            XCTAssertEqual(defaults.data(forKey: MenuBarQuotaPreferences.key), data)
        }
    }

    func testExplicitSelectionSavesQuotaAndGaugeMirrorsInOnePublication() throws {
        try withDefaults { defaults, _ in
            let settings = makeSettings(defaults)
            settings.setMenuBarGaugeSelection(MenuBarGaugeSelection(ids: ["old"], showsLabels: true), for: .claude)
            var publications: [MenuBarQuotaPreferences] = []
            let observation = settings.$menuBarQuotaPreferences.dropFirst().sink { publications.append($0) }
            defer { observation.cancel() }
            settings.setMenuBarQuotaSelection(selection, for: .claude)
            settings.setMenuBarQuotaSelection(selection, for: .claude)
            XCTAssertEqual(publications.count, 1)
            let published = try XCTUnwrap(publications.first)
            XCTAssertEqual(published.providers["claude"]?.arrangement, selection.arrangement)
            XCTAssertEqual(published.providers["claude"]?.percentageIDs, selection.percentageIDs)
            XCTAssertEqual(published.providers["claude"]?.resetIDs, selection.resetIDs)
            XCTAssertEqual(published.providers["claude"]?.gaugeIDs, ["fable", "weekly", "session"])
            XCTAssertEqual(published.gauges?["claude"]?.ids, ["fable", "weekly", "session"])
            XCTAssertEqual(published.gauges?["claude"]?.layout, .concentric)
            XCTAssertEqual(published.gauges?["claude"]?.showsLabels, true)
            XCTAssertEqual(MenuBarQuotaPreferences.load(from: defaults), published)
            XCTAssertEqual(published.version, 1)
        }
    }

    func testLegacyGaugeEditReconcilesArrangementWithoutChangingNumberOrResetSelections() throws {
        try withDefaults { defaults, _ in
            let settings = makeSettings(defaults)
            settings.setMenuBarQuotaSelection(selection, for: .claude)
            settings.setMenuBarGaugeSelection(
                MenuBarGaugeSelection(ids: ["session", "new"], titles: ["new": "새 한도"], layout: .horizontal),
                for: .claude)
            let updated = try XCTUnwrap(settings.menuBarQuotaPreferences.providers["claude"])
            XCTAssertEqual(updated.percentageIDs, selection.percentageIDs)
            XCTAssertEqual(updated.resetIDs, selection.resetIDs)
            XCTAssertEqual(updated.gaugeIDs, ["session", "new"])
            XCTAssertEqual(updated.titles["new"], "새 한도")
            XCTAssertEqual(updated.arrangement?.gaugeLayout, .horizontal)
            XCTAssertEqual(Set(updated.arrangement?.orderedIDs ?? []), updated.selectedIDs)
            XCTAssertEqual(Set(updated.arrangement?.gaugeGroups.flatMap { $0 } ?? []), Set(updated.gaugeIDs))
        }
    }

    func testOldAppGaugeMirrorChangesWinOverStaleArrangementWithoutReadTimeWrite() throws {
        try withDefaults { defaults, _ in
            let preferences = MenuBarQuotaPreferences(
                providers: ["claude": selection],
                gauges: ["claude": MenuBarGaugeSelection(ids: ["new"], titles: ["new": "새 한도"])])
            let data = try JSONEncoder().encode(preferences)
            defaults.set(data, forKey: MenuBarQuotaPreferences.key)
            let settings = makeSettings(defaults)
            let config = try XCTUnwrap(settings.menuBarDisplayConfig(for: .claude))
            let resolved = config.resolvedQuotaSelection(limits: [])
            XCTAssertEqual(resolved.gaugeIDs, ["new"])
            XCTAssertEqual(Set(resolved.arrangement?.gaugeGroups.flatMap { $0 } ?? []), Set(["new"]))
            XCTAssertEqual(defaults.data(forKey: MenuBarQuotaPreferences.key), data)
        }
    }

    func testPresetResetAndSnapshotHaveNoStaleArrangement() throws {
        try withDefaults { defaults, _ in
            let settings = makeSettings(defaults)
            settings.setMenuBarQuotaSelection(selection, for: .claude)
            settings.setMenuBarQuotaSelection(selection, for: .codex)
            let snapshot = settings.createSnapshot()
            settings.applyMenuBarDisplayPreset(.battery, for: .claude)
            XCTAssertNil(settings.menuBarQuotaPreferences.providers["claude"])
            XCTAssertNil(settings.menuBarQuotaPreferences.gauges?["claude"])
            XCTAssertEqual(
                settings.menuBarQuotaPreferences.providers["codex"], snapshot.menuBarQuotaPreferences.providers["codex"]
            )
            settings.restore(from: snapshot)
            XCTAssertEqual(settings.menuBarQuotaPreferences, snapshot.menuBarQuotaPreferences)
            settings.resetToDefaults()
            XCTAssertEqual(settings.menuBarQuotaPreferences, MenuBarQuotaPreferences())
            XCTAssertEqual(MenuBarQuotaPreferences.load(from: defaults), MenuBarQuotaPreferences())
        }
    }

    func testChannelDataResetRemovesArrangementInExistingDefaultsDomain() throws {
        try withDefaults { defaults, suite in
            MenuBarQuotaPreferences(providers: ["claude": selection]).save(to: defaults)
            let reset = AppDataReset(
                bundleIdentifier: suite, directoryName: suite,
                libraryDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                keychainAccounts: { _ in [] }, deleteKeychainItem: { _, _ in }, unregisterLoginItem: {},
                removeNotifications: {},
                removeDefaults: { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) })
            reset.perform(AppDataResetPlan(keepsClaudeCodeTokenCopy: true))
            XCTAssertNil(defaults.data(forKey: MenuBarQuotaPreferences.key))
        }
    }

    func testAntigravityLegacyAndValidArrangementRoundTripKeepSchemaTwo() throws {
        var display = AntigravityDisplaySettings.default
        let legacy = try JSONEncoder().encode(display)
        XCTAssertNil(try JSONDecoder().decode(AntigravityDisplaySettings.self, from: legacy).menuBar.arrangement)
        display.menuBar.arrangement = agyArrangement
        let encoded = try JSONEncoder().encode(display)
        let decoded = try JSONDecoder().decode(AntigravityDisplaySettings.self, from: encoded)
        XCTAssertEqual(decoded, display)
        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertTrue(decoded.isCurrentAndValid)
    }

    func testAntigravityMalformedArrangementIsReadOnlyFallbackAndExplicitSaveWorks() async throws {
        let invalid: [Any] = [
            "not-an-object", ["orderedIDs": ["bad id"], "gaugeGroups": [["bad id"]], "gaugeLayout": "concentric"],
            [
                "orderedIDs": ["gemini.weekly", "gemini.weekly"], "gaugeGroups": [["gemini.weekly"]],
                "gaugeLayout": "horizontal",
            ],
        ]
        for value in invalid {
            var display = AntigravityDisplaySettings.default
            display.menuBar.gaugeLaneIDs = [.geminiWeekly]
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(display)) as? [String: Any])
            var menuBar = try XCTUnwrap(object["menuBar"] as? [String: Any])
            menuBar["arrangement"] = value
            object["menuBar"] = menuBar
            let bytes = try JSONSerialization.data(withJSONObject: object)
            let persistence = ArrangementPersistence()
            persistence.values[AntigravitySettingsMigrationKeys.connectionSettings] = try JSONEncoder().encode(
                AntigravityConnectionSettings.default)
            persistence.values[AntigravitySettingsMigrationKeys.displaySettings] = bytes
            let store = AntigravitySettingsStore(persistence: persistence)
            var loaded = try await store.load().display
            XCTAssertNil(loaded.menuBar.arrangement)
            XCTAssertEqual(loaded.menuBar.gaugeLaneIDs, [.geminiWeekly])
            XCTAssertTrue(loaded.isCurrentAndValid)
            XCTAssertTrue(persistence.writes.isEmpty)
            XCTAssertEqual(persistence.values[AntigravitySettingsMigrationKeys.displaySettings], bytes)
            loaded.menuBar.arrangement = agyArrangement
            let saved = try await store.saveDisplay(loaded)
            XCTAssertEqual(saved.menuBar.arrangement, agyArrangement)
            XCTAssertEqual(persistence.writes, [AntigravitySettingsMigrationKeys.displaySettings])
            let reloaded = try await store.load()
            XCTAssertEqual(reloaded.display, saved)
        }
    }

    func testAntigravityInvalidNewArrangementCannotBeWritten() async throws {
        let persistence = ArrangementPersistence()
        persistence.values[AntigravitySettingsMigrationKeys.connectionSettings] = try JSONEncoder().encode(
            AntigravityConnectionSettings.default)
        persistence.values[AntigravitySettingsMigrationKeys.displaySettings] = try JSONEncoder().encode(
            AntigravityDisplaySettings.default)
        var invalid = AntigravityDisplaySettings.default
        invalid.menuBar.arrangement = MenuBarQuotaArrangement(
            orderedIDs: ["bad id"], gaugeGroups: [["bad id"]], gaugeLayout: .horizontal)
        let store = AntigravitySettingsStore(persistence: persistence)
        do {
            _ = try await store.saveDisplay(invalid)
            XCTFail("Invalid optional arrangement must not be persisted")
        } catch {
            XCTAssertEqual(error as? AntigravitySettingsStoreError, .invalidValue(.display))
        }
        XCTAssertTrue(persistence.writes.isEmpty)
    }

    func testGaugeEditFromPartialUsageRetainsWeeklyTextIntentAcrossReload() throws {
        for provider in [AppProviderKind.claude, .codex] {
            try withDefaults { defaults, _ in
                let settings = makeSettings(defaults)
                settings.setMenuBarStyle(.none, for: provider)
                settings.setProviderPercentageDisplay(.weekly, for: provider)
                settings.setProviderResetTimeDisplay(.weekly, for: provider)
                settings.setProviderShowIcon(false, for: provider)
                let partial = try quotaFixture(provider: provider, includesWeekly: false)
                let config = try XCTUnwrap(settings.menuBarDisplayConfig(for: provider))
                var edited = config.resolvedQuotaSelection(limits: partial.limits, codexUsage: partial.codex)
                XCTAssertEqual(edited.legacyPercentageDisplay, .weekly)
                XCTAssertEqual(edited.legacyResetTimeDisplay, .weekly)
                XCTAssertTrue(edited.percentageIDs.isEmpty)
                XCTAssertTrue(edited.resetIDs.isEmpty)
                let primary = try XCTUnwrap(partial.limits.first)
                edited.gaugeIDs = [primary.id]
                edited.arrangement = .baseline(selection: edited, layout: .horizontal)
                settings.setMenuBarQuotaSelection(edited, for: provider)
                XCTAssertTrue(settings.isProviderVisibleInMenuBar(provider))
                settings.setMenuBarStyle(.batteryBar, for: provider)
                let reloaded = makeSettings(defaults)
                let loaded = try XCTUnwrap(reloaded.menuBarDisplayConfig(for: provider))
                let complete = try quotaFixture(provider: provider, includesWeekly: true)
                let weekly = try XCTUnwrap(complete.limits.first { $0.periodSeconds == 604_800 })
                let resolved = loaded.resolvedQuotaSelection(limits: complete.limits, codexUsage: complete.codex)
                XCTAssertEqual(resolved.percentageIDs, [weekly.id])
                XCTAssertEqual(resolved.resetIDs, [weekly.id])
                XCTAssertEqual(resolved.gaugeIDs, [primary.id])
                XCTAssertEqual(resolved.legacyPercentageDisplay, .weekly)
                XCTAssertEqual(resolved.legacyResetTimeDisplay, .weekly)
                XCTAssertEqual(Set(resolved.arrangement?.orderedIDs ?? []), [primary.id, weekly.id])
                let projection = MenuBarQuotaProjection(
                    selection: resolved, limits: complete.limits, basis: .used, timeFormat: .h24)
                XCTAssertEqual(projection.percentageText, "34%")
                XCTAssertNotNil(projection.resetText)
            }
        }
    }

    func testExplicitTextDisableDoesNotReturnWhenMissingWindowArrives() throws {
        for provider in [AppProviderKind.claude, .codex] {
            try withDefaults { defaults, _ in
                let settings = makeSettings(defaults)
                settings.setMenuBarStyle(.none, for: provider)
                settings.setProviderPercentageDisplay(.weekly, for: provider)
                settings.setProviderResetTimeDisplay(.weekly, for: provider)
                let partial = try quotaFixture(provider: provider, includesWeekly: false)
                let config = try XCTUnwrap(settings.menuBarDisplayConfig(for: provider))
                var edited = config.resolvedQuotaSelection(limits: partial.limits, codexUsage: partial.codex)
                let primary = try XCTUnwrap(partial.limits.first)
                edited.gaugeIDs = [primary.id]
                edited =
                    MenuBarQuotaEditorModel(
                        provider: provider,
                        items: partial.limits.map {
                            .init(
                                id: $0.id, title: $0.title, usedPercentage: $0.usedPercentage,
                                canSelect: $0.usedPercentage != nil)
                        },
                        selection: edited,
                        arrangement: edited.arrangement ?? .baseline(selection: edited, layout: .horizontal),
                        shape: .batteryBar
                    )
                    .applying(.setSurface(primary.id, .percentage, false)).selection
                XCTAssertNil(edited.legacyPercentageDisplay)
                XCTAssertEqual(edited.legacyResetTimeDisplay, .weekly)
                settings.setMenuBarQuotaSelection(edited, for: provider)
                let complete = try quotaFixture(provider: provider, includesWeekly: true)
                let loaded = try XCTUnwrap(makeSettings(defaults).menuBarDisplayConfig(for: provider))
                let resolved = loaded.resolvedQuotaSelection(limits: complete.limits, codexUsage: complete.codex)
                XCTAssertTrue(resolved.percentageIDs.isEmpty)
                XCTAssertEqual(resolved.resetIDs.count, 1)
                edited =
                    MenuBarQuotaEditorModel(
                        provider: provider,
                        items: partial.limits.map {
                            .init(
                                id: $0.id, title: $0.title, usedPercentage: $0.usedPercentage,
                                canSelect: $0.usedPercentage != nil)
                        },
                        selection: edited,
                        arrangement: edited.arrangement ?? .baseline(selection: edited, layout: .horizontal),
                        shape: .batteryBar
                    )
                    .applying(.setSurface(primary.id, .reset, false)).selection
                settings.setMenuBarQuotaSelection(edited, for: provider)
                let disabled = try XCTUnwrap(makeSettings(defaults).menuBarDisplayConfig(for: provider))
                    .resolvedQuotaSelection(limits: complete.limits, codexUsage: complete.codex)
                XCTAssertTrue(disabled.percentageIDs.isEmpty)
                XCTAssertTrue(disabled.resetIDs.isEmpty)
                XCTAssertEqual(disabled.gaugeIDs, [primary.id])
            }
        }
    }

    func testLegacyTextPolicyPreservesExplicitMissingIDsWithoutSelectingObservedModels() throws {
        try withDefaults { defaults, _ in
            let settings = makeSettings(defaults)
            let original = MenuBarQuotaSelection(
                percentageIDs: ["saved-missing-model"], resetIDs: ["saved-missing-model"],
                titles: ["saved-missing-model": "이전 모델"], legacyPercentageDisplay: .weekly,
                legacyResetTimeDisplay: .weekly)
            settings.setMenuBarQuotaSelection(original, for: .claude)
            let usage = ClaudeUsageResponse(
                fiveHour: .init(utilization: 12, resetsAt: nil),
                sevenDay: .init(utilization: 34, resetsAt: "2030-01-03T04:00:00Z"),
                scopedLimits: [
                    .init(kind: "weekly_scoped", percent: 56, resetsAt: nil, modelID: "fable", modelName: "Fable")
                ])
            let limits = UsageLimitCatalog.claude(usage)
            let weekly = try XCTUnwrap(limits.first { $0.scope == "seven_day" })
            let model = try XCTUnwrap(limits.first(where: \.isModelScoped))
            let config = try XCTUnwrap(makeSettings(defaults).menuBarDisplayConfig(for: .claude))
            let resolved = config.resolvedQuotaSelection(limits: limits)
            XCTAssertEqual(resolved.percentageIDs, ["saved-missing-model", weekly.id])
            XCTAssertEqual(resolved.resetIDs, ["saved-missing-model", weekly.id])
            XCTAssertFalse(resolved.selectedIDs.contains(model.id))
            XCTAssertTrue(resolved.gaugeIDs.isEmpty)
            XCTAssertEqual(resolved.titles["saved-missing-model"], "이전 모델")
            XCTAssertEqual(MenuBarQuotaPreferences.load(from: defaults).providers["claude"], original)
        }
    }

    func testLegacyTextPoliciesDecodeIndependentlyAndDoNotInvalidateExistingV1Selection() throws {
        let invalid: [Any] = [NSNull(), "future-policy", 12, ["mode": "weekly"]]
        for value in invalid {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(selection)) as? [String: Any])
            object["legacyPercentageDisplay"] = value
            object["legacyResetTimeDisplay"] = ResetTimeDisplay.weekly.rawValue
            let decoded = try JSONDecoder().decode(
                MenuBarQuotaSelection.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertNil(decoded.legacyPercentageDisplay)
            XCTAssertEqual(decoded.legacyResetTimeDisplay, .weekly)
            XCTAssertEqual(decoded.percentageIDs, selection.percentageIDs)
            XCTAssertEqual(decoded.resetIDs, selection.resetIDs)
            XCTAssertEqual(decoded.arrangement, selection.arrangement)
            object["legacyPercentageDisplay"] = PercentageDisplay.dual.rawValue
            object["legacyResetTimeDisplay"] = value
            let reverse = try JSONDecoder().decode(
                MenuBarQuotaSelection.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(reverse.legacyPercentageDisplay, .dual)
            XCTAssertNil(reverse.legacyResetTimeDisplay)
            XCTAssertEqual(reverse.gaugeIDs, selection.gaugeIDs)
        }
        var value = selection
        value.legacyPercentageDisplay = .dual
        value.legacyResetTimeDisplay = .weekly
        XCTAssertEqual(try JSONDecoder().decode(MenuBarQuotaSelection.self, from: JSONEncoder().encode(value)), value)
    }

    func testLegacyFallbackBaseTextIsReplacedWhenRealSessionArrives() throws {
        for provider in [AppProviderKind.claude, .codex] {
            try withDefaults { defaults, _ in
                let settings = makeSettings(defaults)
                settings.setMenuBarStyle(.batteryBar, for: provider)
                settings.setProviderPercentageDisplay(.fiveHour, for: provider)
                settings.setProviderResetTimeDisplay(.fiveHour, for: provider)
                let weeklyOnly = try basicWindowsFixture(
                    provider: provider, includesSession: false, includesWeekly: true)
                let config = try XCTUnwrap(settings.menuBarDisplayConfig(for: provider))
                var edited = config.resolvedQuotaSelection(limits: weeklyOnly.limits, codexUsage: weeklyOnly.codex)
                let weekly = try XCTUnwrap(weeklyOnly.limits.first)
                XCTAssertEqual(edited.percentageIDs, [weekly.id])
                XCTAssertEqual(edited.resetIDs, provider == .codex ? [weekly.id] : [])
                edited.percentageIDs.append("saved-missing-model")
                edited.resetIDs.append("saved-missing-model")
                edited.titles["saved-missing-model"] = "이전 모델"
                edited.arrangement = .baseline(selection: edited, layout: .horizontal)
                settings.setMenuBarQuotaSelection(edited, for: provider)
                let storedBytes = defaults.data(forKey: MenuBarQuotaPreferences.key)
                let loaded = try XCTUnwrap(makeSettings(defaults).menuBarDisplayConfig(for: provider))
                let complete = try basicWindowsFixture(provider: provider, includesSession: true, includesWeekly: true)
                let primary = try XCTUnwrap(complete.limits.first { $0.periodSeconds == 18000 })
                let resolved = loaded.resolvedQuotaSelection(limits: complete.limits, codexUsage: complete.codex)
                XCTAssertEqual(resolved.percentageIDs, [primary.id, "saved-missing-model"])
                XCTAssertEqual(Set(resolved.resetIDs), [primary.id, "saved-missing-model"])
                XCTAssertFalse(resolved.percentageIDs.contains(weekly.id))
                XCTAssertFalse(resolved.resetIDs.contains(weekly.id))
                XCTAssertEqual(resolved.gaugeIDs, [weekly.id], "The explicit gauge selection stays independent")
                XCTAssertEqual(defaults.data(forKey: MenuBarQuotaPreferences.key), storedBytes)
            }
        }
    }

    func testLegacyDualTextUsesObservedBaseWindowsAndReturnsBothWhenComplete() throws {
        for provider in [AppProviderKind.claude, .codex] {
            try withDefaults { defaults, _ in
                let settings = makeSettings(defaults)
                settings.setProviderPercentageDisplay(.dual, for: provider)
                settings.setProviderResetTimeDisplay(.dual, for: provider)
                let complete = try basicWindowsFixture(provider: provider, includesSession: true, includesWeekly: true)
                let original = try XCTUnwrap(settings.menuBarDisplayConfig(for: provider))
                    .resolvedQuotaSelection(limits: complete.limits, codexUsage: complete.codex)
                XCTAssertEqual(original.percentageIDs.count, 2)
                XCTAssertEqual(original.resetIDs.count, 2)
                settings.setMenuBarQuotaSelection(original, for: provider)
                let config = try XCTUnwrap(makeSettings(defaults).menuBarDisplayConfig(for: provider))
                for hasSession in [true, false] {
                    let partial = try basicWindowsFixture(
                        provider: provider, includesSession: hasSession, includesWeekly: !hasSession)
                    let observed = try XCTUnwrap(partial.limits.first)
                    let resolved = config.resolvedQuotaSelection(limits: partial.limits, codexUsage: partial.codex)
                    XCTAssertEqual(resolved.percentageIDs, [observed.id])
                    XCTAssertEqual(resolved.resetIDs, [observed.id])
                }
                let recovered = config.resolvedQuotaSelection(limits: complete.limits, codexUsage: complete.codex)
                XCTAssertEqual(recovered.percentageIDs, original.percentageIDs)
                XCTAssertEqual(recovered.resetIDs, original.resetIDs)
            }
        }
    }

    func testLegacyPolicyKeepsPreviousBaseIDsUnknownWhenNoBaseWindowIsObserved() throws {
        for provider in [AppProviderKind.claude, .codex] {
            try withDefaults { defaults, _ in
                let settings = makeSettings(defaults)
                settings.setProviderPercentageDisplay(.dual, for: provider)
                settings.setProviderResetTimeDisplay(.dual, for: provider)
                let complete = try basicWindowsFixture(provider: provider, includesSession: true, includesWeekly: true)
                let original = try XCTUnwrap(settings.menuBarDisplayConfig(for: provider))
                    .resolvedQuotaSelection(limits: complete.limits, codexUsage: complete.codex)
                settings.setMenuBarQuotaSelection(original, for: provider)
                let loaded = try XCTUnwrap(makeSettings(defaults).menuBarDisplayConfig(for: provider))
                let absent = try basicWindowsFixture(provider: provider, includesSession: false, includesWeekly: false)
                let resolved = loaded.resolvedQuotaSelection(limits: absent.limits, codexUsage: absent.codex)
                XCTAssertEqual(resolved.percentageIDs, original.percentageIDs)
                XCTAssertEqual(resolved.resetIDs, original.resetIDs)
                let projection = MenuBarQuotaProjection(
                    selection: resolved, limits: absent.limits, basis: .used, timeFormat: .h24)
                XCTAssertTrue(projection.percentageText.contains("데이터 없음"))
                XCTAssertNil(projection.resetText)
            }
        }
    }

    func testBasicIDClassificationRequiresCanonicalNamespaceServiceScopeAndPeriod() throws {
        for provider in [AppProviderKind.claude, .codex] {
            let fixture = try basicWindowsFixture(provider: provider, includesSession: true, includesWeekly: true)
            for limit in fixture.limits {
                XCTAssertTrue(UsageLimitCatalog.isBasicID(limit.id, provider: provider))
                XCTAssertFalse(UsageLimitCatalog.isBasicID(limit.id, provider: provider == .claude ? .codex : .claude))
                XCTAssertFalse(
                    UsageLimitCatalog.isBasicID(limit.id.replacingOccurrences(of: "%2D", with: "-"), provider: provider)
                )
                XCTAssertFalse(UsageLimitCatalog.isBasicID(limit.id + "/extra", provider: provider))
            }
        }
        let unknownCodex = try JSONDecoder().decode(
            CodexUsageResponse.self, from: Data(#"{"rate_limit":{"primary_window":{"used_percent":12}}}"#.utf8))
        XCTAssertTrue(
            UsageLimitCatalog.isBasicID(try XCTUnwrap(UsageLimitCatalog.codex(unknownCodex).first).id, provider: .codex)
        )
        let model = ClaudeUsageResponse(
            fiveHour: nil, sevenDay: nil,
            scopedLimits: [
                .init(kind: "weekly_scoped", percent: 34, resetsAt: nil, modelID: "fable", modelName: "Fable")
            ])
        XCTAssertFalse(
            UsageLimitCatalog.isBasicID(try XCTUnwrap(UsageLimitCatalog.claude(model).first).id, provider: .claude))
        for id in [
            "quota%2Dv2/claude/five%5Fhour/18000", "quota%2Dv1/claude/five%5Fhour/604800",
            "quota%2Dv1/codex/general/0", "quota%2Dv1/codex/general/018000", "quota%2Dv1/codex/general/future",
            "quota%2Dv1/claude/model%3Afable/604800", "quota%2Dv1/codex/model%3Aspark/18000", "saved-missing-model",
        ] {
            XCTAssertFalse(UsageLimitCatalog.isBasicID(id, provider: .claude))
            XCTAssertFalse(UsageLimitCatalog.isBasicID(id, provider: .codex))
        }
    }

    func testDirectStyleChangesAdaptOverlapAndPreserveQuotaMembershipAndText() throws {
        for provider in [AppProviderKind.claude, .codex] {
            try withDefaults { defaults, _ in
                let settings = makeSettings(defaults)
                settings.setMenuBarQuotaSelection(selection, for: provider)
                settings.setMenuBarStyle(.dualBattery, for: provider)
                let before = try XCTUnwrap(settings.menuBarQuotaPreferences.providers[provider.rawValue])
                XCTAssertEqual(before.arrangement?.gaugeLayout, .stacked)
                for (style, layout) in [
                    (MenuBarStyle.circular, MenuBarGaugeLayout.concentric), (.batteryBar, .stacked),
                ] {
                    settings.setMenuBarStyle(style, for: provider)
                    let reloaded = makeSettings(defaults)
                    let config = try XCTUnwrap(reloaded.menuBarDisplayConfig(for: provider))
                    let after = try XCTUnwrap(config.quotaSelection)
                    XCTAssertEqual(config.style, style)
                    XCTAssertEqual(after.arrangement?.gaugeLayout, layout)
                    XCTAssertEqual(config.gaugeSelection?.layout, layout)
                    XCTAssertEqual(after.arrangement?.gaugeGroups, before.arrangement?.gaugeGroups)
                    XCTAssertEqual(after.gaugeIDs, before.gaugeIDs)
                    XCTAssertEqual(after.percentageIDs, before.percentageIDs)
                    XCTAssertEqual(after.resetIDs, before.resetIDs)
                }
            }
        }
    }

    func testDirectNoneStyleRemovesOnlyGaugesAndMirrorsWhileKeepingTextPolicies() throws {
        for provider in [AppProviderKind.claude, .codex] {
            try withDefaults { defaults, _ in
                let settings = makeSettings(defaults)
                var selected = selection
                selected.legacyPercentageDisplay = .weekly
                selected.legacyResetTimeDisplay = .fiveHour
                settings.setMenuBarQuotaSelection(selected, for: provider)
                settings.setMenuBarStyle(.concentricRings, for: provider)
                let before = try XCTUnwrap(settings.menuBarQuotaPreferences.providers[provider.rawValue])
                var publications: [MenuBarQuotaPreferences] = []
                let observation = settings.$menuBarQuotaPreferences.dropFirst().sink { publications.append($0) }
                defer { observation.cancel() }
                settings.setMenuBarStyle(.none, for: provider)
                settings.setMenuBarStyle(.none, for: provider)
                XCTAssertEqual(publications.count, 1)
                let config = try XCTUnwrap(makeSettings(defaults).menuBarDisplayConfig(for: provider))
                let after = try XCTUnwrap(config.quotaSelection)
                XCTAssertEqual(config.style, .none)
                XCTAssertTrue(after.gaugeIDs.isEmpty)
                XCTAssertEqual(config.gaugeSelection?.ids, [])
                XCTAssertEqual(after.arrangement?.gaugeGroups, [])
                XCTAssertEqual(Set(after.arrangement?.orderedIDs ?? []), Set(before.percentageIDs + before.resetIDs))
                XCTAssertEqual(after.percentageIDs, before.percentageIDs)
                XCTAssertEqual(after.resetIDs, before.resetIDs)
                XCTAssertEqual(after.legacyPercentageDisplay, before.legacyPercentageDisplay)
                XCTAssertEqual(after.legacyResetTimeDisplay, before.legacyResetTimeDisplay)
            }
        }
    }

    func testDirectExplicitStylesChooseLayoutWhileLegacySelectionIsNotRewritten() throws {
        for provider in [AppProviderKind.claude, .codex] {
            try withDefaults { defaults, _ in
                let settings = makeSettings(defaults)
                settings.setMenuBarQuotaSelection(selection, for: provider)
                for (style, layout) in [
                    (MenuBarStyle.sideBySideBattery, MenuBarGaugeLayout.horizontal),
                    (.concentricRings, .concentric), (.dualBattery, .stacked),
                ] {
                    settings.setMenuBarStyle(style, for: provider)
                    let config = try XCTUnwrap(makeSettings(defaults).menuBarDisplayConfig(for: provider))
                    XCTAssertEqual(config.quotaSelection?.arrangement?.gaugeLayout, layout)
                    XCTAssertEqual(config.gaugeSelection?.layout, layout)
                    XCTAssertEqual(Set(config.quotaSelection?.gaugeIDs ?? []), Set(selection.gaugeIDs))
                }
                var legacy = selection
                legacy.arrangement = nil
                settings.setMenuBarQuotaSelection(legacy, for: provider)
                let originalBytes = defaults.data(forKey: MenuBarQuotaPreferences.key)
                settings.setMenuBarStyle(.none, for: provider)
                XCTAssertEqual(defaults.data(forKey: MenuBarQuotaPreferences.key), originalBytes)
                XCTAssertEqual(settings.menuBarQuotaPreferences.providers[provider.rawValue], legacy)
                XCTAssertEqual(settings.menuBarQuotaPreferences.gauges?[provider.rawValue]?.ids, legacy.gaugeIDs)
            }
        }
    }

    private func basicWindowsFixture(provider: AppProviderKind, includesSession: Bool, includesWeekly: Bool) throws -> (
        limits: [UsageLimit], codex: CodexUsageResponse?
    ) {
        if provider == .claude {
            let usage = ClaudeUsageResponse(
                fiveHour: includesSession ? .init(utilization: 12, resetsAt: "2030-01-01T01:00:00Z") : nil,
                sevenDay: includesWeekly ? .init(utilization: 34, resetsAt: "2030-01-03T04:00:00Z") : nil)
            return (UsageLimitCatalog.claude(usage), nil)
        }
        var rate: [String: Any] = [:]
        if includesSession {
            rate["primary_window"] = ["used_percent": 12, "limit_window_seconds": 18000, "reset_at": 1893492000]
        }
        if includesWeekly {
            rate["secondary_window"] = ["used_percent": 34, "limit_window_seconds": 604800, "reset_at": 1893628800]
        }
        let usage = try JSONDecoder().decode(
            CodexUsageResponse.self, from: JSONSerialization.data(withJSONObject: ["rate_limit": rate]))
        return (UsageLimitCatalog.codex(usage), usage)
    }

    private func quotaFixture(provider: AppProviderKind, includesWeekly: Bool) throws -> (
        limits: [UsageLimit], codex: CodexUsageResponse?
    ) {
        if provider == .claude {
            let usage = ClaudeUsageResponse(
                fiveHour: .init(utilization: 12, resetsAt: nil),
                sevenDay: includesWeekly ? .init(utilization: 34, resetsAt: "2030-01-03T04:00:00Z") : nil)
            return (UsageLimitCatalog.claude(usage), nil)
        }
        let primary: [String: Any] = ["used_percent": 12, "limit_window_seconds": 18000]
        var rate: [String: Any] = ["primary_window": primary]
        if includesWeekly {
            rate["secondary_window"] = ["used_percent": 34, "limit_window_seconds": 604800, "reset_at": 1893628800]
        }
        let usage = try JSONDecoder().decode(
            CodexUsageResponse.self, from: JSONSerialization.data(withJSONObject: ["rate_limit": rate]))
        return (UsageLimitCatalog.codex(usage), usage)
    }

    private var agyArrangement: MenuBarQuotaArrangement {
        MenuBarQuotaArrangement(
            orderedIDs: [AntigravityQuotaLaneID.geminiWeekly.rawValue, AntigravityQuotaLaneID.geminiFiveHour.rawValue],
            gaugeGroups: [
                [AntigravityQuotaLaneID.geminiWeekly.rawValue, AntigravityQuotaLaneID.geminiFiveHour.rawValue]
            ],
            gaugeLayout: .concentric)
    }

    private func makeSettings(_ defaults: UserDefaults) -> AppSettings {
        AppSettings(
            defaults: defaults, hasExistingAccountStorage: false,
            launchAtLoginController: LaunchAtLoginController(service: ArrangementLoginItemService()))
    }

    private func withDefaults(_ operation: (UserDefaults, String) throws -> Void) throws {
        let suite = "MenuBarQuotaArrangementStorageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try operation(defaults, suite)
    }
}

nonisolated private struct LegacySelection: Decodable {
    let percentageIDs: [String]
    let resetIDs: [String]
    let gaugeIDs: [String]
    let titles: [String: String]
}

@MainActor
private struct ArrangementLoginItemService: LoginItemManaging {
    var status: LoginItemStatus { .notRegistered }
    func register() throws { XCTFail("Storage fixture must not register login items") }
    func unregister() throws { XCTFail("Storage fixture must not unregister login items") }
    func openSystemSettings() { XCTFail("Storage fixture must not open system settings") }
}

private final class ArrangementPersistence: AntigravitySettingsDataPersisting, @unchecked Sendable {
    var values: [String: Data] = [:]
    var writes: [String] = []
    nonisolated func storedData(forKey key: String) -> AntigravitySettingsStoredData {
        values[key].map(AntigravitySettingsStoredData.data) ?? .missing
    }
    nonisolated func setData(_ data: Data, forKey key: String) throws {
        values[key] = data
        writes.append(key)
    }
}
