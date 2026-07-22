import XCTest
@testable import ClaudeUsage

@MainActor
final class AntigravityRefreshConfigurationTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var credentialStore: AntigravityOAuthCredentialsStore!
    private var accountStore: AntigravityOAuthAccountStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        credentialStore = AntigravityOAuthCredentialsStore(
            fileURL: AntigravityOAuthCredentialsStore.defaultURL(home: temporaryDirectory),
            fileManager: .default,
            legacyKeychainStore: nil
        )
        accountStore = AntigravityOAuthAccountStore(
            fileURL: AntigravityOAuthAccountStore.defaultURL(home: temporaryDirectory),
            fileManager: .default,
            activeCredentialStore: credentialStore
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        accountStore = nil
        credentialStore = nil
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testLocalIDESourceIgnoresOAuthAccountState() throws {
        try accountStore.upsert(makeCredentials(email: "first@example.com"), makeActive: true)

        let configuration = AntigravityRefreshConfiguration.current(
            dataSource: .localIDE,
            accountStore: accountStore
        )

        XCTAssertEqual(configuration.dataSource, .localIDE)
        XCTAssertNil(configuration.activeOAuthAccountID)
        XCTAssertNil(configuration.activeOAuthAccountUpdatedAtMilliseconds)
    }

    func testAgyCLISourceIgnoresOAuthAccountState() throws {
        try accountStore.upsert(makeCredentials(email: "first@example.com"), makeActive: true)

        let configuration = AntigravityRefreshConfiguration.current(
            dataSource: .agyCLI,
            accountStore: accountStore
        )

        XCTAssertEqual(configuration.dataSource, .agyCLI)
        XCTAssertNil(configuration.activeOAuthAccountID)
        XCTAssertNil(configuration.activeOAuthAccountUpdatedAtMilliseconds)
    }

    func testRemoteSourceIncludesActiveOAuthAccountMetadata() throws {
        try accountStore.upsert(makeCredentials(email: "first@example.com"), makeActive: true)
        let active = try XCTUnwrap(accountStore.state().activeAccount)

        let configuration = AntigravityRefreshConfiguration.current(
            dataSource: .googleOAuth,
            accountStore: accountStore
        )

        XCTAssertEqual(configuration.dataSource, .googleOAuth)
        XCTAssertEqual(configuration.activeOAuthAccountID, active.id)
        XCTAssertEqual(configuration.activeOAuthAccountUpdatedAtMilliseconds, active.updatedAtMilliseconds)
    }

    func testConfigurationChangesWhenActiveOAuthAccountChanges() throws {
        try accountStore.upsert(makeCredentials(email: "first@example.com"), makeActive: true)
        let first = AntigravityRefreshConfiguration.current(
            dataSource: .auto,
            accountStore: accountStore
        )

        try accountStore.upsert(makeCredentials(email: "second@example.com"), makeActive: true)
        let second = AntigravityRefreshConfiguration.current(
            dataSource: .auto,
            accountStore: accountStore
        )

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.activeOAuthAccountID, second.activeOAuthAccountID)
    }

    private func makeCredentials(email: String) -> AntigravityOAuthCredentials {
        AntigravityOAuthCredentials(
            accessToken: "access-\(email)",
            refreshToken: "refresh-\(email)",
            expiryDate: Date(timeIntervalSince1970: 1_800_000_000),
            idToken: "id-\(email)",
            email: email,
            projectID: "project-\(email)",
            clientID: "client-id",
            clientSecret: "client-secret"
        )
    }
}
