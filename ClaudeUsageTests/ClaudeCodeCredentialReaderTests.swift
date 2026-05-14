import XCTest
@testable import ClaudeUsage

final class ClaudeCodeCredentialReaderTests: XCTestCase {
    func testCredentialFileIsPreferredAfterRefreshedCacheMiss() async throws {
        // 새 흐름: 우리 앱 refresh 캐시 keychain → 파일 → CLI primary keychain → discovered.
        // 캐시가 없으면(status 44) 파일을 사용해야 한다.
        let home = try makeTemporaryHome()
        try writeCredentialFile(home: home, token: "file-token")
        let runner = CommandRunnerStub { arguments, _ in
            // refresh 캐시는 비어 있음 (Item not found)
            if arguments.contains("ClaudeUsage.Claude Code-credentials-refreshed") {
                return ClaudeCodeSecurityCommandResult(status: 44, stdout: "", stderr: "")
            }
            return nil
        }
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home,
            preflightChecker: { _, _ in .allowed },
            securityCommandRunner: { arguments, timeout in
                try await runner.run(arguments: arguments, timeout: timeout)
            }
        )

        let token = try await reader.readAccessToken()

        XCTAssertEqual(token, "file-token")
        // 캐시 keychain 1회만 시도 후 파일 발견 → CLI primary 까지 안 감.
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(Array(runner.calls[0].prefix(3)), ["find-generic-password", "-s", "ClaudeUsage.Claude Code-credentials-refreshed"])
    }

    func testPrimaryKeychainServiceIsUsedWhenRefreshedCacheAndFileAreMissing() async throws {
        let home = try makeTemporaryHome()
        let runner = CommandRunnerStub { arguments, _ in
            if arguments.contains("ClaudeUsage.Claude Code-credentials-refreshed") {
                return ClaudeCodeSecurityCommandResult(status: 44, stdout: "", stderr: "")
            }
            guard arguments.contains("Claude Code-credentials") else { return nil }
            return ClaudeCodeSecurityCommandResult(
                status: 0,
                stdout: Self.credentialJSON(token: "primary-token"),
                stderr: ""
            )
        }
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home,
            preflightChecker: { _, _ in .allowed },
            securityCommandRunner: { arguments, timeout in
                try await runner.run(arguments: arguments, timeout: timeout)
            }
        )

        let token = try await reader.readAccessToken()

        XCTAssertEqual(token, "primary-token")
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(Array(runner.calls[0].prefix(3)), ["find-generic-password", "-s", "ClaudeUsage.Claude Code-credentials-refreshed"])
        XCTAssertEqual(Array(runner.calls[1].prefix(3)), ["find-generic-password", "-s", "Claude Code-credentials"])
    }

    func testDiscoveredHashedKeychainServiceIsUsedWhenPrimaryIsMissing() async throws {
        let home = try makeTemporaryHome()
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
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home,
            preflightChecker: { _, _ in .allowed },
            securityCommandRunner: { arguments, timeout in
                try await runner.run(arguments: arguments, timeout: timeout)
            }
        )

        let token = try await reader.readAccessToken()

        XCTAssertEqual(token, "hashed-token")
        XCTAssertTrue(runner.calls.contains(["dump-keychain"]))
    }

    func testTimeoutReturnsNilWithoutThrowing() async throws {
        let home = try makeTemporaryHome()
        let runner = CommandRunnerStub { _, _ in nil }
        let reader = ClaudeCodeCredentialReader(
            homeDirectory: home,
            preflightChecker: { _, _ in .allowed },
            securityCommandRunner: { arguments, timeout in
                try await runner.run(arguments: arguments, timeout: timeout)
            }
        )

        let token = try await reader.readAccessToken()

        XCTAssertNil(token)
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

    private static func credentialJSON(token: String) -> String {
        """
        {"claudeAiOauth":{"accessToken":"\(token)","expiresAt":"2099-01-01T00:00:00Z"}}
        """
    }
}

private final class CommandRunnerStub: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [[String]] = []
    private let handler: @Sendable ([String], TimeInterval) -> ClaudeCodeSecurityCommandResult?

    init(handler: @escaping @Sendable ([String], TimeInterval) -> ClaudeCodeSecurityCommandResult?) {
        self.handler = handler
    }

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func run(arguments: [String], timeout: TimeInterval) async throws -> ClaudeCodeSecurityCommandResult? {
        recordCall(arguments)
        return handler(arguments, timeout)
    }

    private func recordCall(_ arguments: [String]) {
        lock.lock()
        recordedCalls.append(arguments)
        lock.unlock()
    }
}
