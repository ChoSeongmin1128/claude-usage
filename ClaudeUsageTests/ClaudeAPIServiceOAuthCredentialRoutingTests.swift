import XCTest
@testable import ClaudeUsage

@MainActor
final class ClaudeAPIServiceOAuthCredentialRoutingTests: XCTestCase {
    func testInitializationDefersSessionKeyLoadUntilActorReload()
        async
    {
        let (store, defaults, suite) = makeStore()
        defer {
            defaults.removePersistentDomain(
                forName: suite
            )
        }
        let web = store.upsertWebSessionAccount(
            sessionKey: "sk-ant-browser",
            setActive: true
        )
        let loader = SessionKeyLoaderSpy(
            accountID: web.id,
            value: "sk-ant-browser"
        )

        let service = ClaudeAPIService(
            accountStore: store,
            oauthCredentialReader:
                OAuthReaderSpy(token: nil),
            sessionKeyLoader: {
                loader.load(accountID: $0)
            }
        )

        XCTAssertEqual(loader.callCount(), 0)

        await service.reloadActiveAccount()

        XCTAssertEqual(loader.callCount(), 1)
    }

    func testBrowserAccountHealthSnapshotUsesInventoryWithoutReadingOAuthCredential() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let web = store.upsertWebSessionAccount(sessionKey: "sk-ant-browser", setActive: true)
        _ = store.upsertClaudeCodeExternalAccount(
            validationState: .detected,
            setActiveIfMissing: false
        )
        let webID = web.id
        let reader = OAuthReaderSpy(token: "oauth-token")
        let service = ClaudeAPIService(
            accountStore: store,
            oauthCredentialReader: reader,
            sessionKeyLoader: { accountID in accountID == webID ? "sk-ant-browser" : nil }
        )

        let snapshot = await service.fetchUsageHealthSnapshot()

        let readCount = await reader.readCount
        XCTAssertEqual(readCount, 0)
        XCTAssertTrue(snapshot.runtime.credentialAvailability.sessionCredentialAvailable)
        XCTAssertTrue(snapshot.runtime.credentialAvailability.oauthCredentialAvailable)
    }

    func testClaudeCodeAccountHealthSnapshotReadsOAuthCredentialOnce() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let cli = store.upsertClaudeCodeExternalAccount(
            validationState: .detected,
            setActiveIfMissing: true
        )
        store.setActiveAccountID(cli.id)
        let reader = OAuthReaderSpy(token: "oauth-token")
        let service = ClaudeAPIService(
            accountStore: store,
            oauthCredentialReader: reader,
            sessionKeyLoader: { _ in nil }
        )

        let snapshot = await service.fetchUsageHealthSnapshot()

        let readCount = await reader.readCount
        XCTAssertEqual(readCount, 1)
        XCTAssertTrue(snapshot.runtime.credentialAvailability.oauthCredentialAvailable)
    }

    func testRejectedCLIRefreshTokenIsPresentedAsClaudeReauthenticationRequired() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let cli = store.upsertClaudeCodeExternalAccount(
            validationState: .detected,
            setActiveIfMissing: true
        )
        store.setActiveAccountID(cli.id)
        let reader = OAuthReaderSpy(token: nil, requiresReauthentication: true)
        let service = ClaudeAPIService(
            accountStore: store,
            oauthCredentialReader: reader,
            sessionKeyLoader: { _ in nil }
        )

        do {
            _ = try await service.fetchUsage()
            XCTFail("무효화된 CLI refresh token은 일반 credential 없음으로 축약되면 안 됩니다")
        } catch let error as APIError {
            guard case .claudeCodeReauthenticationRequired = error else {
                return XCTFail("예상하지 못한 API 오류: \(error)")
            }
        } catch {
            XCTFail("APIError가 아닌 오류: \(error)")
        }
    }

    func testRejectedCLIMirrorIsPresentedAsReconnectRequiredWithoutClaimingReauthentication() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let cli = store.upsertClaudeCodeExternalAccount(
            validationState: .detected,
            setActiveIfMissing: true
        )
        store.setActiveAccountID(cli.id)
        let reader = OAuthReaderSpy(token: nil, requiresReconnect: true)
        let service = ClaudeAPIService(
            accountStore: store,
            oauthCredentialReader: reader,
            sessionKeyLoader: { _ in nil }
        )

        do {
            _ = try await service.fetchUsage()
            XCTFail("CLI mirror 거부를 refresh token invalid_grant로 표시하면 안 됩니다")
        } catch let error as APIError {
            guard case .claudeCodeReconnectRequired = error else {
                return XCTFail("예상하지 못한 API 오류: \(error)")
            }
        } catch {
            XCTFail("APIError가 아닌 오류: \(error)")
        }
    }

    func testExplicitInventoryRefreshReadsOAuthForBrowserAccount() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let web = store.upsertWebSessionAccount(sessionKey: "sk-ant-browser", setActive: true)
        let webID = web.id
        let reader = OAuthReaderSpy(token: "oauth-token")
        let service = ClaudeAPIService(
            accountStore: store,
            oauthCredentialReader: reader,
            sessionKeyLoader: { accountID in accountID == webID ? "sk-ant-browser" : nil }
        )

        _ = await service.fetchUsageHealthSnapshot(refreshOAuthCredentialInventory: true)

        let readCount = await reader.readCount
        let refreshCount = await reader.refreshCount
        XCTAssertEqual(readCount, 0)
        XCTAssertEqual(refreshCount, 1)
    }

    func testClaudeCodePreviewUsesStoredInventoryWithoutReadingOAuthCredential() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = store.upsertClaudeCodeExternalAccount(
            validationState: .detected,
            setActiveIfMissing: false
        )
        let reader = OAuthReaderSpy(token: "oauth-token")
        let service = ClaudeAPIService(
            accountStore: store,
            oauthCredentialReader: reader,
            sessionKeyLoader: { _ in nil }
        )

        let available = await service.hasStoredClaudeCodeCredentialInventory()

        let readCount = await reader.readCount
        let invalidationCount = await reader.invalidationCount
        XCTAssertTrue(available)
        XCTAssertEqual(readCount, 0)
        XCTAssertEqual(invalidationCount, 0)
    }

    func testClaudeCodePreviewDoesNotProbeOAuthWhenInventoryIsMissing() async {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let reader = OAuthReaderSpy(token: "oauth-token")
        let service = ClaudeAPIService(
            accountStore: store,
            oauthCredentialReader: reader,
            sessionKeyLoader: { _ in nil }
        )

        let available = await service.hasStoredClaudeCodeCredentialInventory()

        let readCount = await reader.readCount
        let invalidationCount = await reader.invalidationCount
        XCTAssertFalse(available)
        XCTAssertEqual(readCount, 0)
        XCTAssertEqual(invalidationCount, 0)
    }

    func testExplicitClaudeCodeImportClearsStaleIdentityEvenWithoutComparableVaultCredential() async throws {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = store.upsertClaudeCodeExternalAccount(
            identity: ClaudeAccountIdentity(
                email: "old@example.com",
                organizationName: "Old Organization",
                organizationID: "old-organization"
            ),
            validationState: .verified,
            setActiveIfMissing: true
        )
        let reader = OAuthReaderSpy(
            token: "new-token",
            importResult: .imported(credentialChanged: false)
        )
        let service = ClaudeAPIService(
            accountStore: store,
            oauthCredentialReader: reader,
            sessionKeyLoader: { _ in nil }
        )

        try await service.importClaudeCodeCredentialForActivation()

        let updated = try XCTUnwrap(store.accounts().first(where: { $0.id == account.id }))
        XCTAssertNil(updated.identity.email)
        XCTAssertNil(updated.identity.organizationName)
        XCTAssertNil(updated.identity.organizationID)
        XCTAssertEqual(updated.lastValidationState, .detected)
    }

    private func makeStore() -> (ClaudeAccountStore, UserDefaults, String) {
        let suite = "ClaudeAPIServiceOAuthCredentialRoutingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (
            ClaudeAccountStore(
                defaults: defaults,
                keychainVault: EmptySessionVault(),
                postsNotifications: false
            ),
            defaults,
            suite
        )
    }
}

private final class SessionKeyLoaderSpy:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let accountID: String
    private let value: String
    private var calls = 0

    init(
        accountID: String,
        value: String
    ) {
        self.accountID = accountID
        self.value = value
    }

    func load(accountID: String) -> String? {
        lock.withLock {
            calls += 1
        }
        return accountID == self.accountID
            ? value
            : nil
    }

    func callCount() -> Int {
        lock.withLock { calls }
    }
}

private actor OAuthReaderSpy: ClaudeOAuthCredentialReading {
    private let token: String?
    private let requiresReauthentication: Bool
    private let requiresReconnect: Bool
    private let importResult: ClaudeOAuthCredentialImportResult?
    private(set) var readCount = 0
    private(set) var refreshCount = 0
    private(set) var invalidationCount = 0

    init(
        token: String?,
        requiresReauthentication: Bool = false,
        requiresReconnect: Bool = false,
        importResult: ClaudeOAuthCredentialImportResult? = nil
    ) {
        self.token = token
        self.requiresReauthentication = requiresReauthentication
        self.requiresReconnect = requiresReconnect
        self.importResult = importResult
    }

    func readAccessToken() async throws -> String? {
        readCount += 1
        if requiresReauthentication {
            throw ClaudeOAuthCredentialReadError.reauthenticationRequired
        }
        if requiresReconnect {
            throw ClaudeOAuthCredentialReadError.reconnectRequired
        }
        return token
    }

    func refreshCredentialInventoryWithoutUI() async throws -> ClaudeOAuthCredentialInventoryRefresh {
        refreshCount += 1
        return ClaudeOAuthCredentialInventoryRefresh(
            accessToken: token,
            credentialChanged: false
        )
    }

    func forceRefreshAccessToken() async throws -> String? {
        if requiresReauthentication {
            throw ClaudeOAuthCredentialReadError.reauthenticationRequired
        }
        if requiresReconnect {
            throw ClaudeOAuthCredentialReadError.reconnectRequired
        }
        return token
    }

    func invalidateCache() async {
        invalidationCount += 1
    }

    func importActiveCLICredential() async -> ClaudeOAuthCredentialImportResult {
        importResult ?? (token == nil ? .notFound : .available)
    }
}

private final class EmptySessionVault: ClaudeSessionKeyVault, @unchecked Sendable {
    nonisolated func saveString(_ value: String, account: String) throws {
        _ = value
        _ = account
    }

    nonisolated func loadString(account: String) throws -> String? {
        _ = account
        return nil
    }

    nonisolated func delete(account: String) throws {
        _ = account
    }
}
