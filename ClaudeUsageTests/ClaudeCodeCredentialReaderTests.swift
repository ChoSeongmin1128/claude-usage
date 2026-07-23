import XCTest
@testable import ClaudeUsage

final class ClaudeCodeCredentialReaderTests: XCTestCase {
    func testCredentialFileIsPreferredAfterAppVaultMiss() async throws {
        let home = try makeTemporaryHome()
        try writeCredentialFile(home: home, token: "file-token")
        let vault = OAuthVaultStub()
        let runner = CommandRunnerStub { _, _ in
            XCTFail("파일 credential을 찾은 뒤에는 /usr/bin/security를 호출하면 안 됩니다")
            return nil
        }
        let reader = makeReader(home: home, vault: vault, runner: runner)

        let token = try await reader.readAccessToken()

        XCTAssertEqual(token, "file-token")
        XCTAssertEqual(vault.loadCount, 1)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testAppVaultIsPreferredWithoutSecurityCommand() async throws {
        let vault = OAuthVaultStub(payload: Self.credentialJSON(token: "vault-token"))
        let runner = CommandRunnerStub { _, _ in
            XCTFail("앱 전용 vault 조회에 /usr/bin/security를 사용하면 안 됩니다")
            return nil
        }
        let reader = makeReader(home: try makeTemporaryHome(), vault: vault, runner: runner)

        let token = try await reader.readAccessToken()

        XCTAssertEqual(token, "vault-token")
        XCTAssertEqual(vault.loadCount, 1)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testPrimaryCLIKeychainServiceIsUsedWhenVaultAndFileAreMissing() async throws {
        let vault = OAuthVaultStub()
        let runner = CommandRunnerStub { arguments, _ in
            guard arguments.contains("Claude Code-credentials") else { return nil }
            return ClaudeCodeSecurityCommandResult(
                status: 0,
                stdout: Self.credentialJSON(token: "primary-token"),
                stderr: ""
            )
        }
        let reader = makeReader(home: try makeTemporaryHome(), vault: vault, runner: runner)

        let token = try await reader.readAccessToken()

        XCTAssertEqual(token, "primary-token")
        XCTAssertEqual(runner.calls, [[
            "find-generic-password", "-s", "Claude Code-credentials", "-a", NSUserName(), "-w"
        ]])
    }

    func testDiscoveredHashedKeychainServiceIsPreflightedBeforeRead() async throws {
        let runner = CommandRunnerStub { arguments, _ in
            if arguments.contains("Claude Code-credentials") {
                return ClaudeCodeSecurityCommandResult(status: 44, stdout: "", stderr: "")
            }
            if arguments == ["dump-keychain"] {
                return ClaudeCodeSecurityCommandResult(
                    status: 0,
                    stdout: #""svce"<blob>="Claude Code-credentials:hashed""#,
                    stderr: ""
                )
            }
            if arguments.contains("Claude Code-credentials:hashed") {
                return ClaudeCodeSecurityCommandResult(
                    status: 0,
                    stdout: Self.credentialJSON(token: "hashed-token"),
                    stderr: ""
                )
            }
            return nil
        }
        let preflight = PreflightRecorder(outcomes: [
            "Claude Code-credentials": .allowed,
            "Claude Code-credentials:hashed": .allowed,
        ])
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: try makeTemporaryHome(),
            appCredentialVault: OAuthVaultStub(),
            preflightChecker: { service, account in preflight.check(service: service, account: account) },
            securityCommandRunner: { arguments, timeout in
                try await runner.run(arguments: arguments, timeout: timeout)
            }
        )

        let token = try await reader.readAccessToken()

        XCTAssertEqual(token, "hashed-token")
        XCTAssertTrue(preflight.services.contains("Claude Code-credentials:hashed"))
        XCTAssertTrue(runner.calls.contains(["dump-keychain"]))
    }

    func testDiscoveredServiceThatNeedsInteractionIsNotRead() async throws {
        let runner = CommandRunnerStub { arguments, _ in
            if arguments == ["dump-keychain"] {
                return ClaudeCodeSecurityCommandResult(
                    status: 0,
                    stdout: #""svce"<blob>="Claude Code-credentials:locked""#,
                    stderr: ""
                )
            }
            return nil
        }
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: try makeTemporaryHome(),
            appCredentialVault: OAuthVaultStub(),
            preflightChecker: { service, _ in
                service == "Claude Code-credentials:locked" ? .interactionRequired : .notFound
            },
            securityCommandRunner: { arguments, timeout in
                try await runner.run(arguments: arguments, timeout: timeout)
            }
        )

        let token = try await reader.readAccessToken()
        XCTAssertNil(token)
        XCTAssertFalse(runner.calls.contains { $0.contains("Claude Code-credentials:locked") })
    }

    func testConcurrentCredentialRequestsShareOneLookup() async throws {
        let vault = OAuthVaultStub()
        let runner = CommandRunnerStub { arguments, _ in
            guard arguments.contains("Claude Code-credentials") else { return nil }
            try await Task.sleep(for: .milliseconds(80))
            return ClaudeCodeSecurityCommandResult(
                status: 0,
                stdout: Self.credentialJSON(token: "shared-token"),
                stderr: ""
            )
        }
        let reader = makeReader(home: try makeTemporaryHome(), vault: vault, runner: runner)

        let tokens = try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<8 {
                group.addTask { try await reader.readAccessToken() }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(Set(tokens.compactMap { $0 }), ["shared-token"])
        XCTAssertEqual(vault.loadCount, 1)
        XCTAssertEqual(runner.calls.filter { $0.first == "find-generic-password" }.count, 1)
    }

    func testNilResultIsCachedUntilExplicitInvalidation() async throws {
        let vault = OAuthVaultStub()
        let runner = CommandRunnerStub { arguments, _ in
            if arguments == ["dump-keychain"] {
                return ClaudeCodeSecurityCommandResult(status: 0, stdout: "", stderr: "")
            }
            return nil
        }
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: try makeTemporaryHome(),
            appCredentialVault: vault,
            cacheTTL: 600,
            preflightChecker: { _, _ in .notFound },
            securityCommandRunner: { arguments, timeout in
                try await runner.run(arguments: arguments, timeout: timeout)
            }
        )

        let first = try await reader.readAccessToken()
        let second = try await reader.readAccessToken()
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(vault.loadCount, 1)
        XCTAssertEqual(runner.calls.filter { $0 == ["dump-keychain"] }.count, 1)

        await reader.invalidateCache()
        let afterInvalidation = try await reader.readAccessToken()
        XCTAssertNil(afterInvalidation)
        XCTAssertEqual(vault.loadCount, 2)
        XCTAssertEqual(runner.calls.filter { $0 == ["dump-keychain"] }.count, 2)
    }

    func testRefreshedCredentialPersistsToVaultWithoutSecurityAddOrACLArguments() async throws {
        let expired = Self.credentialJSON(
            token: "expired-access",
            refreshToken: "refresh-token",
            expiresAt: "2000-01-01T00:00:00Z"
        )
        let vault = OAuthVaultStub(payload: expired)
        let runner = CommandRunnerStub { _, _ in
            XCTFail("앱 소유 refresh 캐시 저장에 /usr/bin/security를 호출하면 안 됩니다")
            return nil
        }
        let response = #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#
        let refresher = ClaudeOAuthTokenRefresher(
            httpRunner: { request in
                let url = try XCTUnwrap(request.url)
                return (
                    Data(response.utf8),
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: try makeTemporaryHome(),
            tokenRefresher: refresher,
            appCredentialVault: vault,
            preflightChecker: { _, _ in .allowed },
            securityCommandRunner: { arguments, timeout in
                try await runner.run(arguments: arguments, timeout: timeout)
            }
        )

        let token = try await reader.readAccessToken()
        XCTAssertEqual(token, "new-access")
        XCTAssertEqual(vault.saveCount, 1)
        XCTAssertTrue(vault.payload?.contains("new-access") == true)
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertFalse(runner.calls.flatMap { $0 }.contains("-T"))
    }

    func testTimeoutReturnsNilWithoutThrowing() async throws {
        let runner = CommandRunnerStub { _, _ in nil }
        let reader = makeReader(home: try makeTemporaryHome(), vault: OAuthVaultStub(), runner: runner)

        let token = try await reader.readAccessToken()
        XCTAssertNil(token)
    }

    private func makeReader(
        home: URL,
        vault: OAuthVaultStub,
        runner: CommandRunnerStub
    ) -> ClaudeCodeCredentialReader {
        ClaudeCodeCredentialReader(
            homeDirectory: home,
            appCredentialVault: vault,
            preflightChecker: { _, _ in .allowed },
            securityCommandRunner: { arguments, timeout in
                try await runner.run(arguments: arguments, timeout: timeout)
            }
        )
    }

    private func makeTemporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeCredentialReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeCredentialFile(home: URL, token: String) throws {
        let directory = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.credentialJSON(token: token).write(
            to: directory.appendingPathComponent(".credentials.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func credentialJSON(
        token: String,
        refreshToken: String? = nil,
        expiresAt: String = "2099-01-01T00:00:00Z"
    ) -> String {
        let refreshFragment = refreshToken.map { ",\"refreshToken\":\"\($0)\"" } ?? ""
        return "{\"claudeAiOauth\":{\"accessToken\":\"\(token)\"\(refreshFragment),\"expiresAt\":\"\(expiresAt)\"}}"
    }
}

private final class OAuthVaultStub: ClaudeOAuthCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPayload: String?
    private var recordedLoadCount = 0
    private var recordedSaveCount = 0
    private var recordedDeleteCount = 0

    init(payload: String? = nil) {
        storedPayload = payload
    }

    var payload: String? {
        lock.withLock { storedPayload }
    }

    var loadCount: Int {
        lock.withLock { recordedLoadCount }
    }

    var saveCount: Int {
        lock.withLock { recordedSaveCount }
    }

    nonisolated func loadPayload() throws -> String? {
        lock.withLock {
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

private final class CommandRunnerStub: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [[String]] = []
    private let handler: @Sendable ([String], TimeInterval) async throws -> ClaudeCodeSecurityCommandResult?

    init(handler: @escaping @Sendable ([String], TimeInterval) async throws -> ClaudeCodeSecurityCommandResult?) {
        self.handler = handler
    }

    var calls: [[String]] {
        lock.withLock { recordedCalls }
    }

    func run(arguments: [String], timeout: TimeInterval) async throws -> ClaudeCodeSecurityCommandResult? {
        lock.withLock { recordedCalls.append(arguments) }
        return try await handler(arguments, timeout)
    }
}

private final class PreflightRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let outcomes: [String: KeychainAccessPreflight.Outcome]
    private var recordedServices: [String] = []

    init(outcomes: [String: KeychainAccessPreflight.Outcome]) {
        self.outcomes = outcomes
    }

    var services: [String] {
        lock.withLock { recordedServices }
    }

    func check(service: String, account: String?) -> KeychainAccessPreflight.Outcome {
        _ = account
        lock.withLock { recordedServices.append(service) }
        return outcomes[service] ?? .notFound
    }
}
