import Foundation

/// Antigravity 자료를 두는 채널 폴더.
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
