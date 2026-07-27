import Foundation

/// Canonical filesystem roots owned by the Antigravity v2 runtime.
///
/// This type deliberately has no dependency on the legacy OAuth credential
/// store. Credential migration, account metadata, and managed-process state can
/// therefore share the same application-support root after the legacy store is
/// removed.
nonisolated enum AntigravityStoragePaths {
    static func applicationSupportDirectoryURL(
        homeDirectoryURL: URL = FileManager.default.realHomeDirectory
    ) -> URL {
        homeDirectoryURL.standardizedFileURL
            .appendingPathComponent(
                "Library/Application Support/ClaudeUsage",
                isDirectory: true
            )
    }

    static func canonicalStateDirectoryURL(
        homeDirectoryURL: URL = FileManager.default.realHomeDirectory
    ) -> URL {
        applicationSupportDirectoryURL(
            homeDirectoryURL: homeDirectoryURL
        )
        .appendingPathComponent("Antigravity", isDirectory: true)
    }
}
