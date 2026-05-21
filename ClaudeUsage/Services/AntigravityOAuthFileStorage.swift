import Foundation

nonisolated enum AntigravityOAuthFileStorage {
    static let directoryPermissions = 0o700
    static let credentialFilePermissions = 0o600

    static func ensurePrivateDirectory(
        at directory: URL,
        fileManager: FileManager
    ) throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: directoryPermissions]
            )
        }
        try? fileManager.setAttributes(
            [.posixPermissions: directoryPermissions],
            ofItemAtPath: directory.path
        )
    }

    static func applyCredentialFilePermissions(
        at fileURL: URL,
        fileManager: FileManager
    ) {
        try? fileManager.setAttributes(
            [.posixPermissions: credentialFilePermissions],
            ofItemAtPath: fileURL.path
        )
    }
}
