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
        return ClaudeCodeLoginSlot(
            configDirectory: directory, profileFile: directory.appendingPathComponent(".claude.json"),
            keychainService: "claudeusage.test.missing.\(UUID().uuidString)")
    }

    private func token(in slot: ClaudeCodeLoginSlot) throws -> String? {
        let data = try Data(contentsOf: slot.credentialFile)
        guard case .token(let value, _) = ClaudeCodeDirectoryAccount.parse(data) else { return nil }
        return value
    }

    func testClaudeSwapExchangesCredentialsAndAccountButKeepsOtherSettings() throws {
        let a = try slot("a", email: "a@example.com", token: "token-a")
        let b = try slot("b", email: "b@example.com", token: "token-b")

        try ClaudeAccountSwitcher.swap(a, b)

        XCTAssertEqual(try token(in: a), "token-b")
        XCTAssertEqual(try token(in: b), "token-a")
        let profile = try JSONSerialization.jsonObject(with: Data(contentsOf: a.profileFile)) as? [String: Any]
        XCTAssertEqual((profile?["oauthAccount"] as? [String: Any])?["emailAddress"] as? String, "b@example.com")
        XCTAssertEqual(profile?["theme"] as? String, "dark")
        for directory in [a.configDirectory, b.configDirectory] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(".storage-write.lock").path))
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(".oauth_refresh.lock").path))
        }
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
