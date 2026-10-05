import XCTest
@testable import ClaudeUsage

@MainActor
final class PopoverDisplayPreferencesStoreTests: XCTestCase {
    private let claudeOrder = ["currentSession", "weeklyLimit", "modelUsage", "overageUsage", "claudeResetCredits"]
    private let codexOrder = [
        "codexPrimary", "codexSecondary", "codexModelLimits", "codexSpendLimit", "codexCredits", "codexResetCredits",
    ]
    private let oldClaudeOrder = ["currentSession", "weeklyLimit", "modelUsage", "claudeResetCredits", "overageUsage"]
    private let oldCodexOrder = [
        "codexPrimary", "codexSecondary", "codexSpendLimit", "codexModelLimits", "codexResetCredits", "codexCredits",
    ]

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "PopoverDisplayPreferencesStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func items(_ ids: [String]) -> [PopoverItemConfig] {
        ids.enumerated().map { .init(id: $0.element, visible: $0.offset.isMultiple(of: 2)) }
    }

    private func store(
        _ items: [String: [PopoverItemConfig]], key: String, defaults: UserDefaults
    ) throws {
        defaults.set(try JSONEncoder().encode(items), forKey: key)
    }

    private func assertVisibilityPreserved(
        _ old: [PopoverItemConfig], in migrated: [PopoverItemConfig], file: StaticString = #filePath, line: UInt = #line
    ) {
        for item in old {
            XCTAssertEqual(migrated.first { $0.id == item.id }?.visible, item.visible, file: file, line: line)
        }
    }

    func testFreshInstallDefaultsPlaceResetCreditsAfterUsageModelsAndCredits() {
        withDefaults { defaults in
            let preferences = PopoverDisplayPreferencesStore(defaults: defaults)
            XCTAssertEqual(preferences.fullItemsByProvider["claude"]?.map(\.id), claudeOrder)
            XCTAssertEqual(preferences.fullItemsByProvider["codex"]?.map(\.id), codexOrder)
            XCTAssertEqual(preferences.compactItemsByProvider, preferences.fullItemsByProvider)
            XCTAssertTrue(preferences.fullItemsByProvider.values.flatMap { $0 }.allSatisfy(\.visible))
        }
    }

    func testKnownPreviousDefaultsMigrateBothSurfacesOnceAndKeepVisibility() throws {
        try withDefaults { defaults in
            let full = ["claude": items(oldClaudeOrder), "codex": items(oldCodexOrder)]
            let compact = full.mapValues { $0.map { PopoverItemConfig(id: $0.id, visible: !$0.visible) } }
            try store(full, key: "popoverItemsV2", defaults: defaults)
            try store(compact, key: "compactPopoverItemsV2", defaults: defaults)
            defaults.set(4, forKey: "popoverItemsMigrationVersion")
            defaults.set(true, forKey: "separateCompactConfig")

            let preferences = PopoverDisplayPreferencesStore(defaults: defaults)

            for (provider, expected) in [("claude", claudeOrder), ("codex", codexOrder)] {
                let migratedFull = try XCTUnwrap(preferences.fullItemsByProvider[provider])
                let migratedCompact = try XCTUnwrap(preferences.compactItemsByProvider[provider])
                XCTAssertEqual(migratedFull.map(\.id), expected)
                XCTAssertEqual(migratedCompact.map(\.id), expected)
                assertVisibilityPreserved(full[provider]!, in: migratedFull)
                assertVisibilityPreserved(compact[provider]!, in: migratedCompact)
            }
            XCTAssertTrue(preferences.usesSeparateCompactItems)
            XCTAssertEqual(defaults.integer(forKey: "popoverItemsMigrationVersion"), 5)
            let reloaded = PopoverDisplayPreferencesStore(defaults: defaults)
            XCTAssertEqual(reloaded.fullItemsByProvider, preferences.fullItemsByProvider)
            XCTAssertEqual(reloaded.compactItemsByProvider, preferences.compactItemsByProvider)
        }
    }

    func testPublishedCodexDefaultsWithoutMonthlyItemMigrateFromLegacyMirror() throws {
        try withDefaults { defaults in
            let oldOrder = ["codexPrimary", "codexSecondary", "codexModelLimits", "codexResetCredits", "codexCredits"]
            let legacy = items(oldOrder)
            defaults.set(try JSONEncoder().encode(legacy), forKey: "codexPopoverItems")
            defaults.set(4, forKey: "popoverItemsMigrationVersion")

            let preferences = PopoverDisplayPreferencesStore(defaults: defaults)
            let migrated = try XCTUnwrap(preferences.fullItemsByProvider["codex"])

            XCTAssertEqual(migrated.map(\.id), codexOrder)
            assertVisibilityPreserved(legacy, in: migrated)
            XCTAssertEqual(migrated.first { $0.id == "codexSpendLimit" }?.visible, true)
            let mirror = try JSONDecoder().decode(
                [PopoverItemConfig].self, from: XCTUnwrap(defaults.data(forKey: "codexPopoverItems")))
            XCTAssertEqual(mirror, migrated)
        }
    }

    func testCustomFullAndCompactOrdersRemainIndependentAndUnchanged() throws {
        try withDefaults { defaults in
            let full = [
                "claude": items(["claudeResetCredits", "currentSession", "weeklyLimit", "modelUsage", "overageUsage"]),
                "codex": items([
                    "codexResetCredits", "codexCredits", "codexModelLimits", "codexSpendLimit", "codexSecondary",
                    "codexPrimary",
                ]),
            ]
            let compact = [
                "claude": items(["overageUsage", "modelUsage", "weeklyLimit", "currentSession", "claudeResetCredits"]),
                "codex": items([
                    "codexCredits", "codexPrimary", "codexSecondary", "codexModelLimits", "codexSpendLimit",
                    "codexResetCredits",
                ]),
            ]
            try store(full, key: "popoverItemsV2", defaults: defaults)
            try store(compact, key: "compactPopoverItemsV2", defaults: defaults)
            defaults.set(4, forKey: "popoverItemsMigrationVersion")
            defaults.set(true, forKey: "separateCompactConfig")

            let preferences = PopoverDisplayPreferencesStore(defaults: defaults)

            let reloaded = PopoverDisplayPreferencesStore(defaults: defaults)
            for provider in ["claude", "codex"] {
                XCTAssertEqual(preferences.fullItemsByProvider[provider], full[provider])
                XCTAssertEqual(preferences.compactItemsByProvider[provider], compact[provider])
                XCTAssertEqual(reloaded.fullItemsByProvider[provider], full[provider])
                XCTAssertEqual(reloaded.compactItemsByProvider[provider], compact[provider])
            }
        }
    }

    func testIntentionalReturnToFormerDefaultOrderSurvivesRelaunchAfterMigration() throws {
        try withDefaults { defaults in
            let preferences = PopoverDisplayPreferencesStore(defaults: defaults)
            let chosen = items(oldClaudeOrder)
            preferences.setItems(chosen, for: .claude, surface: .standard)

            XCTAssertEqual(preferences.fullItemsByProvider["claude"], chosen)
            XCTAssertEqual(PopoverDisplayPreferencesStore(defaults: defaults).fullItemsByProvider["claude"], chosen)
        }
    }

    func testMissingNewItemsUseNewDefaultsWithoutReorderingExistingCustomItems() throws {
        try withDefaults { defaults in
            let claude = items(["overageUsage", "currentSession", "weeklyLimit"])
            let codex = items(["codexCredits", "codexSecondary", "codexPrimary"])
            try store(["claude": claude, "codex": codex], key: "popoverItemsV2", defaults: defaults)
            defaults.set(4, forKey: "popoverItemsMigrationVersion")
            let preferences = PopoverDisplayPreferencesStore(defaults: defaults)
            let fullClaude = try XCTUnwrap(preferences.fullItemsByProvider["claude"])
            let fullCodex = try XCTUnwrap(preferences.fullItemsByProvider["codex"])

            XCTAssertEqual(
                fullClaude.map(\.id),
                ["overageUsage", "currentSession", "weeklyLimit", "modelUsage", "claudeResetCredits"])
            XCTAssertEqual(
                fullCodex.map(\.id),
                [
                    "codexCredits", "codexSecondary", "codexPrimary", "codexModelLimits", "codexSpendLimit",
                    "codexResetCredits",
                ])
            assertVisibilityPreserved(claude, in: fullClaude)
            assertVisibilityPreserved(codex, in: fullCodex)
        }
    }

    func testNewerMigrationVersionIsNotRewrittenOrReordered() throws {
        try withDefaults { defaults in
            let current = ["claude": items(oldClaudeOrder), "codex": items(oldCodexOrder)]
            let data = try JSONEncoder().encode(current)
            defaults.set(data, forKey: "popoverItemsV2")
            defaults.set(99, forKey: "popoverItemsMigrationVersion")
            let preferences = PopoverDisplayPreferencesStore(defaults: defaults)

            XCTAssertEqual(preferences.fullItemsByProvider, current)
            XCTAssertEqual(defaults.data(forKey: "popoverItemsV2"), data)
            XCTAssertEqual(defaults.integer(forKey: "popoverItemsMigrationVersion"), 99)
        }
    }
}
