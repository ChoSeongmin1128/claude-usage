import Foundation

nonisolated enum ClaudeCodeCLI {
    enum RefreshOutcome: Equatable, Sendable {
        case refreshed
        case notLoggedIn
        case executableNotFound
        case unavailable
    }

    struct AuthStatus: Equatable, Sendable {
        let loggedIn: Bool
        let email: String?
    }

    static let commandTimeout: TimeInterval = 30
    static let refreshInterval: TimeInterval = 600

    static func executable(home: URL = FileManager.default.realHomeDirectory) -> URL? {
        guard AppRuntimeEnvironment.mayRunInstalledClaudeCode else { return nil }
        if home.standardizedFileURL == FileManager.default.realHomeDirectory.standardizedFileURL {
            return executableResolver.cachedSelection()?.executableURL
        }
        return ClaudeCodeExecutableSelection.known(home: home)?.executableURL
    }

    /// configDirectoryValue는 CLAUDE_CONFIG_DIR 원문이다. Claude Code는 이 문자열로 Keychain 이름을 정하므로
    /// 경로로 다시 만들지 않고 그대로 넘긴다(끝 '/'도 이름을 바꾼다).
    static func environment(
        configDirectoryValue: String?, home: URL = FileManager.default.realHomeDirectory,
        additionalSearchDirectories: [String] = []
    ) -> [String: String] {
        var seen: Set<String> = []
        let directories = (additionalSearchDirectories + ExternalCommand.searchDirectories(home: home))
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }
        var environment = [
            "HOME": home.path, "USER": NSUserName(), "LOGNAME": NSUserName(),
            "PATH": directories.joined(separator: ":"), "LANG": "en_US.UTF-8",
        ]
        if let configDirectoryValue { environment["CLAUDE_CONFIG_DIR"] = configDirectoryValue }
        return environment
    }

    static func authStatus(configDirectoryValue: String?) async -> AuthStatus? {
        guard AppRuntimeEnvironment.mayRunInstalledClaudeCode,
            let selection = executableResolver.cachedSelection()
        else { return nil }
        return await authStatus(selection: selection, configDirectoryValue: configDirectoryValue)
    }

    static func refreshLogin(configDirectoryValue: String?) async -> RefreshOutcome {
        guard AppRuntimeEnvironment.mayRunInstalledClaudeCode else { return .unavailable }
        let selection = await executableResolver.resolve()
        guard !Task.isCancelled else { return .unavailable }
        guard let selection else { return .executableNotFound }
        guard let status = await authStatus(selection: selection, configDirectoryValue: configDirectoryValue) else {
            return .unavailable
        }
        guard status.loggedIn else { return .notLoggedIn }
        let throttleKey = configDirectoryValue.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? ""
        guard refreshThrottle.begin(throttleKey) else { return .unavailable }
        // 토큰을 회전해 저장하는 중에 끊으면 서버가 이미 소비한 refresh token만 남는다. 호출자가 취소해도 끝까지 기다린다.
        let output = await Task.detached(priority: .utility) {
            await run(selection: selection, arguments: refreshArguments, configDirectoryValue: configDirectoryValue)
        }.value
        return output?.succeeded == true ? .refreshed : .unavailable
    }

    static let refreshArguments = [
        "-p", "/usage", "--safe-mode", "--strict-mcp-config", "--no-session-persistence",
    ]

    private static let executableResolver: ClaudeCodeExecutableResolver = {
        let home = FileManager.default.realHomeDirectory
        return ClaudeCodeExecutableResolver(
            known: { ClaudeCodeExecutableSelection.known(home: home) },
            lookup: { await ClaudeCodeLoginShellLookup.lookup(home: home) })
    }()
    private static let refreshThrottle = RefreshThrottle(interval: refreshInterval)

    private static func authStatus(
        selection: ClaudeCodeExecutableSelection, configDirectoryValue: String?
    ) async -> AuthStatus? {
        guard
            let output = await run(
                selection: selection, arguments: ["auth", "status", "--json"],
                configDirectoryValue: configDirectoryValue),
            let object = try? JSONSerialization.jsonObject(with: output.data) as? [String: Any],
            let loggedIn = object["loggedIn"] as? Bool
        else { return nil }
        return AuthStatus(loggedIn: loggedIn, email: object["email"] as? String)
    }

    private static func run(
        selection: ClaudeCodeExecutableSelection, arguments: [String], configDirectoryValue: String?
    ) async -> ExternalCommand.Output? {
        guard AppRuntimeEnvironment.mayRunInstalledClaudeCode, selection.isCurrent else { return nil }
        let work = AppStoragePaths.claudeCLIWorkDirectory()
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return await ExternalCommand.run(
            selection.executableURL, arguments: arguments,
            environment: environment(
                configDirectoryValue: configDirectoryValue, additionalSearchDirectories: selection.searchDirectories),
            currentDirectory: work, timeout: commandTimeout)
    }
}

private nonisolated final class RefreshThrottle: @unchecked Sendable {
    private let interval: TimeInterval
    private let lock = NSLock()
    private var startedAt: [String: Date] = [:]

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func begin(_ key: String, now: Date = Date()) -> Bool {
        lock.withLock {
            if let last = startedAt[key], now.timeIntervalSince(last) < interval { return false }
            startedAt[key] = now
            return true
        }
    }
}
