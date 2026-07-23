import XCTest
@testable import ClaudeUsage

final class ClaudeCodeCredentialReaderTests: XCTestCase {
    func testCredentialFileIsUsedAfterVaultMissWithoutInteractiveKeychainRead() async throws {
        let home = try makeTemporaryHome()
        try writeCredentialFile(configDirectory: home.appendingPathComponent(".claude"), token: "file-token")
        let vault = OAuthVaultStub()
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            XCTFail("백그라운드 credential 조회가 CLI Keychain UI를 열면 안 됩니다")
            return .cancelled
        }
        let reader = makeReader(home: home, vault: vault, interactive: interactive)

        let token = try await reader.readAccessToken()

        XCTAssertEqual(token, "file-token")
        XCTAssertEqual(vault.loadCount, 1)
        XCTAssertTrue(interactive.calls.isEmpty)
    }

    func testMissingVaultAndFileDoesNotReadInteractiveKeychain() async throws {
        let vault = OAuthVaultStub()
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            XCTFail("자동 조회가 Claude CLI Keychain에 접근하면 안 됩니다")
            return .value(Self.credentialJSON(token: "unexpected-token"))
        }
        let reader = makeReader(
            home: try makeTemporaryHome(),
            vault: vault,
            interactive: interactive
        )

        let token = try await reader.readAccessToken()

        XCTAssertNil(token)
        XCTAssertEqual(vault.loadCount, 1)
        XCTAssertTrue(interactive.calls.isEmpty)
    }

    func testAppVaultIsPreferredWithoutExternalKeychainRead() async throws {
        let vault = OAuthVaultStub(payload: Self.credentialJSON(token: "vault-token"))
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            XCTFail("앱 전용 vault 조회 성공 후 외부 Keychain을 읽으면 안 됩니다")
            return .cancelled
        }
        let reader = makeReader(
            home: try makeTemporaryHome(),
            vault: vault,
            interactive: interactive
        )

        let token = try await reader.readAccessToken()

        XCTAssertEqual(token, "vault-token")
        XCTAssertEqual(vault.loadCount, 1)
        XCTAssertTrue(interactive.calls.isEmpty)
    }

    func testDefaultConfigExplicitImportReadsOnlyDefaultClaudeCodeService() async throws {
        let interactive = InteractiveKeychainPayloadReaderStub { service, _ , _ in
            XCTAssertEqual(service, "Claude Code-credentials")
            return .value(Self.credentialJSON(token: "default-token"))
        }
        let reader = makeReader(
            home: try makeTemporaryHome(),
            vault: OAuthVaultStub(),
            interactive: interactive
        )

        let result = await reader.importActiveCLICredential()

        XCTAssertEqual(result, .imported(credentialChanged: false))
        XCTAssertEqual(interactive.calls.map(\.service), ["Claude Code-credentials"])
    }

    func testCustomConfigExplicitImportReadsOnlyStrictHashedService() async throws {
        let home = URL(fileURLWithPath: "/tmp/claude-home", isDirectory: true)
        let config = URL(fileURLWithPath: "/tmp/claude-config-work", isDirectory: true)
        let expectedService = "Claude Code-credentials-7516b27d"
        let interactive = InteractiveKeychainPayloadReaderStub { service, _, _ in
            XCTAssertEqual(service, expectedService)
            return .value(Self.credentialJSON(token: "scoped-token"))
        }
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home,
            claudeConfigDirectory: config,
            appCredentialVault: OAuthVaultStub(),
            interactiveKeychainPayloadReader: { service, account, reason in
                interactive.read(service: service, account: account, reason: reason)
            }
        )

        let result = await reader.importActiveCLICredential()

        XCTAssertEqual(
            ClaudeCodeCredentialReader.keychainServiceName(
                for: config,
                homeDirectory: home
            ),
            expectedService
        )
        XCTAssertEqual(result, .imported(credentialChanged: false))
        XCTAssertEqual(interactive.calls.map(\.service), [expectedService])
    }

    func testExplicitDefaultConfigImportStillReadsScopedHashedService() async throws {
        let home = URL(fileURLWithPath: "/tmp/claude-home-default", isDirectory: true)
        let config = home.appendingPathComponent(".claude", isDirectory: true)
        let expectedService = "Claude Code-credentials-fb84b3b6"
        let interactive = InteractiveKeychainPayloadReaderStub { service, _, _ in
            XCTAssertEqual(service, expectedService)
            return .value(Self.credentialJSON(token: "explicit-default-token"))
        }
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home,
            claudeConfigDirectory: config,
            appCredentialVault: OAuthVaultStub(),
            interactiveKeychainPayloadReader: { service, account, reason in
                interactive.read(service: service, account: account, reason: reason)
            }
        )

        let result = await reader.importActiveCLICredential()

        XCTAssertEqual(
            ClaudeCodeCredentialReader.keychainServiceName(
                for: config,
                homeDirectory: home,
                usesExplicitConfigDirectory: true
            ),
            expectedService
        )
        XCTAssertEqual(result, .imported(credentialChanged: false))
        XCTAssertEqual(interactive.calls.map(\.service), [expectedService])
    }

    func testConcurrentCredentialRequestsShareOneLookup() async throws {
        let vault = OAuthVaultStub(payload: Self.credentialJSON(token: "shared-token"))
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: try makeTemporaryHome(),
            appCredentialVault: vault
        )

        let tokens = try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<8 {
                group.addTask { try await reader.readAccessToken() }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(Set(tokens.compactMap { $0 }), ["shared-token"])
        XCTAssertEqual(vault.loadCount, 1)
    }

    func testNilResultIsCachedUntilExplicitInvalidation() async throws {
        let vault = OAuthVaultStub()
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: try makeTemporaryHome(),
            appCredentialVault: vault,
            cacheTTL: 600
        )

        let first = try await reader.readAccessToken()
        let second = try await reader.readAccessToken()
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(vault.loadCount, 1)

        await reader.invalidateCache()
        let afterInvalidation = try await reader.readAccessToken()
        XCTAssertNil(afterInvalidation)
        XCTAssertEqual(vault.loadCount, 2)
    }

    func testVaultReadFailureDoesNotFallBackToFileOrExternalKeychain() async throws {
        let home = try makeTemporaryHome()
        try writeCredentialFile(configDirectory: home.appendingPathComponent(".claude"), token: "file-token")
        let vault = OAuthVaultStub(loadError: OAuthVaultStub.TestError.expected)
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            XCTFail("vault 오류를 cache miss로 처리하면 안 됩니다")
            return .cancelled
        }
        let reader = makeReader(home: home, vault: vault, interactive: interactive)

        let token = try await reader.readAccessToken()

        XCTAssertNil(token)
        XCTAssertTrue(interactive.calls.isEmpty)
    }

    func testMalformedVaultPayloadDoesNotSelectAnotherCredentialSource() async throws {
        let home = try makeTemporaryHome()
        try writeCredentialFile(configDirectory: home.appendingPathComponent(".claude"), token: "file-token")
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            XCTFail("손상된 vault 뒤에 다른 계정을 선택하면 안 됩니다")
            return .cancelled
        }
        let reader = makeReader(
            home: home,
            vault: OAuthVaultStub(payload: #"{"invalid":true}"#),
            interactive: interactive
        )

        let token = try await reader.readAccessToken()
        XCTAssertNil(token)
        XCTAssertTrue(interactive.calls.isEmpty)
    }

    func testRefreshedCredentialPersistsToVaultWithoutExternalKeychainWrite() async throws {
        let expired = Self.credentialJSON(
            token: "expired-access",
            refreshToken: "refresh-token",
            expiresAt: #""2000-01-01T00:00:00Z""#
        )
        let vault = OAuthVaultStub(payload: expired)
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            XCTFail("앱 소유 refresh 캐시는 외부 Keychain을 읽거나 쓰면 안 됩니다")
            return .cancelled
        }
        let refresher = makeSuccessfulRefresher()
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: try makeTemporaryHome(),
            tokenRefresher: refresher,
            appCredentialVault: vault,
            interactiveKeychainPayloadReader: { service, account, reason in
                interactive.read(service: service, account: account, reason: reason)
            }
        )

        let token = try await reader.readAccessToken()

        XCTAssertEqual(token, "new-access")
        XCTAssertEqual(vault.saveCount, 1)
        XCTAssertTrue(vault.payload?.contains("new-access") == true)
        XCTAssertTrue(interactive.calls.isEmpty)
    }

    func testMillisecondExpiresAtIsNormalizedAndRefreshesExpiredCredential() async throws {
        let expiredMilliseconds = #"{"claudeAiOauth":{"accessToken":"expired-access","refreshToken":"refresh-token","expiresAt":1770000000000}}"#
        let vault = OAuthVaultStub(payload: expiredMilliseconds)
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: try makeTemporaryHome(),
            tokenRefresher: makeSuccessfulRefresher(),
            appCredentialVault: vault
        )

        let token = try await reader.readAccessToken()

        XCTAssertEqual(token, "new-access")
        XCTAssertEqual(vault.saveCount, 1)
    }

    func testSecondExpiresAtRemainsSupported() async throws {
        let futureSeconds = #"{"claudeAiOauth":{"accessToken":"seconds-token","expiresAt":4070908800}}"#
        let vault = OAuthVaultStub(payload: futureSeconds)
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: try makeTemporaryHome(),
            tokenRefresher: makeSuccessfulRefresher(),
            appCredentialVault: vault
        )

        let token = try await reader.readAccessToken()
        XCTAssertEqual(token, "seconds-token")
        XCTAssertEqual(vault.saveCount, 0)
    }

    func testExplicitCLIImportReadsExactServiceOnceAndPersistsVault() async throws {
        let home = try makeTemporaryHome()
        let vault = OAuthVaultStub()
        let interactive = InteractiveKeychainPayloadReaderStub { service, account, reason in
            XCTAssertEqual(service, "Claude Code-credentials")
            XCTAssertEqual(account, NSUserName())
            XCTAssertFalse(reason.isEmpty)
            return .value(Self.credentialJSON(token: "imported-token"))
        }
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home,
            appCredentialVault: vault,
            interactiveKeychainPayloadReader: { service, account, reason in
                interactive.read(service: service, account: account, reason: reason)
            }
        )

        let result = await reader.importActiveCLICredential()
        let token = try await reader.readAccessToken()

        XCTAssertEqual(result, .imported(credentialChanged: false))
        XCTAssertEqual(token, "imported-token")
        XCTAssertEqual(interactive.calls.count, 1)
        XCTAssertEqual(vault.saveCount, 1)
    }

    func testExplicitCLIImportPrefersExactKeychainOverCredentialFile() async throws {
        let home = try makeTemporaryHome()
        try writeCredentialFile(
            configDirectory: home.appendingPathComponent(".claude"),
            token: "stale-file-token"
        )
        let vault = OAuthVaultStub()
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            .value(Self.credentialJSON(token: "current-keychain-token"))
        }
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home,
            appCredentialVault: vault,
            interactiveKeychainPayloadReader: { service, account, reason in
                interactive.read(service: service, account: account, reason: reason)
            }
        )

        let result = await reader.importActiveCLICredential()

        XCTAssertEqual(result, .imported(credentialChanged: false))
        XCTAssertEqual(interactive.calls.count, 1)
        XCTAssertTrue(vault.payload?.contains("current-keychain-token") == true)
        XCTAssertFalse(vault.payload?.contains("stale-file-token") == true)
    }

    func testExplicitCLIImportCancellationDoesNotPersistVault() async throws {
        let vault = OAuthVaultStub()
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in .cancelled }
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: try makeTemporaryHome(),
            appCredentialVault: vault,
            interactiveKeychainPayloadReader: { service, account, reason in
                interactive.read(service: service, account: account, reason: reason)
            }
        )

        let result = await reader.importActiveCLICredential()

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(interactive.calls.count, 1)
        XCTAssertEqual(vault.saveCount, 0)
        XCTAssertNil(vault.payload)
    }

    func testExplicitCLIImportRechecksCLIThenFallsBackToExistingVault() async throws {
        let vault = OAuthVaultStub(payload: Self.credentialJSON(token: "vault-token"))
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in .notFound }
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: try makeTemporaryHome(),
            appCredentialVault: vault,
            interactiveKeychainPayloadReader: { service, account, reason in
                interactive.read(service: service, account: account, reason: reason)
            }
        )

        let result = await reader.importActiveCLICredential()

        XCTAssertEqual(result, .available)
        XCTAssertEqual(interactive.calls.count, 1)
        XCTAssertEqual(vault.saveCount, 0)
    }

    func testExplicitCLIImportReportsReplacementOfStaleVaultCredential() async throws {
        let vault = OAuthVaultStub(payload: Self.credentialJSON(token: "old-vault-token"))
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            .value(Self.credentialJSON(token: "new-cli-token"))
        }
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: try makeTemporaryHome(),
            appCredentialVault: vault,
            interactiveKeychainPayloadReader: { service, account, reason in
                interactive.read(service: service, account: account, reason: reason)
            }
        )

        let result = await reader.importActiveCLICredential()

        XCTAssertEqual(result, .imported(credentialChanged: true))
        XCTAssertEqual(interactive.calls.count, 1)
        XCTAssertTrue(vault.payload?.contains("new-cli-token") == true)
    }

    func testInventoryRefreshReplacesStaleVaultWithActiveCredentialFile() async throws {
        let home = try makeTemporaryHome()
        try writeCredentialFile(
            configDirectory: home.appendingPathComponent(".claude"),
            token: "new-file-token"
        )
        let vault = OAuthVaultStub(payload: Self.credentialJSON(token: "old-vault-token"))
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            XCTFail("inventory refresh가 CLI Keychain UI를 열면 안 됩니다")
            return .cancelled
        }
        let reader = makeReader(
            home: home,
            vault: vault,
            interactive: interactive
        )

        let result = try await reader.refreshCredentialInventoryWithoutUI()

        XCTAssertEqual(result.accessToken, "new-file-token")
        XCTAssertTrue(result.credentialChanged)
        XCTAssertEqual(vault.saveCount, 1)
        XCTAssertTrue(vault.payload?.contains("new-file-token") == true)
        XCTAssertTrue(interactive.calls.isEmpty)
    }

    func testInventoryRefreshKeepsVaultWithoutCredentialFileOrKeychainRead() async throws {
        let home = try makeTemporaryHome()
        let vault = OAuthVaultStub(payload: Self.credentialJSON(token: "vault-token"))
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            XCTFail("inventory refresh가 CLI Keychain UI를 열면 안 됩니다")
            return .cancelled
        }
        let reader = makeReader(
            home: home,
            vault: vault,
            interactive: interactive
        )

        let result = try await reader.refreshCredentialInventoryWithoutUI()

        XCTAssertEqual(result.accessToken, "vault-token")
        XCTAssertFalse(result.credentialChanged)
        XCTAssertEqual(vault.saveCount, 0)
        XCTAssertTrue(interactive.calls.isEmpty)
    }

    private func makeReader(
        home: URL,
        vault: OAuthVaultStub,
        interactive: InteractiveKeychainPayloadReaderStub
    ) -> ClaudeCodeCredentialReader {
        ClaudeCodeCredentialReader(
            homeDirectory: home,
            appCredentialVault: vault,
            interactiveKeychainPayloadReader: { service, account, reason in
                interactive.read(service: service, account: account, reason: reason)
            }
        )
    }

    private func makeSuccessfulRefresher() -> ClaudeOAuthTokenRefresher {
        let response = #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#
        return ClaudeOAuthTokenRefresher(
            httpRunner: { request in
                let url = try XCTUnwrap(request.url)
                return (
                    Data(response.utf8),
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )
    }

    private func makeTemporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeCredentialReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeCredentialFile(configDirectory: URL, token: String) throws {
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try Self.credentialJSON(token: token).write(
            to: configDirectory.appendingPathComponent(".credentials.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func credentialJSON(
        token: String,
        refreshToken: String? = nil,
        expiresAt: String = #""2099-01-01T00:00:00Z""#
    ) -> String {
        let refreshFragment = refreshToken.map { ",\"refreshToken\":\"\($0)\"" } ?? ""
        return "{\"claudeAiOauth\":{\"accessToken\":\"\(token)\"\(refreshFragment),\"expiresAt\":\(expiresAt)}}"
    }
}

private final class OAuthVaultStub: ClaudeOAuthCredentialVault, @unchecked Sendable {
    enum TestError: Error {
        case expected
    }

    private let lock = NSLock()
    private var storedPayload: String?
    private var recordedLoadCount = 0
    private var recordedSaveCount = 0
    private var recordedDeleteCount = 0
    private let loadError: Error?

    init(payload: String? = nil, loadError: Error? = nil) {
        storedPayload = payload
        self.loadError = loadError
    }

    var payload: String? { lock.withLock { storedPayload } }
    var loadCount: Int { lock.withLock { recordedLoadCount } }
    var saveCount: Int { lock.withLock { recordedSaveCount } }

    nonisolated func loadPayload() throws -> String? {
        if let loadError { throw loadError }
        return lock.withLock {
            recordedLoadCount += 1
            return storedPayload
        }
    }

    nonisolated func savePayload(_ payload: String) throws {
        lock.withLock {
            recordedSaveCount += 1
            storedPayload = payload
        }
    }

    nonisolated func deletePayload() throws {
        lock.withLock {
            recordedDeleteCount += 1
            storedPayload = nil
        }
    }
}

private final class InteractiveKeychainPayloadReaderStub: @unchecked Sendable {
    struct Call: Equatable {
        let service: String
        let account: String?
        let reason: String
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private let handler: @Sendable (String, String?, String) -> KeychainAccessPreflight.ReadOutcome

    init(handler: @escaping @Sendable (String, String?, String) -> KeychainAccessPreflight.ReadOutcome) {
        self.handler = handler
    }

    var calls: [Call] { lock.withLock { recordedCalls } }

    func read(service: String, account: String?, reason: String) -> KeychainAccessPreflight.ReadOutcome {
        lock.withLock {
            recordedCalls.append(Call(service: service, account: account, reason: reason))
        }
        return handler(service, account, reason)
    }
}
