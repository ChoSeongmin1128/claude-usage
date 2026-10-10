import XCTest
@testable import ClaudeUsage

/// 임시 폴더만 쓴다. 실제 Claude Code와 Codex 로그인은 건드리지 않는다.
final class AccountSwitchingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func slot(_ name: String, email: String, token: String) throws -> ClaudeCodeLoginSlot {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": token]])
            .write(to: directory.appendingPathComponent(".credentials.json"))
        try JSONSerialization.data(withJSONObject: [
            "oauthAccount": ["emailAddress": email], "theme": "dark",
        ]).write(to: directory.appendingPathComponent(".claude.json"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent(".claude.json").path)
        return ClaudeCodeLoginSlot(
            configDirectory: directory, profileFile: directory.appendingPathComponent(".claude.json"),
            keychainService: "claudeusage.test.missing.\(UUID().uuidString)", isDefault: false)
    }

    private func token(in slot: ClaudeCodeLoginSlot) throws -> String? {
        let text = try String(contentsOf: slot.credentialFiles[0], encoding: .utf8)
        return ClaudeCodeCredentialReader.parseCredential(from: text, source: .refreshed)?.accessToken
    }

    func testClaudeSwapExchangesCredentialsAndAccountButKeepsOtherSettingsAndPermissions() async throws {
        let a = try slot("a", email: "a@example.com", token: "token-a")
        let b = try slot("b", email: "b@example.com", token: "token-b")

        try await ClaudeAccountSwitcher.swap(a, b, keychain: .none)

        XCTAssertEqual(try token(in: a), "token-b")
        XCTAssertEqual(try token(in: b), "token-a")
        let profile = try JSONSerialization.jsonObject(with: Data(contentsOf: a.profileFile)) as? [String: Any]
        XCTAssertEqual((profile?["oauthAccount"] as? [String: Any])?["emailAddress"] as? String, "b@example.com")
        XCTAssertEqual(profile?["theme"] as? String, "dark")
        let permissions = try FileManager.default.attributesOfItem(atPath: a.profileFile.path)[.posixPermissions]
        XCTAssertEqual(permissions as? Int, 0o600, ".claude.json에는 다른 비밀 값이 있을 수 있어 권한을 지킵니다")
        for directory in [a.configDirectory, b.configDirectory] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(".storage-write.lock").path))
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(".oauth_refresh.lock").path))
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: ClaudeCodeDirectoryLock.legacyRefreshLock(for: directory).path))
        }
    }

    func testSwitchRestoresBothLoginsWhenVerificationShowsAnotherAccount() async throws {
        let main = try slot("main", email: "a@example.com", token: "token-a")
        let folder = try slot("folder", email: "b@example.com", token: "token-b")

        do {
            try await ClaudeAccountSwitcher.switchSlots(
                main, folder, expectedEmail: "b@example.com", keychain: .none, verify: { "a@example.com" })
            XCTFail("확인에 실패하면 오류를 내야 합니다")
        } catch {
            XCTAssertEqual(error as? AccountSwitchError, .verificationFailed)
        }
        XCTAssertEqual(try token(in: main), "token-a")
        XCTAssertEqual(try token(in: folder), "token-b")
    }

    func testSwitchWithoutKnownEmailIsNotTreatedAsVerified() async throws {
        let main = try slot("main", email: "a@example.com", token: "token-a")
        let folder = try slot("folder", email: "b@example.com", token: "token-b")

        do {
            try await ClaudeAccountSwitcher.switchSlots(
                main, folder, expectedEmail: nil, keychain: .none, verify: { "b@example.com" })
            XCTFail("확인할 이메일이 없으면 성공으로 보면 안 됩니다")
        } catch {
            XCTAssertEqual(error as? AccountSwitchError, .verificationFailed)
        }
        XCTAssertEqual(try token(in: main), "token-a")
    }

    func testSwapLeavesBothLoginsWhenSecondProfileCannotBeWritten() async throws {
        let a = try slot("a", email: "a@example.com", token: "token-a")
        let b = try slot("b", email: "b@example.com", token: "token-b")
        try FileManager.default.removeItem(at: b.profileFile)

        do {
            try await ClaudeAccountSwitcher.swap(a, b, keychain: .none)
            XCTFail("프로필을 쓰지 못하면 오류를 내야 합니다")
        } catch {
            XCTAssertEqual(error as? AccountSwitchError, .writeFailed)
        }
        XCTAssertEqual(try token(in: a), "token-a")
        XCTAssertEqual(try token(in: b), "token-b")
        let profile = try JSONSerialization.jsonObject(with: Data(contentsOf: a.profileFile)) as? [String: Any]
        XCTAssertEqual((profile?["oauthAccount"] as? [String: Any])?["emailAddress"] as? String, "a@example.com")
        let permissions = try FileManager.default.attributesOfItem(atPath: a.credentialFiles[0].path)[.posixPermissions]
        XCTAssertEqual(permissions as? Int, 0o600)
    }

    func testKeychainLoginIsWrittenBackThroughSecurityToolFirst() async throws {
        let a = try slot("a", email: "a@example.com", token: "token-a")
        let b = try slot("b", email: "b@example.com", token: "token-b")
        let written = WrittenPayloads()
        var keychain = ClaudeCodeKeychain.none
        keychain.read = { service in
            service == a.keychainService ? .payload(#"{"claudeAiOauth":{"accessToken":"keychain-a"}}"#) : .notFound
        }
        keychain.update = { service, payload in
            written.record(service, payload)
            return true
        }
        keychain.updateDirectly = { _, _ in
            XCTFail("security 도구로 쓰면 직접 쓰지 않습니다")
            return false
        }

        try await ClaudeAccountSwitcher.swap(a, b, keychain: keychain)

        XCTAssertEqual(written.services, [a.keychainService])
        XCTAssertEqual(try token(in: b), "keychain-a")
    }

    func testTerminalCodexCountExcludesProcessesInsideChatGPTApp() {
        let processes: [(pid: pid_t, path: String)] = [
            (10, "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
            (11, "/opt/homebrew/bin/codex"),
            (12, "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"),
            (13, "/usr/bin/codexbar"),
        ]
        XCTAssertEqual(
            CodexAccountSwitcher.terminalCodexProcesses(
                processes, appPIDs: [12], appBundlePaths: ["/Applications/ChatGPT.app"]),
            [11])
    }

    func testLockWaitsForOlderClaudeCodeHoldingTheLegacyLock() throws {
        let directory = root.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = ClaudeCodeDirectoryLock.legacyRefreshLock(for: directory)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
        XCTAssertEqual(legacy.lastPathComponent, "legacy.lock")

        XCTAssertThrowsError(try ClaudeCodeDirectoryLock(configDirectory: directory).acquire(timeout: 0.3)) {
            XCTAssertEqual($0 as? AccountSwitchError, .busy)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(".oauth_refresh.lock").path),
            "잡지 못하면 먼저 잡은 잠금도 놓아야 합니다")
    }

    func testNonemptyStaleLockStillTimesOutAndReleasesPreviouslyAcquiredLocks() throws {
        let directory = root.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocked = ClaudeCodeDirectoryLock.legacyRefreshLock(for: directory)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try Data("held".utf8).write(to: blocked.appendingPathComponent("owner"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: blocked.path)
        let start = Date()
        XCTAssertThrowsError(try ClaudeCodeDirectoryLock(configDirectory: directory).acquire(timeout: 0.05)) {
            XCTAssertEqual($0 as? AccountSwitchError, .busy)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.appendingPathComponent("owner").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(".oauth_refresh.lock").path))
    }

    func testLockWaitsForLiveHolderButClearsStaleLock() throws {
        let directory = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let live = directory.appendingPathComponent(".oauth_refresh.lock")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: false)

        XCTAssertThrowsError(try ClaudeCodeDirectoryLock(configDirectory: directory).acquire(timeout: 0.3)) {
            XCTAssertEqual($0 as? AccountSwitchError, .busy)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: live.path)
        let lock = ClaudeCodeDirectoryLock(configDirectory: directory)
        XCTAssertNoThrow(try lock.acquire(timeout: 0.3))
        lock.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
    }

    func testCodexAuthFilesSwapAtomically() throws {
        let a = root.appendingPathComponent("home/auth.json")
        let b = root.appendingPathComponent("other/auth.json")
        for (url, value) in [(a, "A"), (b, "B")] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url)
        }

        try CodexAccountSwitcher.swapAuthFiles(a, b)

        XCTAssertEqual(String(decoding: try Data(contentsOf: a), as: UTF8.self), "B")
        XCTAssertEqual(String(decoding: try Data(contentsOf: b), as: UTF8.self), "A")
        XCTAssertThrowsError(
            try CodexAccountSwitcher.swapAuthFiles(a, root.appendingPathComponent("missing/auth.json")))
        XCTAssertEqual(String(decoding: try Data(contentsOf: a), as: UTF8.self), "B")
    }
}

private final class WrittenPayloads: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var services: [String] = []

    func record(_ service: String, _ payload: Data) {
        lock.withLock { services.append(service) }
    }
}
