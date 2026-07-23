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

    func testRotatedChromeSessionReplacesSameProfileAndOrganization() {
        let store = makeStore()
        let first = store.upsertWebSessionAccount(
            sessionKey: "sk-ant-old-cookie",
            identity: ClaudeAccountIdentity(
                organizationName: "Glorang",
                organizationID: "org-company"
            ),
            displayName: "Chrome Nathan",
            source: .chromeProfile,
            sourceDetail: "Nathan (Profile 2) · nathan@example.com",
            lastValidationState: .verified
        )

        let result = store.upsertWebSessionAccountReplacingRotatedChromeSession(
            sessionKey: "sk-ant-new-cookie",
            identity: ClaudeAccountIdentity(
                organizationName: "Glorang",
                organizationID: "org-company"
            ),
            displayName: "Chrome Nathan",
            source: .chromeProfile,
            sourceDetail: "Nathan (Profile 2) · nathan@example.com",
            lastValidationState: .verified
        )

        XCTAssertEqual(result.supersededAccountIDs, [first.id])
        XCTAssertEqual(store.accounts().map(\.id), [result.account.id])
        XCTAssertEqual(store.activeAccount()?.id, result.account.id)
    }

    func testRotatedChromeSessionKeepsDifferentOrganizationAccount() {
        let store = makeStore()
        let first = store.upsertWebSessionAccount(
            sessionKey: "sk-ant-personal-cookie",
            identity: ClaudeAccountIdentity(organizationID: "org-personal"),
            source: .chromeProfile,
            sourceDetail: "Nathan (Profile 2) · nathan@example.com"
        )

        let result = store.upsertWebSessionAccountReplacingRotatedChromeSession(
            sessionKey: "sk-ant-company-cookie",
            identity: ClaudeAccountIdentity(organizationID: "org-company"),
            source: .chromeProfile,
            sourceDetail: "Nathan (Profile 2) · nathan@example.com"
        )

        XCTAssertTrue(result.supersededAccountIDs.isEmpty)
        XCTAssertEqual(Set(store.accounts().map(\.id)), Set([first.id, result.account.id]))
    }

    func testRotatedChromeSessionPreservesExplicitOrganizationSelection() {
        let store = makeStore()
        _ = store.upsertWebSessionAccount(
            sessionKey: "sk-ant-old-cookie",
            preferredOrganizationID: "org-company",
            identity: ClaudeAccountIdentity(organizationID: "org-company"),
            source: .chromeProfile,
            sourceDetail: "Nathan (Profile 2) · nathan@example.com"
        )

        let result = store.upsertWebSessionAccountReplacingRotatedChromeSession(
            sessionKey: "sk-ant-new-cookie",
            preferredOrganizationID: "",
            identity: ClaudeAccountIdentity(organizationID: "org-company"),
            source: .chromeProfile,
            sourceDetail: "Nathan (Profile 2) · nathan@example.com"
        )

        XCTAssertEqual(store.accounts().count, 1)
        XCTAssertEqual(result.account.preferredOrganizationID, "org-company")
        XCTAssertEqual(result.account.preferredOrganizationWasUserSelected, true)
        XCTAssertEqual(result.account.userSelectedPreferredOrganizationID, "org-company")
    }

    func testVersionTwoMigrationConsolidatesExistingRotatedChromeSessions() throws {
        let cli = ClaudeAccount(
            id: ClaudeAccountStore.claudeCodeExternalAccountID,
            kind: .claudeCodeExternal,
            displayName: "team",
            source: .claudeCodeCLI,
            lastValidationState: .verified
        )
        let older = ClaudeAccount(
            id: "web-old",
            kind: .webSession,
            displayName: "Chrome Nathan",
            identity: ClaudeAccountIdentity(
                organizationName: "Glorang",
                organizationID: "org-company",
                fingerprint: "old-fingerprint"
            ),
            source: .chromeProfile,
            sourceDetail: "Nathan (Profile 2) · nathan@example.com",
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            lastUsedAt: Date(timeIntervalSinceReferenceDate: 300),
            lastValidationState: .verified
        )
        let newer = ClaudeAccount(
            id: "web-new",
            kind: .webSession,
            displayName: "Chrome Nathan",
            identity: ClaudeAccountIdentity(
                organizationName: "Glorang",
                organizationID: "org-company",
                fingerprint: "new-fingerprint"
            ),
            source: .chromeProfile,
            sourceDetail: "Nathan (Profile 2) · nathan@example.com",
            createdAt: Date(timeIntervalSinceReferenceDate: 200),
            lastUsedAt: Date(timeIntervalSinceReferenceDate: 250),
            lastValidationState: .verified
        )
        defaults.set(
            try JSONEncoder().encode([cli, older, newer]),
            forKey: ClaudeAccountStore.accountsDefaultsKey
        )
        defaults.set(cli.id, forKey: ClaudeAccountStore.activeAccountDefaultsKey)
        defaults.set(1, forKey: ClaudeAccountStore.migrationVersionDefaultsKey)
        try vault.saveString(
            "sk-ant-old-cookie",
            account: ClaudeKeychainStore.accountName(for: older.id)
        )
        try vault.saveString(
            "sk-ant-new-cookie",
            account: ClaudeKeychainStore.accountName(for: newer.id)
        )

        let store = makeStore()
        store.ensureLegacyMigrationIfNeeded()

        XCTAssertEqual(store.accounts().map(\.id), [cli.id, newer.id])
        XCTAssertEqual(store.activeAccount()?.id, cli.id)
        XCTAssertEqual(
            store.accounts().first(where: { $0.id == newer.id })?.lastUsedAt,
            older.lastUsedAt
        )
        XCTAssertNil(try vault.loadString(account: ClaudeKeychainStore.accountName(for: older.id)))
        XCTAssertEqual(
            try vault.loadString(account: ClaudeKeychainStore.accountName(for: newer.id)),
            "sk-ant-new-cookie"
        )
        XCTAssertEqual(
            defaults.integer(forKey: ClaudeAccountStore.migrationVersionDefaultsKey),
            ClaudeAccountStore.currentMigrationVersion
        )
    }

    func testPreferredOrganizationUpdatesOnlyTargetAccount() {
        let store = makeStore()
        let first = store.upsertWebSessionAccount(sessionKey: "sk-ant-first", preferredOrganizationID: "org-a")
        let second = store.upsertWebSessionAccount(sessionKey: "sk-ant-second", preferredOrganizationID: "org-b")

        store.updatePreferredOrganizationID("org-updated", for: first.id)

        let accounts = Dictionary(uniqueKeysWithValues: store.accounts().map { ($0.id, $0) })
        XCTAssertEqual(accounts[first.id]?.preferredOrganizationID, "org-updated")
        XCTAssertEqual(accounts[first.id]?.preferredOrganizationWasUserSelected, true)
        XCTAssertEqual(accounts[first.id]?.userSelectedPreferredOrganizationID, "org-updated")
        XCTAssertEqual(accounts[second.id]?.preferredOrganizationID, "org-b")
    }

    func testEmptyOrganizationPreferenceUsesAutomaticSelectionMode() {
        let store = makeStore()

        let account = store.upsertWebSessionAccount(
            sessionKey: "sk-ant-automatic",
            preferredOrganizationID: ""
        )

        XCTAssertEqual(account.preferredOrganizationID, "")
        XCTAssertEqual(account.preferredOrganizationWasUserSelected, false)
        XCTAssertNil(account.userSelectedPreferredOrganizationID)
    }

    func testLegacyStoredPreferenceWithoutSelectionMarkerIsTreatedAsAutomatic() throws {
        let legacy = ClaudeAccount(
            id: "legacy-web",
            kind: .webSession,
            displayName: "Chrome",
            identity: ClaudeAccountIdentity(
                organizationName: "personal@example.com's Organization",
                organizationID: "org-personal"
            ),
            source: .chromeProfile,
            preferredOrganizationID: "org-personal"
        )
        let encoded = try JSONEncoder().encode([legacy])
        var array = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [[String: Any]]
        )
        array[0].removeValue(forKey: "preferredOrganizationWasUserSelected")
        defaults.set(
            try JSONSerialization.data(withJSONObject: array),
            forKey: ClaudeAccountStore.accountsDefaultsKey
        )
        defaults.set(legacy.id, forKey: ClaudeAccountStore.activeAccountDefaultsKey)
        defaults.set(
            ClaudeAccountStore.currentMigrationVersion,
            forKey: ClaudeAccountStore.migrationVersionDefaultsKey
        )

        let decoded = try XCTUnwrap(makeStore().activeAccount())

        XCTAssertEqual(decoded.preferredOrganizationID, "org-personal")
        XCTAssertNil(decoded.preferredOrganizationWasUserSelected)
        XCTAssertNil(decoded.userSelectedPreferredOrganizationID)
    }

    func testReplaceIdentityClearsStaleClaudeCodeAccountMetadata() {
        let store = makeStore()
        let account = store.upsertClaudeCodeExternalAccount(
            identity: ClaudeAccountIdentity(
                email: "old@example.com",
                organizationName: "Old Org",
                organizationID: "old-org",
                planLabel: "Old Plan"
            ),
            validationState: .verified,
            setActiveIfMissing: true
        )

        store.replaceIdentity(ClaudeAccountIdentity(), for: account.id)
        store.updateValidationState(.detected, for: account.id)

        let updated = store.accounts().first(where: { $0.id == account.id })
        XCTAssertNil(updated?.identity.email)
        XCTAssertNil(updated?.identity.organizationName)
        XCTAssertNil(updated?.identity.organizationID)
        XCTAssertNil(updated?.identity.planLabel)
        XCTAssertEqual(updated?.lastValidationState, .detected)
    }

    func testUpdatingPreferredOrganizationPostsAccountsDidChangeNotification() {
        // ClaudeAccountStore 가 단일 진실의 출처임을 보장하려면, store 변경이
        // .claudeAccountsDidChange 알림으로 외부에 전파되어야 한다.
        // ClaudeAPIService 의 in-memory 캐시 자동 무효화는 이 알림에 의존한다.
        let store = ClaudeAccountStore(defaults: defaults, keychainVault: vault, postsNotifications: true)
        Self.retainedObjects.append(store)
        let account = store.upsertWebSessionAccount(sessionKey: "sk-ant-x", preferredOrganizationID: "org-a")

        let observed = expectation(description: ".claudeAccountsDidChange posted")
        let token = NotificationCenter.default.addObserver(
            forName: .claudeAccountsDidChange,
            object: nil,
            queue: nil
        ) { _ in observed.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }

        store.updatePreferredOrganizationID("org-b", for: account.id)

        wait(for: [observed], timeout: 1.0)
    }

    func testUpdatingPreferredOrganizationToSameValueDoesNotPostNotification() {
        // 멱등 호출(같은 값 재저장)에서는 알림이 발행되지 않아야 한다.
        // 이는 ClaudeAPIService 가 불필요하게 캐시를 비우고 fetch 를 재트리거하는
        // 폭주를 방지한다.
        let store = ClaudeAccountStore(defaults: defaults, keychainVault: vault, postsNotifications: true)
        Self.retainedObjects.append(store)
        let account = store.upsertWebSessionAccount(sessionKey: "sk-ant-x", preferredOrganizationID: "org-a")

        let unwanted = expectation(description: "no notification")
        unwanted.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: .claudeAccountsDidChange,
            object: nil,
            queue: nil
        ) { _ in unwanted.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }

        store.updatePreferredOrganizationID("org-a", for: account.id)

        wait(for: [unwanted], timeout: 0.3)
    }

    func testActiveAccountSwitchPostsAccountBoundaryWithoutSessionCredentialNotification() {
        let store = ClaudeAccountStore(defaults: defaults, keychainVault: vault, postsNotifications: true)
        Self.retainedObjects.append(store)
        _ = store.upsertWebSessionAccount(sessionKey: "sk-ant-first", setActive: true)
        let second = store.upsertWebSessionAccount(sessionKey: "sk-ant-second", setActive: false)

        let accountBoundary = expectation(description: "active account boundary")
        let unwantedSession = expectation(description: "no session credential notification")
        unwantedSession.isInverted = true
        let accountToken = NotificationCenter.default.addObserver(
            forName: .claudeAccountDidChange,
            object: nil,
            queue: nil
        ) { _ in accountBoundary.fulfill() }
        let sessionToken = NotificationCenter.default.addObserver(
            forName: .claudeSessionKeyDidChange,
            object: nil,
            queue: nil
        ) { _ in unwantedSession.fulfill() }
        defer {
            NotificationCenter.default.removeObserver(accountToken)
            NotificationCenter.default.removeObserver(sessionToken)
        }

        store.setActiveAccountID(second.id)

        wait(for: [accountBoundary, unwantedSession], timeout: 0.3)
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
