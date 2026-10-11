import XCTest
@testable import ClaudeUsage

@MainActor
final class ClaudeAPIServicePathTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        suite = "ClaudeAPIServicePathTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func testOrganizationPreviewDoesNotChangeTheActiveSessionHealthOrCooldown() async throws {
        let service = ClaudeAPIService(
            sessionKey: "sk-ant-fixture",
            cacheStorage: .init(defaults: defaults, profileMetadataDirectory: root),
            httpRunner: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
                return (Data("{}".utf8), response)
            })

        let previews = await service.fetchOrganizationPreviews(
            for: [.init(id: "other-organization", name: "Other")], maxOrganizations: 1)
        let health = await service.fetchUsageHealthSnapshot()

        XCTAssertNotNil(previews.first?.usageErrorMessage)
        XCTAssertEqual(health.session.totalAttempts, 0)
        XCTAssertEqual(health.session.consecutiveFailures, 0)
        XCTAssertNil(health.runtime.sessionCooldownRemaining)
    }

    func testFailureAfterOwnTokenRefreshIsReportedInsteadOfDiscarded() async throws {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }
        settings.claudeMessagesFallbackPolicy = .off

        let store = ClaudeAccountStore(defaults: defaults, keychainVault: EmptyVault(), postsNotifications: false)
        let cli = store.upsertClaudeCodeExternalAccount(validationState: .detected, setActiveIfMissing: true)
        store.setActiveAccountID(cli.id)
        let service = ClaudeAPIService(
            accountStore: store, oauthCredentialReader: RotatingReader(), sessionKeyLoader: { _ in nil },
            cacheStorage: .init(defaults: defaults, profileMetadataDirectory: root),
            httpRunner: { request in
                let url = request.url!
                let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
                if url.path.hasSuffix("/profile") {
                    let body = #"{"account":{"uuid":"user","email":"user@example.com"},"organization":{"uuid":"org"}}"#
                    return (
                        Data(body.utf8),
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    )
                }
                let status = bearer.hasSuffix("token-a") ? 401 : 429
                return (
                    Data("{}".utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
                )
            })

        do {
            _ = try await service.fetchUsageOutcome(bypassOAuthCache: true)
            XCTFail("A rate limit after the refreshed retry must be reported")
        } catch is CancellationError {
            XCTFail("The app's own token refresh must not turn the retry failure into a cancellation")
        } catch {
            guard case .rateLimited = error as? APIError else { return XCTFail("Unexpected \(error)") }
        }
    }
}

private actor RotatingReader: ClaudeOAuthCredentialReading {
    func readAccessToken() async throws -> String? { "token-a" }
    func forceRefreshAccessToken() async throws -> String? { "token-b" }
    func refreshCredentialInventoryWithoutUI() async throws -> ClaudeOAuthCredentialInventoryRefresh {
        ClaudeOAuthCredentialInventoryRefresh(accessToken: "token-a", credentialChanged: false)
    }
    func invalidateCache() async {}
    func importActiveCLICredential() async -> ClaudeOAuthCredentialImportResult { .available }
}

private final class EmptyVault: ClaudeSessionKeyVault, @unchecked Sendable {
    nonisolated func saveString(_ value: String, account: String) throws {}
    nonisolated func loadString(account: String) throws -> String? { nil }
    nonisolated func delete(account: String) throws {}
}
