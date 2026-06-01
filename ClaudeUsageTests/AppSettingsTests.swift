import XCTest
@testable import ClaudeUsage

@MainActor
final class AppSettingsTests: XCTestCase {
    func testRefreshIntervalNormalizationClampsInvalidValues() {
        XCTAssertEqual(AppSettings.normalizedRefreshInterval(.nan), 30)
        XCTAssertEqual(AppSettings.normalizedRefreshInterval(0), AppSettings.minimumRefreshInterval)
        XCTAssertEqual(AppSettings.normalizedRefreshInterval(5), AppSettings.minimumRefreshInterval)
        XCTAssertEqual(AppSettings.normalizedRefreshInterval(7200), AppSettings.maximumRefreshInterval)
        XCTAssertEqual(AppSettings.normalizedRefreshInterval(60), 60)
    }

    func testUpdateChecksAreForcedToThirtyMinutes() {
        XCTAssertEqual(UpdateCheckInterval.allCases, [.automatic])
        XCTAssertEqual(UpdateCheckInterval.enforcedTimerInterval, 1800)
        XCTAssertEqual(UpdateCheckInterval.automatic.timerInterval, 1800)
        XCTAssertEqual(UpdateCheckInterval.off.normalizedForAutomaticChecks, .automatic)
        XCTAssertEqual(UpdateCheckInterval.onLaunch.normalizedForAutomaticChecks, .automatic)
        XCTAssertEqual(UpdateCheckInterval.hourly.normalizedForAutomaticChecks, .automatic)
    }

    func testSetPopoverItemsNormalizesDuplicatesAndUnsupportedEntries() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        settings.setPopoverItems(
            [
                PopoverItemConfig(id: "weeklyLimit", visible: false),
                PopoverItemConfig(id: "unknown", visible: true),
                PopoverItemConfig(id: "weeklyLimit", visible: true),
                PopoverItemConfig(id: "currentSession", visible: true),
            ],
            for: .claude
        )

        XCTAssertEqual(
            settings.popoverItems(for: .claude),
            [
                PopoverItemConfig(id: "weeklyLimit", visible: false),
                PopoverItemConfig(id: "currentSession", visible: true),
                PopoverItemConfig(id: "modelUsage", visible: true),
                PopoverItemConfig(id: "overageUsage", visible: true),
            ]
        )
    }

    func testAntigravityModelGroupStaysStructuralWhileModelsAreFilteredSeparately() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        settings.setPopoverItems(
            [
                PopoverItemConfig(id: "antigravityModels", visible: false),
                PopoverItemConfig(id: "antigravityAccount", visible: true),
            ],
            for: .antigravity
        )
        settings.setAntigravityModelVisible(false, modelID: "gemini-3.1-pro-low")
        settings.antigravityMenuBarPrimaryModelID = "claude-sonnet-4.6-thinking"
        settings.antigravityMenuBarSecondaryModelID = "gpt-oss-120b-medium"

        XCTAssertEqual(
            settings.popoverItems(for: .antigravity),
            [
                PopoverItemConfig(id: "antigravityModels", visible: true),
                PopoverItemConfig(id: "antigravityAccount", visible: true),
            ]
        )
        XCTAssertFalse(settings.isAntigravityModelVisible("gemini-3.1-pro-low"))
        XCTAssertEqual(settings.menuBarDisplayConfig(for: .antigravity)?.primaryModelID, "claude-sonnet-4.6-thinking")
        XCTAssertEqual(settings.menuBarDisplayConfig(for: .antigravity)?.secondaryModelID, "gpt-oss-120b-medium")
    }

    func testSetProviderMenuBarVisibleFalseClearsAllVisibleIndicators() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        settings.setProviderMenuBarVisible(false, for: .antigravity)

        guard let config = settings.menuBarDisplayConfig(for: .antigravity) else {
            return XCTFail("Antigravity 메뉴바 설정을 읽지 못했습니다")
        }
        XCTAssertFalse(config.showIcon)
        XCTAssertEqual(config.percentageDisplay, .none)
        XCTAssertEqual(config.resetTimeDisplay, .none)
        XCTAssertEqual(config.style, .none)
        XCTAssertFalse(settings.isProviderVisibleInMenuBar(.antigravity))
    }

    func testSetProviderMenuBarVisibleTrueRestoresMinimalVisiblePreset() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        settings.setProviderMenuBarVisible(false, for: .antigravity)
        settings.setProviderMenuBarVisible(true, for: .antigravity)

        guard let config = settings.menuBarDisplayConfig(for: .antigravity) else {
            return XCTFail("Antigravity 메뉴바 설정을 읽지 못했습니다")
        }
        XCTAssertTrue(config.showIcon)
        XCTAssertEqual(config.percentageDisplay, .fiveHour)
        XCTAssertEqual(config.resetTimeDisplay, .none)
        XCTAssertEqual(config.style, .none)
        XCTAssertTrue(settings.isProviderVisibleInMenuBar(.antigravity))
        XCTAssertEqual(settings.menuBarDisplayPreset(for: .antigravity), .basic)
    }

    func testApplyMenuBarDisplayPresetUsesExistingConfigKeys() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        settings.applyMenuBarDisplayPreset(.battery, for: .codex)

        guard let batteryConfig = settings.menuBarDisplayConfig(for: .codex) else {
            return XCTFail("Codex 메뉴바 설정을 읽지 못했습니다")
        }
        XCTAssertEqual(settings.menuBarDisplayPreset(for: .codex), .battery)
        XCTAssertTrue(batteryConfig.showIcon)
        XCTAssertEqual(batteryConfig.percentageDisplay, .none)
        XCTAssertEqual(batteryConfig.resetTimeDisplay, .none)
        XCTAssertEqual(batteryConfig.style, .batteryBar)
        XCTAssertTrue(batteryConfig.showBatteryPercent)
        XCTAssertEqual(batteryConfig.circularDisplayMode, .remaining)

        settings.applyMenuBarDisplayPreset(.dual, for: .codex)

        guard let dualConfig = settings.menuBarDisplayConfig(for: .codex) else {
            return XCTFail("Codex 메뉴바 설정을 읽지 못했습니다")
        }
        XCTAssertEqual(settings.menuBarDisplayPreset(for: .codex), .dual)
        XCTAssertEqual(dualConfig.percentageDisplay, .dual)
        XCTAssertEqual(dualConfig.style, .none)
    }

    func testCustomMenuBarDisplayPresetIsInferredWithoutNewStorageKey() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        settings.setProviderShowIcon(true, for: .claude)
        settings.setProviderPercentageDisplay(.fiveHour, for: .claude)
        settings.setProviderResetTimeDisplay(.fiveHour, for: .claude)
        settings.setMenuBarStyle(.none, for: .claude)

        XCTAssertEqual(settings.menuBarDisplayPreset(for: .claude), .custom)
    }

    func testLegacyProviderPopoverKeysMigrateToGlobalPinnedAndCompactValues() {
        let suiteName = "ClaudeUsageTests.legacyPopoverMigration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("테스트 UserDefaults suite를 만들지 못했습니다")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "codexPopoverPinned")
        defaults.set(true, forKey: "codexPopoverCompact")

        XCTAssertTrue(AppSettings.normalizedGlobalPopoverPinned(from: defaults))
        XCTAssertTrue(AppSettings.normalizedGlobalPopoverCompact(from: defaults))
    }

    func testGlobalPopoverKeysOverrideLegacyProviderValues() {
        let suiteName = "ClaudeUsageTests.globalPopoverMigration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("테스트 UserDefaults suite를 만들지 못했습니다")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: "popoverPinned")
        defaults.set(false, forKey: "popoverCompact")
        defaults.set(true, forKey: "claudePopoverPinned")
        defaults.set(true, forKey: "codexPopoverCompact")

        XCTAssertFalse(AppSettings.normalizedGlobalPopoverPinned(from: defaults))
        XCTAssertFalse(AppSettings.normalizedGlobalPopoverCompact(from: defaults))
    }

    func testLegacyWindowedAccountPopoverDefaultMigratesToHidden() throws {
        let suiteName = "ClaudeUsageTests.windowedAccountMigration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("테스트 UserDefaults suite를 만들지 못했습니다")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let oldAntigravityDefaults = [
            PopoverItemConfig(id: "antigravityPrimary", visible: true),
            PopoverItemConfig(id: "antigravitySecondary", visible: true),
            PopoverItemConfig(id: "antigravityTertiary", visible: true),
            PopoverItemConfig(id: "antigravityAccount", visible: true),
        ]
        let dict = [
            "antigravity": oldAntigravityDefaults,
        ]
        let data = try JSONEncoder().encode(dict)
        defaults.set(data, forKey: "popoverItemsV2")
        defaults.set(2, forKey: "popoverItemsMigrationVersion")

        let loaded = AppSettings.loadPopoverItemsByProvider(from: defaults)

        XCTAssertEqual(
            loaded.full["antigravity"]?.first(where: { $0.id == "antigravityAccount" })?.visible,
            false
        )
    }

    func testProviderStateCatalogSkipsLegacyUnknownProviders() throws {
        let json = """
        {
          "states": {
            "claude": { "isEnabled": true, "isActive": true },
            "gemini": { "isEnabled": true, "isActive": false },
            "antigravity": { "isEnabled": true, "isActive": false }
          }
        }
        """

        let catalog = try JSONDecoder().decode(AppProviderStateCatalog.self, from: Data(json.utf8))

        XCTAssertTrue(catalog[.claude].isEnabled)
        XCTAssertTrue(catalog[.antigravity].isEnabled)
        XCTAssertEqual(catalog.states.keys.sorted { $0.rawValue < $1.rawValue }, [.antigravity, .claude, .codex])
    }

    func testAdditionalRuntimeProvidersMigrationDefaultsToClaudeOnly() {
        let suiteName = "ClaudeUsageTests.additionalProvidersDefault.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("테스트 UserDefaults suite를 만들지 못했습니다")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let inferred = AppSettings.inferredAdditionalRuntimeProvidersEnabled(
            from: defaults,
            decodedProviderStates: nil,
            legacyCodexEnabled: false,
            activeService: "claude"
        )

        XCTAssertFalse(inferred)
    }

    func testAdditionalRuntimeProvidersMigrationDetectsExistingProviderUse() {
        let suiteName = "ClaudeUsageTests.additionalProvidersExisting.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("테스트 UserDefaults suite를 만들지 못했습니다")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var catalog = AppProviderStateCatalog.defaultCatalog
        catalog.setEnabled(true, for: .antigravity)

        XCTAssertTrue(AppSettings.inferredAdditionalRuntimeProvidersEnabled(
            from: defaults,
            decodedProviderStates: catalog,
            legacyCodexEnabled: false,
            activeService: "claude"
        ))

        XCTAssertTrue(AppSettings.inferredAdditionalRuntimeProvidersEnabled(
            from: defaults,
            decodedProviderStates: nil,
            legacyCodexEnabled: true,
            activeService: "claude"
        ))

        XCTAssertTrue(AppSettings.inferredAdditionalRuntimeProvidersEnabled(
            from: defaults,
            decodedProviderStates: nil,
            legacyCodexEnabled: false,
            activeService: "antigravity"
        ))
    }

    func testAdditionalRuntimeProvidersExplicitSettingWinsMigrationInference() {
        let suiteName = "ClaudeUsageTests.additionalProvidersExplicit.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("테스트 UserDefaults suite를 만들지 못했습니다")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: "additionalRuntimeProvidersEnabled")
        var catalog = AppProviderStateCatalog.defaultCatalog
        catalog.setEnabled(true, for: .codex)

        let inferred = AppSettings.inferredAdditionalRuntimeProvidersEnabled(
            from: defaults,
            decodedProviderStates: catalog,
            legacyCodexEnabled: true,
            activeService: "codex"
        )

        XCTAssertFalse(inferred)
    }

    func testAdditionalRuntimeProvidersGateFiltersProvidersWithoutDroppingState() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        settings.setProviderEnabled(true, for: .claude)
        settings.additionalRuntimeProvidersEnabled = true
        settings.setProviderEnabled(true, for: .codex)
        settings.setProviderEnabled(true, for: .antigravity)

        XCTAssertEqual(settings.runtimeEnabledProviderKinds, [.claude, .codex, .antigravity])
        XCTAssertEqual(settings.providerSelectionState.exposedRuntimeKinds, [.claude, .codex, .antigravity])
        XCTAssertEqual(ServiceSelectionHelper.exposedServices(settings: settings), [.claude, .codex, .antigravity])

        settings.additionalRuntimeProvidersEnabled = false

        XCTAssertEqual(settings.runtimeEnabledProviderKinds, [.claude])
        XCTAssertEqual(settings.providerSelectionState.exposedRuntimeKinds, [.claude])
        XCTAssertEqual(ServiceSelectionHelper.exposedServices(settings: settings), [.claude])
        XCTAssertFalse(settings.isProviderEnabled(.codex))
        XCTAssertFalse(settings.isProviderEnabled(.antigravity))
        XCTAssertTrue(settings.providerState(for: .codex).isEnabled)
        XCTAssertTrue(settings.providerState(for: .antigravity).isEnabled)

        settings.additionalRuntimeProvidersEnabled = true

        XCTAssertTrue(settings.isProviderEnabled(.codex))
        XCTAssertTrue(settings.isProviderEnabled(.antigravity))
    }

    func testSettingsSidebarHidesAdditionalProvidersWhenGateIsOff() {
        XCTAssertEqual(
            SettingsProviderRegistry.sidebarPanels(exposurePolicy: .primaryOnly).map(\.panel),
            [.common, .claude]
        )
        XCTAssertEqual(
            SettingsProviderRegistry.sidebarPanels(exposurePolicy: .allSupported).map(\.panel),
            [.common, .claude, .codex, .antigravity]
        )
    }

    func testSetMenuBarStyleBatteryVariantForcesRemainingCircularMode() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        settings.setProviderCircularDisplayMode(.usage, for: .codex)
        settings.setMenuBarStyle(.batteryBar, for: .codex)

        guard let config = settings.menuBarDisplayConfig(for: .codex) else {
            return XCTFail("Codex 메뉴바 설정을 읽지 못했습니다")
        }
        XCTAssertEqual(config.style, .batteryBar)
        XCTAssertEqual(config.circularDisplayMode, .remaining)
    }

    func testEnabledAlertThresholdsConvertRemainingModeBackToUsagePercent() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        settings.notificationPresets = [
            NotificationPreset(id: "a", threshold: 10, isEnabled: true),
            NotificationPreset(id: "b", threshold: 25, isEnabled: true),
            NotificationPreset(id: "c", threshold: 90, isEnabled: true),
            NotificationPreset(id: "d", threshold: 95, isEnabled: false),
        ]
        settings.alertRemainingMode = true

        XCTAssertEqual(settings.enabledAlertThresholds, [10, 75, 90])
    }

    func testAntigravityUsageDataSourcePersistsRawValue() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        settings.antigravityUsageDataSource = .googleOAuth

        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "antigravityUsageDataSource"),
            AntigravityUsageDataSource.googleOAuth.rawValue
        )
    }
}
