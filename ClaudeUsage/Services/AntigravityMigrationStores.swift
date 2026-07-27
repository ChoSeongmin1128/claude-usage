import Foundation

protocol AntigravityMigrationJournalStoring: Sendable {
    nonisolated func load() throws -> AntigravityMigrationJournal?
    nonisolated func save(_ journal: AntigravityMigrationJournal) throws
    nonisolated func delete() throws
}

protocol AntigravityMigrationCompletionMarking: Sendable {
    nonisolated func load() throws -> AntigravityMigrationCompletionMarker?
    nonisolated func save(_ marker: AntigravityMigrationCompletionMarker) throws
}

private nonisolated enum AntigravityMigrationFilePermissions {
    static let directoryMode = 0o700
    static let fileMode = 0o600

    static func save<T: Encodable>(
        _ value: T,
        to fileURL: URL,
        fileManager: FileManager
    ) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: directoryMode]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: directoryMode],
            ofItemAtPath: directory.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: fileMode],
            ofItemAtPath: fileURL.path
        )
        guard try mode(at: directory, fileManager: fileManager) == directoryMode,
              try mode(at: fileURL, fileManager: fileManager) == fileMode
        else {
            throw AntigravityAccountRepositoryError.canonicalFilePermissionsVerificationFailed
        }
    }

    private static func mode(at url: URL, fileManager: FileManager) throws -> Int? {
        let value = try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]
        return (value as? NSNumber)?.intValue ?? value as? Int
    }
}

nonisolated final class AntigravityMigrationJournalFileStore:
    AntigravityMigrationJournalStoring,
    @unchecked Sendable
{
    let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = AntigravityStoragePaths
            .canonicalStateDirectoryURL()
            .appendingPathComponent("credential-migration-v2.json"),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    nonisolated func load() throws -> AntigravityMigrationJournal? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(
            AntigravityMigrationJournal.self,
            from: Data(contentsOf: fileURL)
        )
    }

    nonisolated func save(_ journal: AntigravityMigrationJournal) throws {
        try AntigravityMigrationFilePermissions.save(
            journal,
            to: fileURL,
            fileManager: fileManager
        )
    }

    nonisolated func delete() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}

nonisolated final class AntigravityMigrationCompletionMarkerFileStore:
    AntigravityMigrationCompletionMarking,
    @unchecked Sendable
{
    let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = AntigravityStoragePaths
            .applicationSupportDirectoryURL()
            .appendingPathComponent(
                "Migrations",
                isDirectory: true
            )
            .appendingPathComponent("antigravity-credentials-v2.json"),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    nonisolated func load() throws -> AntigravityMigrationCompletionMarker? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(
            AntigravityMigrationCompletionMarker.self,
            from: Data(contentsOf: fileURL)
        )
    }

    nonisolated func save(_ marker: AntigravityMigrationCompletionMarker) throws {
        try AntigravityMigrationFilePermissions.save(
            marker,
            to: fileURL,
            fileManager: fileManager
        )
    }
}
