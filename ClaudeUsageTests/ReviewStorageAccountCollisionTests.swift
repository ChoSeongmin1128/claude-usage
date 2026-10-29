import Foundation
import XCTest
@testable import ClaudeUsage

@MainActor
final class ReviewStorageAccountCollisionTests: XCTestCase {
    func testEquivalentRawDuplicatesCoalesceAndHealthyMigrationCompletes() throws {
        try withDefaults { defaults in
            let vault = CollisionReviewVault()
            var raw = try record(account("equivalent"))
            raw["future"] = NSNull()
            defaults.set(try data([raw, raw]), forKey: ClaudeAccountStore.accountsDefaultsKey)
            defaults.set(1, forKey: ClaudeAccountStore.migrationVersionDefaultsKey)
            defaults.set("equivalent", forKey: ClaudeAccountStore.activeAccountDefaultsKey)
            try vault.saveString("fixture-credential", account: scoped("equivalent"))
            let store = makeStore(defaults, vault)

            store.ensureLegacyMigrationIfNeeded()

            XCTAssertEqual(store.accounts().map(\.id), ["equivalent"])
            XCTAssertEqual(store.activeAccount()?.id, "equivalent")
            XCTAssertTrue(store.canUseAccountID("equivalent"))
            XCTAssertEqual(
                defaults.integer(forKey: ClaudeAccountStore.migrationVersionDefaultsKey),
                ClaudeAccountStore.currentMigrationVersion)
            XCTAssertEqual(try vault.loadString(account: scoped("equivalent")), "fixture-credential")
            XCTAssertTrue(vault.deletedAccounts.isEmpty)
            let rows = try records(defaults)
            XCTAssertEqual(rows.count, 1)
            XCTAssertTrue(rows[0]["future"] is NSNull)
        }
    }

    func testDifferentIdentityOrDifferentUnknownRawFieldsQuarantineEveryDuplicate() throws {
        for changeIdentity in [true, false] {
            try withDefaults { defaults in
                let vault = CollisionReviewVault()
                var first = try record(account("collision"))
                first["future"] = NSNull()
                var second = first
                if changeIdentity {
                    second["identity"] = ["organizationID": "other-org"]
                } else {
                    second["future"] = ["new-format": true]
                }
                let original = try data([first, second])
                defaults.set(original, forKey: ClaudeAccountStore.accountsDefaultsKey)
                defaults.set(1, forKey: ClaudeAccountStore.migrationVersionDefaultsKey)
                defaults.set("collision", forKey: ClaudeAccountStore.activeAccountDefaultsKey)
                try vault.saveString("protected-credential", account: scoped("collision"))
                let store = makeStore(defaults, vault)

                store.ensureLegacyMigrationIfNeeded()
                XCTAssertTrue(store.accounts().isEmpty)
                XCTAssertNil(store.activeAccount())
                XCTAssertFalse(store.canUseAccountID("collision"))
                XCTAssertEqual(store.storedAccountIDs(), ["collision"])
                XCTAssertEqual(defaults.integer(forKey: ClaudeAccountStore.migrationVersionDefaultsKey), 1)
                assertJSON(try records(defaults), [first, second])
                store.deleteAccount(id: "collision")
                store.setActiveAccountID("collision")
                assertJSON(try records(defaults), [first, second])
                XCTAssertEqual(defaults.string(forKey: ClaudeAccountStore.activeAccountDefaultsKey), "collision")
                XCTAssertEqual(try vault.loadString(account: scoped("collision")), "protected-credential")
                XCTAssertTrue(vault.deletedAccounts.isEmpty)
            }
        }
    }

    func testUnverifiedRotatedAccountsStaySeparateWhileConflictRefsStayProtected() throws {
        try withDefaults { defaults in
            let vault = CollisionReviewVault()
            let old = account("healthy-old", source: .chromeProfile, age: 100)
            let new = account("healthy-new", source: .chromeProfile, age: 200)
            let conflictA = try record(account("collision", source: .chromeProfile))
            var conflictB = conflictA
            conflictB["identity"] = ["organizationID": "other-org"]
            defaults.set(
                try data([try record(old), conflictA, try record(new), conflictB]),
                forKey: ClaudeAccountStore.accountsDefaultsKey)
            defaults.set(1, forKey: ClaudeAccountStore.migrationVersionDefaultsKey)
            defaults.set("collision", forKey: ClaudeAccountStore.activeAccountDefaultsKey)
            for id in [old.id, new.id, "collision"] { try vault.saveString("fixture-\(id)", account: scoped(id)) }
            let store = makeStore(defaults, vault)

            store.ensureLegacyMigrationIfNeeded()

            XCTAssertEqual(store.accounts().map(\.id), [old.id, new.id])
            XCTAssertEqual(defaults.integer(forKey: ClaudeAccountStore.migrationVersionDefaultsKey), 1)
            XCTAssertEqual(store.storedAccountIDs(), [old.id, new.id, "collision"])
            XCTAssertEqual(defaults.string(forKey: ClaudeAccountStore.activeAccountDefaultsKey), "collision")
            XCTAssertNil(store.activeAccount())
            XCTAssertTrue(vault.deletedAccounts.isEmpty)
            XCTAssertEqual(try vault.loadString(account: scoped("collision")), "fixture-collision")
            let beforeRetry = try records(defaults)
            assertJSON(beforeRetry.filter { $0["id"] as? String == "collision" }, [conflictA, conflictB])
            store.ensureLegacyMigrationIfNeeded()
            assertJSON(try records(defaults), beforeRetry)
            XCTAssertTrue(vault.deletedAccounts.isEmpty)
            store.setActiveAccountID(new.id)
            XCTAssertEqual(store.activeAccount()?.id, new.id)
            XCTAssertEqual(store.storedAccountIDs(), [old.id, new.id, "collision"])
        }
    }

    func testHealthySaveKeepsOpaqueRecordAndActiveIDAndRejectsCredentialCollision() throws {
        try withDefaults { defaults in
            let vault = CollisionReviewVault()
            let session = "fixture-not-a-real-session"
            let id = ClaudeAccountStore.webSessionAccountID(fingerprint: ClaudeAccountStore.fingerprint(for: session))
            let opaque: [String: Any] = ["id": id, "kind": "future-kind", "future": NSNull()]
            defaults.set(
                try data([try record(account("healthy")), opaque]), forKey: ClaudeAccountStore.accountsDefaultsKey)
            defaults.set(
                ClaudeAccountStore.currentMigrationVersion, forKey: ClaudeAccountStore.migrationVersionDefaultsKey)
            defaults.set(id, forKey: ClaudeAccountStore.activeAccountDefaultsKey)
            try vault.saveString("protected", account: scoped(id))
            let store = makeStore(defaults, vault)

            store.updatePreferredOrganizationID("chosen-org", for: "healthy")

            let saved = try records(defaults)
            assertJSON(saved.first { $0["id"] as? String == id }, opaque)
            XCTAssertFalse(store.canUseAccountID(id))
            XCTAssertEqual(store.storedAccountIDs(), ["healthy", id])
            XCTAssertEqual(defaults.string(forKey: ClaudeAccountStore.activeAccountDefaultsKey), id)
            let result = store.upsertWebSessionAccountWithResult(sessionKey: session)
            XCTAssertFalse(result.wasStored)
            assertJSON(try records(defaults), saved)
            XCTAssertEqual(try vault.loadString(account: scoped(id)), "protected")
            XCTAssertTrue(vault.deletedAccounts.isEmpty)
        }
    }

    func testNewLoginBecomesActiveWhenUnreadableRecordIsActive() throws {
        try withDefaults { defaults in
            let opaque: [String: Any] = ["id": "web-future", "kind": "future-kind", "future": NSNull()]
            defaults.set(try data([opaque]), forKey: ClaudeAccountStore.accountsDefaultsKey)
            defaults.set(
                ClaudeAccountStore.currentMigrationVersion, forKey: ClaudeAccountStore.migrationVersionDefaultsKey)
            defaults.set("web-future", forKey: ClaudeAccountStore.activeAccountDefaultsKey)
            let store = makeStore(defaults, CollisionReviewVault())

            _ = store.upsertWebSessionAccount(sessionKey: "fixture-background", setActive: false)
            XCTAssertEqual(defaults.string(forKey: ClaudeAccountStore.activeAccountDefaultsKey), "web-future")

            let login = store.upsertWebSessionAccount(sessionKey: "fixture-login")
            XCTAssertEqual(store.activeAccount()?.id, login.id)
            assertJSON(try records(defaults).first { $0["id"] as? String == "web-future" }, opaque)
        }
    }

    func testRejectedInventoryWriteDoesNotRetireVaultReferenceOrDeleteAccount() throws {
        try withDefaults { defaults in
            let vault = CollisionReviewVault()
            let old = account("healthy-old", source: .chromeProfile)
            let original = try data([try record(old)])
            defaults.set(original, forKey: ClaudeAccountStore.accountsDefaultsKey)
            defaults.set(old.id, forKey: ClaudeAccountStore.activeAccountDefaultsKey)
            defaults.set(
                ClaudeAccountStore.currentMigrationVersion, forKey: ClaudeAccountStore.migrationVersionDefaultsKey)
            try vault.saveString("existing", account: scoped(old.id))
            let store = makeStore(defaults, vault)
            defaults.rejectInventory = true

            let result = store.upsertWebSessionAccountWithResult(
                sessionKey: "fixture-rotated-session", identity: old.identity,
                source: .chromeProfile, sourceDetail: old.sourceDetail)

            XCTAssertFalse(result.wasStored)
            XCTAssertEqual(defaults.data(forKey: ClaudeAccountStore.accountsDefaultsKey), original)
            XCTAssertEqual(store.accounts().map(\.id), [old.id])
            store.deleteAccount(id: old.id)
            XCTAssertEqual(defaults.data(forKey: ClaudeAccountStore.accountsDefaultsKey), original)
            XCTAssertEqual(try vault.loadString(account: scoped(old.id)), "existing")
            XCTAssertTrue(vault.deletedAccounts.isEmpty)
            XCTAssertEqual(defaults.string(forKey: ClaudeAccountStore.activeAccountDefaultsKey), old.id)
        }
    }

    func testUnreadableRootPreservesInventoryMarkerAndDisablesPruning() throws {
        for original in ["future-format", Data("{}".utf8)] as [Any] {
            try withDefaults { defaults in
                let vault = CollisionReviewVault()
                defaults.set(original, forKey: ClaudeAccountStore.accountsDefaultsKey)
                defaults.set(1, forKey: ClaudeAccountStore.migrationVersionDefaultsKey)
                let store = makeStore(defaults, vault)
                store.ensureLegacyMigrationIfNeeded()
                XCTAssertFalse(store.canPruneAccountData)
                XCTAssertFalse(store.canUseAccountID("unseen"))
                XCTAssertTrue(store.accounts().isEmpty)
                XCTAssertTrue(
                    (defaults.object(forKey: ClaudeAccountStore.accountsDefaultsKey) as? NSObject)?.isEqual(original)
                        == true)
                XCTAssertEqual(defaults.integer(forKey: ClaudeAccountStore.migrationVersionDefaultsKey), 1)
                XCTAssertTrue(vault.deletedAccounts.isEmpty)
                XCTAssertEqual(vault.readCount, 0)
            }
        }
    }

    private func account(_ id: String, source: ClaudeAccountSource = .manualInput, age: TimeInterval = 100)
        -> ClaudeAccount
    {
        ClaudeAccount(
            id: id, kind: .webSession, displayName: "Fixture", identity: .init(organizationID: "fixture-org"),
            source: source, sourceDetail: source == .chromeProfile ? "Fixture Profile" : nil,
            createdAt: Date(timeIntervalSinceReferenceDate: age), lastUsedAt: Date(timeIntervalSinceReferenceDate: age))
    }

    private func makeStore(_ defaults: UserDefaults, _ vault: CollisionReviewVault) -> ClaudeAccountStore {
        ClaudeAccountStore(
            defaults: defaults, keychainVault: vault, legacySandboxCredentialStore: nil, postsNotifications: false)
    }

    private func scoped(_ id: String) -> String { ClaudeKeychainStore.accountName(for: id) }

    private func record(_ account: ClaudeAccount) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any])
    }

    private func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func records(_ defaults: UserDefaults) throws -> [[String: Any]] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: ClaudeAccountStore.accountsDefaultsKey)))
                as? [[String: Any]])
    }

    private func assertJSON(_ actual: Any?, _ expected: Any?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue((actual as? NSObject)?.isEqual(expected) == true, file: file, line: line)
    }

    private func withDefaults(_ body: (CollisionReviewDefaults) throws -> Void) throws {
        let suite = "ReviewStorageAccountCollisionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(CollisionReviewDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}

private final class CollisionReviewDefaults: UserDefaults, @unchecked Sendable {
    nonisolated(unsafe) var rejectInventory = false
    override func set(_ value: Any?, forKey defaultName: String) {
        guard defaultName != ClaudeAccountStore.accountsDefaultsKey || !rejectInventory else { return }
        super.set(value, forKey: defaultName)
    }
}

private final class CollisionReviewVault: ClaudeSessionKeyVault, @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var values: [String: String] = [:]
    private nonisolated(unsafe) var deleted: [String] = []
    private nonisolated(unsafe) var reads = 0

    nonisolated var deletedAccounts: [String] {
        lock.lock(); defer { lock.unlock() }; return deleted
    }

    nonisolated var readCount: Int {
        lock.lock(); defer { lock.unlock() }; return reads
    }

    nonisolated func saveString(_ value: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }; values[account] = value
    }

    nonisolated func loadString(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }; reads += 1; return values[account]
    }

    nonisolated func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }; deleted.append(account); values.removeValue(forKey: account)
    }
}
