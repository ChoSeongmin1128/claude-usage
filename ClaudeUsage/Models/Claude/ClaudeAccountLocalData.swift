import Foundation

/// 계정별로 앱이 남기는 로컬 자료(표시 정보 파일, 캐시 키). 계정을 지울 때 함께 지우고,
/// 이전 버전에서 계정을 지운 뒤 남은 것은 시작할 때 정리한다.
nonisolated enum ClaudeAccountLocalData {
    static let defaultsKeyPrefixes = ["ClaudeUsage.authPathHealth.v1", "ClaudeUsage.cachedOrganizations.v1"]
    private static let metadataFilePrefix = "claude-profile-metadata."
    private static let metadataFileSuffix = ".json"
    private static let unscopedSuffix = "ephemeral"

    static func defaultDirectory() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(AppDistribution.current.applicationSupportDirectoryName, isDirectory: true)
    }

    static func metadataFileURL(accountID: String, directory: URL = defaultDirectory()) -> URL {
        directory.appendingPathComponent("\(metadataFilePrefix)\(accountID)\(metadataFileSuffix)", isDirectory: false)
    }

    static func remove(accountID: String, defaults: UserDefaults = .standard, directory: URL = defaultDirectory()) {
        guard !accountID.isEmpty else { return }
        for prefix in defaultsKeyPrefixes {
            defaults.removeObject(forKey: "\(prefix).\(accountID)")
        }
        try? FileManager.default.removeItem(at: metadataFileURL(accountID: accountID, directory: directory))
    }

    static func removeOrphans(
        keeping accountIDs: Set<String>, defaults: UserDefaults = .standard, directory: URL = defaultDirectory()
    ) {
        for key in defaults.dictionaryRepresentation().keys {
            guard let prefix = defaultsKeyPrefixes.first(where: { key.hasPrefix("\($0).") }) else { continue }
            let suffix = String(key.dropFirst(prefix.count + 1))
            if suffix != unscopedSuffix, !accountIDs.contains(suffix) {
                defaults.removeObject(forKey: key)
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in files where name.hasPrefix(metadataFilePrefix) && name.hasSuffix(metadataFileSuffix) {
            let accountID = String(name.dropFirst(metadataFilePrefix.count).dropLast(metadataFileSuffix.count))
            guard !accountID.isEmpty, !accountIDs.contains(accountID) else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name, isDirectory: false))
        }
    }
}
