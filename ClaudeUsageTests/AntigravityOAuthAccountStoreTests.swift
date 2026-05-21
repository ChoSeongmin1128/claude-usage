import XCTest
@testable import ClaudeUsage

final class AntigravityOAuthAccountStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var credentialURL: URL!
    private var accountURL: URL!
    private var credentialStore: AntigravityOAuthCredentialsStore!
    private var accountStore: AntigravityOAuthAccountStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        credentialURL = AntigravityOAuthCredentialsStore.defaultURL(home: temporaryDirectory)
        accountURL = AntigravityOAuthAccountStore.defaultURL(home: temporaryDirectory)
        credentialStore = AntigravityOAuthCredentialsStore(
            fileURL: credentialURL,
            fileManager: .default,
            legacyKeychainStore: nil
        )
        accountStore = AntigravityOAuthAccountStore(
            fileURL: accountURL,
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
        accountURL = nil
        credentialURL = nil
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testSyncActiveCredentialMigratesSingleFileIntoAccountState() throws {
        try credentialStore.save(makeCredentials(email: "legacy@example.com"))

        let state = try accountStore.syncActiveCredentialIfNeeded()

        XCTAssertEqual(state.accounts.map(\.email), ["legacy@example.com"])
        XCTAssertEqual(state.activeAccount?.email, "legacy@example.com")
        XCTAssertEqual(try credentialStore.load()?.email, "legacy@example.com")
        XCTAssertEqual(try accountFilePermissions(), 0o600)
        XCTAssertEqual(try accountDirectoryPermissions(), 0o700)
    }

    func testSyncActiveCredentialWithoutEmailDoesNotCreateDuplicateAccounts() throws {
        try credentialStore.save(makeCredentials(email: nil, refreshToken: "stable-refresh-token"))

        let first = try accountStore.syncActiveCredentialIfNeeded()
        let second = try accountStore.syncActiveCredentialIfNeeded()

        XCTAssertEqual(first.accounts.count, 1)
        XCTAssertEqual(second.accounts.count, 1)
        XCTAssertEqual(second.activeAccountID, first.activeAccountID)
    }

    func testUpsertAccountsAndSwitchActiveCredentialFile() throws {
        let first = makeCredentials(email: "first@example.com")
        let second = makeCredentials(email: "second@example.com")

        try accountStore.upsert(first, makeActive: true)
        var state = try accountStore.upsert(second, makeActive: true)

        XCTAssertEqual(state.accounts.map(\.email), ["first@example.com", "second@example.com"])
        XCTAssertEqual(state.activeAccount?.email, "second@example.com")
        XCTAssertEqual(try credentialStore.load()?.email, "second@example.com")

        let firstID = try XCTUnwrap(state.accounts.first(where: { $0.email == "first@example.com" })?.id)
        state = try accountStore.setActiveAccountID(firstID)

        XCTAssertEqual(state.activeAccount?.email, "first@example.com")
        XCTAssertEqual(try credentialStore.load()?.email, "first@example.com")
    }

    func testDeleteActiveAccountPromotesNextAndClearsWhenEmpty() throws {
        try accountStore.upsert(makeCredentials(email: "first@example.com"), makeActive: true)
        var state = try accountStore.upsert(makeCredentials(email: "second@example.com"), makeActive: true)
        let firstID = try XCTUnwrap(state.accounts.first(where: { $0.email == "first@example.com" })?.id)
        let secondID = try XCTUnwrap(state.accounts.first(where: { $0.email == "second@example.com" })?.id)

        state = try accountStore.deleteAccount(id: secondID)

        XCTAssertEqual(state.accounts.map(\.email), ["first@example.com"])
        XCTAssertEqual(state.activeAccount?.id, firstID)
        XCTAssertEqual(try credentialStore.load()?.email, "first@example.com")

        state = try accountStore.deleteAccount(id: firstID)

        XCTAssertTrue(state.accounts.isEmpty)
        XCTAssertNil(state.activeAccountID)
        XCTAssertNil(try credentialStore.load())
    }

    func testSyncRestoresMissingActiveCredentialFileFromAccountState() throws {
        try accountStore.upsert(makeCredentials(email: "stored@example.com"), makeActive: true)
        try FileManager.default.removeItem(at: credentialURL)

        let state = try accountStore.syncActiveCredentialIfNeeded()

        XCTAssertEqual(state.activeAccount?.email, "stored@example.com")
        XCTAssertEqual(try credentialStore.load()?.email, "stored@example.com")
    }

    func testSyncRestoresCorruptActiveCredentialFileFromAccountState() throws {
        try accountStore.upsert(makeCredentials(email: "stored@example.com"), makeActive: true)
        try Data("{".utf8).write(to: credentialURL)

        let state = try accountStore.syncActiveCredentialIfNeeded()

        XCTAssertEqual(state.activeAccount?.email, "stored@example.com")
        XCTAssertEqual(try credentialStore.load()?.email, "stored@example.com")
    }

    func testCredentialProbeReadsActiveAccountWhenActiveCredentialFileIsMissing() throws {
        try accountStore.upsert(makeCredentials(email: "stored@example.com"), makeActive: true)
        try FileManager.default.removeItem(at: credentialURL)

        let status = AntigravityOAuthCredentialProbe.current(
            home: temporaryDirectory,
            environment: [:],
            fileManager: .default
        )

        XCTAssertTrue(status.hasCredential)
        XCTAssertEqual(status.email, "stored@example.com")
        XCTAssertEqual(status.sourceDescription, "ClaudeUsage OAuth")
    }

    private func makeCredentials(
        email: String?,
        refreshToken: String = UUID().uuidString
    ) -> AntigravityOAuthCredentials {
        AntigravityOAuthCredentials(
            accessToken: "access-\(refreshToken)",
            refreshToken: refreshToken,
            expiryDate: Date(timeIntervalSince1970: 1_800_000_000),
            idToken: "id-\(refreshToken)",
            email: email,
            projectID: "project-\(refreshToken)",
            clientID: "client-id",
            clientSecret: "client-secret"
        )
    }

    private func accountFilePermissions() throws -> Int? {
        let attributes = try FileManager.default.attributesOfItem(atPath: accountURL.path)
        return attributes[.posixPermissions] as? Int
    }

    private func accountDirectoryPermissions() throws -> Int? {
        let attributes = try FileManager.default.attributesOfItem(atPath: accountURL.deletingLastPathComponent().path)
        return attributes[.posixPermissions] as? Int
    }
}
