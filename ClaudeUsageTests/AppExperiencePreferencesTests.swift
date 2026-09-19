import XCTest
@testable import ClaudeUsage

@MainActor
final class AppExperiencePreferencesTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "AppExperiencePreferencesTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testNewInstallUsesModernAndResumesPendingWelcomeAfterSettingsNormalization() {
        withDefaults { defaults in
            defaults.set("Dark", forKey: "AppleInterfaceStyle")
            let settings = AppSettings(defaults: defaults)
            XCTAssertEqual(settings.menuBarDesign, .modern)
            XCTAssertEqual(settings.welcomeState, .pending)
            XCTAssertTrue(settings.menuBarDesignIntroductionDismissed)
            settings.welcomeStep = .connection
            let reloaded = AppSettings(defaults: defaults)
            XCTAssertEqual(reloaded.menuBarDesign, .modern)
            XCTAssertEqual(reloaded.welcomeState, .pending)
            XCTAssertEqual(reloaded.welcomeStep, .connection)
        }
    }

    func testDirectUpgradeFromOlderVersionsKeepsClassicAndExistingDisplayChoices() {
        for key in [
            "showPercentage", "claudePopoverPinned", "providerStateMigrationVersion", "ClaudeUsage.claudeAccounts.v1",
        ] {
            withDefaults { defaults in
                defaults.set(false, forKey: key)
                let result = AppExperiencePreferences.load(from: defaults, hasAccountStorage: false)
                XCTAssertEqual(result.design, .classic, key)
                XCTAssertEqual(result.welcomeState, .completed, key)
                XCTAssertFalse(result.designIntroductionDismissed, key)
                XCTAssertNotNil(defaults.object(forKey: key))
            }
        }
    }

    func testAccountMetadataWithoutPreferencesStillCountsAsAnExistingInstall() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults, hasExistingAccountStorage: true)
            XCTAssertEqual(settings.menuBarDesign, .classic)
            XCTAssertEqual(settings.welcomeState, .completed)
        }
    }

    func testExplicitChoiceAndDismissalPersistWithoutChangingUsageSettings() {
        withDefaults { defaults in
            defaults.set("battery_bar", forKey: "menuBarStyle")
            defaults.set("remaining", forKey: "circularDisplayMode")
            defaults.set("monochrome", forKey: "menuBarColorMode")
            let settings = AppSettings(defaults: defaults)
            XCTAssertEqual(settings.menuBarDesign, .classic)
            settings.menuBarDesign = .modern
            let reloaded = AppSettings(defaults: defaults)
            XCTAssertEqual(reloaded.menuBarDesign, .modern)
            XCTAssertTrue(reloaded.menuBarDesignIntroductionDismissed)
            XCTAssertEqual(reloaded.menuBarStyle, .batteryBar)
            XCTAssertEqual(reloaded.circularDisplayMode, .remaining)
            XCTAssertEqual(reloaded.menuBarColorMode, .monochrome)
            reloaded.menuBarDesign = .classic
            XCTAssertEqual(AppSettings(defaults: defaults).menuBarDesign, .classic)
        }
    }

    func testStatusNumberColorModePersistsAsAnExplicitChoice() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.menuBarColorMode = .statusNumber

            XCTAssertEqual(
                AppSettings(defaults: defaults).menuBarColorMode,
                .statusNumber
            )
        }
    }

    func testDismissalAndDeferralDoNotBecomeSuccessfulConnection() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.welcomeState = .deferred
            settings.menuBarDesignIntroductionDismissed = true
            let reloaded = AppSettings(defaults: defaults)
            XCTAssertEqual(reloaded.welcomeState, .deferred)
            XCTAssertTrue(reloaded.menuBarDesignIntroductionDismissed)
            XCTAssertFalse(WelcomeServiceStatus.allVerified([.claude], statuses: [:]))
            XCTAssertFalse(WelcomeServiceStatus.allVerified([], statuses: [:]))
            XCTAssertFalse(WelcomeServiceStatus.allVerified([.claude, .codex], statuses: [.claude: .verified]))
            XCTAssertTrue(WelcomeServiceStatus.allVerified([.codex], statuses: [.codex: .verified]))
        }
    }

    func testConnectionRequiresCurrentSuccessfulNumericUsageNotJustCredentials() {
        func status(value: Double?, error: APIError? = nil, loading: Bool = false) -> WelcomeServiceStatus {
            let payload: RuntimeProviderPayload? = value.map {
                .claude(.init(fiveHour: .init(utilization: $0, resetsAt: nil), sevenDay: nil))
            }
            let snapshot = RuntimeProviderSnapshot(
                service: .claude, payload: payload, error: error, isLoading: loading, lastUpdated: Date(),
                credentialState: .usable, isDetected: true, canAttemptRefresh: true, hasAuthError: false)
            return .resolve(snapshot: snapshot, antigravity: .idle)
        }
        XCTAssertEqual(status(value: nil), .notVerified)
        XCTAssertEqual(status(value: .nan), .notVerified)
        XCTAssertEqual(status(value: 0), .verified)
        XCTAssertEqual(status(value: 50, error: .invalidSessionKey), .notVerified)
        XCTAssertEqual(status(value: 50, loading: true), .checking)
    }

    func testDesignChoiceInvalidatesRenderKeyWithoutChangingUsageMeaning() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.menuBarStyle = .batteryBar
            let usage = ClaudeUsageResponse(fiveHour: .init(utilization: 20, resetsAt: nil), sevenDay: nil)
            @MainActor func render(_ design: MenuBarDesign) throws -> MenuBarProviderSnapshot {
                settings.menuBarDesign = design
                return MenuBarStatusComposer.claudeSnapshot(
                    config: try XCTUnwrap(settings.menuBarDisplayConfig(for: .claude)),
                    usage: usage, error: nil, hasAuthError: false, hasCredential: true,
                    secondaryColor: .secondaryLabelColor, icon: nil)
            }
            let classic = try render(.classic), modern = try render(.modern)
            XCTAssertNotEqual(classic.renderKey, modern.renderKey)
            XCTAssertEqual(classic.tooltip, modern.tooltip)
            XCTAssertNotEqual(classic.styleIcon?.size.width, modern.styleIcon?.size.width)
            XCTAssertTrue(settings.menuBarDesignIntroductionDismissed)
        }
    }

    func testGlobalMotionPresetsCustomChoicesAndReducedMotion() {
        var motion = AppMotionPreferences()
        for category in AppMotionCategory.allCases {
            XCTAssertFalse(motion.allows(category, reduceMotion: false))
        }
        motion.enabledCategories = [.disclosure, .popoverPresentation]
        motion.mode = .smooth
        for category in AppMotionCategory.allCases {
            XCTAssertTrue(motion.allows(category, reduceMotion: false))
            XCTAssertFalse(motion.allows(category, reduceMotion: true))
        }
        motion.mode = .custom
        for category in AppMotionCategory.allCases {
            XCTAssertEqual(motion.allows(category, reduceMotion: false), motion.enabledCategories.contains(category))
            XCTAssertFalse(motion.allows(category, reduceMotion: true))
        }
    }

    func testLegacyPopoverMotionMigratesOnceWithoutEnablingOtherMotion() {
        withDefaults { defaults in
            defaults.set("smooth", forKey: "popoverTransitionStyle")
            let motion = AppMotionPreferences.load(from: defaults)
            XCTAssertEqual(motion.mode, .custom)
            XCTAssertEqual(motion.enabledCategories, [.popoverPresentation, .popoverResize])
            XCTAssertNil(defaults.object(forKey: "popoverTransitionStyle"))
            var selected = motion
            selected.enabledCategories.insert(.disclosure)
            selected.persist(to: defaults)
            XCTAssertEqual(AppMotionPreferences.load(from: defaults), selected)
            defaults.set(["mode": "custom", "enabled": ["navigation", "future-option"]], forKey: "motionPreferences")
            XCTAssertEqual(AppMotionPreferences.load(from: defaults).enabledCategories, [.navigation])
        }
    }

    func testLocalAndPublishedStagingLabelsCannotLookLikeProduction() {
        let staging = AppDistributionDescriptor.resolve(releaseChannelValue: "staging", bundleIdentifier: nil)
        XCTAssertEqual(
            staging.versionLabel(version: "2.6.0", build: "20607", releaseVersion: nil), "v2.6.0-beta (빌드 20607)")
        XCTAssertEqual(
            staging.versionLabel(version: "2.6.0", build: "20607", releaseVersion: "2.6.0-stg.2"), "v2.6.0-stg.2")
        for invalid in ["2.5.3-stg.2", "2.6.0-stg.0", "2.6.0-stg.02", "$(CLAUDEUSAGE_RELEASE_VERSION)"] {
            XCTAssertTrue(
                staging.versionLabel(version: "2.6.0", build: "20607", releaseVersion: invalid).contains("-beta"))
        }
        let prod = AppDistributionDescriptor.resolve(releaseChannelValue: "prod", bundleIdentifier: nil)
        XCTAssertEqual(prod.versionLabel(version: "2.6.0", build: "20607", releaseVersion: "2.6.0"), "v2.6.0")
        XCTAssertTrue(prod.versionLabel(version: "2.6.0", build: "20607", releaseVersion: nil).contains("-beta"))
    }
}
