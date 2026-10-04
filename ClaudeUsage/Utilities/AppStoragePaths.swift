import Foundation

/// 이 앱이 Application Support 아래에 두는 폴더. 서비스별 코드가 서로의 경로에서 파생하지 않게 한곳에 둔다.
nonisolated enum AppStoragePaths {
    static func applicationSupportDirectory(
        home: URL = FileManager.default.realHomeDirectory,
        directoryName: String = AppDistribution.current.applicationSupportDirectoryName
    ) -> URL {
        home.standardizedFileURL.appendingPathComponent(
            "Library/Application Support/\(directoryName)", isDirectory: true)
    }

    /// 앱이 만든 Codex 계정 폴더(CODEX_HOME)를 두는 곳.
    static func codexAccountsDirectory(home: URL = FileManager.default.realHomeDirectory) -> URL {
        applicationSupportDirectory(home: home).appendingPathComponent("codex-accounts", isDirectory: true)
    }

    /// Claude Code를 실행하는 빈 작업 폴더. 실행 위치에 프로젝트 기록 폴더가 생기므로 사용자 폴더를 피한다.
    static func claudeCLIWorkDirectory(home: URL = FileManager.default.realHomeDirectory) -> URL {
        applicationSupportDirectory(home: home).appendingPathComponent("claude-cli-work", isDirectory: true)
    }
}
