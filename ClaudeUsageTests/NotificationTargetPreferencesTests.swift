import XCTest
@testable import ClaudeUsage

final class NotificationTargetPreferencesTests: XCTestCase {
    func testMigrationWaitsForUsableQuotaAndPreservesDisabledLegacyTargets() throws {
        var preferences = NotificationTargetPreferences()
        preferences.observe([], provider: .claude) { _ in true }
        XCTAssertNil(preferences.providers["claude"])
        let limits = makeLimits()
        preferences.observe(limits, provider: .claude) { $0.legacyKey == "fiveHour" }
        XCTAssertTrue(preferences.isSelected(limits[0].id, provider: .claude))
        XCTAssertFalse(preferences.isSelected(limits[1].id, provider: .claude))
        preferences.setSelected(false, limit: limits[0])
        let defaults = UserDefaults(suiteName: "notification-target-tests-\(UUID())")!
        preferences.save(to: defaults)
        var loaded = NotificationTargetPreferences.load(from: defaults)
        defaults.removeObject(forKey: NotificationTargetPreferences.key)
        loaded.observe(limits, provider: .claude) { _ in true }
        XCTAssertEqual(loaded.providers["claude"]?.selectedIDs, [])
    }

    func testNewModelsStartOffAndMissingSelectionsAreRetained() {
        var preferences = NotificationTargetPreferences()
        let original = makeLimits()
        preferences.observe(original, provider: .claude) { _ in true }
        let added = UsageLimitCatalog.claude(
            .init(
                fiveHour: .init(utilization: 20, resetsAt: nil), sevenDay: nil,
                scopedLimits: [.init(kind: "weekly_scoped", percent: 10, modelID: "fable", modelName: "Fable")]))
        preferences.observe(added, provider: .claude) { _ in true }
        XCTAssertFalse(preferences.isSelected(added[1].id, provider: .claude))
        XCTAssertTrue(preferences.isSelected(original[1].id, provider: .claude))
        preferences.setSelected(true, limit: added[1])
        preferences.observe([], provider: .claude) { _ in false }
        XCTAssertTrue(preferences.isSelected(added[1].id, provider: .claude))
    }

    func testUnidentifiablePayloadDoesNotCompleteMigration() {
        var preferences = NotificationTargetPreferences()
        let invalid = UsageLimitCatalog.claude(
            .init(
                fiveHour: .init(utilization: .nan, resetsAt: nil), sevenDay: nil,
                scopedLimits: [.init(kind: "weekly_scoped", percent: 10, modelName: "Display only")]))
        preferences.observe(invalid, provider: .claude) { _ in true }
        XCTAssertTrue(preferences.providers.isEmpty)
    }

    func testExplicitSelectionWorksWithoutAnotherFetchAfterPreferencesReset() {
        var preferences = NotificationTargetPreferences()
        let limits = makeLimits()
        preferences.setSelected(true, limit: limits[1])
        preferences.observe(limits, provider: .claude) { _ in true }
        XCTAssertTrue(preferences.isSelected(limits[1].id, provider: .claude))
        XCTAssertFalse(preferences.isSelected(limits[0].id, provider: .claude))
    }

    private func makeLimits() -> [UsageLimit] {
        UsageLimitCatalog.claude(
            .init(fiveHour: .init(utilization: 20, resetsAt: nil), sevenDay: .init(utilization: 40, resetsAt: nil)))
    }
}
