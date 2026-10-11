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
    /// 옮길 폴더 로그인의 토큰 주인을 확인하지 못했다(네트워크 오류, 만료 뒤 갱신 실패)
    case ownerUnverified
    /// 옮길 폴더 로그인의 토큰 주인이 그 폴더 `.claude.json`의 계정과 다르다
    case ownerMismatch
}

// MARK: - Claude Code

/// Claude Code와 같은 잠금(proper-lockfile의 잠금 폴더)을 같은 순서로 잡는다. 오래된 잠금은 Claude Code와 같은 기준으로 치운다.
/// Claude Code 2.1.288은 토큰 갱신 때 폴더 안의 갱신 잠금과 옛 버전이 쓰던 `<폴더 실경로>.lock`을 함께 잡고(stale 60초,
/// 갱신 5초), 저장할 때 저장 잠금(stale 15초)을 잡는다. `.claude.json`은 `<파일>.lock`(stale 10초)을 잡고 다시 읽은 뒤
/// 바꾼 값만 써서, 앱도 이 잠금을 잡아야 서로의 변경을 덮지 않는다. 소유자 기록(`.oauth_refresh.lock.owner`)이 없는
/// 잠금은 가로채지 않고 기다리므로 앱은 기록을 쓰지 않는다.
nonisolated final class ClaudeCodeDirectoryLock: @unchecked Sendable {
    private let paths: [(url: URL, stale: TimeInterval)]
    private var held: [URL] = []
    private var timer: DispatchSourceTimer?

    init(configDirectory: URL, profileFile: URL) {
        paths = [
            (configDirectory.appendingPathComponent(".oauth_refresh.lock"), 60),
            (Self.legacyRefreshLock(for: configDirectory), 60),
            (configDirectory.appendingPathComponent(".storage-write.lock"), 15),
            (Self.profileLock(for: profileFile), 10),
        ]
    }

    static func profileLock(for profileFile: URL) -> URL {
        URL(fileURLWithPath: profileFile.path + ".lock")
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
                guard Date() < deadline else {
                    release()
                    throw AccountSwitchError.busy
                }
                if let modified, Date().timeIntervalSince(modified) > stale, rmdir(url.path) == 0 {
                    continue
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
    /// 바꾸기 전에 폴더 토큰의 주인을 서버에 확인하고, 바꾼 뒤 Claude Code로 다시 확인해 다르면 되돌린다.
    static func switchDefault(
        to folder: ClaudeCodeLoginSlot, expectedEmail: String?, keychain: ClaudeCodeKeychain = .system,
        refresher: ClaudeCodeCredentialReader.CLIRefresher, tokenOwner: ClaudeCodeFolderKeychain.TokenOwner
    ) async throws {
        // 원문을 모르는 항목에 쓰면 그 폴더의 Claude Code가 보지 않는 곳으로 기본 로그인을 옮길 수 있다.
        guard folder.cliConfigDirectoryValue != nil else { throw AccountSwitchError.unavailable }
        let verifiedToken = try await verifyOwner(
            of: folder, keychain: keychain, refresher: refresher, tokenOwner: tokenOwner)
        try await switchSlots(
            .defaultSlot(), folder, expectedEmail: expectedEmail, expectedFolderToken: verifiedToken,
            keychain: keychain, verify: { await ClaudeCodeCLI.authStatus(configDirectoryValue: nil)?.email })
    }

    /// 옮길 폴더 로그인이 그 폴더 `.claude.json` 계정의 것인지 서버에 묻고 확인한 토큰을 돌려준다.
    /// `.claude.json`과 Keychain은 따로 바뀔 수 있어 둘이 어긋난 채 옮기면 다른 계정으로 로그인된다.
    /// 만료됐으면 그 폴더의 Claude Code에 갱신을 맡긴다(회전과 저장을 Claude Code가 한다).
    /// 확인하지 못하면 전환하지 않는다. 잠금을 잡기 전에 부른다(잠금 중에는 네트워크를 쓰지 않는다).
    static func verifyOwner(
        of slot: ClaudeCodeLoginSlot, keychain: ClaudeCodeKeychain = .system,
        refresher: ClaudeCodeCredentialReader.CLIRefresher, tokenOwner: ClaudeCodeFolderKeychain.TokenOwner
    ) async throws -> String {
        guard let expected = slot.identity(), expected.accountID != nil || expected.email != nil else {
            throw AccountSwitchError.ownerUnverified
        }
        var credential = try await snapshotCredential(of: slot, keychain: keychain)
        if credential?.isExpired == true {
            switch await refresher(slot.cliConfigDirectoryValue) {
            case .refreshed: credential = try await snapshotCredential(of: slot, keychain: keychain)
            case .notLoggedIn: throw AccountSwitchError.unavailable
            case .executableNotFound, .unavailable: throw AccountSwitchError.ownerUnverified
            }
        }
        guard let credential, !credential.isExpired, let owner = await tokenOwner(credential.accessToken) else {
            throw AccountSwitchError.ownerUnverified
        }
        // 계정 UUID가 있으면 그것으로만 비교한다. 이메일은 다른 계정이 다시 쓸 수 있다.
        let isOwner =
            if let accountID = expected.accountID {
                owner.accountID == accountID
            } else {
                owner.email?.caseInsensitiveCompare(expected.email ?? "") == .orderedSame
            }
        guard isOwner else { throw AccountSwitchError.ownerMismatch }
        return credential.accessToken
    }

    private static func snapshotCredential(
        of slot: ClaudeCodeLoginSlot, keychain: ClaudeCodeKeychain
    ) async throws -> ClaudeCodeOAuthCredential? {
        try await credential(in: slot.readSnapshot(keychain: keychain))
    }

    private static func credential(in snapshot: ClaudeCodeLoginSlot.Snapshot) -> ClaudeCodeOAuthCredential? {
        let source: ClaudeCodeOAuthCredential.Source =
            switch snapshot.storage {
            case .keychain: .refreshed
            case .file(let url): .file(url)
            }
        return ClaudeCodeCredentialReader.parseCredential(
            from: String(decoding: snapshot.credential, as: UTF8.self), source: source)
    }

    /// verify는 바꾼 뒤 기본 로그인의 이메일을 돌려준다. expectedFolderToken은 바꾸기 전에 주인을 확인한 폴더 토큰이다.
    static func switchSlots(
        _ defaultSlot: ClaudeCodeLoginSlot, _ folderSlot: ClaudeCodeLoginSlot, expectedEmail: String?,
        expectedFolderToken: String? = nil, keychain: ClaudeCodeKeychain = .system,
        verify: @Sendable () async -> String?
    ) async throws {
        try await swap(defaultSlot, folderSlot, expectedSecondToken: expectedFolderToken, keychain: keychain)
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
        _ a: ClaudeCodeLoginSlot, _ b: ClaudeCodeLoginSlot, expectedSecondToken: String? = nil,
        keychain: ClaudeCodeKeychain = .system
    ) async throws {
        let lockA = ClaudeCodeDirectoryLock(configDirectory: a.configDirectory, profileFile: a.profileFile)
        let lockB = ClaudeCodeDirectoryLock(configDirectory: b.configDirectory, profileFile: b.profileFile)
        // 잠금은 최대 10초 기다리므로 협력 스레드를 막지 않게 전용 스레드에서 잡는다.
        try await BlockingWork.run { try lockA.acquire() }
        defer { lockA.release() }
        try await BlockingWork.run { try lockB.acquire() }
        defer { lockB.release() }
        // 잠금을 잡은 뒤 다시 읽는다. 직전에 갱신된 토큰을 놓치지 않기 위해서다.
        let first = try await a.readSnapshot(keychain: keychain)
        let second = try await b.readSnapshot(keychain: keychain)
        // 주인을 확인한 뒤 토큰이 바뀌었으면(그 사이 회전) 확인 결과를 쓸 수 없다. 아무것도 쓰지 않고 다시 시도하게 한다.
        if let expectedSecondToken, credential(in: second)?.accessToken != expectedSecondToken {
            throw AccountSwitchError.busy
        }
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

    /// 이 앱이 사용량 조회로 띄운 app-server(부모가 이 앱)는 기본 로그인을 계속 쓰는 프로그램이 아니라 뺀다.
    static func terminalCodexProcesses(
        _ processes: [(pid: pid_t, parent: pid_t, path: String)], appPIDs: [pid_t], appBundlePaths: [String],
        ownPID: pid_t = getpid()
    ) -> [pid_t] {
        processes.filter { pid, parent, path in
            URL(fileURLWithPath: path).lastPathComponent == "codex" && !appPIDs.contains(pid) && parent != ownPID
                && !appBundlePaths.contains { path.hasPrefix($0 + "/") }
        }.map(\.pid)
    }

    private static func currentUserProcesses() -> [(pid: pid_t, parent: pid_t, path: String)] {
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
            return (pid, pid_t(info.pbi_ppid), String(decoding: bytes, as: UTF8.self))
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
