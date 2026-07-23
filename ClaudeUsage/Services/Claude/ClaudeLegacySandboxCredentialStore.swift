import Foundation

protocol ClaudeLegacySandboxCredentialStoring: Sendable {
    nonisolated func loadLegacySessionKey() throws -> String?
    nonisolated func deleteLegacySessionKey() throws
}

final class ClaudeLegacySandboxCredentialStore: ClaudeLegacySandboxCredentialStoring, @unchecked Sendable {
    nonisolated static let shared = ClaudeLegacySandboxCredentialStore()

    private nonisolated static let legacySessionKey = "claude-session-key"
    private let preferencesURL: URL

    nonisolated init(
        preferencesURL: URL = FileManager.default.realHomeDirectory
            .appendingPathComponent("Library/Containers/com.seongmin.ClaudeUsage")
            .appendingPathComponent("Data/Library/Preferences/com.seongmin.ClaudeUsage.plist")
    ) {
        self.preferencesURL = preferencesURL
    }

    nonisolated func loadLegacySessionKey() throws -> String? {
        guard FileManager.default.fileExists(atPath: preferencesURL.path) else {
            return nil
        }
        let snapshot = try loadPreferences()
        return snapshot.values[Self.legacySessionKey] as? String
    }

    nonisolated func deleteLegacySessionKey() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: preferencesURL.path) else {
            return
        }
        var snapshot = try loadPreferences()
        guard snapshot.values.removeValue(forKey: Self.legacySessionKey) != nil else {
            return
        }
        let attributes = try fileManager.attributesOfItem(atPath: preferencesURL.path)
        let data = try PropertyListSerialization.data(
            fromPropertyList: snapshot.values,
            format: snapshot.format,
            options: 0
        )
        try data.write(to: preferencesURL, options: .atomic)
        if let permissions = attributes[.posixPermissions] {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: preferencesURL.path)
        }
    }

    private nonisolated func loadPreferences() throws -> (
        values: [String: Any],
        format: PropertyListSerialization.PropertyListFormat
    ) {
        let data = try Data(contentsOf: preferencesURL)
        var format = PropertyListSerialization.PropertyListFormat.binary
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        )
        guard let values = propertyList as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return (values, format)
    }
}
