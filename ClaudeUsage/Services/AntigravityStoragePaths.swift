import Foundation

/// Canonical filesystem roots owned by the Antigravity v2 runtime.
///
/// This type deliberately has no dependency on the legacy OAuth credential
/// store. Credential migration, account metadata, and managed-process state can
/// therefore share the same application-support root after the legacy store is
/// removed.
nonisolated enum AntigravityStoragePaths {
    static func applicationSupportDirectoryURL(
        homeDirectoryURL: URL = FileManager.default.realHomeDirectory,
        directoryName: String =
            AppDistribution.current
                .applicationSupportDirectoryName
    ) -> URL {
        homeDirectoryURL.standardizedFileURL
            .appendingPathComponent(
                "Library/Application Support/\(directoryName)",
                isDirectory: true
            )
    }

    static func canonicalStateDirectoryURL(
        homeDirectoryURL: URL = FileManager.default.realHomeDirectory,
        directoryName: String =
            AppDistribution.current
                .applicationSupportDirectoryName
    ) -> URL {
        applicationSupportDirectoryURL(
            homeDirectoryURL: homeDirectoryURL,
            directoryName: directoryName
        )
        .appendingPathComponent("Antigravity", isDirectory: true)
    }

    /// Cross-channel launch serialization prevents prod and staging from
    /// racing to create two managed AGY processes. Credentials, settings and
    /// owned-process ledgers remain in each channel's private directory.
    static func managedLaunchCoordinationDirectoryURL(
        homeDirectoryURL: URL = FileManager.default.realHomeDirectory
    ) -> URL {
        homeDirectoryURL.standardizedFileURL
            .appendingPathComponent(
                "Library/Application Support/ClaudeUsageShared/Antigravity",
                isDirectory: true
            )
    }
}
