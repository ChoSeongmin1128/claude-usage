import XCTest
@testable import ClaudeUsage

@MainActor
final class UsageDisplayPreferencesTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "UsageDisplayPreferencesTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    func testNewInstallUsesRemainingAcrossTextGaugeAndNotifications() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults, hasExistingAccountStorage: false)
            XCTAssertEqual(settings.usageDisplayMode, .remaining)
            XCTAssertEqual(settings.notificationValueBasis, .remaining)
            for service in [PopoverService.claude, .codex] {
                for style in MenuBarStyle.allCases {
                    settings.setMenuBarStyle(style, for: service.providerKind)
                    let config = try XCTUnwrap(settings.menuBarDisplayConfig(for: service.providerKind))
                    XCTAssertEqual(config.usageValueBasis, .remaining)
                    XCTAssertEqual(config.usageValueBasis.text(fromUsed: 80), "20%")
                }
            }
            XCTAssertEqual(AppSettings(defaults: defaults).usageDisplayMode, .remaining)
        }
    }

    func testUpgradePreservesMixedLegacyChoicesUntilCommonBasisIsExplicitlySelected() {
        withDefaults { defaults in
            defaults.set("battery_bar", forKey: "menuBarStyle")
            defaults.set("remaining", forKey: "circularDisplayMode")
            defaults.set("circular", forKey: "codexMenuBarStyle")
            defaults.set("usage", forKey: "codexCircularDisplayMode")
            let settings = AppSettings(defaults: defaults)
            XCTAssertEqual(settings.usageDisplayMode, .legacy)
            XCTAssertEqual(settings.usageValueBasis(for: .claude), .remaining)
            XCTAssertEqual(settings.usageValueBasis(for: .codex), .used)
            XCTAssertEqual(settings.notificationValueBasis, .used)
            settings.usageDisplayMode = .remaining
            XCTAssertEqual(settings.usageValueBasis(for: .codex), .remaining)
            XCTAssertEqual(settings.notificationValueBasis, .remaining)
            settings.usageDisplayMode = .used
            XCTAssertEqual(settings.usageValueBasis(for: .claude), .used)
            XCTAssertEqual(settings.notificationValueBasis, .used)
        }
    }

    func testCanonicalImportPreservesIdentityEnabledFlagsAndLegacyEffectiveThresholdsOnReload() throws {
        for remaining in [false, true] {
            try withDefaults { defaults in
                let legacy = [
                    NotificationPreset(id: "early", threshold: remaining ? 35 : 65),
                    NotificationPreset(id: "middle", threshold: remaining ? 15 : 85, isEnabled: false),
                    NotificationPreset(id: "late", threshold: remaining ? 5 : 95),
                ]
                let data = try JSONEncoder().encode(legacy)
                defaults.set(data, forKey: "notificationPresets")
                defaults.set(remaining, forKey: "alertRemainingMode")
                let settings = AppSettings(defaults: defaults)
                XCTAssertEqual(settings.enabledAlertThresholds, [65, 95])
                XCTAssertEqual(settings.notificationPresets.map(\.id), ["early", "middle", "late"])
                XCTAssertEqual(settings.notificationPresets.map(\.isEnabled), [true, false, true])
                let canonical = settings.notificationPresets
                for mode in [UsageDisplayMode.remaining, .used, .remaining] {
                    settings.usageDisplayMode = mode
                    XCTAssertEqual(settings.notificationPresets, canonical)
                    XCTAssertEqual(settings.enabledAlertThresholds, [65, 95])
                    XCTAssertEqual(
                        settings.sortedNotificationPresets.map(settings.displayedNotificationThreshold),
                        mode == .remaining ? [35, 15, 5] : [65, 85, 95])
                    XCTAssertEqual(AppSettings(defaults: defaults).notificationPresets, canonical)
                }
                XCTAssertEqual(defaults.data(forKey: "notificationPresets"), data)
            }
        }
    }

    func testEmptyAndDisabledCanonicalRulesStayEmptyOrDisabled() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.notificationPresets = []
            XCTAssertEqual(AppSettings(defaults: defaults).notificationPresets, [])
            settings.notificationPresets = [.init(id: "off", threshold: 75, isEnabled: false)]
            let loaded = AppSettings(defaults: defaults)
            XCTAssertEqual(loaded.enabledAlertThresholds, [])
            XCTAssertEqual(loaded.notificationPresets.first?.id, "off")
        }
    }

    func testEditingRemainingThresholdChangesOnlyTheChosenCanonicalRule() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.notificationPresets = [.init(id: "full", threshold: 100), .init(id: "other", threshold: 90)]
            XCTAssertEqual(settings.displayedNotificationThreshold(settings.notificationPresets[0]), 0)
            settings.setDisplayedNotificationThreshold(25, id: "full")
            XCTAssertEqual(settings.notificationPresets.map(\.threshold), [75, 90])
            settings.setDisplayedNotificationThreshold(-20, id: "full")
            XCTAssertEqual(settings.notificationPresets[0].threshold, 100)
            settings.setDisplayedNotificationThreshold(120, id: "full")
            XCTAssertEqual(settings.notificationPresets[0].threshold, 1)
            XCTAssertEqual(settings.notificationPresets[1].threshold, 90)
            // A field finishing its edit after navigation keeps the basis it showed.
            settings.usageDisplayMode = .used
            settings.setDisplayedNotificationThreshold(35, id: "full", basis: .remaining)
            XCTAssertEqual(settings.notificationPresets[0].threshold, 65)
        }
    }

    func testLegacyNumberedRulesImportToTheSameEffectiveThresholds() {
        withDefaults { defaults in
            defaults.set(35, forKey: "alert1Threshold")
            defaults.set(15, forKey: "alert2Threshold")
            defaults.set(5, forKey: "alert3Threshold")
            defaults.set(true, forKey: "alertRemainingMode")
            let settings = AppSettings(defaults: defaults)
            XCTAssertEqual(settings.usageDisplayMode, .legacy)
            XCTAssertEqual(settings.enabledAlertThresholds, [65, 85, 95])
        }
    }
}
