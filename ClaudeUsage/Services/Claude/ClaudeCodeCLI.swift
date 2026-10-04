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

    static func environment(
        configDirectory: URL?, home: URL = FileManager.default.realHomeDirectory,
        additionalSearchDirectories: [String] = []
    ) -> [String: String] {
        var seen: Set<String> = []
        let directories = (additionalSearchDirectories + ExternalCommand.searchDirectories(home: home))
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }
        var environment = [
            "HOME": home.path, "USER": NSUserName(), "LOGNAME": NSUserName(),
            "PATH": directories.joined(separator: ":"), "LANG": "en_US.UTF-8",
        ]
        if let configDirectory { environment["CLAUDE_CONFIG_DIR"] = configDirectory.path }
        return environment
    }

    static func authStatus(configDirectory: URL?) async -> AuthStatus? {
        guard AppRuntimeEnvironment.mayRunInstalledClaudeCode,
            let selection = executableResolver.cachedSelection()
        else { return nil }
        return await authStatus(selection: selection, configDirectory: configDirectory)
    }

    static func refreshLogin(configDirectory: URL?) async -> RefreshOutcome {
        guard AppRuntimeEnvironment.mayRunInstalledClaudeCode else { return .unavailable }
        let selection = await executableResolver.resolve()
        guard !Task.isCancelled else { return .unavailable }
        guard let selection else { return .executableNotFound }
        guard refreshThrottle.begin(configDirectory?.standardizedFileURL.path ?? "") else { return .unavailable }
        guard let status = await authStatus(selection: selection, configDirectory: configDirectory) else {
            return .unavailable
        }
        guard status.loggedIn else { return .notLoggedIn }
        let output = await run(
            selection: selection, arguments: ["-p", "/usage", "--no-session-persistence"],
            configDirectory: configDirectory)
        return output?.succeeded == true ? .refreshed : .unavailable
    }

    private static let executableResolver: ClaudeCodeExecutableResolver = {
        let home = FileManager.default.realHomeDirectory
        return ClaudeCodeExecutableResolver(
            known: { ClaudeCodeExecutableSelection.known(home: home) },
            lookup: { await ClaudeCodeLoginShellLookup.lookup(home: home) })
    }()
    private static let refreshThrottle = RefreshThrottle(interval: refreshInterval)

    private static func authStatus(
        selection: ClaudeCodeExecutableSelection, configDirectory: URL?
    ) async -> AuthStatus? {
        guard
            let output = await run(
                selection: selection, arguments: ["auth", "status", "--json"], configDirectory: configDirectory),
            let object = try? JSONSerialization.jsonObject(with: output.data) as? [String: Any],
            let loggedIn = object["loggedIn"] as? Bool
        else { return nil }
        return AuthStatus(loggedIn: loggedIn, email: object["email"] as? String)
    }

    private static func run(
        selection: ClaudeCodeExecutableSelection, arguments: [String], configDirectory: URL?
    ) async -> ExternalCommand.Output? {
        guard AppRuntimeEnvironment.mayRunInstalledClaudeCode, selection.isCurrent else { return nil }
        let work = AppStoragePaths.claudeCLIWorkDirectory()
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return await ExternalCommand.run(
            selection.executableURL, arguments: arguments,
            environment: environment(
                configDirectory: configDirectory, additionalSearchDirectories: selection.searchDirectories),
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
