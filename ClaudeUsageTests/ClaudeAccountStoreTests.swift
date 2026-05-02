import XCTest
@testable import ClaudeUsage

final class ClaudeAccountStoreTests: XCTestCase {
    private static var retainedObjects: [AnyObject] = []
    private var defaults: UserDefaults!
    private var vault: FakeClaudeSessionKeyVault!
    private var defaultBackups: [String: Any?] = [:]
    private let defaultKeys = [
        ClaudeAccountStore.accountsDefaultsKey,
        ClaudeAccountStore.activeAccountDefaultsKey,
        ClaudeAccountStore.migrationVersionDefaultsKey,
        ClaudeAccountStore.legacySessionKeyDefaultsKey,
        ClaudeAccountStore.legacyPreferredOrganizationDefaultsKey,
    ]

    override func setUp() {
        super.setUp()
        defaults = .standard
        defaultBackups = Dictionary(uniqueKeysWithValues: defaultKeys.map { ($0, defaults.object(forKey: $0)) })
        defaultKeys.forEach { defaults.removeObject(forKey: $0) }
        vault = FakeClaudeSessionKeyVault()
    }

    override func tearDown() {
        for key in defaultKeys {
            if let value = defaultBackups[key] ?? nil {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaultBackups = [:]
        super.tearDown()
    }

    func testLegacySessionKeyMigratesToScopedWebAccountOnce() throws {
        let legacySession = "sk-ant-legacy-session"
        let preferredOrganizationID = "org-company"
        try vault.saveString(legacySession, account: ClaudeKeychainStore.defaultAccount)
        defaults.set(preferredOrganizationID, forKey: ClaudeAccountStore.legacyPreferredOrganizationDefaultsKey)

        let store = makeStore()
        store.ensureLegacyMigrationIfNeeded()

        let state = store.state()
        XCTAssertEqual(state.accounts.count, 1)
        let account = try XCTUnwrap(state.activeAccount)
        XCTAssertEqual(account.kind, .webSession)
        XCTAssertEqual(account.source, .legacyMigration)
        XCTAssertEqual(account.preferredOrganizationID, preferredOrganizationID)
        XCTAssertEqual(account.identity.fingerprint, ClaudeAccountStore.fingerprint(for: legacySession))
        XCTAssertNil(try vault.loadString(account: ClaudeKeychainStore.defaultAccount))
        XCTAssertEqual(
            try vault.loadString(account: ClaudeKeychainStore.accountName(for: account.id)),
            legacySession
        )
        XCTAssertEqual(
            defaults.integer(forKey: ClaudeAccountStore.migrationVersionDefaultsKey),
            ClaudeAccountStore.currentMigrationVersion
        )
    }

    func testMigrationFailureKeepsLegacyKeyAndDoesNotEnableMigration() throws {
        let legacySession = "sk-ant-legacy-session"
        try vault.saveString(legacySession, account: ClaudeKeychainStore.defaultAccount)
        vault.accountsThatFailOnSave.insert(ClaudeKeychainStore.accountName(
            for: ClaudeAccountStore.webSessionAccountID(
                fingerprint: ClaudeAccountStore.fingerprint(for: legacySession)
            )
        ))

        let store = makeStore()
        store.ensureLegacyMigrationIfNeeded()

        XCTAssertTrue(store.accounts().isEmpty)
        XCTAssertEqual(try vault.loadString(account: ClaudeKeychainStore.defaultAccount), legacySession)
        XCTAssertEqual(defaults.integer(forKey: ClaudeAccountStore.migrationVersionDefaultsKey), 0)
    }

    func testClaudeCodeAccountBecomesActiveOnlyWhenNoWebAccountExists() {
        let store = makeStore()

        let cliAccount = store.upsertClaudeCodeExternalAccount(
            identity: ClaudeAccountIdentity(email: "cli@example.com"),
            validationState: .detected,
            setActiveIfMissing: true
        )

        XCTAssertEqual(store.activeAccount()?.id, cliAccount.id)
        XCTAssertEqual(cliAccount.source, .claudeCodeCLI)

        _ = store.upsertWebSessionAccount(
            sessionKey: "sk-ant-company-session",
            preferredOrganizationID: "org-company",
            setActive: true
        )

        let activeWeb = store.activeAccount()
        XCTAssertEqual(activeWeb?.kind, .webSession)

        _ = store.upsertClaudeCodeExternalAccount(
            identity: ClaudeAccountIdentity(email: "cli-updated@example.com"),
            validationState: .verified,
            setActiveIfMissing: true
        )

        XCTAssertEqual(store.activeAccount()?.id, activeWeb?.id)
    }

    func testWebSessionSourceAndDetailAreStoredAndPreservedAcrossValidationUpdates() {
        let store = makeStore()

        let account = store.upsertWebSessionAccount(
            sessionKey: "sk-ant-company-session",
            preferredOrganizationID: "org-company",
            displayName: "Chrome Profile 2",
            source: .chromeProfile,
            sourceDetail: "Profile 2",
            lastValidationState: .verified
        )

        XCTAssertEqual(account.source, .chromeProfile)
        XCTAssertEqual(account.sourceDetail, "Profile 2")

        _ = store.upsertWebSessionAccount(
            sessionKey: "sk-ant-company-session",
            identity: ClaudeAccountIdentity(email: "company@example.com"),
            lastValidationState: .verified
        )

        let updated = store.accounts().first(where: { $0.id == account.id })
        XCTAssertEqual(updated?.source, .chromeProfile)
        XCTAssertEqual(updated?.sourceDetail, "Profile 2")
        XCTAssertEqual(updated?.identity.email, "company@example.com")
    }

    func testPreferredOrganizationUpdatesOnlyTargetAccount() {
        let store = makeStore()
        let first = store.upsertWebSessionAccount(sessionKey: "sk-ant-first", preferredOrganizationID: "org-a")
        let second = store.upsertWebSessionAccount(sessionKey: "sk-ant-second", preferredOrganizationID: "org-b")

        store.updatePreferredOrganizationID("org-updated", for: first.id)

        let accounts = Dictionary(uniqueKeysWithValues: store.accounts().map { ($0.id, $0) })
        XCTAssertEqual(accounts[first.id]?.preferredOrganizationID, "org-updated")
        XCTAssertEqual(accounts[second.id]?.preferredOrganizationID, "org-b")
    }

    func testUpsertingExistingWebSessionWithoutPreferredOrganizationKeepsExistingSelection() {
        let store = makeStore()
        let account = store.upsertWebSessionAccount(
            sessionKey: "sk-ant-company-session",
            preferredOrganizationID: "org-company",
            displayName: "Chrome 회사 프로필"
        )

        _ = store.upsertWebSessionAccount(sessionKey: "sk-ant-company-session")

        let updated = store.accounts().first(where: { $0.id == account.id })
        XCTAssertEqual(updated?.preferredOrganizationID, "org-company")
        XCTAssertEqual(updated?.displayName, "Chrome 회사 프로필")
    }

    private func makeStore() -> ClaudeAccountStore {
        let store = ClaudeAccountStore(defaults: defaults, keychainVault: vault, postsNotifications: false)
        Self.retainedObjects.append(store)
        return store
    }
}

private final class FakeClaudeSessionKeyVault: ClaudeSessionKeyVault, @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var values: [String: String] = [:]
    nonisolated(unsafe) var accountsThatFailOnSave = Set<String>()

    nonisolated func saveString(_ value: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if accountsThatFailOnSave.contains(account) {
            throw ClaudeKeychainStoreError.unexpectedStatus(errSecNotAvailable)
        }
        values[account] = value
    }

    nonisolated func loadString(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    nonisolated func delete(account: String) throws {
        lock.lock()
        values.removeValue(forKey: account)
        lock.unlock()
    }
}
