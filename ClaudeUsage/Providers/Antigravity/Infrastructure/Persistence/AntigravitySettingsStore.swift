// Authoritative typed persistence for Antigravity settings.
import Foundation

nonisolated struct AntigravitySettingsSnapshot: Equatable, Sendable {
    var connection: AntigravityConnectionSettings
    var display: AntigravityDisplaySettings
}

nonisolated enum AntigravitySettingsKind: String, Equatable, Sendable {
    case connection
    case display
}

nonisolated enum AntigravitySettingsStoreError: Error, Equatable, Sendable {
    case missing(AntigravitySettingsKind)
    case invalid(AntigravitySettingsKind)
    case invalidValue(AntigravitySettingsKind)
    case encodingFailed(AntigravitySettingsKind)
    case persistenceFailed(
        AntigravitySettingsKind,
        rollbackCompleted: Bool
    )
    case writeVerificationFailed(
        AntigravitySettingsKind,
        rollbackCompleted: Bool
    )
}

nonisolated protocol AntigravitySettingsStoring: Sendable {
    func load() async throws -> AntigravitySettingsSnapshot

    @discardableResult
    func saveConnection(
        _ connection: AntigravityConnectionSettings
    ) async throws -> AntigravityConnectionSettings

    @discardableResult
    func saveDisplay(
        _ display: AntigravityDisplaySettings
    ) async throws -> AntigravityDisplaySettings

    @discardableResult
    func save(
        _ snapshot: AntigravitySettingsSnapshot
    ) async throws -> AntigravitySettingsSnapshot

    func consumePendingNotice() async throws
        -> AntigravitySettingsMigrationNotice?
}

nonisolated enum AntigravitySettingsStoredData: Equatable, Sendable {
    case missing
    case data(Data)
    case invalidType
}

nonisolated protocol AntigravitySettingsDataPersisting: Sendable {
    nonisolated func storedData(forKey key: String)
        -> AntigravitySettingsStoredData
    nonisolated func setData(_ data: Data, forKey key: String) throws
}

nonisolated final class UserDefaultsAntigravitySettingsDataPersistence:
    AntigravitySettingsDataPersisting,
    @unchecked Sendable
{
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    nonisolated func storedData(
        forKey key: String
    ) -> AntigravitySettingsStoredData {
        guard let object = defaults.object(forKey: key) else {
            return .missing
        }
        guard let data = object as? Data else {
            return .invalidType
        }
        return .data(data)
    }

    nonisolated func setData(_ data: Data, forKey key: String) throws {
        defaults.set(data, forKey: key)
    }
}

/// Typed consumer for the settings created by
/// `AntigravitySettingsMigrationCoordinator`.
///
/// This actor deliberately has no migration or legacy-key deletion behavior.
/// Missing and malformed values remain explicit errors so a normal settings
/// read cannot silently perform a partial migration or erase evidence needed
/// by the migration coordinator.
actor AntigravitySettingsStore: AntigravitySettingsStoring {
    private struct PendingWrite {
        let kind: AntigravitySettingsKind
        let key: String
        let originalData: Data
        let newData: Data
        let verify: @Sendable (Data) -> Bool
    }

    private let persistence: any AntigravitySettingsDataPersisting
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        persistence: any AntigravitySettingsDataPersisting =
            UserDefaultsAntigravitySettingsDataPersistence(),
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.persistence = persistence
        self.encoder = encoder
        self.decoder = decoder
    }

    func load() async throws -> AntigravitySettingsSnapshot {
        AntigravitySettingsSnapshot(
            connection: try loadConnection(),
            display: try loadDisplay()
        )
    }

    @discardableResult
    func saveConnection(
        _ connection: AntigravityConnectionSettings
    ) async throws -> AntigravityConnectionSettings {
        let write = try makeConnectionWrite(connection)
        try persistAtomically([write])
        return connection
    }

    @discardableResult
    func saveDisplay(
        _ display: AntigravityDisplaySettings
    ) async throws -> AntigravityDisplaySettings {
        let write = try makeDisplayWrite(display)
        try persistAtomically([write])
        return display
    }

    @discardableResult
    func save(
        _ snapshot: AntigravitySettingsSnapshot
    ) async throws -> AntigravitySettingsSnapshot {
        let writes = [
            try makeConnectionWrite(snapshot.connection),
            try makeDisplayWrite(snapshot.display),
        ]
        try persistAtomically(writes)
        return snapshot
    }

    func consumePendingNotice() async throws
        -> AntigravitySettingsMigrationNotice?
    {
        let current = try loadDisplay()
        guard let notice = current.pendingNotice else {
            return nil
        }

        var consumed = current
        consumed.pendingNotice = nil
        let write = try makeDisplayWrite(consumed)
        try persistAtomically([write])
        return notice
    }

    private func loadConnection() throws -> AntigravityConnectionSettings {
        let data = try validatedStoredData(
            kind: .connection,
            key: AntigravitySettingsMigrationKeys.connectionSettings
        )
        guard
            let value = try? decoder.decode(
                AntigravityConnectionSettings.self,
                from: data
            ),
            value.isCurrentAndValid
        else {
            throw AntigravitySettingsStoreError.invalid(.connection)
        }
        return value
    }

    private func loadDisplay() throws -> AntigravityDisplaySettings {
        let data = try validatedStoredData(
            kind: .display,
            key: AntigravitySettingsMigrationKeys.displaySettings
        )
        guard
            let value = try? decoder.decode(
                AntigravityDisplaySettings.self,
                from: data
            ),
            value.isCurrentAndValid
        else {
            throw AntigravitySettingsStoreError.invalid(.display)
        }
        return value
    }

    private func validatedStoredData(
        kind: AntigravitySettingsKind,
        key: String
    ) throws -> Data {
        switch persistence.storedData(forKey: key) {
        case .missing:
            throw AntigravitySettingsStoreError.missing(kind)
        case .invalidType:
            throw AntigravitySettingsStoreError.invalid(kind)
        case let .data(data):
            return data
        }
    }

    private func makeConnectionWrite(
        _ value: AntigravityConnectionSettings
    ) throws -> PendingWrite {
        guard value.isCurrentAndValid else {
            throw AntigravitySettingsStoreError.invalidValue(.connection)
        }
        let key = AntigravitySettingsMigrationKeys.connectionSettings
        let original = try validatedStoredData(kind: .connection, key: key)
        guard
            let current = try? decoder.decode(
                AntigravityConnectionSettings.self,
                from: original
            ),
            current.isCurrentAndValid
        else {
            throw AntigravitySettingsStoreError.invalid(.connection)
        }
        let encoded: Data
        do {
            encoded = try encoder.encode(value)
        } catch {
            throw AntigravitySettingsStoreError.encodingFailed(.connection)
        }
        return PendingWrite(
            kind: .connection,
            key: key,
            originalData: original,
            newData: encoded,
            verify: { data in
                guard
                    let stored = try? JSONDecoder().decode(
                        AntigravityConnectionSettings.self,
                        from: data
                    )
                else {
                    return false
                }
                return stored.isCurrentAndValid && stored == value
            }
        )
    }

    private func makeDisplayWrite(
        _ value: AntigravityDisplaySettings
    ) throws -> PendingWrite {
        guard value.isCurrentAndValid else {
            throw AntigravitySettingsStoreError.invalidValue(.display)
        }
        let key = AntigravitySettingsMigrationKeys.displaySettings
        let original = try validatedStoredData(kind: .display, key: key)
        guard
            let current = try? decoder.decode(
                AntigravityDisplaySettings.self,
                from: original
            ),
            current.isCurrentAndValid
        else {
            throw AntigravitySettingsStoreError.invalid(.display)
        }
        let encoded: Data
        do {
            encoded = try encoder.encode(value)
        } catch {
            throw AntigravitySettingsStoreError.encodingFailed(.display)
        }
        return PendingWrite(
            kind: .display,
            key: key,
            originalData: original,
            newData: encoded,
            verify: { data in
                guard
                    let stored = try? JSONDecoder().decode(
                        AntigravityDisplaySettings.self,
                        from: data
                    )
                else {
                    return false
                }
                return stored.isCurrentAndValid && stored == value
            }
        )
    }

    private func persistAtomically(_ writes: [PendingWrite]) throws {
        for write in writes {
            do {
                try persistence.setData(write.newData, forKey: write.key)
            } catch {
                throw AntigravitySettingsStoreError.persistenceFailed(
                    write.kind,
                    rollbackCompleted: rollback(writes)
                )
            }

            guard
                case let .data(readback) =
                    persistence.storedData(forKey: write.key),
                write.verify(readback)
            else {
                throw AntigravitySettingsStoreError.writeVerificationFailed(
                    write.kind,
                    rollbackCompleted: rollback(writes)
                )
            }
        }
    }

    private func rollback(_ writes: [PendingWrite]) -> Bool {
        var completed = true
        for write in writes {
            do {
                try persistence.setData(
                    write.originalData,
                    forKey: write.key
                )
            } catch {
                completed = false
            }
        }
        for write in writes {
            guard
                case let .data(readback) =
                    persistence.storedData(forKey: write.key),
                readback == write.originalData
            else {
                completed = false
                continue
            }
        }
        return completed
    }
}
