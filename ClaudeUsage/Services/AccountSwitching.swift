import AppKit
import Darwin
import Foundation
import Security

/// 계정 전환은 기본 로그인과 다른 폴더의 로그인을 맞바꾼다. 복사하지 않으므로 같은 refresh token이
/// 두 곳에 남지 않는다. 바꾼 뒤 공식 CLI로 확인하고, 다르면 되돌린다.
nonisolated enum AccountSwitchError: Error, Equatable {
    case busy
    case unavailable
    case cancelled
    case verificationFailed
    case writeFailed
}

// MARK: - Claude Code

/// Claude Code와 같은 잠금(proper-lockfile의 잠금 폴더)을 잡는다. 오래된 잠금은 Claude Code와 같은 기준으로 치운다.
nonisolated final class ClaudeCodeDirectoryLock: @unchecked Sendable {
    private let paths: [(url: URL, stale: TimeInterval)]
    private var held: [URL] = []
    private var timer: DispatchSourceTimer?

    init(configDirectory: URL) {
        paths = [
            (configDirectory.appendingPathComponent(".oauth_refresh.lock"), 60),
            (configDirectory.appendingPathComponent(".storage-write.lock"), 15),
        ]
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

/// Claude Code 로그인 한 벌: 자격 증명(Keychain 항목 또는 파일)과 `.claude.json`의 계정 정보.
nonisolated struct ClaudeCodeLoginSlot: Sendable {
    let configDirectory: URL
    let profileFile: URL
    let keychainService: String

    static func defaultSlot(home: URL = FileManager.default.realHomeDirectory) -> Self {
        let directory = home.appendingPathComponent(".claude", isDirectory: true)
        return Self(
            configDirectory: directory, profileFile: home.appendingPathComponent(".claude.json"),
            keychainService: "Claude Code-credentials")
    }

    static func folderSlot(_ directory: URL, home: URL = FileManager.default.realHomeDirectory) -> Self {
        Self(
            configDirectory: directory, profileFile: directory.appendingPathComponent(".claude.json"),
            keychainService: ClaudeCodeCredentialReader.keychainServiceName(
                for: directory, homeDirectory: home, usesExplicitConfigDirectory: true))
    }

    var credentialFile: URL { configDirectory.appendingPathComponent(".credentials.json") }

    struct Snapshot: Equatable {
        enum Storage: Equatable, Sendable { case keychain, file }
        let storage: Storage
        let credential: Data
        let account: Data?
    }

    /// 사용자가 전환을 누른 뒤에만 부른다. Keychain 항목은 macOS 확인 창을 거쳐 읽는다.
    func read() throws -> Snapshot {
        let account = Self.oauthAccount(in: profileFile)
        switch KeychainAccessPreflight.readGenericPasswordInteractively(
            service: keychainService, account: nil, localizedReason: "Claude Code 기본 로그인을 바꿉니다.")
        {
        case .value(let payload):
            return Snapshot(storage: .keychain, credential: Data(payload.utf8), account: account)
        case .cancelled:
            throw AccountSwitchError.cancelled
        case .notFound, .interactionRequired, .invalidData, .failure:
            guard let data = try? Data(contentsOf: credentialFile) else { throw AccountSwitchError.unavailable }
            return Snapshot(storage: .file, credential: data, account: account)
        }
    }

    /// 원래 저장 방식을 지킨다. Keychain에 있던 슬롯은 Keychain에, 파일이던 슬롯은 파일에 쓴다.
    func write(credential: Data, account: Data?, storage: Snapshot.Storage) throws {
        switch storage {
        case .keychain:
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
            ]
            guard
                SecItemUpdate(query as CFDictionary, [kSecValueData as String: credential] as CFDictionary)
                    == errSecSuccess
            else { throw AccountSwitchError.writeFailed }
        case .file:
            do {
                try credential.write(to: credentialFile, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialFile.path)
            } catch {
                throw AccountSwitchError.writeFailed
            }
        }
        try Self.replaceOAuthAccount(in: profileFile, with: account)
    }

    static func oauthAccount(in file: URL) -> Data? {
        guard let data = try? Data(contentsOf: file),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let account = object["oauthAccount"]
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: account)
    }

    /// `.claude.json`의 다른 설정은 그대로 두고 `oauthAccount`만 바꾼다.
    static func replaceOAuthAccount(in file: URL, with account: Data?) throws {
        guard let data = try? Data(contentsOf: file),
            var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            if account == nil { return }
            throw AccountSwitchError.writeFailed
        }
        object["oauthAccount"] = account.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        guard let output = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) else {
            throw AccountSwitchError.writeFailed
        }
        do { try output.write(to: file, options: .atomic) } catch { throw AccountSwitchError.writeFailed }
    }
}

nonisolated enum ClaudeAccountSwitcher {
    /// 기본 Claude Code 로그인을 폴더의 계정으로 바꾸고, 지금 기본 로그인은 그 폴더로 옮긴다.
    /// 실행 중인 Claude Code는 Keychain 캐시(30초)가 지나면 새 로그인을 쓴다.
    static func switchDefault(
        to folder: URL, expectedEmail: String?, workDirectory: URL,
        verify: (URL) async -> String? = { await defaultLoginEmail(workDirectory: $0) }
    ) async throws {
        let defaultSlot = ClaudeCodeLoginSlot.defaultSlot()
        let folderSlot = ClaudeCodeLoginSlot.folderSlot(folder)
        let original = try swap(defaultSlot, folderSlot)
        guard let expectedEmail else { return }
        let actual = await verify(workDirectory)
        guard actual?.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
            try? restore(defaultSlot, folderSlot, original)
            throw AccountSwitchError.verificationFailed
        }
    }

    @discardableResult
    static func swap(_ a: ClaudeCodeLoginSlot, _ b: ClaudeCodeLoginSlot) throws -> (
        ClaudeCodeLoginSlot.Snapshot, ClaudeCodeLoginSlot.Snapshot
    ) {
        let lockA = ClaudeCodeDirectoryLock(configDirectory: a.configDirectory)
        let lockB = ClaudeCodeDirectoryLock(configDirectory: b.configDirectory)
        try lockA.acquire()
        defer { lockA.release() }
        try lockB.acquire()
        defer { lockB.release() }
        // 잠금을 잡은 뒤 다시 읽는다. 직전에 갱신된 토큰을 놓치지 않기 위해서다.
        let first = try a.read()
        let second = try b.read()
        try a.write(credential: second.credential, account: second.account, storage: first.storage)
        do {
            try b.write(credential: first.credential, account: first.account, storage: second.storage)
        } catch {
            try? a.write(credential: first.credential, account: first.account, storage: first.storage)
            throw error
        }
        return (first, second)
    }

    static func restore(
        _ a: ClaudeCodeLoginSlot, _ b: ClaudeCodeLoginSlot,
        _ original: (ClaudeCodeLoginSlot.Snapshot, ClaudeCodeLoginSlot.Snapshot)
    ) throws {
        let lockA = ClaudeCodeDirectoryLock(configDirectory: a.configDirectory)
        let lockB = ClaudeCodeDirectoryLock(configDirectory: b.configDirectory)
        try lockA.acquire()
        defer { lockA.release() }
        try lockB.acquire()
        defer { lockB.release() }
        try a.write(credential: original.0.credential, account: original.0.account, storage: original.0.storage)
        try b.write(credential: original.1.credential, account: original.1.account, storage: original.1.storage)
    }

    static func defaultLoginEmail(workDirectory: URL) async -> String? {
        guard let claude = ClaudeCodeDirectoryAccount.executable() else { return nil }
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = claude
            process.arguments = ["auth", "status", "--json"]
            process.environment = [
                "HOME": FileManager.default.realHomeDirectory.path, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
            ]
            process.currentDirectoryURL = workDirectory
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["email"] as? String
        }.value
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
    static func runningCodex() -> RunningCodex {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").map(
            \.processIdentifier)
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var processes: [pid_t] = []
        let uid = getuid()
        for pid in pids.prefix(max(0, count)) where pid > 0 && pid != getpid() {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                info.pbi_uid == uid
            else { continue }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let url = URL(fileURLWithPath: String(cString: path))
            if url.lastPathComponent == "codex", !apps.contains(pid) { processes.append(pid) }
        }
        return RunningCodex(applications: apps, processes: processes)
    }

    /// 사용자가 "종료하고 전환"을 고른 뒤에만 부른다.
    static func terminate(_ running: RunningCodex, timeout: TimeInterval = 5) async -> Bool {
        for pid in running.applications { NSRunningApplication(processIdentifier: pid)?.terminate() }
        for pid in running.processes { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if runningCodex().isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return runningCodex().isEmpty
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
        verify: (URL, String) async -> Bool = { home, expected in
            (try? await CodexOwnerCLI().readRateLimits(
                sourceURL: home.appendingPathComponent("auth.json"), expectedAccountID: expected,
                budget: CodexRequestBudget(timeout: 20))) != nil
        }
    ) async throws {
        let defaultHome = URL(fileURLWithPath: CodexAuthManager.defaultAuthJsonPath()).deletingLastPathComponent()
        let defaultAuth = defaultHome.appendingPathComponent("auth.json")
        let folderAuth = folder.appendingPathComponent("auth.json")
        try swapAuthFiles(defaultAuth, folderAuth)
        guard await verify(defaultHome, expectedWorkspaceID) else {
            try? swapAuthFiles(defaultAuth, folderAuth)
            throw AccountSwitchError.verificationFailed
        }
    }
}
