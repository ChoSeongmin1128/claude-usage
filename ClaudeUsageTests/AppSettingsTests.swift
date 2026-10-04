import Combine
import XCTest
@testable import ClaudeUsage

@MainActor
final class AppSettingsTests: XCTestCase {
    func testTimeUnitLanguageDefaultsToEnglishForMissingAndUnknownValues() throws {
        let suite = "AppSettingsTests.timeUnits.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(TimeUnitLanguage.load(from: defaults), .english)
        XCTAssertEqual(AppSettings(defaults: defaults).timeUnitLanguage, .english)
        defaults.set("unknown-future-language", forKey: TimeUnitLanguage.storageKey)
        XCTAssertEqual(TimeUnitLanguage.load(from: defaults), .english)
        XCTAssertEqual(AppSettings(defaults: defaults).timeUnitLanguage, .english)
        XCTAssertEqual(TimeUnitLanguage.english.dayUnit, "d")
        XCTAssertEqual(TimeUnitLanguage.english.hourUnit, "h")
        XCTAssertEqual(TimeUnitLanguage.english.minuteUnit, "m")
        XCTAssertEqual(TimeUnitLanguage.korean.dayUnit, "일")
        XCTAssertEqual(TimeUnitLanguage.korean.hourUnit, "시간")
        XCTAssertEqual(TimeUnitLanguage.korean.minuteUnit, "분")
    }

    func testTimeUnitLanguageRoundTripsIndependentlyOfLegacyRemainingClockFormat() throws {
        let suite = "AppSettingsTests.timeUnits.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("remaining_clock", forKey: "timeFormat")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.timeFormat, .remainingClock)

        settings.timeUnitLanguage = .korean
        XCTAssertEqual(defaults.string(forKey: TimeUnitLanguage.storageKey), "ko")
        XCTAssertEqual(defaults.string(forKey: "timeFormat"), "remaining_clock")
        let relaunched = AppSettings(defaults: defaults)
        XCTAssertEqual(relaunched.timeUnitLanguage, .korean)
        XCTAssertEqual(relaunched.timeFormat, .remainingClock)
        relaunched.timeFormat = .remainingTotalClock
        XCTAssertEqual(AppSettings(defaults: defaults).timeUnitLanguage, .korean)
        XCTAssertEqual(defaults.string(forKey: "timeFormat"), "remaining_total_clock")
        relaunched.timeUnitLanguage = .english
        XCTAssertEqual(defaults.string(forKey: TimeUnitLanguage.storageKey), "en")
        XCTAssertEqual(AppSettings(defaults: defaults).timeUnitLanguage, .english)
        XCTAssertEqual(relaunched.timeFormat, .remainingTotalClock)
    }

    func testTimeUnitLanguageSnapshotAndResetKeepProviderConfigsAligned() throws {
        let suite = "AppSettingsTests.timeUnits.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.timeFormat = .remainingClock
        settings.timeUnitLanguage = .korean
        let snapshot = settings.createSnapshot()
        XCTAssertEqual(snapshot.timeUnitLanguage, .korean)
        XCTAssertEqual(settings.timeUnitLanguage, .korean)
        XCTAssertEqual(settings.timeFormat, .remainingClock)
        for kind in [AppProviderKind.claude, .codex] {
            let config = try XCTUnwrap(settings.menuBarDisplayConfig(for: kind))
            XCTAssertEqual(config.timeUnitLanguage, .korean)
            XCTAssertEqual(config.timeFormat, .remainingClock)
        }
        settings.resetToDefaults()
        XCTAssertEqual(settings.timeUnitLanguage, .english)
        XCTAssertEqual(AppSettings(defaults: defaults).timeUnitLanguage, .english)
        XCTAssertEqual(defaults.string(forKey: TimeUnitLanguage.storageKey), "en")
    }

    func testTimeUnitLanguageChangePublishesAndChangesMenuBarConfig() throws {
        let suite = "AppSettingsTests.timeUnits.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let original = try XCTUnwrap(settings.menuBarDisplayConfig(for: .claude))
        var changes = 0
        let subscription = settings.menuBarDisplayChangePublisher.sink { changes += 1 }
        defer { subscription.cancel() }
        let initialChanges = changes

        settings.timeUnitLanguage = .korean

        XCTAssertEqual(changes, initialChanges + 1)
        let updated = try XCTUnwrap(settings.menuBarDisplayConfig(for: .claude))
        XCTAssertNotEqual(updated, original)
        XCTAssertEqual(updated.timeUnitLanguage, .korean)
        XCTAssertEqual(updated.timeFormat, original.timeFormat)
    }

    func testMotionDefaultsPreserveLegacySettingsAndPersistSelection() throws {
        let suite = "AppSettingsTests.motion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "popoverCompact")
        defaults.set(true, forKey: "popoverPinned")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.motion.mode, .instant)
        XCTAssertTrue(settings.popoverCompact)
        XCTAssertTrue(settings.popoverPinned)
        settings.motion.mode = .smooth
        XCTAssertEqual(AppSettings(defaults: defaults).motion.mode, .smooth)
        settings.timeUnitLanguage = .korean
        let snapshot = settings.createSnapshot()
        settings.motion.mode = .instant
        settings.timeUnitLanguage = .english
        settings.restore(from: snapshot)
        XCTAssertEqual(settings.motion.mode, .smooth)
        XCTAssertEqual(settings.timeUnitLanguage, .korean)
        defaults.removeObject(forKey: "motionPreferences")
        defaults.set("unknown-future-value", forKey: "popoverTransitionStyle")
        XCTAssertEqual(AppSettings(defaults: defaults).motion.mode, .instant)
    }

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
                PopoverItemConfig(id: "claudeResetCredits", visible: true),
                PopoverItemConfig(id: "overageUsage", visible: true),
            ]
        )
    }

    func testGenericPopoverDisplaySurfaceRefusesAntigravity() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        settings.setPopoverItems(
            [
                PopoverItemConfig(id: "antigravityUsageLimits", visible: false),
                PopoverItemConfig(id: "antigravityModels", visible: true),
                PopoverItemConfig(id: "antigravityAccount", visible: true),
            ],
            for: .antigravity
        )

        XCTAssertTrue(
            settings.popoverItems(for: .antigravity)
                .isEmpty
        )
        XCTAssertTrue(
            settings.compactPopoverItems(
                for: .antigravity
            )
            .isEmpty
        )
    }

    /// AGY 메뉴바 표시는 `AntigravityDisplaySettings.menuBar`가 단독 소유한다.
    /// generic per-provider 표면으로는 읽지도 쓰지도 못해야 한다. 그렇지 않으면
    /// 아무도 읽지 않는 표시 상태가 다시 생긴다.
    func testGenericMenuBarDisplaySurfaceRefusesAntigravity() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        XCTAssertNil(settings.menuBarDisplayConfig(for: .antigravity))
        XCTAssertNil(settings.menuBarStyle(for: .antigravity))

        settings.setProviderShowIcon(true, for: .antigravity)
        settings.setMenuBarStyle(.batteryBar, for: .antigravity)
        settings.setProviderPercentageDisplay(.dual, for: .antigravity)
        settings.setProviderResetTimeDisplay(.fiveHour, for: .antigravity)
        settings.setProviderTimeFormat(.h12, for: .antigravity)
        settings.setProviderShowBatteryPercent(true, for: .antigravity)
        settings.setProviderCircularDisplayMode(.remaining, for: .antigravity)
        settings.setProviderIconMetric(.weekly, for: .antigravity)
        settings.applyMenuBarDisplayPreset(.battery, for: .antigravity)
        settings.setProviderMenuBarVisible(true, for: .antigravity)

        XCTAssertNil(settings.menuBarDisplayConfig(for: .antigravity))
        XCTAssertEqual(settings.menuBarDisplayPreset(for: .antigravity), .custom)
        XCTAssertFalse(settings.isProviderVisibleInMenuBar(.antigravity))

        // 알림 on/off도 typed 설정이 단독 소유한다.
        settings.setProviderAlertEnabled(true, for: .antigravity)
        XCTAssertFalse(settings.isProviderAlertEnabled(.antigravity))
    }

    /// 위 차단이 다른 provider까지 막지 않는지 함께 고정한다.
    func testGenericMenuBarDisplaySurfaceStillAppliesToOtherProviders() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        settings.setProviderMenuBarVisible(false, for: .codex)
        guard let hidden = settings.menuBarDisplayConfig(for: .codex) else {
            return XCTFail("Codex 메뉴바 설정을 읽지 못했습니다")
        }
        XCTAssertFalse(hidden.showIcon)
        XCTAssertEqual(hidden.percentageDisplay, .none)
        XCTAssertFalse(settings.isProviderVisibleInMenuBar(.codex))

        settings.setProviderMenuBarVisible(true, for: .codex)
        XCTAssertTrue(settings.isProviderVisibleInMenuBar(.codex))
        XCTAssertEqual(settings.menuBarDisplayPreset(for: .codex), .basic)
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

    /// 구 AGY 팝오버 항목은 저장돼 있어도 로드 시점 정규화에서 사라지고
    /// 권위 항목만 남는다.
    func testLegacyAntigravityPopoverItemsDoNotSurviveLoad() throws {
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
            loaded.full["antigravity"]?.map(\.id),
            nil
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

    func testEnabledProvidersAreAllExposed() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        settings.setProviderEnabled(true, for: .claude)
        settings.setProviderEnabled(true, for: .codex)
        settings.setProviderEnabled(true, for: .antigravity)

        XCTAssertEqual(settings.runtimeEnabledProviderKinds, [.claude, .codex, .antigravity])
        XCTAssertEqual(settings.providerSelectionState.exposedRuntimeKinds, [.claude, .codex, .antigravity])
        XCTAssertEqual(ServiceSelectionHelper.exposedServices(settings: settings), [.claude, .codex, .antigravity])
        XCTAssertTrue(settings.isProviderEnabled(.codex))
        XCTAssertTrue(settings.isProviderEnabled(.antigravity))
        XCTAssertTrue(settings.providerState(for: .codex).isEnabled)
        XCTAssertTrue(settings.providerState(for: .antigravity).isEnabled)
    }

    func testSettingsSidebarAlwaysShowsNavigationAndProviders() {
        let expected: [SettingsProviderPanel] = [.common, .accounts, .limits, .display, .updates]
        XCTAssertEqual(
            SettingsProviderRegistry.sidebarPanels(exposurePolicy: .primaryOnly).map(\.panel),
            expected
        )
        XCTAssertEqual(
            SettingsProviderRegistry.sidebarPanels(exposurePolicy: .allSupported).map(\.panel),
            expected
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

    func testEnabledAlertThresholdsAreCanonicalRegardlessOfDisplayMode() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        settings.notificationPresets = [
            NotificationPreset(id: "a", threshold: 10, isEnabled: true),
            NotificationPreset(id: "b", threshold: 25, isEnabled: true),
            NotificationPreset(id: "c", threshold: 90, isEnabled: true),
            NotificationPreset(id: "d", threshold: 95, isEnabled: false),
        ]
        settings.usageDisplayMode = .remaining

        XCTAssertEqual(settings.enabledAlertThresholds, [10, 25, 90])
    }

    /// 구 AGY 키는 초기화 경로에서 지우기만 하고 다시 쓰지 않는다.
    func testResetToDefaultsDoesNotRecreateLegacyAntigravityKeys() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        let legacyKeys = [
            "antigravityUsageDataSource",
            "antigravityHiddenModelIDs",
            "antigravityMenuBarPrimaryModelID",
            "antigravityMenuBarSecondaryModelID",
        ]
        legacyKeys.forEach { UserDefaults.standard.set("stale", forKey: $0) }

        settings.motion.mode = .smooth
        settings.resetToDefaults()
        XCTAssertEqual(settings.motion.mode, .instant)

        for key in legacyKeys {
            XCTAssertNil(UserDefaults.standard.object(forKey: key), key)
        }
    }

    func testResetToDefaultsKeepsServicesAndRestoresDisplayChoices() throws {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: suite)
        settings.setProviderEnabled(true, for: .codex)
        settings.menuBarColorMode = .monochrome
        settings.setResetCreditMenuBarMode(.off, for: .claude)

        settings.resetToDefaults()

        XCTAssertTrue(settings.isProviderEnabled(.codex), "서비스 사용 여부는 기본값 복원 대상이 아닙니다")
        XCTAssertEqual(settings.menuBarColorMode, .always)
        XCTAssertEqual(settings.resetCreditMenuBarMode(for: .claude), .always)
    }

    func testFirstLaunchResetCreditDefaultSurvivesRelaunch() throws {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        let first = AppSettings(defaults: suite)
        let initial = first.resetCreditMenuBarMode(for: .claude)
        let relaunched = AppSettings(defaults: suite)

        XCTAssertEqual(relaunched.resetCreditMenuBarMode(for: .claude), initial)
    }

    // MARK: - Provider legacy mirror

    /// providerStates 변경이 legacy 미러(claudeEnabled/codexEnabled)를 함께
    /// 갱신해야 한다. 마이그레이션 때 한 번만 쓰던 기존 동작은 이후 변경에서
    /// 미러가 어긋난 채 남았다(실측: providerStates codex=true, codexEnabled=false).
    func testProviderStatesChangeKeepsLegacyMirrorsInSync() throws {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: suite)

        settings.setProviderEnabled(true, for: .codex)
        XCTAssertEqual(suite.object(forKey: "codexEnabled") as? Bool, true)

        settings.setProviderEnabled(false, for: .codex)
        XCTAssertEqual(suite.object(forKey: "codexEnabled") as? Bool, false)
        XCTAssertEqual(suite.object(forKey: "claudeEnabled") as? Bool, true)

        // 저장된 catalog 자체도 미러와 같은 값을 봐야 한다.
        let stored = try XCTUnwrap(suite.data(forKey: "providerStates"))
        let catalog = try JSONDecoder().decode(AppProviderStateCatalog.self, from: stored)
        XCTAssertFalse(catalog.state(for: .codex).isEnabled)
        XCTAssertTrue(catalog.state(for: .claude).isEnabled)
    }

    /// 주입된 defaults로 만든 인스턴스는 standard 도메인을 오염시키지 않아야 한다.
    func testInjectedDefaultsDoNotTouchStandardDomain() throws {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        let marker = UserDefaults.standard.data(forKey: "providerStates")
        let settings = AppSettings(defaults: suite)
        settings.setProviderEnabled(true, for: .codex)

        XCTAssertEqual(UserDefaults.standard.data(forKey: "providerStates"), marker)
        XCTAssertNotNil(suite.data(forKey: "providerStates"))
    }
}
