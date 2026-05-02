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
                PopoverItemConfig(id: "activeAccount", visible: true),
                PopoverItemConfig(id: "modelUsage", visible: true),
                PopoverItemConfig(id: "overageUsage", visible: true),
            ]
        )
    }

    func testSetProviderMenuBarVisibleFalseClearsAllVisibleIndicators() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        settings.setProviderMenuBarVisible(false, for: .gemini)

        guard let config = settings.menuBarDisplayConfig(for: .gemini) else {
            return XCTFail("Gemini 메뉴바 설정을 읽지 못했습니다")
        }
        XCTAssertFalse(config.showIcon)
        XCTAssertEqual(config.percentageDisplay, .none)
        XCTAssertEqual(config.resetTimeDisplay, .none)
        XCTAssertEqual(config.style, .none)
        XCTAssertFalse(settings.isProviderVisibleInMenuBar(.gemini))
    }

    func testSetProviderMenuBarVisibleTrueRestoresMinimalVisiblePreset() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        settings.setProviderMenuBarVisible(false, for: .gemini)
        settings.setProviderMenuBarVisible(true, for: .gemini)

        guard let config = settings.menuBarDisplayConfig(for: .gemini) else {
            return XCTFail("Gemini 메뉴바 설정을 읽지 못했습니다")
        }
        XCTAssertTrue(config.showIcon)
        XCTAssertEqual(config.percentageDisplay, .fiveHour)
        XCTAssertEqual(config.resetTimeDisplay, .none)
        XCTAssertEqual(config.style, .none)
        XCTAssertTrue(settings.isProviderVisibleInMenuBar(.gemini))
        XCTAssertEqual(settings.menuBarDisplayPreset(for: .gemini), .basic)
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
        defaults.set(true, forKey: "geminiPopoverCompact")

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
}
