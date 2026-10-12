import Combine
import Foundation
import XCTest
@testable import ClaudeUsage

@MainActor
final class ReviewStoragePreservationTests: XCTestCase {
    func testNotificationHealthyOptOutSurvivesMalformedSiblingAndAutomaticObservation() throws {
        for codex in [17, ["selectedIDs": [String]()]] as [Any] {
            try withDefaults { defaults in
                let original = try data([
                    "version": 1, "providers": ["claude": ["selectedIDs": [String]()], "codex": codex],
                ])
                defaults.set(original, forKey: NotificationTargetPreferences.key)
                let settings = makeSettings(defaults)
                let deliverer = StorageReviewNotificationDeliverer()
                let manager = NotificationManager(deliverer: deliverer, settings: settings)
                let usage = ClaudeUsageResponse(fiveHour: .init(utilization: 20, resetsAt: nil), sevenDay: nil)
                let limit = try XCTUnwrap(UsageLimitCatalog.claude(usage).first)

                manager.checkClaude(usage, accountID: "fixture-owner", policy: nil)

                XCTAssertFalse(settings.notificationTargets.isSelected(limit.id, provider: .claude))
                XCTAssertEqual(settings.notificationTargets.providers["claude"]?.selectedIDs, [])
                XCTAssertEqual(defaults.data(forKey: NotificationTargetPreferences.key), original)
                XCTAssertEqual(deliverer.deliveredCount, 0)
            }
        }
    }

    func testNotificationTwoEditsKeepUnknownNullAndMalformedSelection() throws {
        try withDefaults { defaults in
            let damaged: [String: Any] = ["selectedIDs": 17, "future": NSNull()]
            defaults.set(
                try data([
                    "version": 1, "future": NSNull(),
                    "providers": [
                        "claude": ["selectedIDs": [String](), "importedLegacyIDs": NSNull(), "future": NSNull()],
                        "codex": damaged, "future-provider": NSNull(),
                    ],
                ]), forKey: NotificationTargetPreferences.key)
            let settings = makeSettings(defaults)
            let limits = claudeLimits()
            XCTAssertEqual(settings.setNotificationSelected(true, limit: limits[0]), .saved)
            XCTAssertEqual(settings.setNotificationSelected(true, limit: limits[1]), .saved)

            let raw = try root(defaults, NotificationTargetPreferences.key)
            let providers = try XCTUnwrap(raw["providers"] as? [String: Any])
            assertJSON(providers["codex"], damaged)
            XCTAssertTrue(raw["future"] is NSNull)
            XCTAssertTrue(providers["future-provider"] is NSNull)
            let claude = try XCTUnwrap(providers["claude"] as? [String: Any])
            XCTAssertTrue(claude["future"] is NSNull)
            XCTAssertTrue(claude["importedLegacyIDs"] is NSNull)
            XCTAssertEqual(Set(try XCTUnwrap(claude["selectedIDs"] as? [String])), Set(limits.map(\.id)))
            XCTAssertEqual(settings.notificationTargets, NotificationTargetPreferences.load(from: defaults))
        }
    }

    func testNotificationMalformedFieldCannotBeAutomaticallyReenabledOrPublished() throws {
        try withDefaults { defaults in
            let original = try data(["version": 1, "providers": ["claude": ["selectedIDs": 17]]])
            defaults.set(original, forKey: NotificationTargetPreferences.key)
            let settings = makeSettings(defaults)
            let before = settings.notificationTargets
            var publications = 0
            let subscription = settings.objectWillChange.sink { publications += 1 }
            defer { subscription.cancel() }
            var candidate = before
            candidate.setSelected(true, limit: claudeLimits()[0])

            assertBlocked(settings.commitNotificationTargets(candidate, intent: .automatic))

            XCTAssertEqual(settings.notificationTargets, before)
            XCTAssertFalse(settings.notificationTargets.isSelected(claudeLimits()[0].id, provider: .claude))
            XCTAssertEqual(defaults.data(forKey: NotificationTargetPreferences.key), original)
            XCTAssertEqual(publications, 0)
            assertBlocked(settings.setNotificationSelected(true, limit: claudeLimits()[0]))
            XCTAssertNotNil(settings.preferenceSaveError)
        }
    }

    func testNotificationRootNonDataMalformedAndFutureVersionsStayBlocked() throws {
        let roots: [Any] = [
            "future-format", Data("[]".utf8),
            try data(["version": 99, "providers": ["claude": ["selectedIDs": [String]()]]]),
            try data(["version": true, "providers": [String: Any]()]),
        ]
        for original in roots {
            try withDefaults { defaults in
                defaults.set(original, forKey: NotificationTargetPreferences.key)
                let settings = makeSettings(defaults)
                let before = settings.notificationTargets
                var candidate = before
                candidate.setSelected(true, limit: claudeLimits()[0])
                assertBlocked(settings.commitNotificationTargets(candidate, intent: .automatic))
                XCTAssertEqual(settings.notificationTargets, before)
                assertObject(defaults.object(forKey: NotificationTargetPreferences.key), original)
                settings.resetToDefaults()
                assertObject(defaults.object(forKey: NotificationTargetPreferences.key), original)
            }
        }
    }

    func testNotificationFailedReadbackDoesNotPublishAndCanRetry() throws {
        try withDefaults { defaults in
            let settings = makeSettings(defaults)
            let before = settings.notificationTargets
            var candidate = before
            candidate.setSelected(true, limit: claudeLimits()[0])
            defaults.rejectedKeys = [NotificationTargetPreferences.key]
            var publications = 0
            let subscription = settings.objectWillChange.sink { publications += 1 }
            defer { subscription.cancel() }

            assertFailed(settings.commitNotificationTargets(candidate, intent: .automatic))
            XCTAssertEqual(settings.notificationTargets, before)
            XCTAssertNil(defaults.object(forKey: NotificationTargetPreferences.key))
            XCTAssertEqual(publications, 0)
            defaults.rejectedKeys = []
            XCTAssertEqual(settings.commitNotificationTargets(candidate, intent: .user), .saved)
            XCTAssertTrue(settings.notificationTargets.isSelected(claudeLimits()[0].id, provider: .claude))
        }
    }

    func testUsageHealthyServiceSurvivesMalformedSiblingOnRuntimeBind() throws {
        for codex in [17, [String: Any]()] as [Any] {
            try withDefaults { defaults in
                let healthy: [String: Any] = [
                    "isMultiAccountEnabled": true,
                    "directories": ["/fixture/never-read/claude"], "selected": ["chosen"],
                    "pinnedTop": "chosen", "future": NSNull(),
                ]
                defaults.set(
                    try data(["services": ["claude": healthy, "codex": codex], "order": [String]()]),
                    forKey: UsageAccountPreferences.key)
                let controller = makeController(defaults)
                let before = controller.preferences[.claude]

                controller.bindRuntimeAccount(runtimeCandidate(), for: .claude)

                XCTAssertEqual(controller.preferences[.claude], before)
                XCTAssertTrue(controller.isMultiAccountEnabled(.claude))
                XCTAssertEqual(controller.preferences.order, ["claude:fixture-owner|fixture-team"])
                let services = try XCTUnwrap(
                    try root(defaults, UsageAccountPreferences.key)["services"] as? [String: Any])
                assertJSON(services["claude"], healthy)
                assertJSON(services["codex"], codex)
                XCTAssertEqual(UsageAccountPreferences.load(from: defaults)[.claude], before)
            }
        }
    }

    func testUsageTwoEditsPreserveMalformedFieldsAliasesIdentitiesAndUnknownNull() throws {
        try withDefaults { defaults in
            let original: [String: Any] = [
                "future": NSNull(), "hidden": NSNull(), "order": ["opaque", 17],
                "aliases": ["healthy": "old", "opaque": NSNull()],
                "knownIdentities": [
                    "healthy": ["accountID": "owner", "email": "old@example.invalid", "future": NSNull()],
                    "opaque": ["accountID": 17],
                ],
                "services": [
                    "claude": [
                        "isMultiAccountEnabled": "future", "selected": ["opaque"],
                        "pinnedTop": "healthy", "future": NSNull(),
                        "expectedDefault": ["accountID": "owner", "email": "old@example.invalid", "future": NSNull()],
                    ],
                    "codex": NSNull(), "future-provider": ["anything": NSNull()],
                ],
            ]
            defaults.set(try data(original), forKey: UsageAccountPreferences.key)
            let controller = makeController(defaults)
            var first = controller.preferences
            first.aliases["healthy"] = "edited"
            first[.claude].pinnedTop = nil
            XCTAssertEqual(controller.commitPreferences(first, intent: .user), .saved)
            var second = controller.preferences
            second[.claude].expectedDefault?.email = nil
            second.knownIdentities["healthy"]?.email = "new@example.invalid"
            XCTAssertEqual(controller.commitPreferences(second, intent: .user), .saved)

            let raw = try root(defaults, UsageAccountPreferences.key)
            XCTAssertTrue(raw["future"] is NSNull)
            XCTAssertTrue(raw["hidden"] is NSNull)
            assertJSON(raw["order"], original["order"])
            let aliases = try XCTUnwrap(raw["aliases"] as? [String: Any])
            XCTAssertEqual(aliases["healthy"] as? String, "edited")
            XCTAssertTrue(aliases["opaque"] is NSNull)
            let services = try XCTUnwrap(raw["services"] as? [String: Any])
            let claude = try XCTUnwrap(services["claude"] as? [String: Any])
            XCTAssertEqual(claude["isMultiAccountEnabled"] as? String, "future")
            XCTAssertEqual(claude["selected"] as? [String], ["opaque"])
            XCTAssertNil(claude["pinnedTop"])
            XCTAssertTrue(claude["future"] is NSNull)
            XCTAssertTrue(services["codex"] is NSNull)
            let expected = try XCTUnwrap(claude["expectedDefault"] as? [String: Any])
            XCTAssertNil(expected["email"])
            XCTAssertTrue(expected["future"] is NSNull)
            let identities = try XCTUnwrap(raw["knownIdentities"] as? [String: Any])
            assertJSON(identities["opaque"], ["accountID": 17])
            let healthy = try XCTUnwrap(identities["healthy"] as? [String: Any])
            XCTAssertEqual(healthy["email"] as? String, "new@example.invalid")
            XCTAssertTrue(healthy["future"] is NSNull)
            XCTAssertEqual(controller.preferences, UsageAccountPreferences.load(from: defaults))
        }
    }

    func testUsageMalformedFieldBlocksAutomaticMemoryPublishButHealthyControlSaves() throws {
        for enabled in ["future", false] as [Any] {
            try withDefaults { defaults in
                let original = try data(["services": ["claude": ["isMultiAccountEnabled": enabled]]])
                defaults.set(original, forKey: UsageAccountPreferences.key)
                let controller = makeController(defaults)
                let before = controller.preferences
                var candidate = before
                candidate[.claude].isMultiAccountEnabled = true
                var publications = 0
                let subscription = controller.objectWillChange.sink { publications += 1 }
                defer { subscription.cancel() }
                let result = controller.commitPreferences(candidate, intent: .automatic)
                if enabled is String {
                    assertBlocked(result)
                    XCTAssertEqual(controller.preferences, before)
                    XCTAssertFalse(controller.isMultiAccountEnabled(.claude))
                    XCTAssertEqual(defaults.data(forKey: UsageAccountPreferences.key), original)
                    XCTAssertEqual(publications, 0)
                    controller.setMultiAccountEnabled(true, for: .claude)
                    XCTAssertFalse(controller.isMultiAccountEnabled(.claude))
                    XCTAssertNotNil(controller.preferenceSaveError)
                } else {
                    XCTAssertEqual(result, .saved)
                    XCTAssertTrue(controller.isMultiAccountEnabled(.claude))
                    XCTAssertGreaterThan(publications, 0)
                }
            }
        }
    }

    func testUsageEveryMalformedServiceFieldIsPreservedAndCannotBeReplacedByFallback() throws {
        let fields: [String: Any] = [
            "isMultiAccountEnabled": "future", "popoverMode": "future",
            "selected": 17, "pinnedTop": 17, "directories": 17, "expectedDefault": 17,
            "isMenuBarAccountChosen": "future",
        ]
        for (field, malformed) in fields {
            try withDefaults { defaults in
                defaults.set(
                    try data(["services": ["claude": [field: malformed]], "future": NSNull()]),
                    forKey: UsageAccountPreferences.key)
                let controller = makeController(defaults)
                var healthyEdit = controller.preferences
                healthyEdit.aliases["healthy"] = "edited"
                XCTAssertEqual(controller.commitPreferences(healthyEdit, intent: .user), .saved)
                let saved = try XCTUnwrap(defaults.data(forKey: UsageAccountPreferences.key))
                let services = try XCTUnwrap(
                    try root(defaults, UsageAccountPreferences.key)["services"] as? [String: Any])
                assertJSON((services["claude"] as? [String: Any])?[field], malformed)
                let before = controller.preferences
                var blocked = before
                switch field {
                case "isMultiAccountEnabled": blocked[.claude].isMultiAccountEnabled = true
                case "popoverMode": blocked[.claude].popoverMode = .summaryRows
                case "selected": blocked[.claude].selected = ["healthy"]
                case "pinnedTop": blocked[.claude].pinnedTop = "healthy"
                case "directories": blocked[.claude].directories = ["/fixture/never-read/directory"]
                case "expectedDefault": blocked[.claude].expectedDefault = .init(accountID: "healthy")
                case "isMenuBarAccountChosen": blocked[.claude].isMenuBarAccountChosen = true
                default: XCTFail("Unexpected fixture field")
                }
                assertBlocked(controller.commitPreferences(blocked, intent: .automatic))
                XCTAssertEqual(controller.preferences, before)
                XCTAssertEqual(defaults.data(forKey: UsageAccountPreferences.key), saved)
            }
        }
    }

    func testUsageRootGuardsAndChangedStorageBlockWithoutMemoryPublish() throws {
        let roots: [Any] = ["future", Data("[]".utf8), try data(["version": 99, "services": [String: Any]()])]
        for original in roots {
            try withDefaults { defaults in
                defaults.set(original, forKey: UsageAccountPreferences.key)
                let controller = makeController(defaults)
                let before = controller.preferences
                var candidate = before
                candidate[.claude].isMultiAccountEnabled = true
                assertBlocked(controller.commitPreferences(candidate, intent: .automatic))
                XCTAssertEqual(controller.preferences, before)
                assertObject(defaults.object(forKey: UsageAccountPreferences.key), original)
            }
        }
        try withDefaults { defaults in
            let controller = makeController(defaults)
            let before = controller.preferences
            let external = try data(["services": [String: Any](), "future": NSNull()])
            defaults.set(external, forKey: UsageAccountPreferences.key)
            var candidate = before
            candidate.aliases["healthy"] = "edited"
            assertBlocked(controller.commitPreferences(candidate, intent: .automatic))
            XCTAssertEqual(controller.preferences, before)
            XCTAssertEqual(defaults.data(forKey: UsageAccountPreferences.key), external)
        }
    }

    func testUsageFailedReadbackLeavesRawAndMemoryUnchangedThenRetries() throws {
        try withDefaults { defaults in
            let original = try data(["services": [String: Any](), "future": NSNull()])
            defaults.set(original, forKey: UsageAccountPreferences.key)
            let controller = makeController(defaults)
            let before = controller.preferences
            var candidate = before
            candidate.aliases["healthy"] = "edited"
            defaults.rejectedKeys = [UsageAccountPreferences.key]
            assertFailed(controller.commitPreferences(candidate, intent: .automatic))
            XCTAssertEqual(controller.preferences, before)
            XCTAssertEqual(defaults.data(forKey: UsageAccountPreferences.key), original)
            defaults.rejectedKeys = []
            XCTAssertEqual(controller.commitPreferences(candidate, intent: .user), .saved)
            XCTAssertEqual(controller.preferences.aliases["healthy"], "edited")
            XCTAssertTrue(try root(defaults, UsageAccountPreferences.key)["future"] is NSNull)
        }
    }

    func testSnapshotRestoresNotificationGuardDespiteEqualBusinessValuesAndDefaultReset() throws {
        try withDefaults { defaults in
            let damaged = Data("[]".utf8)
            defaults.set(damaged, forKey: NotificationTargetPreferences.key)
            let settings = makeSettings(defaults)
            let snapshot = settings.createSnapshot()
            let captured = settings.notificationTargets
            defaults.removeObject(forKey: NotificationTargetPreferences.key)
            settings.notificationTargets = NotificationTargetPreferences()
            XCTAssertEqual(settings.notificationTargets, captured)

            settings.restore(from: snapshot)
            XCTAssertEqual(defaults.data(forKey: NotificationTargetPreferences.key), damaged)
            var candidate = settings.notificationTargets
            candidate.setSelected(true, limit: claudeLimits()[0])
            assertBlocked(settings.commitNotificationTargets(candidate, intent: .automatic))
            settings.resetToDefaults()
            XCTAssertEqual(defaults.data(forKey: NotificationTargetPreferences.key), damaged)

            // Clearing the suite key and constructing a new owner models the explicit full-reset boundary.
            defaults.removeObject(forKey: NotificationTargetPreferences.key)
            let fresh = makeSettings(defaults)
            XCTAssertEqual(fresh.setNotificationSelected(true, limit: claudeLimits()[0]), .saved)
        }
    }

    func testDefaultsClearKnownNotificationSelectionAndKeepOpaqueProvider() throws {
        try withDefaults { defaults in
            let limit = claudeLimits()[0]
            defaults.set(
                try data([
                    "version": 1, "future": NSNull(),
                    "providers": [
                        "claude": ["selectedIDs": [limit.id], "future": NSNull()], "future-provider": NSNull(),
                    ],
                ]), forKey: NotificationTargetPreferences.key)
            let settings = makeSettings(defaults)
            settings.resetToDefaults()
            XCTAssertFalse(settings.notificationTargets.isSelected(limit.id, provider: .claude))
            let raw = try root(defaults, NotificationTargetPreferences.key)
            let providers = try XCTUnwrap(raw["providers"] as? [String: Any])
            XCTAssertTrue(raw["future"] is NSNull)
            XCTAssertTrue(providers["future-provider"] is NSNull)
            XCTAssertTrue((providers["claude"] as? [String: Any])?["future"] is NSNull)
        }
    }

    func testMigrationKeepsMalformedProviderAndHealthyVisibilityAndIsIdempotent() throws {
        try withDefaults { defaults in
            let damaged: [[String: Any]] = [["id": "codexPrimary", "visible": "future", "future": NSNull()]]
            defaults.set(
                try data([
                    "claude": [["id": "currentSession", "visible": false, "future": NSNull()]],
                    "codex": damaged, "future": NSNull(),
                ]), forKey: "popoverItemsV2")
            defaults.set(4, forKey: "popoverItemsMigrationVersion")
            let store = PopoverDisplayPreferencesStore(defaults: defaults)
            XCTAssertEqual(
                store.items(for: .claude, surface: .standard).first { $0.id == "currentSession" }?.visible, false)
            XCTAssertFalse(store.items(for: .codex, surface: .standard).contains { $0.id == "codexPrimary" })
            XCTAssertEqual(defaults.integer(forKey: "popoverItemsMigrationVersion"), 4)
            let first = try root(defaults, "popoverItemsV2")
            assertJSON(first["codex"], damaged)
            XCTAssertTrue(first["future"] is NSNull)
            _ = PopoverDisplayPreferencesStore(defaults: defaults)
            assertJSON(try root(defaults, "popoverItemsV2"), first)
            XCTAssertEqual(defaults.integer(forKey: "popoverItemsMigrationVersion"), 4)
        }
    }

    func testMigrationHealthyControlWritesBothSurfacesAndMirrorsBeforeMarker() throws {
        try withDefaults { defaults in
            let store = PopoverDisplayPreferencesStore(defaults: defaults)
            XCTAssertEqual(defaults.integer(forKey: "popoverItemsMigrationVersion"), 5)
            for (key, compact) in [("popoverItemsV2", false), ("compactPopoverItemsV2", true)] {
                let raw = try root(defaults, key)
                for provider in ["claude", "codex"] {
                    let mirror =
                        provider == "claude"
                        ? (compact ? "compactPopoverItems" : "popoverItems")
                        : (compact ? "codexCompactPopoverItems" : "codexPopoverItems")
                    let mirrored = try JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: mirror)))
                    assertJSON(raw[provider], mirrored)
                }
            }
            XCTAssertEqual(store.fullItemsByProvider, store.compactItemsByProvider)
        }
    }

    func testMigrationReadbackFailureKeepsMarkerAndRetriesPartialWrites() throws {
        for rejected in ["popoverItemsV2", "codexCompactPopoverItems", "popoverItemsMigrationVersion"] {
            try withDefaults { defaults in
                defaults.set(4, forKey: "popoverItemsMigrationVersion")
                defaults.rejectedKeys = [rejected]
                let failed = PopoverDisplayPreferencesStore(defaults: defaults)
                assertFailed(failed.lastSaveResult)
                XCTAssertEqual(defaults.integer(forKey: "popoverItemsMigrationVersion"), 4)
                defaults.rejectedKeys = []
                let retried = PopoverDisplayPreferencesStore(defaults: defaults)
                XCTAssertEqual(defaults.integer(forKey: "popoverItemsMigrationVersion"), 5)
                let raw = try root(defaults, "popoverItemsV2")
                let compactRaw = try root(defaults, "compactPopoverItemsV2")
                let again = PopoverDisplayPreferencesStore(defaults: defaults)
                assertJSON(try root(defaults, "popoverItemsV2"), raw)
                assertJSON(try root(defaults, "compactPopoverItemsV2"), compactRaw)
                XCTAssertEqual(again.fullItemsByProvider, retried.fullItemsByProvider)
            }
        }
    }

    func testFutureMarkerAndFutureRootNeverRewriteOnLoadOrDefaultRestore() throws {
        for marker in [5, 99] {
            try withDefaults { defaults in
                let original = try data([
                    "version": 99, "claude": [["id": "currentSession", "visible": false]],
                    "future": NSNull(),
                ])
                defaults.set(original, forKey: "popoverItemsV2")
                defaults.set(marker, forKey: "popoverItemsMigrationVersion")
                let store = PopoverDisplayPreferencesStore(defaults: defaults)
                XCTAssertEqual(defaults.data(forKey: "popoverItemsV2"), original)
                XCTAssertThrowsError(
                    try store.setItems(
                        [.init(id: "currentSession", visible: true)],
                        for: .claude, surface: .standard))
                store.restoreKnownDefaults()
                XCTAssertEqual(defaults.data(forKey: "popoverItemsV2"), original)
                XCTAssertEqual(defaults.integer(forKey: "popoverItemsMigrationVersion"), marker)
            }
        }
        try withDefaults { defaults in
            let original = try data(["claude": [["id": "currentSession", "visible": false]]])
            defaults.set(original, forKey: "popoverItemsV2")
            defaults.set(99, forKey: "popoverItemsMigrationVersion")
            let store = PopoverDisplayPreferencesStore(defaults: defaults)
            XCTAssertThrowsError(
                try store.setItems(
                    [.init(id: "currentSession", visible: true)],
                    for: .claude, surface: .standard))
            XCTAssertEqual(defaults.data(forKey: "popoverItemsV2"), original)
        }
    }

    func testEditingOtherProviderDoesNotMaterializeDefaultsIntoUntouchedPartialRoot() throws {
        for savedProvider in ["claude", "codex"] {
            try withDefaults { defaults in
                let itemID = savedProvider == "claude" ? "currentSession" : "codexPrimary"
                let stored: [[String: Any]] = [["id": itemID, "visible": false, "future": NSNull()]]
                defaults.set(try data([savedProvider: stored, "future": NSNull()]), forKey: "popoverItemsV2")
                defaults.set(5, forKey: "popoverItemsMigrationVersion")
                let store = PopoverDisplayPreferencesStore(defaults: defaults)
                let other: PopoverService = savedProvider == "claude" ? .codex : .claude
                var edited = store.items(for: other, surface: .standard)
                edited[0].visible.toggle()
                try store.setItems(edited, for: other, surface: .standard)
                let raw = try root(defaults, "popoverItemsV2")
                assertJSON(raw[savedProvider], stored)
                XCTAssertTrue(raw["future"] is NSNull)

            }
            try withDefaults { defaults in
                let itemID = savedProvider == "claude" ? "currentSession" : "codexPrimary"
                defaults.set(try data([savedProvider: [["id": itemID, "visible": false]]]), forKey: "popoverItemsV2")
                defaults.set(5, forKey: "popoverItemsMigrationVersion")
                let store = PopoverDisplayPreferencesStore(defaults: defaults)
                let same: PopoverService = savedProvider == "claude" ? .claude : .codex
                let other: PopoverService = savedProvider == "claude" ? .codex : .claude
                var known = store.items(for: same, surface: .standard)
                known[0].visible = true
                try store.setItems(known, for: same, surface: .standard)
                XCTAssertNil(try root(defaults, "popoverItemsV2")[other.rawValue])
            }
        }
    }

    func testPopoverTwoEditsPreserveOpaqueOrderUnknownNullAndIndependentCompactRaw() throws {
        try withDefaults { defaults in
            let opaque: [String: Any] = ["id": "future-lane", "visible": "future", "future": NSNull()]
            defaults.set(
                try data([
                    "claude": [
                        ["id": "currentSession", "visible": false, "future": NSNull()],
                        opaque, ["id": "weeklyLimit", "visible": true],
                    ], "future": NSNull(),
                ]), forKey: "popoverItemsV2")
            let compact = try data(["claude": [["id": "currentSession", "visible": true]]])
            defaults.set(compact, forKey: "compactPopoverItemsV2")
            defaults.set(5, forKey: "popoverItemsMigrationVersion")
            let store = PopoverDisplayPreferencesStore(defaults: defaults)
            var first = store.items(for: .claude, surface: .standard)
            first[first.firstIndex { $0.id == "currentSession" }!].visible = true
            try store.setItems(first, for: .claude, surface: .standard)
            var second = store.items(for: .claude, surface: .standard)
            second[second.firstIndex { $0.id == "weeklyLimit" }!].visible = false
            try store.setItems(second, for: .claude, surface: .standard)

            let raw = try root(defaults, "popoverItemsV2")
            let rows = try XCTUnwrap(raw["claude"] as? [[String: Any]])
            assertJSON(rows.first { $0["id"] as? String == "future-lane" }, opaque)
            XCTAssertEqual(rows[1]["id"] as? String, "future-lane")
            XCTAssertEqual(rows.first { $0["id"] as? String == "currentSession" }?["visible"] as? Bool, true)
            XCTAssertEqual(rows.first { $0["id"] as? String == "weeklyLimit" }?["visible"] as? Bool, false)
            XCTAssertTrue(rows.first { $0["id"] as? String == "currentSession" }?["future"] is NSNull)
            XCTAssertTrue(raw["future"] is NSNull)
            XCTAssertEqual(defaults.data(forKey: "compactPopoverItemsV2"), compact)
            XCTAssertEqual(
                PopoverDisplayPreferencesStore(defaults: defaults).items(for: .claude, surface: .standard), second)
        }
    }

    func testPopoverSnapshotRestoresRootGuardAndAppSettingsUsesOpaqueProjection() throws {
        try withDefaults { defaults in
            let original = try data(["claude": [["id": "currentSession", "visible": "future"]]])
            defaults.set(original, forKey: "popoverItemsV2")
            defaults.set(5, forKey: "popoverItemsMigrationVersion")
            let settings = makeSettings(defaults)
            XCTAssertTrue(settings.popoverItems(for: .claude).isEmpty)
            let snapshot = settings.createSnapshot()
            defaults.set("future-root", forKey: "popoverItemsV2")
            settings.restore(from: snapshot)
            XCTAssertEqual(defaults.data(forKey: "popoverItemsV2"), original)
            XCTAssertTrue(settings.popoverItems(for: .claude).isEmpty)
            settings.resetToDefaults()
            let restored = try XCTUnwrap(try root(defaults, "popoverItemsV2")["claude"] as? [[String: Any]])
            assertJSON(
                restored.first { $0["id"] as? String == "currentSession" },
                ["id": "currentSession", "visible": "future"])
            XCTAssertEqual(restored.filter { $0["id"] as? String == "currentSession" }.count, 1)
            XCTAssertFalse(settings.popoverItems(for: .claude).contains { $0.id == "currentSession" })
        }
        try withDefaults { defaults in
            defaults.set("future-root", forKey: "popoverItemsV2")
            defaults.set(5, forKey: "popoverItemsMigrationVersion")
            let settings = makeSettings(defaults)
            let snapshot = settings.createSnapshot()
            defaults.removeObject(forKey: "popoverItemsV2")
            settings.restore(from: snapshot)
            XCTAssertThrowsError(
                try settings.setDisplayItems(
                    [.init(id: "currentSession", visible: false)],
                    for: .claude, surface: .standard))
            XCTAssertEqual(defaults.string(forKey: "popoverItemsV2"), "future-root")
        }
    }

    func testCompactEditAndFlagAreCommittedTogetherWithoutCopyingOverEdit() throws {
        try withDefaults { defaults in
            let settings = makeSettings(defaults)
            let full = settings.popoverItems(for: .claude)
            var compact = full
            compact[0].visible.toggle()
            let before = defaults.data(forKey: "compactPopoverItemsV2")
            defaults.rejectedKeys = ["separateCompactConfig"]
            XCTAssertThrowsError(try settings.setDisplayItems(compact, for: .claude, surface: .compact))
            XCTAssertFalse(settings.separateCompactConfig)
            XCTAssertEqual(settings.compactPopoverItems(for: .claude), full)
            XCTAssertEqual(defaults.data(forKey: "compactPopoverItemsV2"), before)
            defaults.rejectedKeys = []
            try settings.setDisplayItems(compact, for: .claude, surface: .compact)
            XCTAssertTrue(settings.separateCompactConfig)
            XCTAssertEqual(settings.compactPopoverItems(for: .claude), compact)
            XCTAssertEqual(settings.popoverItems(for: .claude), full)
        }
    }

    func testHealthyMirrorQuarantinedByRootIDSurvivesOtherProviderEditAndMigration() throws {
        for marker in [5, 4] {
            for surface in [ProviderDisplaySurface.standard, .compact] {
                try withDefaults { defaults in
                    let rootKey = surface == .standard ? "popoverItemsV2" : "compactPopoverItemsV2"
                    let mirrorKey = surface == .standard ? "popoverItems" : "compactPopoverItems"
                    let damaged: [String: Any] = ["id": "currentSession", "visible": "future", "future": NSNull()]
                    let healthyMirror = try data([["id": "currentSession", "visible": false, "future": NSNull()]])
                    defaults.set(
                        try data(["claude": [damaged], "codex": [["id": "codexPrimary", "visible": true]]]),
                        forKey: rootKey)
                    defaults.set(healthyMirror, forKey: mirrorKey)
                    defaults.set(marker, forKey: "popoverItemsMigrationVersion")
                    defaults.set(true, forKey: "separateCompactConfig")
                    let store = PopoverDisplayPreferencesStore(defaults: defaults)
                    XCTAssertEqual(store.items(for: .claude, surface: surface).first?.id, "currentSession")
                    XCTAssertEqual(store.items(for: .claude, surface: surface).first?.visible, false)
                    XCTAssertEqual(defaults.data(forKey: mirrorKey), healthyMirror)
                    var codex = store.items(for: .codex, surface: surface)
                    let index = try XCTUnwrap(codex.firstIndex { $0.id == "codexPrimary" })
                    codex[index].visible = false
                    try store.setItems(codex, for: .codex, surface: surface)

                    XCTAssertEqual(defaults.data(forKey: mirrorKey), healthyMirror)
                    assertJSON(try root(defaults, rootKey)["claude"], [damaged])
                    XCTAssertEqual(defaults.integer(forKey: "popoverItemsMigrationVersion"), marker)
                    let restarted = PopoverDisplayPreferencesStore(defaults: defaults)
                    XCTAssertEqual(restarted.items(for: .claude, surface: surface).first?.id, "currentSession")
                    XCTAssertEqual(restarted.items(for: .claude, surface: surface).first?.visible, false)
                    XCTAssertEqual(restarted.items(for: .codex, surface: surface), codex)
                    XCTAssertEqual(defaults.data(forKey: mirrorKey), healthyMirror)
                    assertJSON(try root(defaults, rootKey)["claude"], [damaged])
                }
            }
        }
    }

    func testPartiallyMalformedMirrorReadsHealthyFalseVisibilityAndCustomOrder() throws {
        for surface in [ProviderDisplaySurface.standard, .compact] {
            try withDefaults { defaults in
                let mirrorKey = surface == .standard ? "popoverItems" : "compactPopoverItems"
                let original = try data([
                    ["id": "overageUsage", "visible": false, "future": NSNull()],
                    ["id": "currentSession", "visible": "future"],
                    ["id": "weeklyLimit", "visible": true],
                    ["id": "modelUsage", "visible": false],
                ])
                defaults.set(original, forKey: mirrorKey)
                defaults.set(5, forKey: "popoverItemsMigrationVersion")
                defaults.set(surface == .compact, forKey: "separateCompactConfig")
                let settings = makeSettings(defaults)
                let items = settings.displayItems(for: .claude, surface: surface)

                XCTAssertEqual(items.map(\.id), ["overageUsage", "weeklyLimit", "modelUsage", "claudeResetCredits"])
                XCTAssertEqual(items.first { $0.id == "overageUsage" }?.visible, false)
                XCTAssertEqual(items.first { $0.id == "modelUsage" }?.visible, false)
                XCTAssertEqual(items.first { $0.id == "weeklyLimit" }?.visible, true)
                XCTAssertFalse(items.contains { $0.id == "currentSession" })
                XCTAssertEqual(defaults.data(forKey: mirrorKey), original)
                XCTAssertEqual(
                    PopoverDisplayPreferencesStore(defaults: defaults).items(for: .claude, surface: surface), items)
                XCTAssertEqual(defaults.data(forKey: mirrorKey), original)
            }
        }
    }

    func testMarkerFourOldDefaultOrderActuallyMovesOnceOnBothSurfacesAndMirrors() throws {
        try withDefaults { defaults in
            let oldClaude = ["currentSession", "weeklyLimit", "modelUsage", "claudeResetCredits", "overageUsage"]
            let oldCodex = [
                "codexPrimary", "codexSecondary", "codexSpendLimit", "codexModelLimits", "codexResetCredits",
                "codexCredits",
            ]
            let newOrders = [
                "claude": ["currentSession", "weeklyLimit", "modelUsage", "overageUsage", "claudeResetCredits"],
                "codex": [
                    "codexPrimary", "codexSecondary", "codexModelLimits", "codexSpendLimit", "codexCredits",
                    "codexResetCredits",
                ],
            ]
            let full: [String: [PopoverItemConfig]] = [
                "claude": alternatingItems(oldClaude), "codex": alternatingItems(oldCodex),
            ]
            let compact = full.mapValues { $0.map { PopoverItemConfig(id: $0.id, visible: !$0.visible) } }
            defaults.set(try JSONEncoder().encode(full), forKey: "popoverItemsV2")
            defaults.set(try JSONEncoder().encode(compact), forKey: "compactPopoverItemsV2")
            defaults.set(4, forKey: "popoverItemsMigrationVersion")
            defaults.set(true, forKey: "separateCompactConfig")
            let store = PopoverDisplayPreferencesStore(defaults: defaults)

            XCTAssertEqual(defaults.integer(forKey: "popoverItemsMigrationVersion"), 5)
            for surface in [ProviderDisplaySurface.standard, .compact] {
                let rootKey = surface == .standard ? "popoverItemsV2" : "compactPopoverItemsV2"
                let original = surface == .standard ? full : compact
                let raw = try root(defaults, rootKey)
                XCTAssertNil(raw["orderMigrationVersion"])
                XCTAssertNil(raw["version"])
                for service in [PopoverService.claude, .codex] {
                    let provider = service.rawValue
                    let rendered = store.items(for: service, surface: surface)
                    XCTAssertEqual(rendered.map(\.id), newOrders[provider])
                    for item in original[provider] ?? [] {
                        XCTAssertEqual(rendered.first { $0.id == item.id }?.visible, item.visible)
                    }
                    let rows = try XCTUnwrap(raw[provider] as? [[String: Any]])
                    XCTAssertEqual(rows.compactMap { $0["id"] as? String }, newOrders[provider])
                    XCTAssertTrue(rows.contains { $0["orderMigrationVersion"] as? Int == 5 })
                    let mirror =
                        provider == "claude"
                        ? (surface == .standard ? "popoverItems" : "compactPopoverItems")
                        : (surface == .standard ? "codexPopoverItems" : "codexCompactPopoverItems")
                    let mirrorData = try XCTUnwrap(defaults.data(forKey: mirror))
                    let decoded = try JSONDecoder().decode([PopoverItemConfig].self, from: mirrorData)
                    XCTAssertEqual(decoded, rendered, "Existing Codable ignores the supplemental row field")
                }
            }
            let keys = [
                "popoverItemsV2", "compactPopoverItemsV2", "popoverItems", "compactPopoverItems",
                "codexPopoverItems", "codexCompactPopoverItems",
            ]
            let saved = try keys.map { try XCTUnwrap(defaults.data(forKey: $0)) }
            _ = PopoverDisplayPreferencesStore(defaults: defaults)
            for (key, bytes) in zip(keys, saved) { XCTAssertEqual(defaults.data(forKey: key), bytes) }
        }
    }

    func testPartialCodexKeepsGlobalMarkerFourButExplicitClaudeOldOrderSurvivesRestartPerSurface() throws {
        for editedSurface in [ProviderDisplaySurface.standard, .compact] {
            try withDefaults { defaults in
                let oldOrder = ["currentSession", "weeklyLimit", "modelUsage", "claudeResetCredits", "overageUsage"]
                let newOrder = ["currentSession", "weeklyLimit", "modelUsage", "overageUsage", "claudeResetCredits"]
                let old = alternatingItems(oldOrder)
                let damaged: [[String: Any]] = [["id": "codexPrimary", "visible": "future", "future": NSNull()]]
                let stored = try data([
                    "claude": old.map { item -> [String: Any] in
                        ["id": item.id, "visible": item.visible]
                    }, "codex": damaged,
                ])
                defaults.set(stored, forKey: "popoverItemsV2")
                defaults.set(stored, forKey: "compactPopoverItemsV2")
                defaults.set(4, forKey: "popoverItemsMigrationVersion")
                defaults.set(true, forKey: "separateCompactConfig")
                let store = PopoverDisplayPreferencesStore(defaults: defaults)
                XCTAssertEqual(store.items(for: .claude, surface: editedSurface).map(\.id), newOrder)
                XCTAssertEqual(defaults.integer(forKey: "popoverItemsMigrationVersion"), 4)

                try store.setItems(old, for: .claude, surface: editedSurface)

                let otherSurface: ProviderDisplaySurface = editedSurface == .standard ? .compact : .standard
                let rootKey = editedSurface == .standard ? "popoverItemsV2" : "compactPopoverItemsV2"
                let mirrorKey = editedSurface == .standard ? "popoverItems" : "compactPopoverItems"
                let raw = try root(defaults, rootKey)
                let rows = try XCTUnwrap(raw["claude"] as? [[String: Any]])
                XCTAssertEqual(rows.compactMap { $0["id"] as? String }, oldOrder)
                XCTAssertTrue(rows.contains { $0["orderMigrationVersion"] as? Int == 5 })
                assertJSON(raw["codex"], damaged)
                let mirrored = try JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: mirrorKey)))
                let mirrorRows = try XCTUnwrap(mirrored as? [[String: Any]])
                XCTAssertTrue(mirrorRows.contains { $0["orderMigrationVersion"] as? Int == 5 })
                let savedRoot = defaults.data(forKey: rootKey)
                let savedMirror = defaults.data(forKey: mirrorKey)
                for _ in 0..<2 {
                    let restarted = PopoverDisplayPreferencesStore(defaults: defaults)
                    XCTAssertEqual(restarted.items(for: .claude, surface: editedSurface), old)
                    XCTAssertEqual(restarted.items(for: .claude, surface: otherSurface).map(\.id), newOrder)
                    XCTAssertEqual(defaults.integer(forKey: "popoverItemsMigrationVersion"), 4)
                    XCTAssertEqual(defaults.data(forKey: rootKey), savedRoot)
                    XCTAssertEqual(defaults.data(forKey: mirrorKey), savedMirror)
                    assertJSON(try root(defaults, rootKey)["codex"], damaged)
                }
            }
        }
    }

    func testBlockedAdoptCurrentMenuBarCannotAutomaticallyChooseWebAndControlsRemainValid() async throws {
        let cases: [(chosen: Any, adopt: Bool)] = [("future", true), (false, true), (false, false)]
        for fixture in cases {
            let suite = "ReviewStoragePreservationTests.adopt.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(StorageReviewDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let original = try data([
                "services": ["claude": ["isMenuBarAccountChosen": fixture.chosen]],
                "order": ["claude:defaultLogin:fixture-cli", "claude:web:fixture-web"],
            ])
            defaults.set(original, forKey: UsageAccountPreferences.key)
            let provider = StorageReviewMenuBarProvider()
            provider.forbidsShow = fixture.adopt
            let controller = UsageAccountsController(
                providers: [provider], defaults: defaults,
                recoveryCoordinator: .isolated(), adoptsCurrentMenuBarAccount: fixture.adopt,
                notifyAccountChange: { _, _ in XCTFail("Storage fixture must not notify account changes") },
                isServiceEnabled: { _ in true })
            defer { controller.stop() }

            await controller.discoverAndWait()
            await Task.yield()

            XCTAssertEqual(controller.accounts[.claude]?.count, 2)
            if fixture.chosen is String {
                XCTAssertFalse(controller.preferences[.claude].isMenuBarAccountChosen)
                XCTAssertEqual(defaults.data(forKey: UsageAccountPreferences.key), original)
                XCTAssertEqual(provider.currentTarget, "fixture-cli")
                XCTAssertEqual(provider.defaultChoiceCalls, 0)
                XCTAssertTrue(provider.shownTargets.isEmpty)
                await controller.discoverAndWait()
                XCTAssertEqual(provider.defaultChoiceCalls, 0)
                XCTAssertEqual(provider.currentTarget, "fixture-cli")
                XCTAssertEqual(defaults.data(forKey: UsageAccountPreferences.key), original)
            } else if fixture.adopt {
                XCTAssertTrue(controller.preferences[.claude].isMenuBarAccountChosen)
                XCTAssertTrue(UsageAccountPreferences.load(from: defaults)[.claude].isMenuBarAccountChosen)
                XCTAssertEqual(provider.currentTarget, "fixture-cli")
                XCTAssertEqual(provider.defaultChoiceCalls, 0)
                XCTAssertTrue(provider.shownTargets.isEmpty)
            } else {
                let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                while provider.shownTargets.isEmpty, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertFalse(controller.preferences[.claude].isMenuBarAccountChosen)
                XCTAssertEqual(provider.defaultChoiceCalls, 1)
                XCTAssertEqual(provider.shownTargets, ["fixture-web"])
                XCTAssertEqual(provider.currentTarget, "fixture-web")
            }
        }
    }

    private func alternatingItems(_ ids: [String]) -> [PopoverItemConfig] {
        ids.enumerated().map { .init(id: $0.element, visible: $0.offset.isMultiple(of: 2)) }
    }

    private func makeSettings(_ defaults: UserDefaults) -> AppSettings {
        AppSettings(
            defaults: defaults, hasExistingAccountStorage: false,
            launchAtLoginController: LaunchAtLoginController(service: StorageReviewLoginItemService()))
    }

    private func makeController(_ defaults: UserDefaults) -> UsageAccountsController {
        UsageAccountsController(
            providers: [], defaults: defaults, recoveryCoordinator: .isolated(),
            notifyAccountChange: { _, _ in XCTFail("Storage fixture must not notify account changes") },
            isServiceEnabled: { _ in true })
    }

    private func runtimeCandidate() -> UsageAccountCandidate {
        .init(
            source: .init(role: .defaultLogin, reference: "/fixture/never-read/default-login"),
            identity: .init(accountID: "fixture-owner", organizationID: "fixture-team"))
    }

    private func claudeLimits() -> [UsageLimit] {
        UsageLimitCatalog.claude(
            .init(
                fiveHour: .init(utilization: 20, resetsAt: nil),
                sevenDay: .init(utilization: 40, resetsAt: nil)))
    }

    private func withDefaults(_ body: (StorageReviewDefaults) throws -> Void) throws {
        let suite = "ReviewStoragePreservationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(StorageReviewDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    }

    private func root(_ defaults: UserDefaults, _ key: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [String: Any])
    }

    private func assertJSON(_ actual: Any?, _ expected: Any?, file: StaticString = #filePath, line: UInt = #line) {
        assertObject(actual, expected, file: file, line: line)
    }

    private func assertObject(_ actual: Any?, _ expected: Any?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(PreferencePersistenceContext.equal(actual, expected), file: file, line: line)
    }

    private func assertBlocked(_ result: PreferenceSaveResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .blocked = result else { XCTFail("Expected blocked, got \(result)", file: file, line: line); return }
    }

    private func assertFailed(_ result: PreferenceSaveResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failed = result else { XCTFail("Expected failed, got \(result)", file: file, line: line); return }
    }
}

private final class StorageReviewDefaults: UserDefaults, @unchecked Sendable {
    nonisolated(unsafe) var rejectedKeys: Set<String> = []

    override func set(_ value: Any?, forKey defaultName: String) {
        guard !rejectedKeys.contains(defaultName) else { return }
        super.set(value, forKey: defaultName)
    }

    override func set(_ value: Int, forKey defaultName: String) {
        guard !rejectedKeys.contains(defaultName) else { return }
        super.set(value, forKey: defaultName)
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        guard !rejectedKeys.contains(defaultName) else { return }
        super.set(value, forKey: defaultName)
    }
}

@MainActor
private struct StorageReviewLoginItemService: LoginItemManaging {
    var status: LoginItemStatus { .notRegistered }
    func register() throws { XCTFail("Storage fixture must not register a login item") }
    func unregister() throws { XCTFail("Storage fixture must not unregister a login item") }
    func openSystemSettings() { XCTFail("Storage fixture must not open system settings") }
}

private final class StorageReviewNotificationDeliverer: NotificationDelivering {
    private(set) var deliveredCount = 0
    func requestPermission() { XCTFail("Storage fixture must not request notification permission") }
    func deliver(title: String, body: String) { deliveredCount += 1 }
}

@MainActor
private final class StorageReviewMenuBarProvider: UsageAccountProvider, UsageAccountMenuBarPolicy {
    let service: PopoverService = .claude
    let cliName = "Fixture"
    let configDirectoryVariable = "FIXTURE_HOME"
    let addMethods: [UsageAccountAddMethod] = []
    let managedDirectoryRoot: URL? = nil
    var menuBar: (any UsageAccountMenuBarPolicy)? { self }
    private(set) var currentTarget: String? = "fixture-cli"
    private(set) var defaultChoiceCalls = 0
    private(set) var shownTargets: [String] = []
    var forbidsShow = false

    func discoveryInput(directories: [String], knownIdentities: [String: UsageAccountIdentity])
        -> UsageAccountDiscoveryInput
    {
        .init(
            directories: [],
            webLogins: [
                .init(id: "fixture-cli", identity: .init()),
                .init(id: "fixture-web", identity: .init()),
            ])
    }

    nonisolated func candidates(_ input: UsageAccountDiscoveryInput) async -> [UsageAccountCandidate] {
        input.webLogins.map {
            .init(
                source: .init(
                    role: $0.id == "fixture-cli" ? .defaultLogin : .web,
                    reference: $0.id), identity: $0.identity)
        }
    }

    func badgeHelp(for role: UsageAccountSource.Role) -> String { "Fixture" }
    func isRuntime(_ account: UsageAccount) -> Bool { account.sources.contains { $0.reference == currentTarget } }
    func runtimeUsage(from snapshot: RuntimeProviderSnapshot) -> UsageAccountUsage? { nil }
    func fetchUsage(for account: UsageAccount, interactive: Bool) async throws -> UsageAccountFetchResult {
        XCTFail("Storage fixture must not fetch usage")
        throw UsageAccountFetchError.unavailable
    }
    func validateFetchBinding(_ binding: UsageAccountFetchBinding) async throws {
        XCTFail("Storage fixture must not validate a credential")
        throw UsageAccountFetchError.unavailable
    }
    func canSwitch(to account: UsageAccount) -> Bool { false }
    func switchPlan(for account: UsageAccount, name: String) -> UsageAccountSwitchPlan {
        .init(message: "Fixture", confirmTitle: "Fixture", terminatesRunningApps: false)
    }
    func switchDefault(to account: UsageAccount, plan: UsageAccountSwitchPlan) async throws {
        XCTFail("Storage fixture must not switch login")
    }
    func target(for account: UsageAccount) -> String? { account.sources.first?.reference }
    func show(_ target: String) {
        if forbidsShow { XCTFail("A rejected or adopted current menu bar must not choose another account") }
        shownTargets.append(target)
        currentTarget = target
    }
    func defaultChoice(among visible: [UsageAccount]) -> UsageAccountMenuBarDefault? {
        defaultChoiceCalls += 1
        guard let web = visible.first(where: { $0.source(.web) != nil }) else { return nil }
        return .init(preferred: .init(account: web, origin: "Fixture"), alternative: nil)
    }
    func replacement(among visible: [UsageAccount]) -> UsageAccount? { visible.first }
}
