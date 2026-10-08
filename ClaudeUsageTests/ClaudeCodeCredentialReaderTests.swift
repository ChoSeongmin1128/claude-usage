import XCTest
@testable import ClaudeUsage

final class ClaudeCodeCredentialReaderTests: XCTestCase {
    func testCredentialFileIsUsedAfterVaultMissWithoutInteractiveKeychainRead() async throws {
        let home = try makeTemporaryHome()
        try writeCredentialFile(configDirectory: home.appendingPathComponent(".claude"), token: "file-token")
        let vault = OAuthVaultStub(payload: Self.credentialJSON(token: "stale-vault-token"))
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            XCTFail("백그라운드 credential 조회가 CLI Keychain UI를 열면 안 됩니다")
            return .cancelled
        }
        let reader = makeReader(home: home, vault: vault, interactive: interactive)

        let token = try await reader.readAccessToken()

        XCTAssertEqual(token, "file-token")
        XCTAssertEqual(vault.loadCount, 1)
        XCTAssertNotEqual(token, "stale-vault-token")
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

    func testAppVaultIsUsedWhenActiveCredentialFileIsMissing() async throws {
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

    func testVaultReadFailureDoesNotFallBackToPossiblyStaleCredentialFile() async throws {
        let home = try makeTemporaryHome()
        try writeCredentialFile(configDirectory: home.appendingPathComponent(".claude"), token: "file-token")
        let vault = OAuthVaultStub(loadError: OAuthVaultStub.TestError.expected)
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            XCTFail("vault 오류 뒤에 외부 Keychain을 읽으면 안 됩니다")
            return .cancelled
        }
        let reader = makeReader(home: home, vault: vault, interactive: interactive)

        do {
            _ = try await reader.readAccessToken()
            XCTFail("vault 읽기 실패를 cache miss로 처리해 stale CLI 파일로 내려가면 안 됩니다")
        } catch let error as ClaudeOAuthCredentialReadError {
            XCTAssertEqual(error, .reconnectRequired)
        }
        XCTAssertEqual(vault.loadCount, 0)
        XCTAssertTrue(interactive.calls.isEmpty)
    }

    func testActiveCredentialFileTakesPriorityOverMalformedVaultMirror() async throws {
        let home = try makeTemporaryHome()
        try writeCredentialFile(configDirectory: home.appendingPathComponent(".claude"), token: "file-token")
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            XCTFail("손상된 vault 뒤에 다른 계정을 선택하면 안 됩니다")
            return .cancelled
        }
        let vault = OAuthVaultStub(payload: #"{"invalid":true}"#)
        let reader = makeReader(
            home: home,
            vault: vault,
            interactive: interactive
        )

        let token = try await reader.readAccessToken()
        XCTAssertEqual(token, "file-token")
        XCTAssertEqual(vault.loadCount, 1)
        XCTAssertTrue(interactive.calls.isEmpty)
    }

    func testMalformedActiveCredentialFileDoesNotFallBackToVaultMirror() async throws {
        let home = try makeTemporaryHome()
        let configDirectory = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try #"{"invalid":true}"#.write(
            to: configDirectory.appendingPathComponent(".credentials.json"),
            atomically: true,
            encoding: .utf8
        )
        let vault = OAuthVaultStub(payload: Self.credentialJSON(token: "different-account-vault"))
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home,
            appCredentialVault: vault
        )

        let token = try await reader.readAccessToken()

        XCTAssertNil(token)
        XCTAssertEqual(vault.loadCount, 1)
    }

    func testExpiredVaultMirrorDoesNotRotateCLIOwnedRefreshToken() async throws {
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
        let refresher = ClaudeOAuthTokenRefresher(httpRunner: { request in
            XCTFail("만료된 vault mirror의 refresh token을 사용하면 안 됩니다")
            let url = try XCTUnwrap(request.url)
            return (
                Data(#"{"access_token":"unexpected"}"#.utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        })
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: try makeTemporaryHome(),
            tokenRefresher: refresher,
            appCredentialVault: vault,
            interactiveKeychainPayloadReader: { service, account, reason in
                interactive.read(service: service, account: account, reason: reason)
            }
        )

        let token = try await reader.readAccessToken()

        XCTAssertNil(token)
        XCTAssertEqual(vault.saveCount, 0)
        XCTAssertTrue(interactive.calls.isEmpty)
    }

    func testForcedRefreshDoesNotConsumeStaleFileWhenVersionedCLIMirrorIsNewer() async throws {
        let home = try makeTemporaryHome()
        let configDirectory = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try Self.credentialJSON(
            token: "expired-file-access",
            refreshToken: "stale-file-refresh",
            expiresAt: #""2000-01-01T00:00:00Z""#
        ).write(
            to: configDirectory.appendingPathComponent(".credentials.json"),
            atomically: true,
            encoding: .utf8
        )
        let mirrorPayload = try XCTUnwrap(
            ClaudeOAuthCredentialVaultPayload.encode(
                credentialPayload: Self.credentialJSON(
                    token: "fresh-keychain-access",
                    refreshToken: "shared-keychain-refresh",
                    expiresAt: #""2099-01-01T00:00:00Z""#
                ),
                ownership: .cliMirror
            )
        )
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home,
            tokenRefresher: ClaudeOAuthTokenRefresher(httpRunner: { _ in
                XCTFail("최신 CLI mirror가 있으면 stale 파일 refresh token을 소비하면 안 됩니다")
                throw URLError(.cancelled)
            }),
            appCredentialVault: OAuthVaultStub(payload: mirrorPayload)
        )

        do {
            _ = try await reader.forceRefreshAccessToken()
            XCTFail("CLI mirror는 앱이 독립적으로 refresh하지 않고 재연결을 요구해야 합니다")
        } catch let error as ClaudeOAuthCredentialReadError {
            XCTAssertEqual(error, .reconnectRequired)
        }
    }

    func testMigratedAppManagedVaultRefreshesWithoutReadingStaleCLIFileOrKeychain() async throws {
        let home = try makeTemporaryHome()
        let configDirectory = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try Self.credentialJSON(
            token: "stale-file-access",
            refreshToken: "stale-file-refresh",
            expiresAt: #""2000-01-01T00:00:00Z""#
        ).write(
            to: configDirectory.appendingPathComponent(".credentials.json"),
            atomically: true,
            encoding: .utf8
        )
        let migratedPayload = try XCTUnwrap(
            ClaudeOAuthCredentialVaultPayload.encode(
                credentialPayload: Self.credentialJSON(
                    token: "migrated-expired-access",
                    refreshToken: "migrated-refresh",
                    expiresAt: #""2000-01-01T00:00:00Z""#
                ),
                ownership: .appManaged
            )
        )
        let vault = OAuthVaultStub(payload: migratedPayload)
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            XCTFail("migration 이후 자동 refresh가 CLI Keychain을 읽으면 안 됩니다")
            return .cancelled
        }
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home,
            tokenRefresher: makeSuccessfulRefresher(),
            appCredentialVault: vault,
            interactiveKeychainPayloadReader: { service, account, reason in
                interactive.read(service: service, account: account, reason: reason)
            }
        )

        let token = try await reader.readAccessToken()

        XCTAssertEqual(token, "new-access")
        XCTAssertTrue(vault.payload?.contains("new-refresh") == true)
        XCTAssertEqual(
            vault.payload.map(ClaudeOAuthCredentialVaultPayload.ownership(of:)),
            .appManaged
        )
        XCTAssertTrue(interactive.calls.isEmpty)
    }

    func testUnusableActiveCredentialFileDoesNotFallBackToAnotherVaultAccount() async throws {
        let home = try makeTemporaryHome()
        let configDirectory = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let expired = Self.credentialJSON(
            token: "active-expired",
            refreshToken: "active-rejected-refresh",
            expiresAt: #""2000-01-01T00:00:00Z""#
        )
        try expired.write(
            to: configDirectory.appendingPathComponent(".credentials.json"),
            atomically: true,
            encoding: .utf8
        )
        let vault = OAuthVaultStub(payload: Self.credentialJSON(token: "different-account-vault"))
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home,
            appCredentialVault: vault,
            cliRefresher: { _ in .notLoggedIn }
        )

        do {
            _ = try await reader.readAccessToken()
            XCTFail("Claude Code가 로그아웃 상태면 재로그인 오류로 노출되어야 합니다")
        } catch let error as ClaudeOAuthCredentialReadError {
            guard case .reauthenticationRequired = error else {
                return XCTFail("예상하지 못한 credential 오류: \(error)")
            }
        }
        XCTAssertEqual(vault.loadCount, 1)
    }

    func testExpiredCredentialFileIsRefreshedByClaudeCodeNotByTheApp() async throws {
        let home = try makeTemporaryHome()
        let configDirectory = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let credentialURL = configDirectory.appendingPathComponent(".credentials.json")
        try Self.credentialJSON(
            token: "expired",
            refreshToken: "old-refresh",
            expiresAt: #""2000-01-01T00:00:00Z""#
        ).write(to: credentialURL, atomically: true, encoding: .utf8)
        let refresher = ClaudeOAuthTokenRefresher(httpRunner: { _ in
            XCTFail("Claude Code의 refresh token을 앱이 쓰면 Claude Code 로그인이 끊깁니다")
            throw URLError(.cancelled)
        })
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home,
            tokenRefresher: refresher,
            appCredentialVault: OAuthVaultStub(),
            cliRefresher: { directory in
                XCTAssertNil(directory)
                try? Self.credentialJSON(token: "cli-refreshed-access", refreshToken: "cli-new-refresh")
                    .write(to: credentialURL, atomically: true, encoding: .utf8)
                return .refreshed
            }
        )

        let token = try await reader.readAccessToken()

        XCTAssertEqual(token, "cli-refreshed-access")
    }

    func testExpiredCredentialFileStaysUnusedWhenClaudeCodeCannotRefresh() async throws {
        let home = try makeTemporaryHome()
        let configDirectory = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try Self.credentialJSON(
            token: "expired",
            refreshToken: "refresh-token",
            expiresAt: #""2000-01-01T00:00:00Z""#
        ).write(to: configDirectory.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home,
            tokenRefresher: makeSuccessfulRefresher(),
            appCredentialVault: OAuthVaultStub(),
            cliRefresher: { _ in .unavailable }
        )

        let token = try await reader.readAccessToken()

        XCTAssertNil(token)
    }

    func testFresherClaudeCodeKeychainWinsOverStaleCredentialFile() async throws {
        let home = try makeTemporaryHome()
        let configDirectory = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try Self.credentialJSON(
            token: "stale-file",
            refreshToken: "old-refresh",
            expiresAt: #""2000-01-01T00:00:00Z""#
        ).write(to: configDirectory.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home,
            tokenRefresher: makeSuccessfulRefresher(),
            appCredentialVault: OAuthVaultStub(),
            cliKeychainPayloadReader: { _ in .payload(Self.credentialJSON(token: "keychain-current")) },
            cliRefresher: { _ in
                XCTFail("Keychain에 유효한 로그인이 있으면 갱신하지 않습니다")
                return .unavailable
            }
        )

        let token = try await reader.readAccessToken()

        XCTAssertEqual(token, "keychain-current")
    }

    func testMissingExecutableForExpiredFileKeepsCredentialAndVault() async throws {
        let home = try makeTemporaryHome()
        let directory = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(".credentials.json")
        let payload = Self.credentialJSON(
            token: "expired", refreshToken: "kept-refresh", expiresAt: #""2000-01-01T00:00:00Z""#)
        try payload.write(to: file, atomically: true, encoding: .utf8)
        let vault = OAuthVaultStub(payload: payload)
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home, appCredentialVault: vault, cliRefresher: { _ in .executableNotFound })

        do {
            _ = try await reader.readAccessToken()
            XCTFail("CLI 없음이 만료 토큰의 원인을 지우면 안 됩니다")
        } catch let error as ClaudeOAuthCredentialReadError {
            guard case .executableNotFound = error else { return XCTFail("잘못된 오류: \(error)") }
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), payload)
        XCTAssertEqual(vault.payload, payload)
        XCTAssertEqual(vault.saveCount, 0)
    }

    func testMissingExecutableForKeychainOnlyInventoryIsReportedWithoutDeletingVault() async throws {
        let payload = Self.credentialJSON(
            token: "expired", refreshToken: "kept-refresh", expiresAt: #""2000-01-01T00:00:00Z""#)
        let vault = OAuthVaultStub(payload: payload)
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: try makeTemporaryHome(), appCredentialVault: vault,
            cliKeychainPayloadReader: { _ in .payload(payload) }, cliRefresher: { _ in .executableNotFound })

        do {
            _ = try await reader.refreshCredentialInventoryWithoutUI()
            XCTFail("Keychain 경로도 CLI 없음 오류를 보존해야 합니다")
        } catch let error as ClaudeOAuthCredentialReadError {
            guard case .executableNotFound = error else { return XCTFail("잘못된 오류: \(error)") }
        }
        XCTAssertEqual(vault.payload, payload)
        XCTAssertEqual(vault.saveCount, 0)
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

    func testExplicitCLIImportChoosesFresherActiveCredentialFileAfterOneKeychainRead() async throws {
        let home = try makeTemporaryHome()
        try writeCredentialFile(
            configDirectory: home.appendingPathComponent(".claude"),
            token: "active-file-token"
        )
        let vault = OAuthVaultStub()
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            .value(
                Self.credentialJSON(
                    token: "stale-keychain-token",
                    expiresAt: #""2000-01-01T00:00:00Z""#
                )
            )
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
        XCTAssertTrue(vault.payload?.contains("active-file-token") == true)
        XCTAssertFalse(vault.payload?.contains("stale-keychain-token") == true)
    }

    func testExplicitCLIImportPrefersFreshKeychainOverExpiredFileWithoutRefreshingStaleLineage() async throws {
        let home = try makeTemporaryHome()
        let configDirectory = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try Self.credentialJSON(
            token: "expired-file-token",
            refreshToken: "consumed-file-refresh",
            expiresAt: #""2000-01-01T00:00:00Z""#
        ).write(
            to: configDirectory.appendingPathComponent(".credentials.json"),
            atomically: true,
            encoding: .utf8
        )
        let vault = OAuthVaultStub(payload: Self.credentialJSON(token: "old-vault-token"))
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            .value(Self.credentialJSON(token: "fresh-keychain-token"))
        }
        let refresher = ClaudeOAuthTokenRefresher(httpRunner: { _ in
            XCTFail("fresh Keychain credential가 있으면 stale 파일 lineage를 refresh하면 안 됩니다")
            throw URLError(.cancelled)
        })
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home,
            tokenRefresher: refresher,
            appCredentialVault: vault,
            interactiveKeychainPayloadReader: { service, account, reason in
                interactive.read(service: service, account: account, reason: reason)
            }
        )

        let result = await reader.importActiveCLICredential()

        XCTAssertEqual(result, .imported(credentialChanged: true))
        XCTAssertEqual(interactive.calls.count, 1)
        XCTAssertTrue(vault.payload?.contains("fresh-keychain-token") == true)
        XCTAssertFalse(vault.payload?.contains("expired-file-token") == true)
    }

    func testInventoryRefreshKeepsFreshExplicitKeychainMirrorOverExpiredCredentialFile() async throws {
        let home = try makeTemporaryHome()
        let configDirectory = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try Self.credentialJSON(
            token: "expired-file-token",
            refreshToken: "consumed-file-refresh",
            expiresAt: #""2000-01-01T00:00:00Z""#
        ).write(
            to: configDirectory.appendingPathComponent(".credentials.json"),
            atomically: true,
            encoding: .utf8
        )
        let vault = OAuthVaultStub()
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            .value(
                Self.credentialJSON(
                    token: "fresh-keychain-token",
                    expiresAt: #""2099-01-01T00:00:00Z""#
                )
            )
        }
        let refresher = ClaudeOAuthTokenRefresher(httpRunner: { _ in
            XCTFail("명시적으로 가져온 최신 Keychain mirror 뒤에 stale 파일을 refresh하면 안 됩니다")
            throw URLError(.cancelled)
        })
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home,
            tokenRefresher: refresher,
            appCredentialVault: vault,
            interactiveKeychainPayloadReader: { service, account, reason in
                interactive.read(service: service, account: account, reason: reason)
            }
        )

        let importResult = await reader.importActiveCLICredential()
        XCTAssertEqual(importResult, .imported(credentialChanged: false))
        let inventory = try await reader.refreshCredentialInventoryWithoutUI()

        XCTAssertEqual(inventory.accessToken, "fresh-keychain-token")
        XCTAssertFalse(inventory.credentialChanged)
        XCTAssertEqual(interactive.calls.count, 1)
        let savedPayload = try XCTUnwrap(vault.payload)
        XCTAssertEqual(
            ClaudeOAuthCredentialVaultPayload.ownership(of: savedPayload),
            .cliMirror
        )
    }

    func testExplicitCLIImportPrefersLaterKeychainExpiryEvenWhenFileIsStillUsable() async throws {
        let home = try makeTemporaryHome()
        let configDirectory = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try Self.credentialJSON(
            token: "usable-but-stale-file-token",
            expiresAt: #""2050-01-01T00:00:00Z""#
        ).write(
            to: configDirectory.appendingPathComponent(".credentials.json"),
            atomically: true,
            encoding: .utf8
        )
        let vault = OAuthVaultStub()
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            .value(Self.credentialJSON(token: "later-keychain-token"))
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
        XCTAssertTrue(vault.payload?.contains("later-keychain-token") == true)
        XCTAssertFalse(vault.payload?.contains("usable-but-stale-file-token") == true)
    }

    func testExplicitCLIImportKeepsMetadataFromSelectedFileInsteadOfStaleKeychainCandidate() async throws {
        let home = try makeTemporaryHome()
        let configDirectory = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let filePayload = #"{"claudeAiOauth":{"accessToken":"selected-file","expiresAt":"2099-01-01T00:00:00Z","subscriptionType":"team"}}"#
        try filePayload.write(
            to: configDirectory.appendingPathComponent(".credentials.json"),
            atomically: true,
            encoding: .utf8
        )
        let metadataStore = ClaudeProfileMetadataStore(
            fileURL: home.appendingPathComponent("metadata.json")
        )
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            .value(
                #"{"claudeAiOauth":{"accessToken":"stale-keychain","expiresAt":"2000-01-01T00:00:00Z","subscriptionType":"free"}}"#
            )
        }
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home,
            profileMetadataStore: metadataStore,
            appCredentialVault: OAuthVaultStub(),
            interactiveKeychainPayloadReader: { service, account, reason in
                interactive.read(service: service, account: account, reason: reason)
            }
        )

        let result = await reader.importActiveCLICredential()
        let metadata = await metadataStore.load()
        let subscriptionType = metadata?.subscriptionType

        XCTAssertEqual(result, .imported(credentialChanged: false))
        XCTAssertEqual(subscriptionType, "team")
    }

    func testExplicitCLIImportUpdatesMetadataOnlyFromSelectedKeychainCandidate() async throws {
        let home = try makeTemporaryHome()
        let configDirectory = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let filePayload = #"{"claudeAiOauth":{"accessToken":"older-file","expiresAt":"2050-01-01T00:00:00Z","subscriptionType":"free"}}"#
        try filePayload.write(
            to: configDirectory.appendingPathComponent(".credentials.json"),
            atomically: true,
            encoding: .utf8
        )
        let metadataStore = ClaudeProfileMetadataStore(
            fileURL: home.appendingPathComponent("metadata.json")
        )
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            .value(
                #"{"claudeAiOauth":{"accessToken":"selected-keychain","expiresAt":"2099-01-01T00:00:00Z","subscriptionType":"team"}}"#
            )
        }
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home,
            profileMetadataStore: metadataStore,
            appCredentialVault: OAuthVaultStub(),
            interactiveKeychainPayloadReader: { service, account, reason in
                interactive.read(service: service, account: account, reason: reason)
            }
        )

        let result = await reader.importActiveCLICredential()
        let metadata = await metadataStore.load()
        let subscriptionType = metadata?.subscriptionType

        XCTAssertEqual(result, .imported(credentialChanged: false))
        XCTAssertEqual(subscriptionType, "team")
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

    func testExplicitCLIImportFallsBackToActiveCredentialFileWhenKeychainDataIsInvalid() async throws {
        let home = try makeTemporaryHome()
        try writeCredentialFile(
            configDirectory: home.appendingPathComponent(".claude"),
            token: "active-file-token"
        )
        let vault = OAuthVaultStub(payload: Self.credentialJSON(token: "stale-vault-token"))
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            .invalidData
        }
        let reader = makeReader(
            home: home,
            vault: vault,
            interactive: interactive
        )

        let result = await reader.importActiveCLICredential()

        XCTAssertEqual(result, .imported(credentialChanged: true))
        XCTAssertEqual(interactive.calls.count, 1)
        XCTAssertTrue(vault.payload?.contains("active-file-token") == true)
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

    // MARK: - Data reset

    func testResetDropsAVaultCopyWhoseTokenTheCredentialFileHolds() async throws {
        let home = try makeTemporaryHome()
        try writeCredentialFile(home: home, refreshToken: "shared-refresh")
        let vault = OAuthVaultStub(payload: Self.credentialJSON(token: "vault-access", refreshToken: "shared-refresh"))

        let canDiscard = await makeResetReader(home: home, vault: vault).canDiscardAppVaultCopy()

        XCTAssertTrue(canDiscard)
    }

    func testResetKeepsAVaultCopyUnlessTheCredentialFileHoldsItsToken() async throws {
        let rotatedFileHome = try makeTemporaryHome()
        try writeCredentialFile(home: rotatedFileHome, refreshToken: "older")
        for home in [rotatedFileHome, try makeTemporaryHome()] {
            let vault = OAuthVaultStub(payload: Self.credentialJSON(token: "vault-access", refreshToken: "only-copy"))

            let canDiscard = await makeResetReader(home: home, vault: vault).canDiscardAppVaultCopy()

            XCTAssertFalse(canDiscard, home.path)
        }
    }

    func testResetKeepsAVaultCopyItCannotRead() async throws {
        let vault = OAuthVaultStub(loadError: OAuthVaultStub.TestError.expected)

        let canDiscard = await makeResetReader(home: try makeTemporaryHome(), vault: vault).canDiscardAppVaultCopy()

        XCTAssertFalse(canDiscard)
    }

    func testResetHasNothingToKeepWithoutARotatingToken() async throws {
        for vault in [OAuthVaultStub(), OAuthVaultStub(payload: Self.credentialJSON(token: "access-only"))] {
            let canDiscard = await makeResetReader(home: try makeTemporaryHome(), vault: vault).canDiscardAppVaultCopy()

            XCTAssertTrue(canDiscard)
        }
    }

    private func makeResetReader(home: URL, vault: OAuthVaultStub) -> ClaudeCodeCredentialReader {
        ClaudeCodeCredentialReader(
            homeDirectory: home,
            appCredentialVault: vault,
            interactiveKeychainPayloadReader: { _, _, _ in
                XCTFail("초기화 확인은 Keychain 확인 창을 열지 않아야 합니다")
                return .cancelled
            }
        )
    }

    private func writeCredentialFile(home: URL, refreshToken: String) throws {
        let config = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Self.credentialJSON(token: "file-access", refreshToken: refreshToken).write(
            to: config.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
    }

    func testMissingFileReadsCurrentClaudeCodeKeychainThroughSecurityToolWithoutPrompt() async throws {
        let vault = OAuthVaultStub(
            payload: Self.credentialJSON(token: "stale-copy", expiresAt: #""2000-01-01T00:00:00Z""#))
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            XCTFail("확인 창을 띄우는 직접 읽기를 하면 안 됩니다")
            return .cancelled
        }
        let cli = CLIKeychainStub([.payload(Self.credentialJSON(token: "current-token"))])
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: try makeTemporaryHome(),
            appCredentialVault: vault,
            interactiveKeychainPayloadReader: { service, account, reason in
                interactive.read(service: service, account: account, reason: reason)
            },
            cliKeychainPayloadReader: { await cli.read($0) },
            cliRefresher: { _ in
                XCTFail("만료되지 않은 로그인은 Claude Code에 갱신을 맡기지 않습니다")
                return .unavailable
            }
        )

        let token = try await reader.readAccessToken()

        XCTAssertEqual(token, "current-token")
        XCTAssertEqual(cli.services, ["Claude Code-credentials"])
        XCTAssertEqual(vault.saveCount, 1)
        XCTAssertTrue(interactive.calls.isEmpty)
    }

    func testExpiredClaudeCodeKeychainIsRefreshedByClaudeCodeAndReadAgain() async throws {
        let cli = CLIKeychainStub([
            .payload(Self.credentialJSON(token: "expired", expiresAt: #""2000-01-01T00:00:00Z""#)),
            .payload(Self.credentialJSON(token: "refreshed-by-claude-code")),
        ])
        let refreshes = CLIKeychainStub([])
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: try makeTemporaryHome(),
            appCredentialVault: OAuthVaultStub(),
            cliKeychainPayloadReader: { await cli.read($0) },
            cliRefresher: { directory in
                XCTAssertNil(directory, "기본 로그인은 CLAUDE_CONFIG_DIR 없이 갱신해야 Keychain 이름이 같습니다")
                refreshes.record("refresh")
                return .refreshed
            }
        )

        let token = try await reader.readAccessToken()

        XCTAssertEqual(token, "refreshed-by-claude-code")
        XCTAssertEqual(refreshes.services, ["refresh"])
        XCTAssertEqual(cli.services.count, 2)
    }

    func testExplicitImportUsesSecurityToolBeforePrompting() async throws {
        let vault = OAuthVaultStub()
        let interactive = InteractiveKeychainPayloadReaderStub { _, _, _ in
            XCTFail("security 도구로 읽히면 확인 창을 띄우면 안 됩니다")
            return .cancelled
        }
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: try makeTemporaryHome(),
            appCredentialVault: vault,
            interactiveKeychainPayloadReader: { service, account, reason in
                interactive.read(service: service, account: account, reason: reason)
            },
            cliKeychainPayloadReader: { _ in .payload(Self.credentialJSON(token: "imported-token")) }
        )

        let result = await reader.importActiveCLICredential()

        XCTAssertEqual(result, .imported(credentialChanged: false))
        XCTAssertEqual(vault.saveCount, 1)
        XCTAssertTrue(interactive.calls.isEmpty)
    }

    func testCurrentNativeKeychainIsCheckedBeforeFresherVaultMirror() async throws {
        let (reader, vault, keychain) = try nativeOwnerFixture(
            .payload(
                Self.credentialJSON(
                    token: "native-B", expiresAt: #""2080-01-01T00:00:00Z""#)))

        let token = try await reader.readAccessToken()

        XCTAssertEqual(token, "native-B")
        XCTAssertEqual(keychain.services, ["Claude Code-credentials"])
        XCTAssertTrue(vault.payload?.contains("native-B") == true)
    }

    func testInventoryReplacesMirrorWhenCurrentNativeCredentialChanged() async throws {
        let (reader, vault, _) = try nativeOwnerFixture(
            .payload(
                Self.credentialJSON(
                    token: "native-B", expiresAt: #""2080-01-01T00:00:00Z""#)))

        let result = try await reader.refreshCredentialInventoryWithoutUI()

        XCTAssertEqual(result.accessToken, "native-B")
        XCTAssertTrue(result.credentialChanged)
        XCTAssertTrue(vault.payload?.contains("native-B") == true)
    }

    func testTemporarilyUnreadableNativeKeychainKeepsPermittedMirrorFallback() async throws {
        let (reader, vault, keychain) = try nativeOwnerFixture(.failed)

        let result = try await reader.refreshCredentialInventoryWithoutUI()

        XCTAssertEqual(result.accessToken, "mirror-A")
        XCTAssertFalse(result.credentialChanged)
        XCTAssertEqual(keychain.services.count, 1)
        XCTAssertEqual(vault.saveCount, 0)
    }

    func testForceRefreshCanAdoptReplacementNativeTokenWithoutConsumingStaleRefreshToken() async throws {
        let (reader, vault, _) = try nativeOwnerFixture(
            .payload(
                Self.credentialJSON(
                    token: "native-B", expiresAt: #""2080-01-01T00:00:00Z""#)))

        let result = try await reader.forceRefreshAccessToken()

        XCTAssertEqual(result, "native-B")
        XCTAssertTrue(vault.payload?.contains("native-B") == true)
    }

    func testCurrentNativeCredentialWinsEvenWhenOldFileExpiresLater() async throws {
        let (reader, vault, _) = try nativeOwnerFixture(
            .payload(
                Self.credentialJSON(
                    token: "native-B", expiresAt: #""2080-01-01T00:00:00Z""#)),
            fileExpiry: #""2099-01-01T00:00:00Z""#)
        let token = try await reader.readAccessToken()
        XCTAssertEqual(token, "native-B")
        XCTAssertTrue(vault.payload?.contains("native-B") == true)
    }

    func testExpiredNativeCredentialDoesNotReplaceUsableFile() async throws {
        let (reader, _, _) = try nativeOwnerFixture(
            .payload(
                Self.credentialJSON(
                    token: "expired-native-B", expiresAt: #""2000-01-01T00:00:00Z""#)))
        let token = try await reader.readAccessToken()
        XCTAssertEqual(token, "mirror-A")
    }

    private func nativeOwnerFixture(
        _ native: ClaudeCodeKeychainCLI.Outcome,
        fileExpiry: String = #""2050-01-01T00:00:00Z""#
    ) throws
        -> (ClaudeCodeCredentialReader, OAuthVaultStub, CLIKeychainStub)
    {
        let home = try makeTemporaryHome()
        let config = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Self.credentialJSON(token: "file-A", expiresAt: fileExpiry)
            .write(to: config.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
        let payload = try XCTUnwrap(
            ClaudeOAuthCredentialVaultPayload.encode(
                credentialPayload: Self.credentialJSON(token: "mirror-A", expiresAt: #""2099-01-01T00:00:00Z""#),
                ownership: .cliMirror))
        let vault = OAuthVaultStub(payload: payload)
        let keychain = CLIKeychainStub([native])
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home, appCredentialVault: vault,
            interactiveKeychainPayloadReader: { _, _, _ in
                XCTFail("background native selection must never prompt")
                return .cancelled
            },
            cliKeychainPayloadReader: { await keychain.read($0) },
            cliRefresher: { _ in
                XCTFail("unexpired native or permitted mirror must not refresh")
                return .unavailable
            })
        return (reader, vault, keychain)
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

private final class CLIKeychainStub: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [ClaudeCodeKeychainCLI.Outcome]
    private var recorded: [String] = []

    init(_ outcomes: [ClaudeCodeKeychainCLI.Outcome]) {
        self.outcomes = outcomes
    }

    var services: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ value: String) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }

    func read(_ service: String) async -> ClaudeCodeKeychainCLI.Outcome {
        lock.withLock {
            recorded.append(service)
            return outcomes.isEmpty ? .notFound : outcomes.removeFirst()
        }
    }
}
