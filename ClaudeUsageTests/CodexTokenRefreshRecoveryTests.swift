import XCTest
import os
@testable import ClaudeUsage

@MainActor
final class CodexTokenRefreshRecoveryTests: XCTestCase {
    override func tearDown() {
        CodexURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testReloadDetectsSameMtimeReplacementAndLogout() async throws {
        let (path, manager) = try fixture()
        let first = try await manager.loadSnapshot()
        let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date)
        try writeAuthJSON(accessToken: "access-b", refreshToken: "refresh-b", to: path, accountID: "account-b")
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.path)
        let second = try await manager.loadSnapshot()
        XCTAssertNotEqual(first.generation, second.generation)
        XCTAssertEqual(second.token.accountID, "account-b")
        let unchanged = try await manager.loadSnapshot()
        XCTAssertEqual(second.generation, unchanged.generation)
        try FileManager.default.removeItem(at: path)
        do { _ = try await manager.loadSnapshot(); XCTFail("logout must invalidate the cache") } catch {
            XCTAssertEqual(error as? CodexCredentialError, .missing)
        }
        XCTAssertNil(manager.getToken())
        XCTAssertFalse(manager.authJsonExists)
    }

    func testMalformedFileInvalidatesCacheAndRestorationRecovers() async throws {
        let (path, manager) = try fixture()
        let first = try await manager.loadSnapshot()
        try Data("{broken".utf8).write(to: path)
        do { _ = try await manager.loadSnapshot(); XCTFail("malformed credential must fail") } catch {
            XCTAssertEqual(error as? CodexCredentialError, .malformed)
        }
        XCTAssertNil(manager.getToken())
        try writeAuthJSON(accessToken: "access-a", refreshToken: "refresh-a", to: path)
        let restored = try await manager.loadSnapshot()
        XCTAssertNotEqual(first.generation, restored.generation)
    }

    func testConcurrentReadsPreserveOneGenerationWithoutWriting() async throws {
        let (path, manager) = try fixture()
        let original = try Data(contentsOf: path)
        let generations = try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<32 { group.addTask { try await manager.loadSnapshot().generation } }
            var values: [UUID] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(Set(generations).count, 1)
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testExpiredCredentialIsRefreshedOnlyByOwner() async throws {
        let (path, manager) = try fixture()
        try writeAuthJSON(
            accessToken: makeJWT(expiration: Date(timeIntervalSinceNow: -600)), refreshToken: "refresh-a", to: path)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let owner = TestCodexOwner { source, account, _ in
            calls.withLock { $0 += 1 }
            XCTAssertEqual(source, path)
            XCTAssertEqual(account, "account-a")
            try writeAuthJSON(accessToken: "rotated-access", refreshToken: "rotated-refresh", to: source)
        }
        let recorder = CodexRequestRecorder()
        let service = service(manager, owner: owner) { request in
            recorder.record(request)
            return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 42))
        }
        let result = try await service.fetchUsage()
        XCTAssertEqual(result.usage.primaryPercentage, 42)
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertEqual(recorder.count { $0.url.host == "auth.openai.com" }, 0)
        XCTAssertEqual(recorder.count { $0.authorization != "Bearer rotated-access" || $0.accountID != "account-a" }, 0)
        XCTAssertEqual(manager.getToken()?.accessToken, "rotated-access")
    }

    func testUnauthorizedRecoversAtMostOnceAndDoesNotOverwriteLogin() async throws {
        let (path, manager) = try fixture()
        let original = try Data(contentsOf: path)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let owner = TestCodexOwner { _, _, _ in calls.withLock { $0 += 1 } }
        let recorder = CodexRequestRecorder()
        let service = service(manager, owner: owner) { request in
            recorder.record(request)
            return httpResponse(for: request, statusCode: 401, body: "{}")
        }
        do { _ = try await service.fetchUsage(); XCTFail("repeated rejection must stop") } catch let failure
            as CodexUsageFailure
        {
            guard case .codexReauthRequired(reason: "usage_unauthorized_after_recovery") = failure.error else {
                return XCTFail("unexpected failure")
            }
        }
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertEqual(recorder.count { $0.url.path.hasSuffix("wham/usage") }, 2)
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testLoginChangingDuringOwnerRefreshRejectsOldRequest() async throws {
        let (path, manager) = try fixture()
        let owner = TestCodexOwner { _, _, _ in
            try writeAuthJSON(accessToken: "access-b", refreshToken: "refresh-b", to: path, accountID: "account-b")
        }
        let service = service(manager, owner: owner) { request in
            httpResponse(for: request, statusCode: 401, body: "{}")
        }
        do { _ = try await service.fetchUsage(); XCTFail("old request must not adopt a new account") } catch {
            XCTAssertEqual(error as? CodexCredentialError, .changed)
        }
        XCTAssertEqual(manager.getToken()?.accountID, "account-b")
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
        XCTAssertEqual((file?["tokens"] as? [String: Any])?["access_token"] as? String, "access-b")
    }

    func testNewLoginBeforeCreditEnrichmentCannotMixHeaders() async throws {
        let (path, manager) = try fixture()
        let recorder = CodexRequestRecorder()
        let service = service(manager) { request in
            recorder.record(request)
            if request.url?.path.hasSuffix("wham/usage") == true {
                try? writeAuthJSON(accessToken: "access-b", refreshToken: "refresh-b", to: path, accountID: "account-b")
            }
            return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 10))
        }
        do { _ = try await service.fetchUsage(); XCTFail("changed account must invalidate usage") } catch {
            XCTAssertEqual(error as? CodexCredentialError, .changed)
        }
        XCTAssertEqual(recorder.count { $0.url.path.hasSuffix("rate-limit-reset-credits") }, 0)
    }

    func testConcurrentRequestsShareOneUsageAndCreditFetch() async throws {
        let (_, manager) = try fixture()
        let recorder = CodexRequestRecorder()
        let service = service(manager) { request in
            recorder.record(request)
            try? await Task.sleep(for: .milliseconds(100))
            return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 27))
        }
        let results = try await withThrowingTaskGroup(of: Double.self) { group in
            for _ in 0..<8 { group.addTask { try await service.fetchUsage().usage.primaryPercentage } }
            var values: [Double] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results, Array(repeating: 27, count: 8))
        XCTAssertEqual(recorder.count { $0.url.path.hasSuffix("wham/usage") }, 1)
        XCTAssertEqual(recorder.count { $0.url.path.hasSuffix("rate-limit-reset-credits") }, 1)
    }

    func testTimeoutAndCancellationDoNotBecomeLoginFailure() async throws {
        let (_, manager) = try fixture()
        let started = expectation(description: "request started")
        let service = service(manager) { request in
            started.fulfill()
            try? await Task.sleep(for: .seconds(30))
            return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 27))
        }
        let task = Task { try await service.fetchUsage() }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled caller must stop") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await service.shutdown()
        do { _ = try await service.fetchUsage(); XCTFail("shutdown prevents new work") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let another = self.service(manager) { request in
            try? await Task.sleep(for: .seconds(30))
            return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 27))
        }
        do {
            _ = try await another.fetchUsage(budget: CodexRequestBudget(timeout: 0.03)); XCTFail("deadline must stop")
        } catch let failure as CodexUsageFailure {
            XCTAssertTrue(failure.error.isTemporaryFailure)
        }
    }

    func testControllerAutomaticallyAdoptsNewLoginWithoutShowingOldResult() async throws {
        let (path, manager) = try fixture()
        let published = expectation(description: "new account displayed")
        let service = service(manager) { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer access-a" {
                try? writeAuthJSON(accessToken: "access-b", refreshToken: "refresh-b", to: path, accountID: "account-b")
                return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 10))
            }
            return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 80))
        }
        var shown: [String] = []
        let controller = CodexRefreshController(
            authManager: manager, apiService: service, isEnabled: { true }, prepare: { _ in true },
            clearPresentation: {},
            applySuccess: { result in
                shown.append(result.credential.token.accountID ?? "missing")
                XCTAssertEqual(result.usage.primaryPercentage, 80)
                published.fulfill()
            }, applyFailure: { _ in XCTFail("account change must recover") }
        )
        controller.refresh(force: true)
        await fulfillment(of: [published], timeout: 3)
        XCTAssertEqual(shown, ["account-b"])
        await controller.shutdown()
    }

    func testCredentialRetrySharesOwnerRecoveryLimit() async throws {
        let (path, manager) = try fixture()
        let failed = expectation(description: "recovery limit reached")
        let count = OSAllocatedUnfairLock(initialState: 0)
        let owner = TestCodexOwner { _, _, _ in
            count.withLock { $0 += 1 }
            try writeAuthJSON(accessToken: "access-b", refreshToken: "refresh-b", to: path, accountID: "account-b")
        }
        let service = service(manager, owner: owner) { request in
            httpResponse(for: request, statusCode: 401, body: "{}")
        }
        let controller = CodexRefreshController(
            authManager: manager, apiService: service, isEnabled: { true }, prepare: { _ in true },
            clearPresentation: {}, applySuccess: { _ in XCTFail("rejected credentials must not display quota") },
            applyFailure: { error in
                guard case .codexTokenRefreshTemporary(reason: "owner_recovery_exhausted") = error else {
                    return XCTFail("one UI request must have one owner recovery budget")
                }
                failed.fulfill()
            }
        )
        controller.refresh(force: true)
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(count.withLock { $0 }, 1)
        await controller.shutdown()
    }

    func testMalformedUsageCannotBecomeZeroPercent() throws {
        for body in [
            #"{"rate_limit":{"primary_window":{}}}"#,
            #"{"rate_limit":{"primary_window":{"used_percent":"changed"}}}"#,
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(CodexUsageResponse.self, from: Data(body.utf8)))
        }
    }

    func testShutdownWaitsForCancelledOwnerCleanup() async throws {
        let (_, manager) = try fixture()
        let entered = expectation(description: "owner entered")
        let cleaning = expectation(description: "owner cleaning")
        let gate = CodexTestGate()
        let owner = TestCodexOwner { _, _, _ in
            entered.fulfill()
            try? await Task.sleep(for: .seconds(30))
            cleaning.fulfill()
            await gate.wait()
            throw CancellationError()
        }
        let service = service(manager, owner: owner) { request in
            httpResponse(for: request, statusCode: 401, body: "{}")
        }
        let caller = Task { try await service.fetchUsage() }
        await fulfillment(of: [entered], timeout: 2)
        caller.cancel()
        do { _ = try await caller.value; XCTFail("caller must cancel promptly") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await fulfillment(of: [cleaning], timeout: 2)
        var finished = false
        let shutdown = Task {
            await service.shutdown(); finished = true
        }
        await Task.yield()
        XCTAssertFalse(finished)
        await gate.open()
        await shutdown.value
        XCTAssertTrue(finished)
    }

    private func fixture() throws -> (URL, CodexAuthManager) {
        let directory = try makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("auth.json")
        try writeAuthJSON(accessToken: "access-a", refreshToken: "refresh-a", to: path)
        return (path, CodexAuthManager(authJsonPath: path.path))
    }

    private func service(
        _ manager: CodexAuthManager,
        owner: any CodexOwnerRefreshing = TestCodexOwner { _, _, _ in throw CodexOwnerError.unavailable },
        handler: @escaping CodexURLProtocolStub.Handler
    ) -> CodexAPIService {
        CodexAPIService(
            baseURL: URL(string: "https://chatgpt.test/backend-api")!,
            urlSession: makeStubbedSession(handler: handler), authManager: manager, owner: owner)
    }
}

private struct TestCodexOwner: CodexOwnerRefreshing {
    let action: @Sendable (URL, String, CodexRequestBudget) async throws -> Void
    init(_ action: @escaping @Sendable (URL, String, CodexRequestBudget) async throws -> Void) { self.action = action }
    func refresh(sourceURL: URL, expectedAccountID: String, budget: CodexRequestBudget) async throws {
        try await action(sourceURL, expectedAccountID, budget)
    }
}

private struct CodexRecordedRequest {
    let url: URL
    let authorization: String?
    let accountID: String?
}

private final class CodexRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [CodexRecordedRequest] = []

    func record(_ request: URLRequest) {
        guard let url = request.url else { return }
        lock.lock()
        requests.append(
            CodexRecordedRequest(
                url: url, authorization: request.value(forHTTPHeaderField: "Authorization"),
                accountID: request.value(forHTTPHeaderField: "ChatGPT-Account-Id")))
        lock.unlock()
    }

    func count(where predicate: (CodexRecordedRequest) -> Bool) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter(predicate).count
    }
}

private final class CodexURLProtocolStub: URLProtocol, @unchecked Sendable {
    private let loading = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    typealias Handler = @Sendable (URLRequest) async -> (HTTPURLResponse, Data)
    private static let handlerState = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    static var handler: Handler? {
        get { handlerState.withLock { $0 } }
        set { handlerState.withLock { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let request = request
        let task = Task {
            let (response, data) = await handler(request)
            guard !Task.isCancelled else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        loading.withLock { $0 = task }
    }

    override func stopLoading() {
        loading.withLock {
            $0?.cancel(); $0 = nil
        }
    }
}

private func makeStubbedSession(
    handler: @escaping @Sendable (URLRequest) async -> (HTTPURLResponse, Data)
) -> URLSession {
    CodexURLProtocolStub.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CodexURLProtocolStub.self]
    return URLSession(configuration: configuration)
}

private func httpResponse(
    for request: URLRequest,
    statusCode: Int,
    body: String
) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, Data(body.utf8))
}

private func usageJSON(primary: Double) -> String {
    """
    {
      "rate_limit": {
        "primary_window": {
          "used_percent": \(primary),
          "reset_at": 1700000000
        }
      }
    }
    """
}

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClaudeUsageCodexTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeAuthJSON(
    accessToken: String,
    refreshToken: String?,
    to path: URL,
    accountID: String = "account-a"
) throws {
    var tokens: [String: Any] = ["access_token": accessToken, "account_id": accountID]
    if let refreshToken {
        tokens["refresh_token"] = refreshToken
    }
    let json: [String: Any] = [
        "tokens": tokens,
        "last_refresh": "2026-05-01T00:00:00.000Z",
    ]
    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: path, options: [.atomic])
}

private func makeJWT(expiration: Date) throws -> String {
    let header = try base64URLJSONObject(["alg": "none", "typ": "JWT"])
    let payload = try base64URLJSONObject(["exp": Int(expiration.timeIntervalSince1970)])
    return "\(header).\(payload).signature"
}

private func base64URLJSONObject(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object)
    return data
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private actor CodexTestGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
