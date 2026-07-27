import Foundation
import XCTest
@testable import ClaudeUsage

final class AntigravitySettingsStoreTests: XCTestCase {
    func testLoadReportsMissingConnectionInsteadOfCreatingDefaults() async {
        let persistence = SettingsPersistenceDouble()
        let store = AntigravitySettingsStore(persistence: persistence)

        await XCTAssertThrowsErrorAsync(try await store.load()) { error in
            XCTAssertEqual(
                error as? AntigravitySettingsStoreError,
                .missing(.connection)
            )
        }
        XCTAssertTrue(persistence.writes.isEmpty)
    }

    func testLoadReportsInvalidStoredTypeAndDoesNotMutateIt() async {
        let persistence = SettingsPersistenceDouble()
        persistence.values[
            AntigravitySettingsMigrationKeys.connectionSettings
        ] = .invalidType
        let store = AntigravitySettingsStore(persistence: persistence)

        await XCTAssertThrowsErrorAsync(try await store.load()) { error in
            XCTAssertEqual(
                error as? AntigravitySettingsStoreError,
                .invalid(.connection)
            )
        }
        XCTAssertTrue(persistence.writes.isEmpty)
        XCTAssertEqual(
            persistence.values[
                AntigravitySettingsMigrationKeys.connectionSettings
            ],
            .invalidType
        )
    }

    func testLoadRejectsUnsupportedSchemaWithoutFallingBackToDefaults() async throws {
        let persistence = SettingsPersistenceDouble()
        var invalidConnection = AntigravityConnectionSettings.default
        invalidConnection = AntigravityConnectionSettings(
            schemaVersion:
                AntigravityConnectionSettings.currentSchemaVersion + 1,
            sourcePolicy: invalidConnection.sourcePolicy,
            allowManagedCLI: invalidConnection.allowManagedCLI,
            managedSession: invalidConnection.managedSession
        )
        persistence.seed(
            connection: invalidConnection,
            display: .default
        )
        let store = AntigravitySettingsStore(persistence: persistence)

        await XCTAssertThrowsErrorAsync(try await store.load()) { error in
            XCTAssertEqual(
                error as? AntigravitySettingsStoreError,
                .invalid(.connection)
            )
        }
        XCTAssertTrue(persistence.writes.isEmpty)
    }

    func testSaveConnectionWritesAndReadsBackTypedValue() async throws {
        let persistence = SettingsPersistenceDouble()
        persistence.seed(connection: .default, display: .default)
        let store = AntigravitySettingsStore(persistence: persistence)
        var changed = AntigravityConnectionSettings.default
        changed.sourcePolicy = .localSession
        changed.allowManagedCLI = true

        let saved = try await store.saveConnection(changed)
        let loaded = try await store.load()

        XCTAssertEqual(saved, changed)
        XCTAssertEqual(loaded.connection, changed)
        XCTAssertEqual(loaded.display, .default)
        XCTAssertEqual(
            persistence.writes,
            [AntigravitySettingsMigrationKeys.connectionSettings]
        )
    }

    func testSaveSnapshotRollsBackBothKeysWhenSecondReadbackFails() async throws {
        let persistence = SettingsPersistenceDouble()
        let original = AntigravitySettingsSnapshot(
            connection: .default,
            display: .default
        )
        persistence.seed(
            connection: original.connection,
            display: original.display
        )
        persistence.corruptReadbackAfterNextWrite.insert(
            AntigravitySettingsMigrationKeys.displaySettings
        )
        let store = AntigravitySettingsStore(persistence: persistence)
        var changedConnection = original.connection
        changedConnection.sourcePolicy = .googleAccount
        var changedDisplay = original.display
        changedDisplay.notifications.isEnabled = true

        await XCTAssertThrowsErrorAsync(
            try await store.save(
                AntigravitySettingsSnapshot(
                    connection: changedConnection,
                    display: changedDisplay
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? AntigravitySettingsStoreError,
                .writeVerificationFailed(
                    .display,
                    rollbackCompleted: true
                )
            )
        }

        let restored = try await store.load()
        XCTAssertEqual(restored, original)
        XCTAssertEqual(
            persistence.writes,
            [
                AntigravitySettingsMigrationKeys.connectionSettings,
                AntigravitySettingsMigrationKeys.displaySettings,
                AntigravitySettingsMigrationKeys.connectionSettings,
                AntigravitySettingsMigrationKeys.displaySettings,
            ]
        )
    }

    func testSaveRejectsInvalidInputBeforeWriting() async {
        let persistence = SettingsPersistenceDouble()
        persistence.seed(connection: .default, display: .default)
        let store = AntigravitySettingsStore(persistence: persistence)
        let invalid = AntigravityConnectionSettings(
            schemaVersion:
                AntigravityConnectionSettings.currentSchemaVersion,
            sourcePolicy: .automatic,
            allowManagedCLI: true,
            managedSession: .init(idleTimeoutSeconds: 0)
        )

        await XCTAssertThrowsErrorAsync(
            try await store.saveConnection(invalid)
        ) { error in
            XCTAssertEqual(
                error as? AntigravitySettingsStoreError,
                .invalidValue(.connection)
            )
        }
        XCTAssertTrue(persistence.writes.isEmpty)
    }

    func testSaveReportsIntegrityRecoveryFailureWhenRollbackCannotBeVerified() async {
        let persistence = SettingsPersistenceDouble()
        persistence.seed(connection: .default, display: .default)
        persistence.corruptReadbackAfterNextWrite.insert(
            AntigravitySettingsMigrationKeys.displaySettings
        )
        // New connection, new display, then the first rollback write.
        persistence.failingWriteAttempts = [3]
        let store = AntigravitySettingsStore(persistence: persistence)
        var changedConnection = AntigravityConnectionSettings.default
        changedConnection.sourcePolicy = .googleAccount
        var changedDisplay = AntigravityDisplaySettings.default
        changedDisplay.notifications.isEnabled = true

        await XCTAssertThrowsErrorAsync(
            try await store.save(
                AntigravitySettingsSnapshot(
                    connection: changedConnection,
                    display: changedDisplay
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? AntigravitySettingsStoreError,
                .writeVerificationFailed(
                    .display,
                    rollbackCompleted: false
                )
            )
        }
    }

    func testConsumePendingNoticeClearsItWithVerifiedWrite() async throws {
        let persistence = SettingsPersistenceDouble()
        var display = AntigravityDisplaySettings.default
        display.pendingNotice = .displaySelectionUpdated
        persistence.seed(connection: .default, display: display)
        let store = AntigravitySettingsStore(persistence: persistence)

        let first = try await store.consumePendingNotice()
        let second = try await store.consumePendingNotice()

        XCTAssertEqual(first, .displaySelectionUpdated)
        XCTAssertNil(second)
        let loaded = try await store.load()
        XCTAssertNil(loaded.display.pendingNotice)
        XCTAssertEqual(
            persistence.writes,
            [AntigravitySettingsMigrationKeys.displaySettings]
        )
    }
}

private final class SettingsPersistenceDouble:
    AntigravitySettingsDataPersisting,
    @unchecked Sendable
{
    var values: [String: AntigravitySettingsStoredData] = [:]
    var writes: [String] = []
    var corruptReadbackAfterNextWrite: Set<String> = []
    var failingWriteAttempts: Set<Int> = []
    private var pendingCorruptReadback: Set<String> = []
    private var writeAttempt = 0

    nonisolated func storedData(
        forKey key: String
    ) -> AntigravitySettingsStoredData {
        if pendingCorruptReadback.remove(key) != nil {
            return .data(Data("corrupt".utf8))
        }
        return values[key] ?? .missing
    }

    nonisolated func setData(_ data: Data, forKey key: String) throws {
        writeAttempt += 1
        writes.append(key)
        if failingWriteAttempts.contains(writeAttempt) {
            throw SettingsPersistenceDoubleError.injectedFailure
        }
        values[key] = .data(data)
        if corruptReadbackAfterNextWrite.remove(key) != nil {
            pendingCorruptReadback.insert(key)
        }
    }

    func seed(
        connection: AntigravityConnectionSettings,
        display: AntigravityDisplaySettings
    ) {
        let encoder = JSONEncoder()
        values[AntigravitySettingsMigrationKeys.connectionSettings] =
            .data(try! encoder.encode(connection))
        values[AntigravitySettingsMigrationKeys.displaySettings] =
            .data(try! encoder.encode(display))
    }
}

private enum SettingsPersistenceDoubleError: Error {
    case injectedFailure
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
