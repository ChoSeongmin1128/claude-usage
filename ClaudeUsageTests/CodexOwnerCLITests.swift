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

@MainActor
extension CodexOwnerCLITests {
    func testOwnedQuotaChecksSameSessionUserBeforeAndAfterUsage() async throws {
        let fixture = try ownedFixture(before: "a@example.com", after: "a@example.com")
        let result = try await fixture.owner.readOwnedRateLimits(
            sourceURL: fixture.auth, expectedAccountID: "team", budget: CodexRequestBudget(timeout: 2))
        XCTAssertEqual(result.email, "a@example.com")
        XCTAssertEqual(result.accountID, "team")
        XCTAssertEqual(
            try CodexHomeAccount.usageResponse(fromAppServer: result.quota.value).sessionWindow?.utilization, 42)
        try assertStopped(fixture.auth)
    }

    func testOwnedQuotaRejectsUserChangeInsideTheSameWorkspace() async throws {
        let fixture = try ownedFixture(before: "a@example.com", after: "b@example.com")
        do {
            _ = try await fixture.owner.readOwnedRateLimits(
                sourceURL: fixture.auth, expectedAccountID: "team", budget: CodexRequestBudget(timeout: 2))
            XCTFail("The workspace alone must not identify a user")
        } catch { XCTAssertEqual(error as? CodexOwnerError, .accountMismatch) }
        try assertStopped(fixture.auth)
    }

    func testOwnedQuotaDoesNotInventAMissingRPCEmail() async throws {
        let fixture = try ownedFixture(before: nil, after: nil)
        do {
            _ = try await fixture.owner.readOwnedRateLimits(
                sourceURL: fixture.auth, expectedAccountID: "team", budget: CodexRequestBudget(timeout: 2))
            XCTFail("The RPC user is unknown")
        } catch { XCTAssertEqual(error as? CodexOwnerError, .invalidResponse) }
        try assertStopped(fixture.auth)
    }

    func testLegacyQuotaWrapperDoesNotRequireOrReadEmail() async throws {
        let fixture = try ownedFixture(before: nil, after: nil, legacyOnly: true)
        let quota = try await fixture.owner.readRateLimits(
            sourceURL: fixture.auth, expectedAccountID: "team", budget: CodexRequestBudget(timeout: 2))
        XCTAssertEqual(try CodexHomeAccount.usageResponse(fromAppServer: quota).sessionWindow?.utilization, 42)
        try assertStopped(fixture.auth)
    }

    func testOwnedQuotaDeadlineStillReapsOnlyTheFixtureProcessGroup() async throws {
        let fixture = try ownedFixture(before: "a@example.com", after: "a@example.com", silent: true)
        do {
            _ = try await fixture.owner.readOwnedRateLimits(
                sourceURL: fixture.auth, expectedAccountID: "team", budget: CodexRequestBudget(timeout: 0.1))
            XCTFail("A silent helper must exhaust the same request budget")
        } catch { XCTAssertEqual(error as? CodexOwnerError, .timedOut) }
        try assertStopped(fixture.auth)
        XCTAssertEqual(kill(getpid(), 0), 0)
    }

    private func ownedFixture(
        before: String?, after: String?, legacyOnly: Bool = false, silent: Bool = false
    ) throws -> (owner: CodexOwnerCLI, auth: URL) {
        if silent { return try makeFixture(quota: "{}", sleep: true) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexOwnedFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        func account(_ email: String?) throws -> String {
            var value = ["type": "chatgpt"]
            if let email { value["email"] = email }
            return try JSONSerialization.data(withJSONObject: ["account": value]).base64EncodedString()
        }
        let quota = Data(
            #"{"accountId":"team","rateLimits":{"primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":1790000000}}}"#
                .utf8
        ).base64EncodedString()
        let script = """
            #!/usr/bin/python3
            import base64, json, os, sys
            with open(os.path.join(os.environ["CODEX_HOME"], "owner.pid"), "w") as pid_file:
                pid_file.write(str(os.getpid()))
            before = json.loads(base64.b64decode("\(try account(before))"))
            after = json.loads(base64.b64decode("\(try account(after))"))
            quota = json.loads(base64.b64decode("\(quota)"))
            for line in sys.stdin:
                request = json.loads(line)
                method = request["method"]
                if method == "initialized":
                    continue
                if method == "initialize":
                    result = {}
                elif method == "account/read":
                    if "\(legacyOnly)" == "true":
                        sys.exit(7)
                    if request.get("params", {}).get("refreshToken") is not False:
                        sys.exit(8)
                    result = before if request["id"] == 2 else after
                elif method == "account/rateLimits/read":
                    result = quota
                else:
                    sys.exit(9)
                print(json.dumps({"id": request["id"], "result": result}), flush=True)
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (CodexOwnerCLI(executableURL: executable), root.appendingPathComponent("auth.json"))
    }
}
