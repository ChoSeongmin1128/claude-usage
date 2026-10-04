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
        AppStoragePaths.applicationSupportDirectory(home: homeDirectoryURL, directoryName: directoryName)
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
}
