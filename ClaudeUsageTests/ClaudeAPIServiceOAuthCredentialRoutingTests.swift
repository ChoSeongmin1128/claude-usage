import XCTest
@testable import ClaudeUsage

@MainActor
final class ClaudeAPIServiceOAuthCredentialRoutingTests: XCTestCase {
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

private actor OAuthReaderSpy: ClaudeOAuthCredentialReading {
    private let token: String?
    private(set) var readCount = 0
    private(set) var refreshCount = 0
    private(set) var invalidationCount = 0

    init(token: String?) {
        self.token = token
    }

    func readAccessToken() async throws -> String? {
        readCount += 1
        return token
    }

    func refreshCredentialInventoryWithoutUI() async throws -> ClaudeOAuthCredentialInventoryRefresh {
        refreshCount += 1
        return ClaudeOAuthCredentialInventoryRefresh(
            accessToken: token,
            credentialChanged: false
        )
    }

    func forceRefreshAccessToken() async -> String? {
        token
    }

    func invalidateCache() async {
        invalidationCount += 1
    }

    func importActiveCLICredential() async -> ClaudeOAuthCredentialImportResult {
        token == nil ? .notFound : .available
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
