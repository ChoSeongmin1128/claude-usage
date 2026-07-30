import XCTest
@testable import ClaudeUsage

@MainActor
final class AntigravitySettingsMigrationCoordinatorTests: XCTestCase {
    func testLegacyKeyInventoryIsExplicitAndComplete() {
        let expectedAntigravityKeys: Set<String> = [
            "antigravityUsageDataSource",
            "antigravityHiddenModelIDs",
            "antigravityMenuBarPrimaryModelID",
            "antigravityMenuBarSecondaryModelID",
            "antigravity.showIcon",
            "antigravity.alertEnabled",
            "antigravity.menuBarStyle",
            "antigravity.percentageDisplay",
            "antigravity.resetTimeDisplay",
            "antigravity.timeFormat",
            "antigravity.showBatteryPercent",
            "antigravity.circularDisplayMode",
            "antigravity.iconMetric",
            "antigravityPopoverPinned",
            "antigravityPopoverCompact",
            "antigravitySettingsLastTab",
        ]
        let expectedGeminiKeys: Set<String> = [
            "gemini.alertEnabled",
            "gemini.circularDisplayMode",
            "gemini.iconMetric",
            "gemini.menuBarStyle",
            "gemini.percentageDisplay",
            "gemini.resetTimeDisplay",
            "gemini.showBatteryPercent",
            "gemini.showIcon",
            "gemini.timeFormat",
            "geminiPopoverCompact",
            "geminiPopoverPinned",
            "geminiSettingsLastTab",
        ]

        XCTAssertEqual(
            Set(AntigravitySettingsMigrationKeys.legacyAntigravityKeys),
            expectedAntigravityKeys
        )
        XCTAssertEqual(
            Set(AntigravitySettingsMigrationKeys.removedGeminiKeys),
            expectedGeminiKeys
        )
        XCTAssertEqual(AntigravitySettingsMigrationKeys.legacyAntigravityKeys.count, 16)
        XCTAssertEqual(AntigravitySettingsMigrationKeys.removedGeminiKeys.count, 12)
        XCTAssertEqual(
            Set(AntigravitySettingsMigrationKeys.ownedMutationKeys).count,
            AntigravitySettingsMigrationKeys.ownedMutationKeys.count
        )
        XCTAssertFalse(
            AntigravitySettingsMigrationKeys.ownedMutationKeys.contains(
                "antigravityRefreshInterval"
            )
        )
        XCTAssertFalse(
            AntigravitySettingsMigrationKeys.ownedMutationKeys.contains("providerStates")
        )
        XCTAssertFalse(
            AntigravitySettingsMigrationKeys.ownedMutationKeys.contains("popoverCompact")
        )
    }

    func testAllLegacySourceKeysMigrateToAutomaticV2Settings() throws {
        let cases = [
            "auto",
            "local_ide",
            "agy_cli",
            "google_oauth",
        ]

        for legacy in cases {
            let store = InMemoryAntigravitySettingsMigrationStore()
            store.set(legacy, forKey: "antigravityUsageDataSource")

            let outcome = AntigravitySettingsMigrationCoordinator(store: store).migrate()

            XCTAssertEqual(outcome, .migrated(pendingNotice: nil), legacy)
            let connection = try connectionSettings(in: store)
            XCTAssertEqual(
                connection.schemaVersion,
                AntigravityConnectionSettings
                    .currentSchemaVersion,
                legacy
            )
            XCTAssertEqual(
                connection.managedSession.idleTimeoutSeconds,
                AntigravityConnectionSettings.ManagedSessionPolicy.defaultIdleTimeoutSeconds,
                legacy
            )
            XCTAssertNil(store.object(forKey: "antigravityUsageDataSource"))
        }
    }

    func testV1ConnectionMigratesToV2AndPreservesManagedTimeout()
        throws
    {
        for sourcePolicy in [
            "automatic",
            "local_session",
            "google_account",
        ] {
            let store =
                InMemoryAntigravitySettingsMigrationStore()
            let legacy = Data(
                """
                {"schemaVersion":1,"sourcePolicy":"\(sourcePolicy)","allowManagedCLI":false,"managedSession":{"idleTimeoutSeconds":271}}
                """.utf8
            )
            store.set(
                legacy,
                forKey:
                    AntigravitySettingsMigrationKeys
                        .connectionSettings
            )
            store.set(
                1,
                forKey:
                    AntigravitySettingsMigrationKeys
                        .migrationVersion
            )

            let outcome =
                AntigravitySettingsMigrationCoordinator(
                    store: store
                ).migrate()

            XCTAssertEqual(
                outcome,
                .migrated(pendingNotice: nil),
                sourcePolicy
            )
            let connection = try connectionSettings(
                in: store
            )
            XCTAssertEqual(
                connection.schemaVersion,
                2,
                sourcePolicy
            )
            XCTAssertEqual(
                connection.managedSession
                    .idleTimeoutSeconds,
                271,
                sourcePolicy
            )
        }
    }

    func testUserDefaultsStorePerformsVerifiedMigrationWithoutTouchingSharedKeys() throws {
        let suiteName = "ClaudeUsageTests.antigravitySettingsMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("agy_cli", forKey: "antigravityUsageDataSource")
        defaults.set(false, forKey: "antigravity.showIcon")
        defaults.set("pct_weekly", forKey: "antigravity.percentageDisplay")
        defaults.set(88.0, forKey: "antigravityRefreshInterval")
        defaults.set(Data("shared-state".utf8), forKey: "providerStates")

        let outcome = AntigravitySettingsMigrationCoordinator(defaults: defaults).migrate()

        XCTAssertEqual(
            outcome,
            .migrated(pendingNotice: .displaySelectionUpdated)
        )
        let connectionData = try XCTUnwrap(
            defaults.data(forKey: AntigravitySettingsMigrationKeys.connectionSettings)
        )
        let connection = try JSONDecoder().decode(
            AntigravityConnectionSettings.self,
            from: connectionData
        )
        XCTAssertEqual(connection.schemaVersion, 2)
        XCTAssertNil(defaults.object(forKey: "antigravityUsageDataSource"))
        XCTAssertNil(defaults.object(forKey: "antigravity.showIcon"))
        XCTAssertNil(defaults.object(forKey: "antigravity.percentageDisplay"))
        XCTAssertEqual(defaults.double(forKey: "antigravityRefreshInterval"), 88)
        XCTAssertEqual(defaults.data(forKey: "providerStates"), Data("shared-state".utf8))
        XCTAssertEqual(
            defaults.integer(forKey: AntigravitySettingsMigrationKeys.migrationVersion),
            AntigravitySettingsMigrationKeys.currentMigrationVersion
        )
    }

    func testSuccessfulMigrationPreservesSemanticIntentAndCleansEveryLegacyKey() throws {
        let store = InMemoryAntigravitySettingsMigrationStore()
        seedAllLegacySettings(in: store)

        let fullOtherProviders: [String: [PopoverItemConfig]] = [
            "claude": [
                PopoverItemConfig(id: "weeklyLimit", visible: false),
                PopoverItemConfig(id: "currentSession", visible: true),
            ],
            "codex": [
                PopoverItemConfig(id: "codexWeeklyLimit", visible: true),
            ],
            "future-provider": [
                PopoverItemConfig(id: "futureItem", visible: false),
            ],
        ]
        var fullPopover = fullOtherProviders
        fullPopover["antigravity"] = [
            PopoverItemConfig(id: "antigravityAccount", visible: true),
            PopoverItemConfig(id: "antigravityPrimary", visible: false),
            PopoverItemConfig(id: "antigravityModels", visible: true),
            PopoverItemConfig(id: "antigravityCustom", visible: false),
        ]
        let compactPopover: [String: [PopoverItemConfig]] = [
            "claude": [
                PopoverItemConfig(id: "weeklyLimit", visible: true),
            ],
            "antigravity": [
                PopoverItemConfig(id: "antigravityTertiary", visible: false),
                PopoverItemConfig(id: "antigravityAccount", visible: true),
            ],
        ]
        store.set(
            try JSONEncoder().encode(fullPopover),
            forKey: AntigravitySettingsMigrationKeys.popoverItemsByProvider
        )
        store.set(
            try JSONEncoder().encode(compactPopover),
            forKey: AntigravitySettingsMigrationKeys.compactPopoverItemsByProvider
        )

        let sharedValues: [String: Any] = [
            "providerStates": Data("provider-state-sentinel".utf8),
            "providerOrder": ["codex", "antigravity", "claude"],
            "menuBarActiveService": "antigravity",
            "popoverCompact": true,
            "separateCompactConfig": true,
            "additionalRuntimeProvidersEnabled": true,
            "autoRefresh": false,
            "notificationsEnabled": true,
            "reducedRefreshOnBattery": false,
            "antigravityRefreshInterval": 75.0,
            "antigravityActiveAccountID": "account-sentinel",
            "unrelated.setting": "do-not-touch",
        ]
        for (key, value) in sharedValues {
            store.set(value, forKey: key)
        }
        let sharedSnapshot = snapshot(store, keys: Array(sharedValues.keys))

        let outcome = AntigravitySettingsMigrationCoordinator(store: store).migrate()

        XCTAssertEqual(
            outcome,
            .migrated(pendingNotice: .displaySelectionUpdated)
        )

        let connection = try connectionSettings(in: store)
        XCTAssertEqual(connection.schemaVersion, 2)
        XCTAssertEqual(connection.managedSession.idleTimeoutSeconds, 180)

        let display = try displaySettings(in: store)
        XCTAssertEqual(
            display.standard,
            AntigravityDisplaySettings.default.standard
        )
        XCTAssertEqual(
            display.compact,
            AntigravityDisplaySettings.default.compact
        )
        XCTAssertEqual(display.menuBar.laneSelection, .automaticMostConstrained)
        XCTAssertTrue(display.menuBar.isVisible)
        XCTAssertFalse(display.menuBar.showsProviderIcon)
        XCTAssertEqual(display.menuBar.style, .circular)
        XCTAssertTrue(display.menuBar.showsSelectedLanePercentage)
        XCTAssertTrue(display.menuBar.showsSelectedLaneResetTime)
        XCTAssertEqual(display.menuBar.timeFormat, .h12)
        XCTAssertFalse(display.menuBar.showsGaugePercentage)
        XCTAssertEqual(display.menuBar.circularValue, .remaining)
        XCTAssertTrue(display.notifications.isEnabled)
        XCTAssertEqual(display.pendingNotice, .displaySelectionUpdated)

        for key in AntigravitySettingsMigrationKeys.legacyKeys {
            XCTAssertNil(store.object(forKey: key), key)
        }
        XCTAssertEqual(
            store.object(forKey: AntigravitySettingsMigrationKeys.migrationVersion) as? Int,
            AntigravitySettingsMigrationKeys.currentMigrationVersion
        )

        let migratedFull = try popoverDictionary(
            in: store,
            key: AntigravitySettingsMigrationKeys.popoverItemsByProvider
        )
        XCTAssertEqual(migratedFull["claude"], fullOtherProviders["claude"])
        XCTAssertEqual(migratedFull["codex"], fullOtherProviders["codex"])
        XCTAssertEqual(
            migratedFull["future-provider"],
            fullOtherProviders["future-provider"]
        )
        XCTAssertNil(migratedFull["antigravity"])

        let migratedCompact = try popoverDictionary(
            in: store,
            key: AntigravitySettingsMigrationKeys.compactPopoverItemsByProvider
        )
        XCTAssertEqual(migratedCompact["claude"], compactPopover["claude"])
        XCTAssertNil(migratedCompact["antigravity"])

        try assertSnapshot(sharedSnapshot, matches: store)

        let encodedDisplay = try XCTUnwrap(
            store.object(forKey: AntigravitySettingsMigrationKeys.displaySettings) as? Data
        )
        let encodedText = String(decoding: encodedDisplay, as: UTF8.self)
        XCTAssertFalse(encodedText.contains("gemini-3.1-pro-low"))
        XCTAssertFalse(encodedText.contains("claude-sonnet-4.6-thinking"))
        XCTAssertFalse(encodedText.contains("weekly-model-slot"))
    }

    func testPopoverMigrationMergesExistingUsageLimitsWithoutChangingOtherProviders() throws {
        let store = InMemoryAntigravitySettingsMigrationStore()
        let original: [String: [PopoverItemConfig]] = [
            "claude": [
                PopoverItemConfig(id: "weeklyLimit", visible: false),
            ],
            "codex": [
                PopoverItemConfig(id: "codexWeeklyLimit", visible: true),
            ],
            "antigravity": [
                PopoverItemConfig(id: "antigravityAccount", visible: false),
                PopoverItemConfig(id: "antigravityPrimary", visible: false),
                PopoverItemConfig(id: "antigravityCustom", visible: true),
                PopoverItemConfig(id: "antigravityUsageLimits", visible: false),
                PopoverItemConfig(id: "antigravitySecondary", visible: true),
            ],
        ]
        store.set(
            try JSONEncoder().encode(original),
            forKey: AntigravitySettingsMigrationKeys.popoverItemsByProvider
        )

        let outcome = AntigravitySettingsMigrationCoordinator(store: store).migrate()

        XCTAssertEqual(
            outcome,
            .migrated(pendingNotice: .displaySelectionUpdated)
        )
        let migrated = try popoverDictionary(
            in: store,
            key: AntigravitySettingsMigrationKeys.popoverItemsByProvider
        )
        XCTAssertEqual(migrated["claude"], original["claude"])
        XCTAssertEqual(migrated["codex"], original["codex"])
        XCTAssertNil(migrated["antigravity"])
    }

    func testMenuBarVisibilityPreservesPercentageAndResetIntent() throws {
        struct Case {
            let percentage: String
            let reset: String
            let expectedVisible: Bool
            let expectedPercentage: Bool
            let expectedReset: Bool
        }
        let cases = [
            Case(
                percentage: "pct_weekly",
                reset: "none",
                expectedVisible: true,
                expectedPercentage: true,
                expectedReset: false
            ),
            Case(
                percentage: "pct_none",
                reset: "weekly",
                expectedVisible: true,
                expectedPercentage: false,
                expectedReset: true
            ),
            Case(
                percentage: "pct_none",
                reset: "none",
                expectedVisible: false,
                expectedPercentage: false,
                expectedReset: false
            ),
        ]

        for item in cases {
            let store = InMemoryAntigravitySettingsMigrationStore()
            store.set(false, forKey: "antigravity.showIcon")
            store.set("none", forKey: "antigravity.menuBarStyle")
            store.set(item.percentage, forKey: "antigravity.percentageDisplay")
            store.set(item.reset, forKey: "antigravity.resetTimeDisplay")

            _ = AntigravitySettingsMigrationCoordinator(store: store).migrate()
            let display = try displaySettings(in: store)

            XCTAssertEqual(display.menuBar.isVisible, item.expectedVisible)
            XCTAssertEqual(
                display.menuBar.showsSelectedLanePercentage,
                item.expectedPercentage
            )
            XCTAssertEqual(
                display.menuBar.showsSelectedLaneResetTime,
                item.expectedReset
            )
        }
    }

    func testLegacyMenuBarStylesMapToSingleLaneStyles() throws {
        struct Case {
            let legacy: String
            let expected: AntigravityDisplaySettings.MenuBarPresentationIntent.Style
            let resetsSelection: Bool
        }
        let cases = [
            Case(legacy: "none", expected: .none, resetsSelection: false),
            Case(legacy: "battery_bar", expected: .batteryBar, resetsSelection: false),
            Case(legacy: "circular", expected: .circular, resetsSelection: false),
            Case(legacy: "concentric_rings", expected: .circular, resetsSelection: true),
            Case(legacy: "dual_battery", expected: .batteryBar, resetsSelection: true),
            Case(legacy: "side_by_side_battery", expected: .batteryBar, resetsSelection: true),
        ]

        for item in cases {
            let store = InMemoryAntigravitySettingsMigrationStore()
            store.set(false, forKey: "antigravity.showIcon")
            store.set("pct_none", forKey: "antigravity.percentageDisplay")
            store.set("none", forKey: "antigravity.resetTimeDisplay")
            store.set(item.legacy, forKey: "antigravity.menuBarStyle")

            let outcome = AntigravitySettingsMigrationCoordinator(store: store).migrate()
            let display = try displaySettings(in: store)

            XCTAssertEqual(display.menuBar.style, item.expected, item.legacy)
            XCTAssertEqual(
                display.menuBar.isVisible,
                item.expected != .none,
                item.legacy
            )
            XCTAssertEqual(
                outcome,
                .migrated(
                    pendingNotice: item.resetsSelection
                        ? .displaySelectionUpdated
                        : nil
                ),
                item.legacy
            )
        }
    }

    func testSingleLaneSelectionPoliciesRoundTripWithStableLaneIDs() throws {
        let unknownLaneID = AntigravityQuotaLaneID(
            rawValue: "unknown.\(String(repeating: "a", count: 64))"
        )
        let policies: [AntigravityDisplaySettings.SingleLaneSelectionPolicy] = [
            .automaticMostConstrained,
            .fixed(.thirdPartyWeekly),
            .fixed(unknownLaneID),
        ]

        for policy in policies {
            let data = try JSONEncoder().encode(policy)
            let decoded = try JSONDecoder().decode(
                AntigravityDisplaySettings.SingleLaneSelectionPolicy.self,
                from: data
            )
            XCTAssertEqual(decoded, policy)
            XCTAssertTrue(decoded.isValid)
        }

        let display = AntigravityDisplaySettings(
            schemaVersion: AntigravityDisplaySettings.currentSchemaVersion,
            standard:
                AntigravityDisplaySettings.default.standard,
            compact: .init(
                orderedLaneIDs: [
                    .thirdPartyWeekly,
                    .geminiFiveHour,
                    .geminiWeekly,
                    .thirdPartyFiveHour,
                ],
                hiddenLaneIDs: [
                    .geminiFiveHour,
                    .geminiWeekly,
                ],
                orderingPolicy: .manual
            ),
            menuBar: .init(
                isVisible: true,
                showsProviderIcon: true,
                style: .circular,
                laneSelection: .automaticMostConstrained,
                showsSelectedLanePercentage: true,
                showsSelectedLaneResetTime: false,
                timeFormat: .h24,
                showsGaugePercentage: true,
                circularValue: .usage
            ),
            notifications: .init(isEnabled: false),
            pendingNotice: nil
        )
        var multiLaneDisplay = display
        multiLaneDisplay.menuBar.additionalLaneIDs = [
            .geminiFiveHour,
            .geminiWeekly,
        ]
        let multiLaneData = try JSONEncoder().encode(
            multiLaneDisplay
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                AntigravityDisplaySettings.self,
                from: multiLaneData
            ),
            multiLaneDisplay
        )
        XCTAssertTrue(multiLaneDisplay.isCurrentAndValid)

        let displayData = try JSONEncoder().encode(display)

        XCTAssertEqual(
            try JSONDecoder().decode(
                AntigravityDisplaySettings.self,
                from: displayData
            ),
            display
        )
        XCTAssertTrue(display.isCurrentAndValid)
    }

    func testInvalidFixedLaneIdentifiersCannotBecomeCurrentSettings() {
        let invalidLaneIDs = [
            "",
            "gemini",
            ".weekly",
            "gemini.",
            " gemini.weekly",
            "gemini.weekly ",
            "gemini weekly",
            "gemini/weekly",
            "gemini..weekly",
            "invalid.\(String(repeating: "a", count: 249))",
        ]

        for rawLaneID in invalidLaneIDs {
            let invalidLaneID = AntigravityQuotaLaneID(rawValue: rawLaneID)

            var display = AntigravityDisplaySettings.default
            display.compact.orderedLaneIDs = [
                invalidLaneID,
            ]

            XCTAssertFalse(display.isCurrentAndValid, rawLaneID)

            display = .default
            display.menuBar.laneSelection = .fixed(invalidLaneID)

            XCTAssertFalse(display.isCurrentAndValid, rawLaneID)
            XCTAssertThrowsError(try JSONEncoder().encode(display), rawLaneID)

            let corruptPolicy = Data(
                #"{"mode":"fixed","laneID":"\#(rawLaneID)"}"#.utf8
            )
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    AntigravityDisplaySettings.SingleLaneSelectionPolicy.self,
                    from: corruptPolicy
                ),
                rawLaneID
            )
        }
    }

    func testValidCurrentSettingsWinAndSecondRunIsIdempotent() throws {
        let store = InMemoryAntigravitySettingsMigrationStore()
        let currentConnection = AntigravityConnectionSettings(
            schemaVersion: AntigravityConnectionSettings.currentSchemaVersion,
            managedSession: .init(idleTimeoutSeconds: 333)
        )
        let currentDisplay = AntigravityDisplaySettings(
            schemaVersion: AntigravityDisplaySettings.currentSchemaVersion,
            standard:
                AntigravityDisplaySettings.default.standard,
            compact: .init(
                orderedLaneIDs: [
                    .thirdPartyWeekly,
                    .geminiFiveHour,
                    .geminiWeekly,
                    .thirdPartyFiveHour,
                ],
                hiddenLaneIDs: [
                    .geminiFiveHour,
                    .geminiWeekly,
                    .thirdPartyFiveHour,
                ],
                orderingPolicy: .manual
            ),
            menuBar: .init(
                isVisible: false,
                showsProviderIcon: false,
                style: .none,
                laneSelection: .automaticMostConstrained,
                showsSelectedLanePercentage: false,
                showsSelectedLaneResetTime: false,
                timeFormat: .remaining,
                showsGaugePercentage: false,
                circularValue: .remaining
            ),
            notifications: .init(isEnabled: true),
            pendingNotice: nil
        )
        let connectionData = try JSONEncoder().encode(currentConnection)
        let displayData = try JSONEncoder().encode(currentDisplay)
        store.set(
            connectionData,
            forKey: AntigravitySettingsMigrationKeys.connectionSettings
        )
        store.set(
            displayData,
            forKey: AntigravitySettingsMigrationKeys.displaySettings
        )
        store.set("auto", forKey: "antigravityUsageDataSource")
        store.set(true, forKey: "antigravity.showIcon")
        store.set("dual_battery", forKey: "antigravity.menuBarStyle")
        store.set("legacy", forKey: "gemini.showIcon")
        store.set("preserve", forKey: "unrelated.setting")

        let first = AntigravitySettingsMigrationCoordinator(store: store).migrate()

        XCTAssertEqual(first, .migrated(pendingNotice: nil))
        XCTAssertEqual(
            store.object(forKey: AntigravitySettingsMigrationKeys.connectionSettings) as? Data,
            connectionData
        )
        XCTAssertEqual(
            store.object(forKey: AntigravitySettingsMigrationKeys.displaySettings) as? Data,
            displayData
        )
        XCTAssertEqual(try connectionSettings(in: store), currentConnection)
        XCTAssertEqual(try displaySettings(in: store), currentDisplay)
        XCTAssertNil(store.object(forKey: "antigravityUsageDataSource"))
        XCTAssertNil(store.object(forKey: "antigravity.showIcon"))
        XCTAssertNil(store.object(forKey: "antigravity.menuBarStyle"))
        XCTAssertNil(store.object(forKey: "gemini.showIcon"))
        XCTAssertEqual(store.object(forKey: "unrelated.setting") as? String, "preserve")

        let beforeSecondRun = snapshot(
            store,
            keys: Array(store.storage.keys)
        )
        let second = AntigravitySettingsMigrationCoordinator(store: store).migrate()

        XCTAssertEqual(second, .alreadyCurrent)
        try assertSnapshot(beforeSecondRun, matches: store)
    }

    func testPendingNoticeAcknowledgementPersistsAcrossCoordinatorInstances() throws {
        let store = InMemoryAntigravitySettingsMigrationStore()
        store.set(
            "claude-sonnet-4.6-thinking",
            forKey: "antigravityMenuBarPrimaryModelID"
        )

        let migrationCoordinator = AntigravitySettingsMigrationCoordinator(store: store)
        _ = migrationCoordinator.migrate()
        let displayBeforeAcknowledgement = try displaySettings(in: store)
        let notice = try XCTUnwrap(displayBeforeAcknowledgement.pendingNotice)

        let copy = [
            notice.title,
            notice.message,
        ].joined(separator: " ").lowercased()
        for internalTerm in [
            "migration",
            "마이그레이션",
            "schema",
            "slot",
            "lane",
            "model id",
            "userdefaults",
            "oauth",
            "cli",
        ] {
            XCTAssertFalse(copy.contains(internalTerm), internalTerm)
        }
        XCTAssertTrue(copy.contains("antigravity"))
        XCTAssertTrue(copy.contains("사용 한도"))

        let relaunchedCoordinator = AntigravitySettingsMigrationCoordinator(store: store)
        XCTAssertEqual(
            relaunchedCoordinator.acknowledgePendingNotice(),
            .consumed(.displaySelectionUpdated)
        )
        XCTAssertNil(try displaySettings(in: store).pendingNotice)
        XCTAssertEqual(
            store.object(forKey: AntigravitySettingsMigrationKeys.migrationVersion) as? Int,
            AntigravitySettingsMigrationKeys.currentMigrationVersion
        )

        let secondRelaunch = AntigravitySettingsMigrationCoordinator(store: store)
        XCTAssertEqual(
            secondRelaunch.acknowledgePendingNotice(),
            .noPendingNotice
        )
    }

    func testPendingNoticeAcknowledgementSilentWriteFailureKeepsNoticePending() throws {
        let store = InMemoryAntigravitySettingsMigrationStore()
        store.set(
            "claude-sonnet-4.6-thinking",
            forKey: "antigravityMenuBarPrimaryModelID"
        )
        _ = AntigravitySettingsMigrationCoordinator(store: store).migrate()
        let originalDisplayData = try XCTUnwrap(
            store.object(forKey: AntigravitySettingsMigrationKeys.displaySettings)
                as? Data
        )
        store.ignoreNextSet(
            forKey: AntigravitySettingsMigrationKeys.displaySettings
        )

        let outcome = AntigravitySettingsMigrationCoordinator(store: store)
            .acknowledgePendingNotice()

        XCTAssertEqual(
            outcome,
            .failed(
                .init(
                    reason: .writeVerificationFailed(
                        AntigravitySettingsMigrationKeys.displaySettings
                    ),
                    rollbackCompleted: true
                )
            )
        )
        XCTAssertEqual(
            store.object(forKey: AntigravitySettingsMigrationKeys.displaySettings)
                as? Data,
            originalDisplayData
        )
        XCTAssertEqual(
            try displaySettings(in: store).pendingNotice,
            .displaySelectionUpdated
        )

        XCTAssertEqual(
            AntigravitySettingsMigrationCoordinator(store: store)
                .acknowledgePendingNotice(),
            .consumed(.displaySelectionUpdated)
        )
        XCTAssertNil(try displaySettings(in: store).pendingNotice)
    }

    func testSilentSettingsAndPopoverWriteFailuresRestoreOnlyOwnedState() throws {
        let failingKeys = [
            AntigravitySettingsMigrationKeys.connectionSettings,
            AntigravitySettingsMigrationKeys.displaySettings,
            AntigravitySettingsMigrationKeys.popoverItemsByProvider,
            AntigravitySettingsMigrationKeys.compactPopoverItemsByProvider,
        ]

        for key in failingKeys {
            let store = try makeFailureFixture()
            let ownedBefore = snapshot(
                store,
                keys: AntigravitySettingsMigrationKeys.ownedMutationKeys
            )
            let unrelatedBefore = snapshot(
                store,
                keys: ["unrelated.setting", "providerStates", "antigravityRefreshInterval"]
            )
            store.ignoreNextSet(forKey: key)

            let outcome = AntigravitySettingsMigrationCoordinator(store: store).migrate()

            guard case let .failed(failure) = outcome else {
                XCTFail("\(key) write 실패가 성공으로 처리되었습니다")
                continue
            }
            XCTAssertEqual(failure.reason, .writeVerificationFailed(key), key)
            XCTAssertTrue(failure.rollbackCompleted, key)
            try assertSnapshot(ownedBefore, matches: store)
            try assertSnapshot(unrelatedBefore, matches: store)
        }
    }

    func testSilentLegacyDeleteFailureRestoresAllLegacyAndCurrentState() throws {
        let store = try makeFailureFixture()
        let before = snapshot(
            store,
            keys: AntigravitySettingsMigrationKeys.ownedMutationKeys
                + ["unrelated.setting", "providerStates", "antigravityRefreshInterval"]
        )
        let failingKey = "gemini.showIcon"
        store.ignoreNextRemove(forKey: failingKey)

        let outcome = AntigravitySettingsMigrationCoordinator(store: store).migrate()

        guard case let .failed(failure) = outcome else {
            return XCTFail("legacy delete 실패가 성공으로 처리되었습니다")
        }
        XCTAssertEqual(failure.reason, .deleteVerificationFailed(failingKey))
        XCTAssertTrue(failure.rollbackCompleted)
        try assertSnapshot(before, matches: store)
        XCTAssertNil(
            store.object(forKey: AntigravitySettingsMigrationKeys.migrationVersion)
        )
    }

    func testMarkerReadbackFailureRestoresLegacyAndPreexistingCurrentSettings() throws {
        let store = try makeFailureFixture()
        let currentConnection = AntigravityConnectionSettings(
            schemaVersion: AntigravityConnectionSettings.currentSchemaVersion,
            managedSession: .init(idleTimeoutSeconds: 444)
        )
        let currentConnectionData = try JSONEncoder().encode(currentConnection)
        store.set(
            currentConnectionData,
            forKey: AntigravitySettingsMigrationKeys.connectionSettings
        )
        let before = snapshot(
            store,
            keys: AntigravitySettingsMigrationKeys.ownedMutationKeys
                + ["unrelated.setting", "providerStates", "antigravityRefreshInterval"]
        )
        store.ignoreNextSet(
            forKey: AntigravitySettingsMigrationKeys.migrationVersion
        )

        let outcome = AntigravitySettingsMigrationCoordinator(store: store).migrate()

        guard case let .failed(failure) = outcome else {
            return XCTFail("marker readback 실패가 성공으로 처리되었습니다")
        }
        XCTAssertEqual(
            failure.reason,
            .writeVerificationFailed(
                AntigravitySettingsMigrationKeys.migrationVersion
            )
        )
        XCTAssertTrue(failure.rollbackCompleted)
        try assertSnapshot(before, matches: store)
        XCTAssertEqual(
            store.object(forKey: AntigravitySettingsMigrationKeys.connectionSettings) as? Data,
            currentConnectionData
        )
        XCTAssertNil(
            store.object(forKey: AntigravitySettingsMigrationKeys.displaySettings)
        )
        for key in AntigravitySettingsMigrationKeys.legacyKeys {
            XCTAssertNotNil(store.object(forKey: key), key)
        }
    }

    func testCorruptPopoverFailsBeforeMutationAndPreservesLegacy() throws {
        let store = InMemoryAntigravitySettingsMigrationStore()
        store.set("google_oauth", forKey: "antigravityUsageDataSource")
        store.set(
            Data("not-json".utf8),
            forKey: AntigravitySettingsMigrationKeys.popoverItemsByProvider
        )
        store.set("preserve", forKey: "unrelated.setting")
        let before = snapshot(
            store,
            keys: AntigravitySettingsMigrationKeys.ownedMutationKeys
                + ["unrelated.setting"]
        )

        let outcome = AntigravitySettingsMigrationCoordinator(store: store).migrate()

        XCTAssertEqual(
            outcome,
            .failed(
                .init(
                    reason: .invalidPopoverSettings(
                        AntigravitySettingsMigrationKeys.popoverItemsByProvider
                    ),
                    rollbackCompleted: true
                )
            )
        )
        try assertSnapshot(before, matches: store)
    }

    func testInvalidCurrentSettingsAreNeverOverwrittenByLegacyValues() throws {
        let store = InMemoryAntigravitySettingsMigrationStore()
        store.set(
            Data("invalid-current-display".utf8),
            forKey: AntigravitySettingsMigrationKeys.displaySettings
        )
        store.set(true, forKey: "antigravity.showIcon")
        let before = snapshot(
            store,
            keys: AntigravitySettingsMigrationKeys.ownedMutationKeys
        )

        let outcome = AntigravitySettingsMigrationCoordinator(store: store).migrate()

        XCTAssertEqual(
            outcome,
            .failed(
                .init(
                    reason: .invalidCurrentDisplaySettings,
                    rollbackCompleted: true
                )
            )
        )
        try assertSnapshot(before, matches: store)
    }

    private func seedAllLegacySettings(
        in store: InMemoryAntigravitySettingsMigrationStore
    ) {
        store.set("google_oauth", forKey: "antigravityUsageDataSource")
        store.set(
            try! JSONEncoder().encode(["gemini-3.1-pro-low"]),
            forKey: "antigravityHiddenModelIDs"
        )
        store.set(
            "claude-sonnet-4.6-thinking",
            forKey: "antigravityMenuBarPrimaryModelID"
        )
        store.set(
            "weekly-model-slot",
            forKey: "antigravityMenuBarSecondaryModelID"
        )
        store.set(false, forKey: "antigravity.showIcon")
        store.set(true, forKey: "antigravity.alertEnabled")
        store.set("concentric_rings", forKey: "antigravity.menuBarStyle")
        store.set("pct_weekly", forKey: "antigravity.percentageDisplay")
        store.set("weekly", forKey: "antigravity.resetTimeDisplay")
        store.set("12h", forKey: "antigravity.timeFormat")
        store.set(false, forKey: "antigravity.showBatteryPercent")
        store.set("remaining", forKey: "antigravity.circularDisplayMode")
        store.set("weekly", forKey: "antigravity.iconMetric")
        store.set(true, forKey: "antigravityPopoverPinned")
        store.set(true, forKey: "antigravityPopoverCompact")
        store.set("usage", forKey: "antigravitySettingsLastTab")

        for key in AntigravitySettingsMigrationKeys.removedGeminiKeys {
            store.set("legacy:\(key)", forKey: key)
        }
    }

    private func makeFailureFixture() throws
        -> InMemoryAntigravitySettingsMigrationStore {
        let store = InMemoryAntigravitySettingsMigrationStore()
        seedAllLegacySettings(in: store)
        let popover: [String: [PopoverItemConfig]] = [
            "claude": [
                PopoverItemConfig(id: "weeklyLimit", visible: true),
            ],
            "antigravity": [
                PopoverItemConfig(id: "antigravityPrimary", visible: true),
                PopoverItemConfig(id: "antigravityAccount", visible: false),
            ],
        ]
        store.set(
            try JSONEncoder().encode(popover),
            forKey: AntigravitySettingsMigrationKeys.popoverItemsByProvider
        )
        let compactPopover: [String: [PopoverItemConfig]] = [
            "codex": [
                PopoverItemConfig(id: "codexWeeklyLimit", visible: false),
            ],
            "antigravity": [
                PopoverItemConfig(id: "antigravitySecondary", visible: false),
                PopoverItemConfig(id: "antigravityAccount", visible: true),
            ],
        ]
        store.set(
            try JSONEncoder().encode(compactPopover),
            forKey: AntigravitySettingsMigrationKeys.compactPopoverItemsByProvider
        )
        store.set("preserve", forKey: "unrelated.setting")
        store.set(Data("provider-state".utf8), forKey: "providerStates")
        store.set(91.0, forKey: "antigravityRefreshInterval")
        return store
    }

    private func connectionSettings(
        in store: InMemoryAntigravitySettingsMigrationStore
    ) throws -> AntigravityConnectionSettings {
        let data = try XCTUnwrap(
            store.object(forKey: AntigravitySettingsMigrationKeys.connectionSettings)
                as? Data
        )
        return try JSONDecoder().decode(
            AntigravityConnectionSettings.self,
            from: data
        )
    }

    private func displaySettings(
        in store: InMemoryAntigravitySettingsMigrationStore
    ) throws -> AntigravityDisplaySettings {
        let data = try XCTUnwrap(
            store.object(forKey: AntigravitySettingsMigrationKeys.displaySettings)
                as? Data
        )
        return try JSONDecoder().decode(
            AntigravityDisplaySettings.self,
            from: data
        )
    }

    private func popoverDictionary(
        in store: InMemoryAntigravitySettingsMigrationStore,
        key: String
    ) throws -> [String: [PopoverItemConfig]] {
        let data = try XCTUnwrap(store.object(forKey: key) as? Data)
        return try JSONDecoder().decode(
            [String: [PopoverItemConfig]].self,
            from: data
        )
    }

    private func snapshot(
        _ store: InMemoryAntigravitySettingsMigrationStore,
        keys: [String]
    ) -> [String: TestStoredValue] {
        Dictionary(uniqueKeysWithValues: Set(keys).map { key in
            if let object = store.object(forKey: key) as? NSObject {
                return (key, .present(object))
            }
            return (key, .absent)
        })
    }

    private func assertSnapshot(
        _ snapshot: [String: TestStoredValue],
        matches store: InMemoryAntigravitySettingsMigrationStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for (key, expected) in snapshot {
            switch expected {
            case .absent:
                XCTAssertNil(store.object(forKey: key), key, file: file, line: line)
            case let .present(expectedObject):
                let actual = try XCTUnwrap(
                    store.object(forKey: key) as? NSObject,
                    key,
                    file: file,
                    line: line
                )
                XCTAssertTrue(
                    actual.isEqual(expectedObject),
                    key,
                    file: file,
                    line: line
                )
            }
        }
    }
}

private enum TestStoredValue {
    case absent
    case present(NSObject)
}

@MainActor
private final class InMemoryAntigravitySettingsMigrationStore:
    AntigravitySettingsMigrationStore {
    fileprivate var storage: [String: Any] = [:]
    private var ignoredSetKeysOnce: Set<String> = []
    private var ignoredRemoveKeysOnce: Set<String> = []

    func object(forKey key: String) -> Any? {
        storage[key]
    }

    func set(_ value: Any, forKey key: String) {
        if ignoredSetKeysOnce.remove(key) != nil {
            return
        }
        storage[key] = value
    }

    func removeObject(forKey key: String) {
        if ignoredRemoveKeysOnce.remove(key) != nil {
            return
        }
        storage.removeValue(forKey: key)
    }

    func ignoreNextSet(forKey key: String) {
        ignoredSetKeysOnce.insert(key)
    }

    func ignoreNextRemove(forKey key: String) {
        ignoredRemoveKeysOnce.insert(key)
    }
}
