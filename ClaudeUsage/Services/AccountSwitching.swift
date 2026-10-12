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
    /// Actual credentials were verified, but completion recording was not confirmed.
    case recoveryPending
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
    private struct Prepared: Sendable {
        let id: UUID
        let recovery: CredentialRecoveryCoordinator
        let components: [CredentialRecoverySwitchComponent]
        let originalIdentity: UsageAccountIdentity?
    }

    static func switchDefault(
        to folder: ClaudeCodeLoginSlot, expectedIdentity: UsageAccountIdentity,
        keychain: ClaudeCodeKeychain = .system,
        refresher: ClaudeCodeCredentialReader.CLIRefresher, tokenOwner: ClaudeCodeFolderKeychain.TokenOwner,
        recoveryCoordinator: CredentialRecoveryCoordinator? = nil
    ) async throws {
        guard folder.cliConfigDirectoryValue != nil else { throw AccountSwitchError.unavailable }
        let token = try await verifyOwner(
            of: folder, expectedIdentity: expectedIdentity, keychain: keychain,
            refresher: refresher, tokenOwner: tokenOwner, recoveryCoordinator: recoveryCoordinator)
        let main = ClaudeCodeLoginSlot.defaultSlot()
        let prepared = try await prepare(
            main, folder, expectedIdentity: expectedIdentity, expectedSecondToken: token,
            keychain: keychain, recoveryCoordinator: recoveryCoordinator)
        do {
            try await prepared.recovery.applySwitch(prepared.id)
            try Task.checkCancellation()
            let mainToken = try await verifyOwner(
                of: main, expectedIdentity: expectedIdentity, keychain: keychain,
                refresher: refresher, tokenOwner: tokenOwner, recoveryCoordinator: prepared.recovery,
                switchOperationID: prepared.id)
            let folderToken: String?
            if let original = prepared.originalIdentity,
                original.accountID != nil || original.email != nil
            {
                folderToken = try await verifyOwner(
                    of: folder, expectedIdentity: original, keychain: keychain,
                    refresher: refresher, tokenOwner: tokenOwner, recoveryCoordinator: prepared.recovery,
                    switchOperationID: prepared.id)
            } else {
                folderToken = nil
            }
            try Task.checkCancellation()
            let states = try await prepared.recovery.switchStates(prepared.id)
            guard credentialToken(states[0]) == mainToken,
                states[1] == prepared.components[1].proposed,
                folderToken.map({ credentialToken(states[2]) == $0 })
                    ?? (states[2] == prepared.components[2].proposed),
                states[3] == prepared.components[3].proposed
            else { throw AccountSwitchError.verificationFailed }
            try await prepared.recovery.completeSwitch(prepared.id, verifiedStates: states)
        } catch {
            try await restore(prepared, after: error)
        }
    }

    /// Source-compatible entry point for callers without a stored canonical ID.
    /// Production account providers pass the full selected identity instead.
    static func switchDefault(
        to folder: ClaudeCodeLoginSlot, expectedEmail: String?, keychain: ClaudeCodeKeychain = .system,
        refresher: ClaudeCodeCredentialReader.CLIRefresher, tokenOwner: ClaudeCodeFolderKeychain.TokenOwner
    ) async throws {
        guard let expectedEmail else { throw AccountSwitchError.ownerUnverified }
        try await switchDefault(
            to: folder, expectedIdentity: UsageAccountIdentity(email: expectedEmail),
            keychain: keychain, refresher: refresher, tokenOwner: tokenOwner)
    }

    static func verifyOwner(
        of slot: ClaudeCodeLoginSlot, expectedIdentity selected: UsageAccountIdentity? = nil,
        keychain: ClaudeCodeKeychain = .system,
        refresher: ClaudeCodeCredentialReader.CLIRefresher, tokenOwner: ClaudeCodeFolderKeychain.TokenOwner,
        recoveryCoordinator: CredentialRecoveryCoordinator? = nil, switchOperationID: UUID? = nil
    ) async throws -> String {
        guard let observed = slot.identity(), observed.accountID != nil || observed.email != nil else {
            throw AccountSwitchError.ownerUnverified
        }
        let expected = selected ?? observed
        guard expected.accountID != nil || expected.email != nil,
            UsageAccountFetchBinding.matches(expected: expected, observed: observed)
        else { throw AccountSwitchError.ownerMismatch }
        var snapshot = try await slot.readSnapshot(keychain: keychain)
        var credential = credential(in: snapshot)
        if credential?.isExpired == true {
            try Task.checkCancellation()
            let recovery = recoveryCoordinator ?? CredentialRecoveryCoordinator.operationDefault(keychain: keychain)
            guard let currentCredential = credential,
                await recovery.canRefreshCLIGeneration(currentCredential, duringSwitch: switchOperationID)
            else {
                throw AccountSwitchError.ownerUnverified
            }
            switch await refresher(slot.cliConfigDirectoryValue) {
            case .refreshed:
                snapshot = try await slot.readSnapshot(keychain: keychain)
                credential = self.credential(in: snapshot)
            case .notLoggedIn: throw AccountSwitchError.unavailable
            case .executableNotFound, .unavailable: throw AccountSwitchError.ownerUnverified
            }
        }
        try Task.checkCancellation()
        guard let credential, !credential.isExpired, let owner = await tokenOwner(credential.accessToken) else {
            throw AccountSwitchError.ownerUnverified
        }
        guard UsageAccountFetchBinding.matches(expected: expected, observed: owner),
            UsageAccountFetchBinding.matches(expected: observed, observed: owner)
        else { throw AccountSwitchError.ownerMismatch }
        let latest = try await slot.readSnapshot(keychain: keychain, interactive: false)
        guard latest == snapshot else { throw AccountSwitchError.busy }
        return credential.accessToken
    }

    private static func credential(in snapshot: ClaudeCodeLoginSlot.Snapshot) -> ClaudeCodeOAuthCredential? {
        ClaudeCodeCredentialReader.parseCredential(
            from: String(decoding: snapshot.credential, as: UTF8.self), source: .refreshed)
    }

    private static func credentialToken(_ data: Data?) -> String? {
        data.flatMap {
            ClaudeCodeCredentialReader.parseCredential(
                from: String(decoding: $0, as: UTF8.self), source: .refreshed)?.accessToken
        }
    }

    static func switchSlots(
        _ defaultSlot: ClaudeCodeLoginSlot, _ folderSlot: ClaudeCodeLoginSlot, expectedEmail: String?,
        expectedFolderToken: String? = nil, keychain: ClaudeCodeKeychain = .system,
        recoveryCoordinator: CredentialRecoveryCoordinator? = nil,
        verify: @Sendable () async -> String?
    ) async throws {
        let prepared = try await prepare(
            defaultSlot, folderSlot, expectedIdentity: nil, expectedSecondToken: expectedFolderToken,
            keychain: keychain, recoveryCoordinator: recoveryCoordinator)
        do {
            try await prepared.recovery.applySwitch(prepared.id)
            try Task.checkCancellation()
            let actual = await verify()
            guard let expectedEmail, actual?.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
                throw AccountSwitchError.verificationFailed
            }
            let states = try await prepared.recovery.switchStates(prepared.id)
            guard states == prepared.components.map(\.proposed) else { throw AccountSwitchError.verificationFailed }
            try await prepared.recovery.completeSwitch(prepared.id, verifiedStates: states)
        } catch { try await restore(prepared, after: error) }
    }

    static func swap(
        _ a: ClaudeCodeLoginSlot, _ b: ClaudeCodeLoginSlot, expectedSecondToken: String? = nil,
        keychain: ClaudeCodeKeychain = .system, recoveryCoordinator: CredentialRecoveryCoordinator? = nil
    ) async throws {
        let prepared = try await prepare(
            a, b, expectedIdentity: nil, expectedSecondToken: expectedSecondToken,
            keychain: keychain, recoveryCoordinator: recoveryCoordinator)
        do {
            try await prepared.recovery.applySwitch(prepared.id)
            try await prepared.recovery.completeSwitch(prepared.id, verifiedStates: prepared.components.map(\.proposed))
        } catch { try await restore(prepared, after: error) }
    }

    private static func prepare(
        _ a: ClaudeCodeLoginSlot, _ b: ClaudeCodeLoginSlot, expectedIdentity: UsageAccountIdentity?,
        expectedSecondToken: String?, keychain: ClaudeCodeKeychain,
        recoveryCoordinator: CredentialRecoveryCoordinator?
    ) async throws -> Prepared {
        let slots = [a, b].sorted {
            $0.configDirectory.resolvingSymlinksInPath().path < $1.configDirectory.resolvingSymlinksInPath().path
        }
        guard slots[0].configDirectory.resolvingSymlinksInPath() != slots[1].configDirectory.resolvingSymlinksInPath()
        else {
            throw AccountSwitchError.unavailable
        }
        let locks = slots.map {
            ClaudeCodeDirectoryLock(configDirectory: $0.configDirectory, profileFile: $0.profileFile)
        }
        defer { for lock in locks.reversed() { lock.release() } }
        for lock in locks { try await BlockingWork.run { try lock.acquire() } }
        try Task.checkCancellation()
        let first = try await a.readSnapshot(keychain: keychain)
        let second = try await b.readSnapshot(keychain: keychain)
        if let expectedSecondToken, credential(in: second)?.accessToken != expectedSecondToken {
            throw AccountSwitchError.busy
        }
        if let expectedIdentity {
            guard let current = b.identity(),
                UsageAccountFetchBinding.matches(expected: expectedIdentity, observed: current)
            else {
                throw AccountSwitchError.ownerMismatch
            }
        }
        let components =
            try a.recoveryComponents(replacing: first, with: second)
            + b.recoveryComponents(replacing: second, with: first)
        let recovery = recoveryCoordinator ?? CredentialRecoveryCoordinator.operationDefault(keychain: keychain)
        let id: UUID
        do {
            id = try await recovery.beginSwitch(
                provider: .claude, accountID: expectedIdentity?.mergeKey ?? b.identity()?.mergeKey,
                components: components,
                claudeLockLocations: slots.map {
                    .init(configDirectory: $0.configDirectory, profileFile: $0.profileFile)
                },
                affectedAccountIDs: [a.identity()?.mergeKey, b.identity()?.mergeKey].compactMap { $0 })
        } catch { throw mapped(error) }
        return Prepared(id: id, recovery: recovery, components: components, originalIdentity: a.identity())
    }

    private static func restore(_ prepared: Prepared, after error: Error) async throws {
        if error as? AccountSwitchError == .recoveryPending { throw AccountSwitchError.recoveryPending }
        // A caller's cancellation must not discard the only saved originals.
        do {
            try await Task.detached { try await prepared.recovery.rollbackSwitch(prepared.id) }.value
        } catch AccountSwitchError.recoveryPending {
            throw AccountSwitchError.recoveryPending
        } catch {
            await prepared.recovery.releaseSwitch(prepared.id)
            throw AccountSwitchError.rollbackFailed
        }
        throw mapped(error)
    }

    static func mapped(_ error: Error) -> Error {
        if let error = error as? AccountSwitchError { return error }
        if error is CancellationError { return AccountSwitchError.cancelled }
        switch error as? CredentialRecoveryError {
        case .busy, .changed, .unsupported: return AccountSwitchError.busy
        case .unreadable: return AccountSwitchError.unavailable
        case .sealed: return AccountSwitchError.cancelled
        case .writeFailed, .none: return AccountSwitchError.writeFailed
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

    /// Same-volume RENAME_SWAP remains the first choice. The journal-backed
    /// fallback replaces each physical target from a verified 0600 temporary on
    /// that target's volume, with both complete originals already in Keychain.
    static func swapAuthFiles(
        _ a: URL, _ b: URL, recoveryCoordinator: CredentialRecoveryCoordinator? = nil,
        preferAtomicExchange: Bool = true
    ) async throws {
        let recovery = recoveryCoordinator ?? CredentialRecoveryCoordinator.operationDefault()
        let components = try switchComponents(a, b)
        let id: UUID
        do {
            id = try await recovery.beginSwitch(
                provider: .codex, accountID: nil, components: components, preferAtomicExchange: preferAtomicExchange)
        } catch { throw ClaudeAccountSwitcher.mapped(error) }
        do {
            try await recovery.applySwitch(id)
            try await recovery.completeSwitch(id, verifiedStates: components.map(\.proposed))
        } catch { try await restore(recovery, id: id, after: error) }
    }

    static func switchDefault(
        to folder: URL, expectedIdentity: UsageAccountIdentity,
        owner: any CodexOwnedRateLimitsReading = CodexOwnerCLI(),
        defaultHome: URL = CodexAuthManager.defaultHomeURL,
        recoveryCoordinator: CredentialRecoveryCoordinator? = nil
    ) async throws {
        guard expectedIdentity.email?.isEmpty == false, expectedIdentity.organizationID?.isEmpty == false,
            defaultHome.resolvingSymlinksInPath() != folder.resolvingSymlinksInPath(),
            let originalIdentity = CodexHomeAccount.identity(home: defaultHome),
            originalIdentity.email?.isEmpty == false, originalIdentity.organizationID?.isEmpty == false
        else { throw AccountSwitchError.ownerUnverified }
        let selected = try await CodexHomeAccount.fetchOwnedUsage(
            home: folder, expectedIdentity: expectedIdentity, owner: owner)
        let original = try await CodexHomeAccount.fetchOwnedUsage(
            home: defaultHome, expectedIdentity: originalIdentity, owner: owner)
        try Task.checkCancellation()
        guard try await CodexHomeAccount.currentCredentialRevision(home: folder) == selected.credentialRevision,
            try await CodexHomeAccount.currentCredentialRevision(home: defaultHome) == original.credentialRevision
        else { throw AccountSwitchError.busy }
        let components = try switchComponents(
            CodexHomeAccount.authFile(in: defaultHome), CodexHomeAccount.authFile(in: folder))
        guard try await CodexHomeAccount.currentCredentialRevision(home: folder) == selected.credentialRevision,
            try await CodexHomeAccount.currentCredentialRevision(home: defaultHome) == original.credentialRevision
        else { throw AccountSwitchError.busy }
        let recovery = recoveryCoordinator ?? CredentialRecoveryCoordinator.operationDefault()
        let id: UUID
        do {
            id = try await recovery.beginSwitch(
                provider: .codex, accountID: expectedIdentity.mergeKey,
                components: components, preferAtomicExchange: true,
                affectedAccountIDs: [expectedIdentity.mergeKey, originalIdentity.mergeKey].compactMap { $0 })
        } catch { throw ClaudeAccountSwitcher.mapped(error) }
        do {
            try await recovery.applySwitch(id)
            try Task.checkCancellation()
            let selectedAfter = try await CodexHomeAccount.fetchOwnedUsage(
                home: defaultHome, expectedIdentity: expectedIdentity, owner: owner)
            let originalAfter = try await CodexHomeAccount.fetchOwnedUsage(
                home: folder, expectedIdentity: originalIdentity, owner: owner)
            let states = try await recovery.switchStates(id)
            guard
                try await CodexHomeAccount.currentCredentialRevision(home: defaultHome)
                    == selectedAfter.credentialRevision,
                try await CodexHomeAccount.currentCredentialRevision(home: folder) == originalAfter.credentialRevision
            else { throw AccountSwitchError.busy }
            try Task.checkCancellation()
            try await recovery.completeSwitch(id, verifiedStates: states)
        } catch { try await restore(recovery, id: id, after: error) }
    }

    private static func switchComponents(_ a: URL, _ b: URL) throws -> [CredentialRecoverySwitchComponent] {
        let first = CredentialRecoveryLocation.file(a)
        let second = CredentialRecoveryLocation.file(b)
        guard first.physicalPath != second.physicalPath,
            let originalA = try CredentialRecoveryFile.read(first),
            let originalB = try CredentialRecoveryFile.read(second)
        else { throw AccountSwitchError.unavailable }
        let components: [CredentialRecoverySwitchComponent] = [
            .init(location: first, original: originalA, proposed: originalB),
            .init(location: second, original: originalB, proposed: originalA),
        ]
        do { try CredentialRecoveryFile.refuseAliases(components) } catch { throw AccountSwitchError.unavailable }
        return components
    }

    private static func restore(_ recovery: CredentialRecoveryCoordinator, id: UUID, after error: Error) async throws {
        if error as? AccountSwitchError == .recoveryPending { throw AccountSwitchError.recoveryPending }
        do { try await Task.detached { try await recovery.rollbackSwitch(id) }.value } catch AccountSwitchError
            .recoveryPending
        { throw AccountSwitchError.recoveryPending } catch {
            await recovery.releaseSwitch(id)
            throw AccountSwitchError.rollbackFailed
        }
        throw ClaudeAccountSwitcher.mapped(error)
    }
}
