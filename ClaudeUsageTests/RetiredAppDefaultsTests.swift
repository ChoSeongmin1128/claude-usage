import XCTest
@testable import ClaudeUsage

final class RetiredAppDefaultsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "ClaudeUsageTests.retiredDefaults.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testUnreadKeysAreRemovedWithoutTouchingCurrentOnes() {
        let unread = RetiredAppDefaults.groups.filter { $0.replacement == nil }.flatMap(\.keys)
        unread.forEach { defaults.set(true, forKey: $0) }
        let current = ["settingsLastTab", "ClaudeUsage.authPathHealth.v1.ephemeral", "notificationPresets"]
        current.forEach { defaults.set(true, forKey: $0) }

        RetiredAppDefaults.remove(from: defaults)

        for key in unread { XCTAssertNil(defaults.object(forKey: key), key) }
        for key in current { XCTAssertNotNil(defaults.object(forKey: key), key) }
    }

    func testImportedKeysStayUntilTheirReplacementExists() {
        for group in RetiredAppDefaults.groups {
            guard let replacement = group.replacement else { continue }
            group.keys.forEach { defaults.set(true, forKey: $0) }

            RetiredAppDefaults.remove(from: defaults)
            for key in group.keys { XCTAssertNotNil(defaults.object(forKey: key), key) }

            defaults.set(true, forKey: replacement)
            RetiredAppDefaults.remove(from: defaults)
            for key in group.keys { XCTAssertNil(defaults.object(forKey: key), key) }
        }
    }

    @MainActor
    func testLaunchImportsLegacyValuesBeforeRemovingThemAndKeepsTheInstallExisting() {
        defaults.set(true, forKey: "claudePopoverPinned")
        defaults.set(true, forKey: "codexPopoverCompact")
        defaults.set(35, forKey: "alert1Threshold")
        defaults.set(15, forKey: "alert2Threshold")
        defaults.set(5, forKey: "alert3Threshold")
        defaults.set(true, forKey: "alertRemainingMode")

        let first = AppSettings(defaults: defaults, hasExistingAccountStorage: false)

        for key in [
            "claudePopoverPinned", "codexPopoverCompact", "alert1Threshold", "alert2Threshold", "alert3Threshold",
        ] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        let relaunched = AppSettings(defaults: defaults, hasExistingAccountStorage: false)
        XCTAssertTrue(first.popoverPinned)
        XCTAssertTrue(first.popoverCompact)
        XCTAssertEqual(first.enabledAlertThresholds, [65, 85, 95])
        XCTAssertEqual(relaunched.popoverPinned, first.popoverPinned)
        XCTAssertEqual(relaunched.popoverCompact, first.popoverCompact)
        XCTAssertEqual(relaunched.enabledAlertThresholds, first.enabledAlertThresholds)
        XCTAssertEqual(relaunched.usageDisplayMode, .legacy)
        XCTAssertEqual(relaunched.welcomeState, .completed)
    }
}
