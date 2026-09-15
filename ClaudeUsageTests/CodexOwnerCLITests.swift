import Darwin
import XCTest
@testable import ClaudeUsage

@MainActor
final class CodexOwnerCLITests: XCTestCase {
    func testAuthenticatedHandshakeChecksAccountAndReapsOwnedProcess() async throws {
        let fixture = try makeFixture(
            quota:
                #"{"accountId":"account-a","rateLimits":{"primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":1789000000}}}"#
        )
        try await fixture.owner.refresh(
            sourceURL: fixture.auth, expectedAccountID: "account-a", budget: CodexRequestBudget(timeout: 2))
        try assertStopped(fixture.auth)
    }

    func testWrongAccountAndMalformedQuotaAreRejected() async throws {
        for quota in [#"{"accountId":"account-b"}"#, #"{"accountId":"account-a","rateLimits":{"primary":{}}}"#] {
            let fixture = try makeFixture(quota: quota)
            do {
                try await fixture.owner.refresh(
                    sourceURL: fixture.auth, expectedAccountID: "account-a", budget: CodexRequestBudget(timeout: 2))
                XCTFail("unverified identity or quota must fail")
            } catch let error as CodexOwnerError {
                XCTAssertTrue(error == .accountMismatch || error == .invalidResponse)
            }
            try assertStopped(fixture.auth)
        }
    }

    func testTimeoutAndCancellationStopOnlyOwnedHelper() async throws {
        let fixture = try makeFixture(quota: "{}", sleep: true)
        let began = ContinuousClock.now
        do {
            try await fixture.owner.refresh(
                sourceURL: fixture.auth, expectedAccountID: "account-a", budget: CodexRequestBudget(timeout: 2))
            XCTFail("deadline must stop a silent helper")
        } catch { XCTAssertEqual(error as? CodexOwnerError, .timedOut) }
        XCTAssertLessThan(began.duration(to: .now), .seconds(4))
        try assertStopped(fixture.auth)
        let ready = fixture.auth.deletingLastPathComponent().appendingPathComponent("owner.pid")
        try? FileManager.default.removeItem(at: ready)
        let task = Task {
            try await fixture.owner.refresh(
                sourceURL: fixture.auth, expectedAccountID: "account-a", budget: CodexRequestBudget())
        }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        task.cancel()
        do { try await task.value; XCTFail("cancellation must propagate") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        try assertStopped(fixture.auth)
        XCTAssertEqual(kill(getpid(), 0), 0)
    }

    func testUnavailableExecutableDoesNotLaunch() async throws {
        let owner = CodexOwnerCLI(executableURL: URL(fileURLWithPath: "/nonexistent/codex"))
        do {
            try await owner.refresh(
                sourceURL: URL(fileURLWithPath: "/nonexistent/auth.json"), expectedAccountID: "account-a",
                budget: CodexRequestBudget())
            XCTFail("missing CLI must be reported")
        } catch { XCTAssertEqual(error as? CodexOwnerError, .unavailable) }
    }

    private func makeFixture(quota: String, sleep: Bool = false) throws -> (owner: CodexOwnerCLI, auth: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexOwnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        let body = """
            #!/bin/sh
            printf '%s' "$$" > "$CODEX_HOME/owner.pid"
            \(sleep ? "sleep 30" : "")
            while IFS= read -r line; do
              case "$line" in
                *'"id":1'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
                *'"id":2'*) printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt"}}}' ;;
                *'"id":3'*) printf '%s\\n' '{"id":3,"result":\(quota)}' ;;
              esac
            done
            """
        try body.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (CodexOwnerCLI(executableURL: executable), root.appendingPathComponent("auth.json"))
    }

    private func assertStopped(_ auth: URL) throws {
        let contents = try String(
            contentsOf: auth.deletingLastPathComponent().appendingPathComponent("owner.pid"), encoding: .utf8)
        let pid = try XCTUnwrap(Int32(contents))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
