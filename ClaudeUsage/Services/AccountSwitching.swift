import AppKit
import Darwin
import Foundation

/// 계정 전환은 기본 로그인과 다른 폴더의 로그인을 맞바꾼다. 복사하지 않으므로 같은 refresh token이
/// 두 곳에 남지 않는다. 바꾼 뒤 공식 CLI로 확인하고, 다르면 되돌린다.
nonisolated enum AccountSwitchError: Error, Equatable {
    case busy
    case unavailable
    case cancelled
    case verificationFailed
    /// 확인에 실패했는데 원래대로 되돌리지도 못했다
    case rollbackFailed
    /// 기본 로그인을 쓰는 프로그램을 종료하지 못했다
    case runningAppsNotTerminated
    /// 전환을 확인받은 뒤 기본 로그인을 쓰는 프로그램이 새로 실행됐다
    case runningAppsStarted
    case writeFailed
}

// MARK: - Claude Code

/// Claude Code와 같은 잠금(proper-lockfile의 잠금 폴더)을 같은 순서로 잡는다. 오래된 잠금은 Claude Code와 같은 기준으로 치운다.
/// Claude Code 2.1.288은 토큰 갱신 때 폴더 안의 갱신 잠금과 옛 버전이 쓰던 `<폴더 실경로>.lock`을 함께 잡고(stale 60초,
/// 갱신 5초), 저장할 때 저장 잠금(stale 15초)을 잡는다. 소유자 기록(`.oauth_refresh.lock.owner`)이 없는 잠금은
/// 가로채지 않고 기다리므로 앱은 기록을 쓰지 않는다.
nonisolated final class ClaudeCodeDirectoryLock: @unchecked Sendable {
    private let paths: [(url: URL, stale: TimeInterval)]
    private var held: [URL] = []
    private var timer: DispatchSourceTimer?

    init(configDirectory: URL) {
        paths = [
            (configDirectory.appendingPathComponent(".oauth_refresh.lock"), 60),
            (Self.legacyRefreshLock(for: configDirectory), 60),
            (configDirectory.appendingPathComponent(".storage-write.lock"), 15),
        ]
    }

    static func legacyRefreshLock(for configDirectory: URL) -> URL {
        URL(fileURLWithPath: configDirectory.resolvingSymlinksInPath().path + ".lock")
    }

    func acquire(timeout: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(timeout)
        for (url, stale) in paths {
            while mkdir(url.path, 0o755) != 0 {
                guard errno == EEXIST else {
                    release()
                    throw AccountSwitchError.unavailable
                }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                if let modified, Date().timeIntervalSince(modified) > stale {
                    rmdir(url.path)
                    continue
                }
                guard Date() < deadline else {
                    release()
                    throw AccountSwitchError.busy
                }
                usleep(200_000)
            }
            held.append(url)
        }
        // Claude Code는 잠금 폴더의 수정 시각으로 살아 있는지 본다.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        let urls = held
        timer.setEventHandler {
            for url in urls { utimes(url.path, nil) }
        }
        timer.resume()
        self.timer = timer
    }

    func release() {
        timer?.cancel()
        timer = nil
        for url in held.reversed() { rmdir(url.path) }
        held.removeAll()
    }

    deinit { release() }
}

nonisolated enum ClaudeAccountSwitcher {
    /// 기본 Claude Code 로그인을 폴더의 계정으로 바꾸고, 지금 기본 로그인은 그 폴더로 옮긴다.
    /// 바꾼 뒤 Claude Code로 확인하고, 다르면 되돌린다.
    static func switchDefault(to folder: URL, expectedEmail: String?) async throws {
        try await switchSlots(
            .defaultSlot(), .folderSlot(folder), expectedEmail: expectedEmail,
            verify: { await ClaudeCodeCLI.authStatus(configDirectory: nil)?.email })
    }

    /// verify는 바꾼 뒤 기본 로그인의 이메일을 돌려준다.
    static func switchSlots(
        _ defaultSlot: ClaudeCodeLoginSlot, _ folderSlot: ClaudeCodeLoginSlot, expectedEmail: String?,
        keychain: ClaudeCodeKeychain = .system, verify: @Sendable () async -> String?
    ) async throws {
        try await swap(defaultSlot, folderSlot, keychain: keychain)
        let actual = await verify()
        guard let expectedEmail, actual?.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
            // 한 번 더 맞바꿔 되돌린다. 저장해 둔 값을 다시 쓰면 확인하는 동안 갱신된 토큰을 옛 토큰으로 덮는다.
            do {
                try await swap(defaultSlot, folderSlot, keychain: keychain)
            } catch {
                throw AccountSwitchError.rollbackFailed
            }
            throw AccountSwitchError.verificationFailed
        }
    }

    static func swap(
        _ a: ClaudeCodeLoginSlot, _ b: ClaudeCodeLoginSlot, keychain: ClaudeCodeKeychain = .system
    ) async throws {
        let lockA = ClaudeCodeDirectoryLock(configDirectory: a.configDirectory)
        let lockB = ClaudeCodeDirectoryLock(configDirectory: b.configDirectory)
        try lockA.acquire()
        defer { lockA.release() }
        try lockB.acquire()
        defer { lockB.release() }
        // 잠금을 잡은 뒤 다시 읽는다. 직전에 갱신된 토큰을 놓치지 않기 위해서다.
        let first = try await a.readSnapshot(keychain: keychain)
        let second = try await b.readSnapshot(keychain: keychain)
        try await a.write(credential: second.credential, account: second.account, over: first, keychain: keychain)
        do {
            try await b.write(credential: first.credential, account: first.account, over: second, keychain: keychain)
        } catch {
            // b는 그대로이므로 a만 되돌린다. a마저 되돌리지 못하면 a의 원래 로그인이 어디에도 남지 않는다.
            let written = ClaudeCodeLoginSlot.Snapshot(
                storage: first.storage, credential: second.credential, account: second.account)
            do {
                try await a.write(
                    credential: first.credential, account: first.account, over: written, keychain: keychain)
            } catch {
                throw AccountSwitchError.rollbackFailed
            }
            throw error
        }
    }
}

// MARK: - Codex

nonisolated enum CodexAccountSwitcher {
    struct RunningCodex: Equatable, Sendable {
        var applications: [pid_t]
        var processes: [pid_t]
        var isEmpty: Bool { applications.isEmpty && processes.isEmpty }
    }

    /// ChatGPT 앱(Codex 포함)과 터미널의 codex가 기본 로그인을 쓰고 있는지 본다.
    /// ChatGPT 앱 안에 든 codex는 앱을 종료하면 함께 끝나므로 터미널 실행으로 세지 않는다.
    static func runningCodex() -> RunningCodex {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: CodexOwnerCLI.chatGPTBundleIdentifier)
        let appPIDs = apps.map(\.processIdentifier)
        let terminal = terminalCodexProcesses(
            currentUserProcesses(), appPIDs: appPIDs,
            appBundlePaths: apps.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path })
        return RunningCodex(applications: appPIDs, processes: terminal)
    }

    static func terminalCodexProcesses(
        _ processes: [(pid: pid_t, path: String)], appPIDs: [pid_t], appBundlePaths: [String]
    ) -> [pid_t] {
        processes.filter { pid, path in
            URL(fileURLWithPath: path).lastPathComponent == "codex" && !appPIDs.contains(pid)
                && !appBundlePaths.contains { path.hasPrefix($0 + "/") }
        }.map(\.pid)
    }

    private static func currentUserProcesses() -> [(pid: pid_t, path: String)] {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        // 목록을 받는 사이 새로 뜬 프로세스를 위해 여유를 둔다.
        var pids = [pid_t](repeating: 0, count: capacity * 2)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let uid = getuid()
        return pids.prefix(max(0, count)).compactMap { pid in
            guard pid > 0, pid != getpid() else { return nil }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                info.pbi_uid == uid
            else { return nil }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
            let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return (pid, String(decoding: bytes, as: UTF8.self))
        }
    }

    /// 사용자가 "종료하고 전환"을 고른 뒤에만 부른다.
    static func terminate(_ running: RunningCodex, timeout: TimeInterval = 5) async -> Bool {
        for pid in running.applications { NSRunningApplication(processIdentifier: pid)?.terminate() }
        for pid in running.processes { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await Task.detached(operation: { runningCodex().isEmpty }).value { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return await Task.detached(operation: { runningCodex().isEmpty }).value
    }

    /// 두 auth.json을 한 번에 맞바꾼다. 같은 볼륨이 아니면 임시 이름을 거쳐 바꾸고, 실패하면 되돌린다.
    static func swapAuthFiles(_ a: URL, _ b: URL) throws {
        if renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 { return }
        let temporary = a.deletingLastPathComponent().appendingPathComponent(".auth.json.switch-\(UUID().uuidString)")
        let manager = FileManager.default
        do {
            try manager.moveItem(at: a, to: temporary)
            do {
                try manager.moveItem(at: b, to: a)
            } catch {
                try? manager.moveItem(at: temporary, to: a)
                throw error
            }
            do {
                try manager.moveItem(at: temporary, to: b)
            } catch {
                try? manager.moveItem(at: a, to: b)
                try? manager.moveItem(at: temporary, to: a)
                throw error
            }
        } catch {
            throw AccountSwitchError.writeFailed
        }
    }

    /// 기본 `~/.codex` 로그인을 폴더의 계정으로 바꾸고 app-server로 확인한다. 다르면 되돌린다.
    static func switchDefault(
        to folder: URL, expectedWorkspaceID: String,
        verify: @Sendable (URL) async -> Bool = { home in (try? await CodexHomeAccount.fetchUsage(home: home)) != nil }
    ) async throws {
        let defaultHome = CodexAuthManager.defaultHomeURL
        let defaultAuth = CodexHomeAccount.authFile(in: defaultHome)
        let folderAuth = CodexHomeAccount.authFile(in: folder)
        try swapAuthFiles(defaultAuth, folderAuth)
        guard CodexHomeAccount.identity(home: defaultHome)?.organizationID == expectedWorkspaceID,
            await verify(defaultHome)
        else {
            do {
                try swapAuthFiles(defaultAuth, folderAuth)
            } catch {
                throw AccountSwitchError.rollbackFailed
            }
            throw AccountSwitchError.verificationFailed
        }
    }
}
