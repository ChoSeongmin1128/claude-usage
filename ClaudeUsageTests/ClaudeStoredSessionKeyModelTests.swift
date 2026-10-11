import Foundation
import XCTest
@testable import ClaudeUsage

@MainActor
final class ClaudeStoredSessionKeyModelTests: XCTestCase {
    func testReloadReadsKeychainOffTheMainThreadAndKeepsOnlyAFingerprint() async throws {
        try await withStore { store, vault in
            let account = store.upsertWebSessionAccount(sessionKey: "sk-ant-stored")
            try vault.saveString(
                " sessionKey=sk-ant-stored; ", account: ClaudeKeychainStore.accountName(for: account.id))
            let reads = ReadLog()
            let model = ClaudeStoredSessionKeyModel(accountStore: store) { accountID in
                reads.record(isMainThread: Thread.isMainThread)
                return (try? vault.loadString(account: ClaudeKeychainStore.accountName(for: accountID))) ?? nil
            }
            XCTAssertFalse(model.hasStoredKey)

            await model.reload().value

            XCTAssertEqual(reads.mainThreadReads, [false])
            XCTAssertEqual(model.fingerprint, ClaudeAccountStore.fingerprint(for: "sk-ant-stored"))
            XCTAssertTrue(model.matches("sk-ant-stored"))
            XCTAssertFalse(model.matches("sk-ant-other"))
            XCTAssertFalse(model.matches(""))
        }
    }

    func testLateReloadDoesNotOverwriteAJustSavedKey() async throws {
        try await withStore { store, _ in
            _ = store.upsertWebSessionAccount(sessionKey: "sk-ant-old")
            let gate = DispatchSemaphore(value: 0)
            let model = ClaudeStoredSessionKeyModel(accountStore: store) { _ in
                gate.wait()
                return "sk-ant-old"
            }

            let reload = model.reload()
            model.markSaved("sk-ant-new")
            gate.signal()
            await reload.value

            XCTAssertTrue(model.matches("sk-ant-new"))
            let loaded = await model.loadedFingerprint()
            XCTAssertEqual(loaded, ClaudeAccountStore.fingerprint(for: "sk-ant-new"))
        }
    }

    func testNoActiveWebAccountHasNoStoredKey() async throws {
        try await withStore { store, _ in
            let model = ClaudeStoredSessionKeyModel(accountStore: store) { _ in
                XCTFail("Without a web account the vault must not be read")
                return nil
            }
            await model.reload().value
            XCTAssertNil(model.fingerprint)
        }
    }

    func testSessionKeyInputKeepsOnlyTheKey() {
        XCTAssertEqual(ClaudeSessionKeyInput.normalize("  sessionKey=\"sk-ant-abc\"; Path=/ "), "sk-ant-abc")
        XCTAssertEqual(ClaudeSessionKeyInput.normalize("SESSIONKEY=sk-ant-abc"), "sk-ant-abc")
        XCTAssertEqual(ClaudeSessionKeyInput.normalize("\"\""), "")
    }

    private func withStore(_ operation: (ClaudeAccountStore, MemoryVault) async throws -> Void) async throws {
        let suite = "ClaudeStoredSessionKeyModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = MemoryVault()
        let store = ClaudeAccountStore(defaults: defaults, keychainVault: vault, postsNotifications: false)
        try await operation(store, vault)
    }
}

private final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    nonisolated func record(isMainThread: Bool) {
        lock.withLock { values.append(isMainThread) }
    }

    var mainThreadReads: [Bool] { lock.withLock { values } }
}

private final class MemoryVault: ClaudeSessionKeyVault, @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var values: [String: String] = [:]

    nonisolated func saveString(_ value: String, account: String) throws {
        lock.withLock { values[account] = value }
    }

    nonisolated func loadString(account: String) throws -> String? {
        lock.withLock { values[account] }
    }

    nonisolated func delete(account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: account) }
    }
}
