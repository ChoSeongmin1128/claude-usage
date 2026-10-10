import AppKit
import Darwin
import Foundation
import os

nonisolated struct CodexOwnedRateLimits: Sendable {
    let email: String
    let accountID: String
    let quota: CodexOwnerResultBox
}

nonisolated protocol CodexOwnedRateLimitsReading: Sendable {
    func readOwnedRateLimits(sourceURL: URL, expectedAccountID: String, budget: CodexRequestBudget) async throws
        -> CodexOwnedRateLimits
}

/// A bounded stdio session with the CLI that owns the auth file. No threads,
/// turns, user prompts, token arguments or external processes are involved.
nonisolated struct CodexOwnerCLI: CodexOwnerRefreshing, CodexOwnedRateLimitsReading {
    let executableURL: URL?

    init(executableURL: URL? = nil) {
        self.executableURL = executableURL
    }

    func refresh(sourceURL: URL, expectedAccountID: String, budget: CodexRequestBudget) async throws {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let session = try CodexOwnerSession(
                    executableURL: try self.resolvedExecutable(), sourceURL: sourceURL,
                    budget: budget, cancelled: cancelled
                )
                defer { session.close() }
                _ = try session.request(
                    1, "initialize",
                    params: [
                        "clientInfo": ["name": "claudeusage", "version": "1"],
                        "capabilities": ["experimentalApi": false],
                    ])
                try session.send(["method": "initialized"])
                let account = try session.request(2, "account/read", params: ["refreshToken": true])
                guard (account["account"] as? [String: Any])?["type"] as? String == "chatgpt" else {
                    throw CodexOwnerError.rejected
                }
                let quota = try session.request(3, "account/rateLimits/read")
                guard quota["accountId"] as? String == expectedAccountID else {
                    throw CodexOwnerError.accountMismatch
                }
                let limits = Self.codexRateLimits(in: quota)
                guard
                    ["primary", "secondary"].contains(where: { key in
                        guard let window = limits?[key] as? [String: Any],
                            let used = Self.number(window["usedPercent"]), used >= 0,
                            let duration = Self.number(window["windowDurationMins"]), duration > 0,
                            Self.number(window["resetsAt"]) != nil
                        else { return false }
                        return true
                    })
                else { throw CodexOwnerError.invalidResponse }
            }.value
            try Task.checkCancellation()
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// `account/rateLimits/read` 응답에서 Codex 한도. 한도별 묶음이 있으면 codex 묶음을, 없으면 전체 값을 쓴다.
    nonisolated static func codexRateLimits(in quota: [String: Any]) -> [String: Any]? {
        let buckets = quota["rateLimitsByLimitId"] as? [String: [String: Any]]
        return buckets?["codex"] ?? quota["rateLimits"] as? [String: Any]
    }

    /// 그 폴더(CODEX_HOME)의 공식 app-server에서 사용량 응답을 그대로 받는다.
    func readRateLimits(sourceURL: URL, expectedAccountID: String, budget: CodexRequestBudget) async throws
        -> [String: Any]
    {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let box: CodexOwnerResultBox = try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let session = try CodexOwnerSession(
                    executableURL: try self.resolvedExecutable(), sourceURL: sourceURL,
                    budget: budget, cancelled: cancelled)
                defer { session.close() }
                _ = try session.request(
                    1, "initialize",
                    params: [
                        "clientInfo": ["name": "claudeusage", "version": "1"],
                        "capabilities": ["experimentalApi": false],
                    ])
                try session.send(["method": "initialized"])
                let quota = try session.request(2, "account/rateLimits/read")
                guard quota["accountId"] as? String == expectedAccountID else {
                    throw CodexOwnerError.accountMismatch
                }
                return CodexOwnerResultBox(value: quota)
            }.value
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        return box.value
    }

    func readOwnedRateLimits(sourceURL: URL, expectedAccountID: String, budget: CodexRequestBudget) async throws
        -> CodexOwnedRateLimits
    {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let result = try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let session = try CodexOwnerSession(
                    executableURL: try self.resolvedExecutable(), sourceURL: sourceURL,
                    budget: budget, cancelled: cancelled)
                defer { session.close() }
                _ = try session.request(
                    1, "initialize",
                    params: [
                        "clientInfo": ["name": "claudeusage", "version": "1"],
                        "capabilities": ["experimentalApi": false],
                    ])
                try session.send(["method": "initialized"])
                let before = try Self.accountEmail(
                    session.request(2, "account/read", params: ["refreshToken": false]))
                let quota = try session.request(3, "account/rateLimits/read")
                guard quota["accountId"] as? String == expectedAccountID else {
                    throw CodexOwnerError.accountMismatch
                }
                let after = try Self.accountEmail(
                    session.request(4, "account/read", params: ["refreshToken": false]))
                guard before.caseInsensitiveCompare(after) == .orderedSame else {
                    throw CodexOwnerError.accountMismatch
                }
                return CodexOwnedRateLimits(
                    email: after, accountID: expectedAccountID, quota: CodexOwnerResultBox(value: quota))
            }.value
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        try budget.check()
        return result
    }

    private static func accountEmail(_ result: [String: Any]) throws -> String {
        guard let account = result["account"] as? [String: Any], account["type"] as? String == "chatgpt" else {
            throw CodexOwnerError.rejected
        }
        guard let email = (account["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !email.isEmpty
        else { throw CodexOwnerError.invalidResponse }
        return email
    }

    static func resetCredits(from value: Any?) -> CodexResetCreditsResponse? {
        guard let summary = value as? [String: Any] else { return nil }
        var payload: [String: Any] = ["available_count": summary["availableCount"] ?? NSNull()]
        if let credits = summary["credits"] as? [[String: Any]] {
            let keys = [
                "id": "id", "resetType": "reset_type", "status": "status", "grantedAt": "granted_at",
                "expiresAt": "expires_at", "title": "title", "description": "description",
            ]
            payload["credits"] = credits.filter { ($0["id"] as? String)?.isEmpty == false }.map { item in
                Dictionary(
                    uniqueKeysWithValues: keys.compactMap { source, target in
                        item[source].map { (target, $0) }
                    })
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
            let result = try? JSONDecoder().decode(CodexResetCreditsResponse.self, from: data),
            let count = result.availableCountField, count >= 0
        else { return nil }
        return result
    }

    static func isAvailable() -> Bool { (try? Self().resolvedExecutable()) != nil }

    static var searchPath: String { ExternalCommand.searchPath() }

    /// Codex가 들어 있는 ChatGPT 앱
    static let chatGPTBundleIdentifier = "com.openai.codex"

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite
        else { return nil }
        return number.doubleValue
    }

    func resolvedExecutable() throws -> URL {
        let home = CodexAuthManager.defaultHomeURL.deletingLastPathComponent()
        let pathCandidates = ExternalCommand.searchDirectories(home: home).map {
            URL(fileURLWithPath: $0).appendingPathComponent("codex")
        }
        // ChatGPT 앱은 Codex CLI를 앱 안에 담는다. bin/codex는 실행 스크립트라 실제 파일을 쓴다.
        let chatGPTApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.chatGPTBundleIdentifier)
            .map { $0.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex") }
        let candidates =
            executableURL.map { [$0] } ?? [
                URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                URL(fileURLWithPath: "/usr/local/bin/codex"),
                URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            ] + [chatGPTApp].compactMap { $0 } + [
                home.appendingPathComponent(".npm-global/bin/codex"),
                home.appendingPathComponent(".local/bin/codex"),
            ] + pathCandidates
        guard let resolved = ExternalCommand.firstTrustedExecutable(in: candidates) else {
            throw CodexOwnerError.unavailable
        }
        return resolved
    }
}

/// The child remains unreaped until cleanup signals its private process group.
/// Its PID therefore cannot be recycled while that group is being terminated.
private nonisolated final class CodexOwnerSession {
    private var pid: pid_t = 0
    private var input: Int32 = -1
    private var output: Int32 = -1
    private var buffer = Data()
    private var receivedBytes = 0
    private let budget: CodexRequestBudget
    private let cancelled: OSAllocatedUnfairLock<Bool>

    init(executableURL: URL, sourceURL: URL, budget: CodexRequestBudget, cancelled: OSAllocatedUnfairLock<Bool>) throws
    {
        self.budget = budget
        self.cancelled = cancelled
        try check()
        var stdinPipe = [Int32](repeating: -1, count: 2)
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        defer {
            for fd in stdinPipe + stdoutPipe where fd >= 0 { Darwin.close(fd) }
        }
        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0 else { throw CodexOwnerError.launchFailed }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw CodexOwnerError.launchFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw CodexOwnerError.launchFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        let results = [
            posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO),
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
            posix_spawn_file_actions_addchdir_np(&actions, "/"),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)),
            posix_spawnattr_setpgroup(&attributes, 0),
        ]
        guard results.allSatisfy({ $0 == 0 }) else { throw CodexOwnerError.launchFailed }
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        var argv: [UnsafeMutablePointer<CChar>?] = []
        for value in [executableURL.path, "app-server"] { argv.append(strdup(value)) }
        var env: [UnsafeMutablePointer<CChar>?] = []
        for value in [
            "HOME=\(home)", "CODEX_HOME=\(sourceURL.deletingLastPathComponent().path)",
            "PATH=\(CodexOwnerCLI.searchPath)", "LANG=en_US.UTF-8",
        ] { env.append(strdup(value)) }
        defer { (argv + env).forEach { free($0) } }
        guard (argv + env).allSatisfy({ $0 != nil }) else { throw CodexOwnerError.launchFailed }
        let spawnResult = (argv + [nil]).withUnsafeBufferPointer { args in
            (env + [nil]).withUnsafeBufferPointer { environment in
                posix_spawn(
                    &pid, executableURL.path, &actions, &attributes,
                    UnsafeMutablePointer(mutating: args.baseAddress),
                    UnsafeMutablePointer(mutating: environment.baseAddress))
            }
        }
        guard spawnResult == 0 else { throw CodexOwnerError.launchFailed }
        input = stdinPipe[1]; stdinPipe[1] = -1
        output = stdoutPipe[0]; stdoutPipe[0] = -1
        // Poll and short cancellation checks bound both directions of the pipe.
        guard fcntl(input, F_SETFL, O_NONBLOCK) == 0, fcntl(output, F_SETFL, O_NONBLOCK) == 0 else {
            close()
            throw CodexOwnerError.launchFailed
        }
        let noSignal: Int32 = 1
        guard fcntl(input, F_SETNOSIGPIPE, noSignal) == 0 else {
            close()
            throw CodexOwnerError.launchFailed
        }
    }

    func send(_ message: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: message) + Data([10])
        var offset = 0
        while offset < data.count {
            try wait(input, events: Int16(POLLOUT))
            let count = data.withUnsafeBytes {
                Darwin.write(input, $0.baseAddress!.advanced(by: offset), $0.count - offset)
            }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw CodexOwnerError.invalidResponse }
            offset += count
        }
    }

    func request(_ id: Int, _ method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        try send(["id": id, "method": method, "params": params])
        while true {
            try check()
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer[..<newline]
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw CodexOwnerError.invalidResponse
                }
                buffer.removeSubrange(...newline)
                guard object["id"] as? Int == id else { continue }
                if let error = object["error"] as? [String: Any] {
                    if let code = error["code"] as? Int, code == -32601 || code == -32602 {
                        throw CodexOwnerError.unavailable
                    }
                    let message = (error["message"] as? String ?? "").lowercased()
                    let authFailures = [
                        "unauthorized", "not logged", "login required", "authentication required",
                        "credentials are required", "refresh_token_reused", "refresh_token_expired",
                        "refresh_token_invalidated",
                    ]
                    if authFailures.contains(where: { message.contains($0) }) { throw CodexOwnerError.rejected }
                    throw CodexOwnerError.temporarilyUnavailable
                }
                guard let result = object["result"] as? [String: Any] else { throw CodexOwnerError.invalidResponse }
                return result
            }
            try wait(output, events: Int16(POLLIN))
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(output, &bytes, bytes.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw CodexOwnerError.invalidResponse }
            receivedBytes += count
            guard receivedBytes <= 1_048_576 else { throw CodexOwnerError.invalidResponse }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }

    private func wait(_ fd: Int32, events: Int16) throws {
        while true {
            try check()
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(50, max(1, budget.remaining * 1000))))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw CodexOwnerError.invalidResponse }
            if result > 0 { return }
        }
    }

    private func check() throws {
        if cancelled.withLock({ $0 }) { throw CancellationError() }
        guard budget.remaining > 0 else { throw CodexOwnerError.timedOut }
    }

    func close() {
        if input >= 0 { Darwin.close(input); input = -1 }
        if output >= 0 { Darwin.close(output); output = -1 }
        guard pid > 0 else { return }
        kill(-pid, SIGTERM)
        // Keep the parent unreaped during the grace period. Descendants that
        // ignore TERM must still receive KILL before its group ID can be reused.
        usleep(200_000)
        var status: Int32 = 0
        kill(-pid, SIGKILL)
        let reapDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < reapDeadline {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result < 0 && errno == ECHILD) { pid = 0; return }
            usleep(10_000)
        }
        let ownedPID = pid
        // No further signals are sent. A delayed kernel exit only needs reaping.
        Task.detached(priority: .utility) {
            var status: Int32 = 0
            while waitpid(ownedPID, &status, 0) < 0 && errno == EINTR {}
        }
        pid = 0
    }
}

/// app-server 응답(JSON 사전)을 Task 경계 너머로 옮긴다. 만든 뒤에는 바꾸지 않는다.
nonisolated struct CodexOwnerResultBox: @unchecked Sendable {
    let value: [String: Any]
}
