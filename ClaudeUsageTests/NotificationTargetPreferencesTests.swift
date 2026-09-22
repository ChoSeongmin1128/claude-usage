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
                scopedLimits: [.init(kind: "weekly_scoped", percent: 10, modelName: nil)]))
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

    func testPartialClaudeImportResumesAfterPersistenceWithoutEnablingNewModels() throws {
        var preferences = NotificationTargetPreferences()
        let original = makeLimits()
        preferences.observe([original[0]], provider: .claude) { _ in true }
        preferences = try reloaded(preferences)

        let model = try XCTUnwrap(
            UsageLimitCatalog.claude(
                .init(
                    fiveHour: .init(utilization: 20, resetsAt: nil), sevenDay: nil,
                    scopedLimits: [.init(kind: "weekly_scoped", percent: 10, modelName: "New model")]
                )
            ).first { $0.isModelScoped }
        )
        preferences.observe(original + [model], provider: .claude) { _ in true }

        XCTAssertTrue(preferences.isSelected(original[0].id, provider: .claude))
        XCTAssertTrue(preferences.isSelected(original[1].id, provider: .claude))
        XCTAssertFalse(preferences.isSelected(model.id, provider: .claude))
    }

    func testPartialImportPreservesExplicitOptOutAndLegacyDisabledChoice() throws {
        var preferences = NotificationTargetPreferences()
        let original = makeLimits()
        preferences.observe([original[0]], provider: .claude) { _ in true }
        preferences.setSelected(false, limit: original[0])
        preferences = try reloaded(preferences)

        preferences.observe(original, provider: .claude) { $0.legacyKey != "weekly" }
        preferences = try reloaded(preferences)
        preferences.observe(original, provider: .claude) { _ in true }

        XCTAssertEqual(preferences.providers["claude"]?.selectedIDs, [])
    }

    func testUnavailableLegacyTargetWaitsForNumericQuotaUnlessExplicitlyDisabled() throws {
        let original = makeLimits()
        let partial = [original[0], original[1].unavailable()]

        var preferences = NotificationTargetPreferences()
        preferences.observe(partial, provider: .claude) { _ in true }
        preferences = try reloaded(preferences)
        preferences.observe(original, provider: .claude) { _ in true }
        XCTAssertTrue(preferences.isSelected(original[1].id, provider: .claude))

        var optedOut = NotificationTargetPreferences()
        optedOut.observe(partial, provider: .claude) { _ in true }
        optedOut.setSelected(false, limit: original[1].unavailable())
        optedOut = try reloaded(optedOut)
        optedOut.observe(original, provider: .claude) { _ in true }
        XCTAssertFalse(optedOut.isSelected(original[1].id, provider: .claude))
    }

    func testEitherCodexBaseWindowCanArriveAfterInitialImport() throws {
        let usage = try JSONDecoder().decode(
            CodexUsageResponse.self,
            from: Data(
                """
                {"rate_limit":{
                  "primary_window":{"used_percent":20,"limit_window_seconds":18000},
                  "secondary_window":{"used_percent":40,"limit_window_seconds":604800}},
                  "additional_rate_limits":[{"metered_feature":"new-model","limit_name":"New model",
                    "rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}}}]}
                """.utf8
            )
        )
        let limits = UsageLimitCatalog.codex(usage)
        let base = limits.filter { $0.legacyKey == "base" }
        let model = try XCTUnwrap(limits.first { $0.isModelScoped })
        XCTAssertEqual(base.count, 2)

        for first in base {
            var preferences = NotificationTargetPreferences()
            preferences.observe([first], provider: .codex) { $0.legacyKey == "base" }
            preferences = try reloaded(preferences)
            preferences.observe(Array(limits.reversed()), provider: .codex) { $0.legacyKey == "base" }
            XCTAssertTrue(base.allSatisfy { preferences.isSelected($0.id, provider: .codex) })
            XCTAssertFalse(preferences.isSelected(model.id, provider: .codex))
        }
    }

    func testExistingV1SelectionsNeverInferMissingLegacyChoices() throws {
        struct LegacySelection: Encodable { let selectedIDs: Set<String> }
        struct LegacyPreferences: Encodable {
            let version = 1
            let providers: [String: LegacySelection]
        }
        let limits = makeLimits()
        for selectedIDs in [Set<String>(), Set([limits[0].id])] {
            let legacy = LegacyPreferences(providers: ["claude": LegacySelection(selectedIDs: selectedIDs)])
            var preferences = try JSONDecoder().decode(
                NotificationTargetPreferences.self, from: JSONEncoder().encode(legacy)
            )
            preferences.observe(limits, provider: .claude) { _ in true }
            preferences = try reloaded(preferences)
            preferences.observe(limits, provider: .claude) { _ in true }
            XCTAssertEqual(preferences.providers["claude"]?.selectedIDs, selectedIDs)
            XCTAssertNil(preferences.providers["claude"]?.importedLegacyIDs)
        }
    }

    func testNewCodexPeriodRequiresOptInAfterCompleteBaseImport() throws {
        let initial = try codexLimits(primaryPeriod: 18_000, secondaryPeriod: 604_800)
        for period in [86_400, nil] as [Int?] {
            var preferences = NotificationTargetPreferences()
            preferences.observe(initial, provider: .codex) { _ in true }
            preferences = try reloaded(preferences)
            let changed = try codexLimits(primaryPeriod: period, secondaryPeriod: 604_800)
            preferences.observe(changed, provider: .codex) { _ in true }
            XCTAssertFalse(preferences.isSelected(changed[0].id, provider: .codex))
            XCTAssertTrue(preferences.isSelected(changed[1].id, provider: .codex))
        }
    }

    func testNewCodexPeriodRequiresOptInWhileWeeklyImportIsPending() throws {
        let initial = try codexLimits(primaryPeriod: 18_000)
        for period in [86_400, nil] as [Int?] {
            var preferences = NotificationTargetPreferences()
            preferences.observe(initial, provider: .codex) { _ in true }
            preferences = try reloaded(preferences)
            let changed = try codexLimits(primaryPeriod: period)
            preferences.observe(changed, provider: .codex) { _ in true }
            XCTAssertFalse(preferences.isSelected(changed[0].id, provider: .codex))

            let complete = try codexLimits(primaryPeriod: 604_800, secondaryPeriod: 18_000)
            preferences.observe(complete, provider: .codex) { _ in true }
            XCTAssertTrue(complete.allSatisfy { preferences.isSelected($0.id, provider: .codex) })
        }
    }

    func testCodexExplicitOptOutSurvivesPeriodReplacementAndReturn() throws {
        let initial = try codexLimits(primaryPeriod: 18_000)
        var preferences = NotificationTargetPreferences()
        preferences.observe(initial, provider: .codex) { _ in true }
        preferences.setSelected(false, limit: initial[0])
        preferences = try reloaded(preferences)

        let changed = try codexLimits(primaryPeriod: 86_400)
        preferences.observe(changed, provider: .codex) { _ in true }
        XCTAssertFalse(preferences.isSelected(changed[0].id, provider: .codex))
        preferences.observe(initial, provider: .codex) { _ in true }
        XCTAssertFalse(preferences.isSelected(initial[0].id, provider: .codex))
    }

    func testCodexSlotSwapPreservesSelectionsByDuration() throws {
        let initial = try codexLimits(primaryPeriod: 18_000, secondaryPeriod: 604_800)
        var preferences = NotificationTargetPreferences()
        preferences.observe(initial, provider: .codex) { _ in true }
        preferences.setSelected(false, limit: initial[0])
        preferences = try reloaded(preferences)

        let swapped = try codexLimits(primaryPeriod: 604_800, secondaryPeriod: 18_000)
        preferences.observe(swapped, provider: .codex) { _ in true }
        XCTAssertEqual(swapped[0].id, initial[1].id)
        XCTAssertEqual(swapped[1].id, initial[0].id)
        XCTAssertTrue(preferences.isSelected(swapped[0].id, provider: .codex))
        XCTAssertFalse(preferences.isSelected(swapped[1].id, provider: .codex))
    }

    func testInitialCodexImportRetainsObservedArbitraryBasePeriods() throws {
        for period in [86_400, nil] as [Int?] {
            let limits = try codexLimits(primaryPeriod: period)
            var preferences = NotificationTargetPreferences()
            preferences.observe(limits, provider: .codex) { _ in true }
            XCTAssertTrue(preferences.isSelected(limits[0].id, provider: .codex))
        }
    }

    private func codexLimits(primaryPeriod: Int?, secondaryPeriod: Int? = nil) throws -> [UsageLimit] {
        var primary = ["used_percent": 20]
        if let primaryPeriod { primary["limit_window_seconds"] = primaryPeriod }
        var rateLimit = ["primary_window": primary]
        if let secondaryPeriod {
            rateLimit["secondary_window"] = ["used_percent": 40, "limit_window_seconds": secondaryPeriod]
        }
        let response = try JSONDecoder().decode(
            CodexUsageResponse.self, from: JSONSerialization.data(withJSONObject: ["rate_limit": rateLimit])
        )
        return UsageLimitCatalog.codex(response)
    }

    private func reloaded(_ preferences: NotificationTargetPreferences) throws -> NotificationTargetPreferences {
        try JSONDecoder().decode(NotificationTargetPreferences.self, from: JSONEncoder().encode(preferences))
    }

    private func makeLimits() -> [UsageLimit] {
        UsageLimitCatalog.claude(
            .init(fiveHour: .init(utilization: 20, resetsAt: nil), sevenDay: .init(utilization: 40, resetsAt: nil)))
    }
}
