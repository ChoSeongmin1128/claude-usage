import Foundation
import XCTest
@testable import ClaudeUsage

@MainActor
final class AntigravityDisplaySettingsV2MigrationTests:
    XCTestCase
{
    func testAutomaticV1MigratesToAllVisibleMostConstrainedOrdering() throws {
        let store = try seededStore(
            compact: .automaticMostConstrained
        )
        seedGenericPopoverState(in: store)

        let outcome =
            AntigravitySettingsMigrationCoordinator(
                store: store
            )
            .migrate()

        XCTAssertEqual(
            outcome,
            .migrated(
                pendingNotice:
                    .displaySelectionUpdated
            )
        )
        let display = try decodedDisplay(in: store)
        XCTAssertEqual(
            display.schemaVersion,
            AntigravityDisplaySettings
                .currentSchemaVersion
        )
        XCTAssertEqual(
            display.compact.orderedLaneIDs,
            AntigravityDisplaySettings.builtInLaneIDs
        )
        XCTAssertTrue(
            display.compact.hiddenLaneIDs.isEmpty
        )
        XCTAssertEqual(
            display.compact.orderingPolicy,
            .mostConstrainedFirst
        )
        XCTAssertEqual(
            store.object(
                forKey:
                    AntigravitySettingsMigrationKeys
                        .migrationVersion
            ) as? Int,
            AntigravitySettingsMigrationKeys
                .currentMigrationVersion
        )
        let generic = try decodedPopover(
            in: store,
            key:
                AntigravitySettingsMigrationKeys
                    .popoverItemsByProvider
        )
        XCTAssertNil(generic["antigravity"])
        XCTAssertNotNil(generic["claude"])
    }

    func testFixedV1PreservesOneVisibleLaneAndMenuPolicy() throws {
        let store = try seededStore(
            compact: .fixed(.thirdPartyWeekly)
        )

        let outcome =
            AntigravitySettingsMigrationCoordinator(
                store: store
            )
            .migrate()
        let display = try decodedDisplay(in: store)

        XCTAssertEqual(
            outcome,
            .migrated(
                pendingNotice:
                    .displaySelectionUpdated
            )
        )
        XCTAssertEqual(
            display.compact.orderedLaneIDs.first,
            .thirdPartyWeekly
        )
        XCTAssertEqual(
            Set(
                display.compact.orderedLaneIDs
                    .filter {
                        !display.compact
                            .hiddenLaneIDs
                            .contains($0)
                    }
            ),
            [.thirdPartyWeekly]
        )
        XCTAssertEqual(
            display.compact.orderingPolicy,
            .manual
        )
        XCTAssertEqual(
            display.menuBar.laneSelection,
            .fixed(.geminiWeekly)
        )
    }

    func testV1MigrationRollsBackWhenMarkerVerificationFails() throws {
        let store = try seededStore(
            compact: .automaticMostConstrained
        )
        let originalDisplay = try XCTUnwrap(
            store.object(
                forKey:
                    AntigravitySettingsMigrationKeys
                        .displaySettings
            ) as? Data
        )
        store.ignoreNextSet(
            forKey:
                AntigravitySettingsMigrationKeys
                    .migrationVersion
        )

        let outcome =
            AntigravitySettingsMigrationCoordinator(
                store: store
            )
            .migrate()

        guard case .failed(let failure) = outcome else {
            return XCTFail("migration should fail")
        }
        XCTAssertTrue(failure.rollbackCompleted)
        XCTAssertEqual(
            store.object(
                forKey:
                    AntigravitySettingsMigrationKeys
                        .displaySettings
            ) as? Data,
            originalDisplay
        )
        XCTAssertEqual(
            store.object(
                forKey:
                    AntigravitySettingsMigrationKeys
                        .migrationVersion
            ) as? Int,
            2
        )
    }

    private func seededStore(
        compact:
            AntigravityDisplaySettings
                .SingleLaneSelectionPolicy
    ) throws -> DisplayMigrationStoreDouble {
        let store = DisplayMigrationStoreDouble()
        store.set(
            try JSONEncoder().encode(
                AntigravityConnectionSettings.default
            ),
            forKey:
                AntigravitySettingsMigrationKeys
                    .connectionSettings
        )
        let legacy = LegacyDisplaySettingsV1Fixture(
            schemaVersion: 1,
            standard: .init(
                laneSelection: "all_known"
            ),
            compact: .init(
                laneSelection: compact
            ),
            menuBar: .init(
                isVisible: true,
                showsProviderIcon: true,
                style: .none,
                laneSelection:
                    .fixed(.geminiWeekly),
                showsSelectedLanePercentage: true,
                showsSelectedLaneResetTime: false,
                timeFormat: .h24,
                showsGaugePercentage: true,
                circularValue: .usage
            ),
            notifications: .init(isEnabled: false),
            pendingNotice: nil
        )
        store.set(
            try JSONEncoder().encode(legacy),
            forKey:
                AntigravitySettingsMigrationKeys
                    .displaySettings
        )
        store.set(
            2,
            forKey:
                AntigravitySettingsMigrationKeys
                    .migrationVersion
        )
        return store
    }

    private func seedGenericPopoverState(
        in store: DisplayMigrationStoreDouble
    ) {
        let dictionary = [
            "claude": [
                PopoverItemConfig(
                    id: "weeklyLimit",
                    visible: true
                ),
            ],
            "antigravity": [
                PopoverItemConfig(
                    id: "antigravityUsageLimits",
                    visible: true
                ),
            ],
        ]
        store.set(
            try! JSONEncoder().encode(dictionary),
            forKey:
                AntigravitySettingsMigrationKeys
                    .popoverItemsByProvider
        )
    }

    private func decodedDisplay(
        in store: DisplayMigrationStoreDouble
    ) throws -> AntigravityDisplaySettings {
        let data = try XCTUnwrap(
            store.object(
                forKey:
                    AntigravitySettingsMigrationKeys
                        .displaySettings
            ) as? Data
        )
        return try JSONDecoder().decode(
            AntigravityDisplaySettings.self,
            from: data
        )
    }

    private func decodedPopover(
        in store: DisplayMigrationStoreDouble,
        key: String
    ) throws -> [String: [PopoverItemConfig]] {
        let data = try XCTUnwrap(
            store.object(forKey: key) as? Data
        )
        return try JSONDecoder().decode(
            [String: [PopoverItemConfig]].self,
            from: data
        )
    }
}

private struct LegacyDisplaySettingsV1Fixture:
    Encodable
{
    struct Standard: Encodable {
        let laneSelection: String
    }

    struct Compact: Encodable {
        let laneSelection:
            AntigravityDisplaySettings
                .SingleLaneSelectionPolicy
    }

    let schemaVersion: Int
    let standard: Standard
    let compact: Compact
    let menuBar:
        AntigravityDisplaySettings
            .MenuBarPresentationIntent
    let notifications:
        AntigravityDisplaySettings
            .NotificationPresentationIntent
    let pendingNotice:
        AntigravitySettingsMigrationNotice?
}

private final class DisplayMigrationStoreDouble:
    AntigravitySettingsMigrationStore
{
    private var values: [String: Any] = [:]
    private var ignoredSetKeys: Set<String> = []

    func object(forKey key: String) -> Any? {
        values[key]
    }

    func set(_ value: Any, forKey key: String) {
        if ignoredSetKeys.remove(key) != nil {
            return
        }
        values[key] = value
    }

    func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
    }

    func ignoreNextSet(forKey key: String) {
        ignoredSetKeys.insert(key)
    }
}
