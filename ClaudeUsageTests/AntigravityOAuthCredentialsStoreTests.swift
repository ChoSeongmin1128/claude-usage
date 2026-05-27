import XCTest
@testable import ClaudeUsage

final class AntigravityOAuthCredentialsStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var fileURL: URL!
    private var legacyMetadataURL: URL!
    private var legacyKeychain: FakeAntigravityLegacyOAuthKeychainStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        fileURL = AntigravityOAuthCredentialsStore.defaultURL(home: temporaryDirectory)
        legacyMetadataURL = fileURL.deletingLastPathComponent().appendingPathComponent("oauth_metadata.json")
        legacyKeychain = FakeAntigravityLegacyOAuthKeychainStore()
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        legacyMetadataURL = nil
        fileURL = nil
        temporaryDirectory = nil
        legacyKeychain = nil
        try super.tearDownWithError()
    }

    func testSaveStoresCredentialsInUserReadableFileWithOAuthClientMetadata() throws {
        let store = makeStore()

        try store.save(makeCredentials())

        let payload = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(payload.contains("access-token-secret"))
        XCTAssertTrue(payload.contains("refresh-token-secret"))
        XCTAssertTrue(payload.contains("id-token-secret"))
        XCTAssertTrue(payload.contains("user@example.com"))
        XCTAssertTrue(payload.contains("project-123"))
        XCTAssertTrue(payload.contains("client-id"))
        XCTAssertTrue(payload.contains("client-secret"))
        XCTAssertFalse(legacyKeychain.deletedAccounts.contains(AntigravityOAuthCredentialsStore.legacyKeychainAccount))

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.deletingLastPathComponent().path)
        XCTAssertEqual(directoryAttributes[.posixPermissions] as? Int, 0o700)
    }

    func testLoadReadsSavedFileCredentials() throws {
        let store = makeStore()
        try store.save(makeCredentials())
        legacyKeychain.values[AntigravityOAuthCredentialsStore.legacyKeychainAccount] =
            String(data: try JSONEncoder().encode(makeCredentials()), encoding: .utf8)

        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.accessToken, "access-token-secret")
        XCTAssertEqual(loaded.refreshToken, "refresh-token-secret")
        XCTAssertEqual(loaded.idToken, "id-token-secret")
        XCTAssertEqual(loaded.email, "user@example.com")
        XCTAssertEqual(loaded.projectID, "project-123")
        XCTAssertEqual(loaded.clientID, "client-id")
        XCTAssertEqual(loaded.clientSecret, "client-secret")
        XCTAssertFalse(legacyKeychain.deletedAccounts.contains(AntigravityOAuthCredentialsStore.legacyKeychainAccount))
    }

    func testLoadDoesNotDeleteLegacyKeychainCredentialWhenFileDecodeFails() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"access_token":"#.write(to: fileURL, atomically: true, encoding: .utf8)
        legacyKeychain.values[AntigravityOAuthCredentialsStore.legacyKeychainAccount] =
            String(data: try JSONEncoder().encode(makeCredentials()), encoding: .utf8)

        XCTAssertThrowsError(try makeStore().load())

        XCTAssertFalse(legacyKeychain.deletedAccounts.contains(AntigravityOAuthCredentialsStore.legacyKeychainAccount))
        XCTAssertNotNil(legacyKeychain.values[AntigravityOAuthCredentialsStore.legacyKeychainAccount])
    }

    func testSaveRemovesLegacySplitMetadataFile() throws {
        try FileManager.default.createDirectory(
            at: legacyMetadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"email":"old@example.com","has_token_material":true}"#.write(
            to: legacyMetadataURL,
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyMetadataURL.path))

        try makeStore().save(makeCredentials())

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyMetadataURL.path))
    }

    func testLoadDoesNotAttemptLegacyKeychainMigrationWhenFileIsMissing() throws {
        legacyKeychain.values[AntigravityOAuthCredentialsStore.legacyKeychainAccount] =
            String(data: try JSONEncoder().encode(makeCredentials()), encoding: .utf8)

        let loaded = try makeStore().load()

        XCTAssertNil(loaded)
        XCTAssertEqual(legacyKeychain.readAttempts, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(legacyKeychain.deletedAccounts.contains(AntigravityOAuthCredentialsStore.legacyKeychainAccount))
    }

    func testMigrationMovesPromptFreeLegacyKeychainCredentialIntoFileStorage() throws {
        let legacy = makeCredentials()
        legacyKeychain.values[AntigravityOAuthCredentialsStore.legacyKeychainAccount] =
            String(data: try JSONEncoder().encode(legacy), encoding: .utf8)

        let loaded = try XCTUnwrap(makeStore().migrateLegacyKeychainCredentialsIfAvailable())

        XCTAssertEqual(loaded.accessToken, legacy.accessToken)
        XCTAssertEqual(loaded.refreshToken, legacy.refreshToken)
        XCTAssertEqual(loaded.email, legacy.email)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(legacyKeychain.deletedAccounts.contains(AntigravityOAuthCredentialsStore.legacyKeychainAccount))
    }

    func testMigrationMovesLegacySplitKeychainCredentialWithMetadata() throws {
        let secrets = """
        {
          "access_token": "legacy-access-token",
          "refresh_token": "legacy-refresh-token",
          "id_token": "legacy-id-token"
        }
        """
        legacyKeychain.values[AntigravityOAuthCredentialsStore.legacyKeychainAccount] = secrets
        try FileManager.default.createDirectory(
            at: legacyMetadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {
          "client_id": "legacy-client-id",
          "email": "legacy@example.com",
          "expiry_date": 1800000000000,
          "project_id": "legacy-project"
        }
        """.write(to: legacyMetadataURL, atomically: true, encoding: .utf8)

        let loaded = try XCTUnwrap(makeStore().migrateLegacyKeychainCredentialsIfAvailable())

        XCTAssertEqual(loaded.accessToken, "legacy-access-token")
        XCTAssertEqual(loaded.refreshToken, "legacy-refresh-token")
        XCTAssertEqual(loaded.idToken, "legacy-id-token")
        XCTAssertEqual(loaded.email, "legacy@example.com")
        XCTAssertEqual(loaded.projectID, "legacy-project")
        XCTAssertEqual(loaded.clientID, "legacy-client-id")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyMetadataURL.path))
        XCTAssertTrue(legacyKeychain.deletedAccounts.contains(AntigravityOAuthCredentialsStore.legacyKeychainAccount))
    }

    func testMigrationDoesNotDeleteLegacyKeychainCredentialWhenPromptFreeReadIsUnavailable() throws {
        legacyKeychain.promptFreeReadsUnavailable = true
        legacyKeychain.values[AntigravityOAuthCredentialsStore.legacyKeychainAccount] =
            String(data: try JSONEncoder().encode(makeCredentials()), encoding: .utf8)

        let loaded = try makeStore().migrateLegacyKeychainCredentialsIfAvailable()

        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(legacyKeychain.deletedAccounts.contains(AntigravityOAuthCredentialsStore.legacyKeychainAccount))
    }

    func testMigrationAttemptsLegacyKeychainOnlyOncePerStorePath() throws {
        legacyKeychain.promptFreeReadsUnavailable = true
        legacyKeychain.values[AntigravityOAuthCredentialsStore.legacyKeychainAccount] =
            String(data: try JSONEncoder().encode(makeCredentials()), encoding: .utf8)
        let store = makeStore()

        XCTAssertNil(try store.migrateLegacyKeychainCredentialsIfAvailable())
        XCTAssertNil(try store.migrateLegacyKeychainCredentialsIfAvailable())

        XCTAssertEqual(legacyKeychain.readAttempts, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(legacyKeychain.deletedAccounts.contains(AntigravityOAuthCredentialsStore.legacyKeychainAccount))
    }

    func testDeleteRemovesCredentialAndLegacyMetadataFiles() throws {
        let store = makeStore()
        try store.save(makeCredentials())
        try #"{"email":"old@example.com","has_token_material":true}"#.write(
            to: legacyMetadataURL,
            atomically: true,
            encoding: .utf8
        )

        try store.deleteIfPresent()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyMetadataURL.path))
        XCTAssertTrue(legacyKeychain.deletedAccounts.contains(AntigravityOAuthCredentialsStore.legacyKeychainAccount))
    }

    func testCredentialProbeReadsFileStorage() throws {
        let store = makeStore()
        try store.save(makeCredentials())

        let status = AntigravityOAuthCredentialProbe.current(
            home: temporaryDirectory,
            environment: [:],
            fileManager: .default
        )

        XCTAssertTrue(status.hasCredential)
        XCTAssertEqual(status.email, "user@example.com")
        XCTAssertEqual(status.sourceDescription, "ClaudeUsage OAuth")
    }

    func testEnvironmentCredentialParserTrimsSerializedJSON() throws {
        let credentials = makeCredentials()
        let data = try JSONEncoder().encode(credentials)
        let value = "\n  \(String(decoding: data, as: UTF8.self))  \n"

        let decoded = try XCTUnwrap(AntigravityOAuthCredentialsStore.credentials(fromEnvironmentValue: value))

        XCTAssertEqual(decoded.refreshToken, credentials.refreshToken)
        XCTAssertEqual(decoded.email, credentials.email)
    }

    func testCredentialStatusDoesNotAttemptLegacyKeychainMigration() throws {
        legacyKeychain.values[AntigravityOAuthCredentialsStore.legacyKeychainAccount] =
            String(data: try JSONEncoder().encode(makeCredentials()), encoding: .utf8)

        let status = makeStore().credentialStatus()

        XCTAssertNil(status)
        XCTAssertEqual(legacyKeychain.readAttempts, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(legacyKeychain.deletedAccounts.contains(AntigravityOAuthCredentialsStore.legacyKeychainAccount))
    }

    func testOAuthClientDiscoveryParsesAntigravityTwoLanguageServerContent() throws {
        let firstSecret = fakeGoogleOAuthSecret("A", count: 28)
        let secondSecret = fakeGoogleOAuthSecret("B", count: 28)
        let firstClientID = fakeGoogleOAuthClientID(prefix: "111111111111")
        let secondClientID = fakeGoogleOAuthClientID(prefix: "222222222222")
        let content = """
        binary-prefix \(firstSecret) \(secondSecret)
        unrelated
        \(firstClientID)
        \(secondClientID)
        """

        let client = try XCTUnwrap(AntigravityOAuthConfig.parseClient(fromBundleContent: content))

        XCTAssertEqual(client.clientID, firstClientID)
        XCTAssertEqual(client.clientSecret, firstSecret)
        XCTAssertEqual(client.clientSecretCandidates, [
            firstSecret,
            secondSecret,
        ])
        XCTAssertEqual(client.tokenClientSecretCandidates, [
            nil,
            firstSecret,
            secondSecret,
        ])
    }

    func testOAuthClientDiscoveryDoesNotAssumeFixedSecretLength() throws {
        let clientID = fakeGoogleOAuthClientID(prefix: "111111111111")
        let longSecret = fakeGoogleOAuthSecret("A", count: 42)
        let content = """
        vs/platform/cloudCode/common/oauthClient.js
        \(clientID)
        \(longSecret)
        """

        let client = try XCTUnwrap(AntigravityOAuthConfig.parseClient(fromBundleContent: content))

        XCTAssertEqual(client.clientSecret, longSecret)
        XCTAssertEqual(client.clientSecretCandidates, [longSecret])
        XCTAssertEqual(client.tokenClientSecretCandidates, [nil, longSecret])
    }

    func testOAuthClientDiscoveryFallsBackWhenMarkerWindowMissesSecret() throws {
        let clientID = fakeGoogleOAuthClientID(prefix: "111111111111")
        let secret = fakeGoogleOAuthSecret("A", count: 28)
        let content = """
        vs/platform/cloudCode/common/oauthClient.js
        \(clientID)
        \(String(repeating: "x", count: 5000))
        \(secret)
        """

        let client = try XCTUnwrap(AntigravityOAuthConfig.parseClient(fromBundleContent: content))

        XCTAssertEqual(client.clientID, clientID)
        XCTAssertEqual(client.clientSecret, secret)
        XCTAssertEqual(client.tokenClientSecretCandidates, [nil, secret])
    }

    func testOAuthClientDiscoveryAllowsPublicClientWhenSecretIsMissing() throws {
        let clientID = fakeGoogleOAuthClientID(prefix: "111111111111")
        let content = """
        vs/platform/cloudCode/common/oauthClient.js
        \(clientID)
        no bundled secret
        """

        let client = try XCTUnwrap(AntigravityOAuthConfig.parseClient(fromBundleContent: content))

        XCTAssertEqual(client.clientID, clientID)
        XCTAssertNil(client.clientSecret)
        XCTAssertTrue(client.clientSecretCandidates.isEmpty)
        XCTAssertEqual(client.tokenClientSecretCandidates, [nil])
    }

    func testOAuthClientDiscoveryIgnoresConcatenatedSecretLikeURLPrefix() throws {
        let clientID = fakeGoogleOAuthClientID(prefix: "111111111111")
        let invalidSecret = fakeGoogleOAuthSecret("A", count: 68) + "https"
        let content = """
        \(clientID)
        \(invalidSecret)://cloudcode-pa.googleapis.com
        """

        let client = try XCTUnwrap(AntigravityOAuthConfig.parseClient(fromBundleContent: content))

        XCTAssertEqual(client.clientID, clientID)
        XCTAssertNil(client.clientSecret)
        XCTAssertTrue(client.clientSecretCandidates.isEmpty)
        XCTAssertEqual(client.tokenClientSecretCandidates, [nil])
    }

    func testExplicitOAuthClientDoesNotUsePublicAttemptWhenSecretIsConfigured() {
        let client = AntigravityOAuthClient(clientID: "client-id", clientSecret: "client-secret")

        XCTAssertEqual(client.tokenClientSecretCandidates, ["client-secret"])
    }

    private func fakeGoogleOAuthClientID(prefix: String) -> String {
        "\(prefix)-aabbccddeeff00112233445566778899.apps." + "googleusercontent.com"
    }

    private func fakeGoogleOAuthSecret(_ character: Character, count: Int) -> String {
        "GOC" + "SPX-" + String(repeating: String(character), count: count)
    }

    private func makeStore() -> AntigravityOAuthCredentialsStore {
        AntigravityOAuthCredentialsStore(
            fileURL: fileURL,
            fileManager: .default,
            legacyKeychainStore: legacyKeychain
        )
    }

    private func makeCredentials() -> AntigravityOAuthCredentials {
        AntigravityOAuthCredentials(
            accessToken: "access-token-secret",
            refreshToken: "refresh-token-secret",
            expiryDate: Date(timeIntervalSince1970: 1_800_000_000),
            idToken: "id-token-secret",
            email: "user@example.com",
            projectID: "project-123",
            clientID: "client-id",
            clientSecret: "client-secret"
        )
    }
}

private final class FakeAntigravityLegacyOAuthKeychainStore: AntigravityLegacyOAuthKeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    var values: [String: String] = [:]
    var deletedAccounts: Set<String> = []
    var promptFreeReadsUnavailable = false
    var readAttempts = 0

    func loadStringWithoutAuthenticationPrompt(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        readAttempts += 1
        guard !promptFreeReadsUnavailable else { return nil }
        return values[account]
    }

    func delete(account: String) throws {
        lock.lock()
        values.removeValue(forKey: account)
        deletedAccounts.insert(account)
        lock.unlock()
    }
}
