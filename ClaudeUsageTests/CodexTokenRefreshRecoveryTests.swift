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

    func testNewLoginBeforeDetailRequestCannotMixHeaders() async throws {
        let (path, manager) = try fixture()
        let recorder = CodexRequestRecorder()
        let service = service(manager) { request in
            recorder.record(request)
            try? writeAuthJSON(accessToken: "access-b", refreshToken: "refresh-b", to: path, accountID: "account-b")
            return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 10, resetCount: 2))
        }
        do { _ = try await service.fetchUsage(); XCTFail("changed account must invalidate usage") } catch {
            XCTAssertEqual(error as? CodexCredentialError, .changed)
        }
        XCTAssertEqual(recorder.count { $0.url.path.hasSuffix("rate-limit-reset-credits") }, 0)
    }

    func testConcurrentRequestsShareOneFlightPerStage() async throws {
        let (_, manager) = try fixture()
        let recorder = CodexRequestRecorder()
        let owner = TestCodexOwner { _, _, _ in XCTFail("healthy usage/details must not launch the CLI") }
        let service = service(manager, owner: owner) { request in
            recorder.record(request)
            try? await Task.sleep(for: .milliseconds(100))
            let body =
                request.url?.path.hasSuffix("wham/usage") == true
                ? usageJSON(primary: 27, resetCount: 2) : detailJSON(count: 2)
            return httpResponse(for: request, statusCode: 200, body: body)
        }
        let results = try await withThrowingTaskGroup(of: CodexUsageSnapshot.self) { group in
            for _ in 0..<8 { group.addTask { try await service.fetchUsage() } }
            var values: [CodexUsageSnapshot] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.map { $0.usage.primaryPercentage }, Array(repeating: 27, count: 8))
        XCTAssertEqual(recorder.count { $0.url.path.hasSuffix("wham/usage") }, 1)
        XCTAssertEqual(recorder.count { $0.url.path.hasSuffix("rate-limit-reset-credits") }, 0)
        let details = try await withThrowingTaskGroup(of: CodexUsageSnapshot.self) { group in
            for base in results { group.addTask { try await service.fetchResetCreditDetails(for: base) } }
            var values: [CodexUsageSnapshot] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertTrue(details.allSatisfy { $0.usage.resetCredits?.availableCount() == 2 })
        XCTAssertEqual(recorder.count { $0.url.path.hasSuffix("rate-limit-reset-credits") }, 1)
    }

    func testCurrentUsageReplacesCachedCountAndDiscardsOldDetails() async throws {
        let (_, manager) = try fixture()
        let usageRequests = OSAllocatedUnfairLock(initialState: 0)
        let service = service(manager) { request in
            if request.url?.path.hasSuffix("rate-limit-reset-credits") == true {
                return httpResponse(for: request, statusCode: 200, body: detailJSON(count: 1))
            }
            let index = usageRequests.withLock {
                $0 += 1; return $0
            }
            return httpResponse(
                for: request, statusCode: 200,
                body: usageJSON(primary: 27, resetCount: index == 1 ? 1 : index == 2 ? 2 : nil))
        }
        let basic = try await service.fetchUsage()
        let first = try await service.fetchResetCreditDetails(for: basic)
        XCTAssertEqual(first.usage.resetCredits?.credits.count, 1)
        let second = try await service.fetchUsage()
        XCTAssertEqual(second.usage.resetCredits?.availableCount(), 2)
        XCTAssertEqual(second.usage.resetCredits?.credits, [])
        let third = try await service.fetchUsage()
        XCTAssertEqual(third.usage.resetCredits?.availableCount(), 2)
        XCTAssertEqual(third.usage.resetCredits?.credits, [])
        XCTAssertEqual(third.usage.resetCreditMetadata?.countIsCurrent, false)
        XCTAssertEqual(ResetCreditSummary.codex(third.usage)?.expirationDescription(), "이전 개수 / 상세 확인 필요")
    }

    func testZeroUsageCountClearsCacheAndMissingCountDoesNotReuseItAsCurrent() async throws {
        let (_, manager) = try fixture()
        let usageRequests = OSAllocatedUnfairLock(initialState: 0)
        let detailRequests = OSAllocatedUnfairLock(initialState: 0)
        let service = service(manager) { request in
            if request.url?.path.hasSuffix("rate-limit-reset-credits") == true {
                detailRequests.withLock { $0 += 1 }
                return httpResponse(for: request, statusCode: 200, body: detailJSON(count: 2))
            }
            let index = usageRequests.withLock {
                $0 += 1; return $0
            }
            return httpResponse(
                for: request, statusCode: 200,
                body: usageJSON(primary: 27, resetCount: index == 1 ? 2 : index == 2 ? 0 : nil))
        }
        let basic = try await service.fetchUsage()
        _ = try await service.fetchResetCreditDetails(for: basic)
        let zero = try await service.fetchUsage()
        let zeroDetails = try await service.fetchResetCreditDetails(for: zero)
        XCTAssertEqual(zeroDetails.usage.resetCredits?.availableCount(), 0)
        XCTAssertNil(ResetCreditSummary.codex(zeroDetails.usage))
        XCTAssertEqual(detailRequests.withLock { $0 }, 1)
        let missing = try await service.fetchUsage()
        XCTAssertEqual(missing.usage.resetCreditMetadata?.countIsCurrent, false)
        let confirmed = try await service.fetchResetCreditDetails(for: missing)
        XCTAssertEqual(confirmed.usage.resetCredits?.availableCount(), 2)
        XCTAssertEqual(detailRequests.withLock { $0 }, 2)
    }

    func testFreshHTTPDetailCountTakesPrecedenceOverEarlierUsageSummary() async throws {
        for count in [0, 1] {
            let (_, manager) = try fixture()
            let service = service(manager) { request in
                let body =
                    request.url?.path.hasSuffix("wham/usage") == true
                    ? usageJSON(primary: 27, resetCount: 2) : detailJSON(count: count)
                return httpResponse(for: request, statusCode: 200, body: body)
            }
            let basic = try await service.fetchUsage()
            XCTAssertEqual(basic.usage.resetCredits?.availableCount(), 2)
            let detailed = try await service.fetchResetCreditDetails(for: basic)
            XCTAssertEqual(detailed.usage.resetCredits?.availableCount(), count)
            XCTAssertEqual(detailed.usage.primaryPercentage, 27)
        }
    }

    func testResetCountFromAnotherUsageAccountIsRejectedBeforeDetails() async throws {
        let (_, manager) = try fixture()
        let recorder = CodexRequestRecorder()
        let service = service(manager) { request in
            recorder.record(request)
            return httpResponse(
                for: request, statusCode: 200,
                body: usageJSON(primary: 27, resetCount: 2, accountID: "account-b"))
        }
        do { _ = try await service.fetchUsage(); XCTFail("another account's count must be rejected") } catch {
            XCTAssertEqual(error as? CodexCredentialError, .changed)
        }
        XCTAssertEqual(recorder.count { $0.url.path.hasSuffix("rate-limit-reset-credits") }, 0)
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
            }, applyFailure: { _ in XCTFail("account change must recover") }, applyDetails: { _ in }
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
            }, applyDetails: { _ in XCTFail("rejected credentials must not display details") }
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
        now: @escaping @Sendable () -> Date = { Date() },
        handler: @escaping CodexURLProtocolStub.Handler
    ) -> CodexAPIService {
        CodexAPIService(
            baseURL: URL(string: "https://chatgpt.test/backend-api")!,
            urlSession: makeStubbedSession(handler: handler), authManager: manager, owner: owner, now: now)
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
    typealias Handler = @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)
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
            do {
                let (response, data) = try await handler(request)
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didFailWithError: error)
            }
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
    handler: @escaping @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)
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

private func usageJSON(primary: Double, resetCount: Int? = nil, accountID: String? = nil) -> String {
    let reset = resetCount.map { ", \"rate_limit_reset_credits\": {\"available_count\": \($0)}" } ?? ""
    let account = accountID.map { ", \"account_id\": \"\($0)\"" } ?? ""
    return """
    {
      "rate_limit": {
        "primary_window": {
          "used_percent": \(primary),
          "reset_at": 1700000000
        }
      }\(reset)\(account)
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

final class CodexAppServerResetCreditsTests: XCTestCase {
    func testSummaryMapsCountsAndExpiry() throws {
        let summary: [String: Any] = [
            "availableCount": 2,
            "credits": [
                [
                    "id": "credit-1", "resetType": "codexRateLimits", "status": "available", "grantedAt": 1_790_000_000,
                    "expiresAt": 1_790_600_000, "title": "Full reset", "description": NSNull(),
                ],
                ["status": "available"],
            ],
        ]
        let response = try XCTUnwrap(CodexOwnerCLI.resetCredits(from: summary))

        XCTAssertEqual(response.availableCount(at: Date(timeIntervalSince1970: 1_790_000_100)), 2)
        XCTAssertEqual(response.credits.map(\.id), ["credit-1"])
        XCTAssertEqual(response.credits.first?.title, "Full reset")
        XCTAssertNotNil(response.credits.first?.expiresDate)
    }

    func testMissingSummaryIsUnknownNotZero() {
        XCTAssertNil(CodexOwnerCLI.resetCredits(from: nil))
        XCTAssertNil(CodexOwnerCLI.resetCredits(from: NSNull()))
        XCTAssertEqual(
            CodexOwnerCLI.resetCredits(from: ["availableCount": 0, "credits": NSNull()])?.availableCount(), 0)
    }
}

@MainActor
extension CodexTokenRefreshRecoveryTests {
    func testAlreadyExpiredDetailBudgetDoesNotTurnValidUsageIntoFailure() async throws {
        let (_, manager) = try fixture()
        let recorder = CodexRequestRecorder()
        let service = service(manager) { request in
            recorder.record(request)
            return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 27, resetCount: 2))
        }
        let base = try await service.fetchUsage()
        let result = try await service.fetchResetCreditDetails(for: base, budget: CodexRequestBudget(timeout: 0))
        XCTAssertEqual(result.usage.resetCreditMetadata?.status, .failed(.timeout))
        XCTAssertEqual(result.usage.primaryPercentage, 27)
        XCTAssertEqual(result.usage.resetCredits?.availableCount(), 2)
        XCTAssertEqual(recorder.count { $0.url.path.hasSuffix("rate-limit-reset-credits") }, 0)
    }

    func testFailureAfterForcedRefreshDoesNotReuseUnexpiredSuccessAsCurrent() async throws {
        let (_, manager) = try fixture()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let service = service(manager) { request in
            if request.url?.path.hasSuffix("rate-limit-reset-credits") == true {
                let attempt = calls.withLock {
                    $0 += 1; return $0
                }
                return httpResponse(
                    for: request, statusCode: attempt == 2 ? 403 : 200,
                    body: attempt == 2 ? "{}" : detailJSON(count: 2))
            }
            return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 27, resetCount: 2))
        }
        let base = try await service.fetchUsage()
        let first = try await service.fetchResetCreditDetails(for: base)
        let failed = try await service.fetchResetCreditDetails(for: base, force: true)
        XCTAssertEqual(failed.usage.resetCreditMetadata?.status, .failed(.http(403)))
        XCTAssertEqual(failed.usage.resetCreditMetadata?.updatedAt, first.usage.resetCreditMetadata?.updatedAt)
        let next = try await service.fetchUsage()
        XCTAssertEqual(next.usage.resetCreditMetadata?.status, .loading)
        let retried = try await service.fetchResetCreditDetails(for: next)
        XCTAssertEqual(retried.usage.resetCreditMetadata?.status, .fresh)
        XCTAssertEqual(calls.withLock { $0 }, 3)
    }

    func testCancelledLastDetailWaiterCannotPopulateCache() async throws {
        let (_, manager) = try fixture()
        let started = expectation(description: "detail started")
        let gate = CodexTestGate()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let service = service(manager) { request in
            if request.url?.path.hasSuffix("rate-limit-reset-credits") == true {
                let attempt = calls.withLock {
                    $0 += 1; return $0
                }
                if attempt == 1 { started.fulfill(); await gate.wait() }
                return httpResponse(for: request, statusCode: 200, body: detailJSON(count: 2))
            }
            return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 27, resetCount: 2))
        }
        let base = try await service.fetchUsage()
        let task = Task { try await service.fetchResetCreditDetails(for: base) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled details must stop") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await gate.open()
        let next = try await service.fetchUsage()
        XCTAssertEqual(next.usage.resetCredits?.credits, [])
        let retried = try await service.fetchResetCreditDetails(for: next)
        XCTAssertEqual(retried.usage.resetCreditMetadata?.status, .fresh)
        XCTAssertEqual(calls.withLock { $0 }, 2)
        await service.shutdown()
    }

    func testSharedDetailsMergeIntoEachCallersOwnUsageSnapshot() async throws {
        let (_, manager) = try fixture()
        let started = expectation(description: "detail started")
        let gate = CodexTestGate()
        let usageCalls = OSAllocatedUnfairLock(initialState: 0)
        let service = service(manager) { request in
            if request.url?.path.hasSuffix("rate-limit-reset-credits") == true {
                started.fulfill()
                await gate.wait()
                return httpResponse(for: request, statusCode: 200, body: detailJSON(count: 2))
            }
            let call = usageCalls.withLock {
                $0 += 1; return $0
            }
            return httpResponse(
                for: request, statusCode: 200, body: usageJSON(primary: call == 1 ? 27 : 68, resetCount: 2))
        }
        let old = try await service.fetchUsage()
        let first = Task { try await service.fetchResetCreditDetails(for: old) }
        await fulfillment(of: [started], timeout: 2)
        let current = try await service.fetchUsage()
        let second = Task { try await service.fetchResetCreditDetails(for: current) }
        try await Task.sleep(for: .milliseconds(30))
        await gate.open()
        let a = try await first.value
        let b = try await second.value
        XCTAssertEqual(a.usage.primaryPercentage, 27)
        XCTAssertEqual(b.usage.primaryPercentage, 68)
        XCTAssertEqual(a.usage.resetCredits, b.usage.resetCredits)
    }

    func testMissingIDsRemainPartialEvenWithKnownExpiry() async throws {
        let (_, manager) = try fixture()
        let service = service(manager) { request in
            let body =
                request.url?.path.hasSuffix("wham/usage") == true
                ? usageJSON(primary: 27, resetCount: 1)
                : #"{"available_count":1,"credits":[{"status":"available","expires_at":null}]}"#
            return httpResponse(for: request, statusCode: 200, body: body)
        }
        let base = try await service.fetchUsage()
        let detailed = try await service.fetchResetCreditDetails(for: base)
        XCTAssertEqual(detailed.usage.resetCreditMetadata?.status, .partial)
        XCTAssertNil(detailed.usage.resetCredits?.credits.first?.id)
        XCTAssertFalse(try XCTUnwrap(ResetCreditSummary.codex(detailed.usage)).identityDetailsComplete)
    }

    func testDetailsUseCapturedHeadersAndSuccessfulCacheWithoutWritingCredential() async throws {
        let (path, manager) = try fixture()
        let original = try Data(contentsOf: path)
        let recorder = CodexRequestRecorder()
        let service = service(manager) { request in
            recorder.record(request)
            if request.url?.path.hasSuffix("rate-limit-reset-credits") == true {
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-a")
                XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-a")
                XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
                return httpResponse(for: request, statusCode: 200, body: detailJSON(count: 2))
            }
            return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 27, resetCount: 2))
        }
        for _ in 0..<2 {
            let basic = try await service.fetchUsage()
            let detailed = try await service.fetchResetCreditDetails(for: basic)
            XCTAssertEqual(detailed.usage.primaryPercentage, 27)
            XCTAssertEqual(ResetCreditSummary.codex(detailed.usage)?.expirationDescription(), "만료 없음")
        }
        XCTAssertEqual(recorder.count { $0.url.path.hasSuffix("rate-limit-reset-credits") }, 1)
        let basic = try await service.fetchUsage()
        XCTAssertEqual(basic.usage.resetCreditMetadata?.status, .cached)
        _ = try await service.fetchResetCreditDetails(for: basic, force: true)
        XCTAssertEqual(recorder.count { $0.url.path.hasSuffix("rate-limit-reset-credits") }, 2)
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testFailedDetailsRetryWithoutFiveMinuteFailureCacheAndPreserveUsage() async throws {
        for (status, body, reason) in [
            (401, "{}", CodexResetCreditFailure.http(401)), (403, "{}", .http(403)),
            (500, "{}", .http(500)), (200, "{}", .invalidResponse), (200, "invalid", .invalidResponse),
            (200, #"{"available_count":-1}"#, .invalidResponse),
        ] {
            let (_, manager) = try fixture()
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let owner = TestCodexOwner { _, _, _ in XCTFail("detail failure must not rotate credentials") }
            let service = service(manager, owner: owner) { request in
                if request.url?.path.hasSuffix("rate-limit-reset-credits") == true {
                    let attempt = calls.withLock {
                        $0 += 1; return $0
                    }
                    return httpResponse(
                        for: request, statusCode: attempt == 1 ? status : 200,
                        body: attempt == 1 ? body : detailJSON(count: 2))
                }
                return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 27, resetCount: 2))
            }
            let basic = try await service.fetchUsage()
            let failed = try await service.fetchResetCreditDetails(for: basic)
            XCTAssertEqual(failed.usage.primaryPercentage, 27)
            XCTAssertEqual(failed.usage.resetCredits?.availableCount(), 2)
            XCTAssertEqual(failed.usage.resetCreditMetadata?.status, .failed(reason))
            XCTAssertEqual(ResetCreditSummary.codex(failed.usage)?.expirationDescription(), "상세 조회 지연")
            let next = try await service.fetchUsage()
            let retried = try await service.fetchResetCreditDetails(for: next)
            XCTAssertEqual(retried.usage.resetCreditMetadata?.status, .fresh)
            XCTAssertEqual(calls.withLock { $0 }, 2)
        }
    }

    func testExpiredSuccessfulCacheIsLabeledAndRetriedAfterFailure() async throws {
        let (_, manager) = try fixture()
        let clock = OSAllocatedUnfairLock(initialState: Date())
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let service = service(manager, now: { clock.withLock { $0 } }) { request in
            if request.url?.path.hasSuffix("rate-limit-reset-credits") == true {
                let attempt = calls.withLock {
                    $0 += 1; return $0
                }
                return httpResponse(
                    for: request, statusCode: attempt == 2 ? 403 : 200,
                    body: attempt == 2 ? "{}" : detailJSON(count: 2, expiresAt: Date(timeIntervalSinceNow: 3600)))
            }
            return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 27, resetCount: 2))
        }
        let initial = try await service.fetchUsage()
        let first = try await service.fetchResetCreditDetails(for: initial)
        clock.withLock { $0 = $0.addingTimeInterval(301) }
        let basic = try await service.fetchUsage()
        XCTAssertEqual(basic.usage.resetCreditMetadata?.status, .loading)
        let stale = try await service.fetchResetCreditDetails(for: basic)
        XCTAssertEqual(stale.usage.resetCredits, first.usage.resetCredits)
        XCTAssertEqual(stale.usage.resetCreditMetadata?.status, .failed(.http(403)))
        let summary = try XCTUnwrap(ResetCreditSummary.codex(stale.usage))
        XCTAssertTrue(summary.expirationDescription().hasPrefix("이전 확인 정보 / "))
        XCTAssertFalse(summary.isExpiringSoon())
        XCTAssertFalse(summary.identityDetailsComplete)
        let next = try await service.fetchUsage()
        let recovered = try await service.fetchResetCreditDetails(for: next)
        XCTAssertEqual(recovered.usage.resetCreditMetadata?.status, .fresh)
        XCTAssertEqual(calls.withLock { $0 }, 3)
    }

    func testAccountIdentityOmissionAcceptedButExplicitMismatchRejected() async throws {
        for account in [nil, "account-a", "account-b"] as [String?] {
            let (_, manager) = try fixture()
            let service = service(manager) { request in
                let body =
                    request.url?.path.hasSuffix("wham/usage") == true
                    ? usageJSON(primary: 27, resetCount: 2) : detailJSON(count: 2, accountID: account)
                return httpResponse(for: request, statusCode: 200, body: body)
            }
            let base = try await service.fetchUsage()
            do {
                let result = try await service.fetchResetCreditDetails(for: base)
                XCTAssertNotEqual(account, "account-b")
                XCTAssertEqual(result.usage.resetCreditMetadata?.status, .fresh)
            } catch { XCTAssertEqual(error as? CodexCredentialError, .changed); XCTAssertEqual(account, "account-b") }
        }
    }

    func testCredentialReplacementInvalidatesSameWorkspaceCache() async throws {
        let (path, manager) = try fixture()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let service = service(manager) { request in
            if request.url?.path.hasSuffix("rate-limit-reset-credits") == true {
                calls.withLock { $0 += 1 }
                return httpResponse(for: request, statusCode: 200, body: detailJSON(count: 2))
            }
            return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 27, resetCount: 2))
        }
        let first = try await service.fetchUsage()
        _ = try await service.fetchResetCreditDetails(for: first)
        try writeAuthJSON(accessToken: "access-b", refreshToken: "refresh-b", to: path)
        let second = try await service.fetchUsage()
        XCTAssertNotEqual(second.credential.generation, first.credential.generation)
        XCTAssertEqual(second.usage.resetCredits?.credits, [])
        _ = try await service.fetchResetCreditDetails(for: second)
        XCTAssertEqual(calls.withLock { $0 }, 2)
        do {
            _ = try await service.fetchResetCreditDetails(for: first);
            XCTFail("old cache must not bypass auth validation")
        } catch { XCTAssertEqual(error as? CodexCredentialError, .changed) }
    }

    func testAccountChangeDuringDetailsRejectsResponseAndFailureFallback() async throws {
        for status in [200, 403] {
            let (path, manager) = try fixture()
            let service = service(manager) { request in
                if request.url?.path.hasSuffix("rate-limit-reset-credits") == true {
                    try? writeAuthJSON(
                        accessToken: "access-b", refreshToken: "refresh-b", to: path, accountID: "account-b")
                    return httpResponse(for: request, statusCode: status, body: detailJSON(count: 2))
                }
                return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 27, resetCount: 2))
            }
            let base = try await service.fetchUsage()
            do {
                _ = try await service.fetchResetCreditDetails(for: base);
                XCTFail("changed credentials must reject details")
            } catch { XCTAssertEqual(error as? CodexCredentialError, .changed) }
        }
    }

    func testLateDetailsCannotResurrectCountOrOldIDs() async throws {
        let (_, manager) = try fixture()
        let detailStarted = expectation(description: "old detail request started")
        let gate = CodexTestGate()
        let usageCalls = OSAllocatedUnfairLock(initialState: 0)
        let service = service(manager) { request in
            if request.url?.path.hasSuffix("rate-limit-reset-credits") == true {
                detailStarted.fulfill()
                await gate.wait()
                return httpResponse(for: request, statusCode: 200, body: detailJSON(count: 2))
            }
            let call = usageCalls.withLock {
                $0 += 1; return $0
            }
            return httpResponse(
                for: request, statusCode: 200,
                body: usageJSON(primary: call == 1 ? 27 : 68, resetCount: call == 1 ? 2 : 1))
        }
        let old = try await service.fetchUsage()
        let details = Task { try await service.fetchResetCreditDetails(for: old) }
        await fulfillment(of: [detailStarted], timeout: 2)
        let current = try await service.fetchUsage()
        XCTAssertEqual(current.usage.resetCredits?.availableCount(), 1)
        await gate.open()
        let late = try await details.value
        XCTAssertEqual(late.usage.resetCredits?.availableCount(), 1)
        XCTAssertEqual(late.usage.resetCredits?.credits, [])
        let next = try await service.fetchUsage()
        XCTAssertEqual(next.usage.resetCredits?.availableCount(), 1)
        XCTAssertEqual(next.usage.resetCredits?.credits, [])
    }

    func testPartialRowsPreserveCountAndRetryWithoutInventingMissingData() async throws {
        let (_, manager) = try fixture()
        let detailCalls = OSAllocatedUnfairLock(initialState: 0)
        let service = service(manager) { request in
            if request.url?.path.hasSuffix("rate-limit-reset-credits") == true {
                detailCalls.withLock { $0 += 1 }
                return httpResponse(
                    for: request, statusCode: 200,
                    body:
                        #"{"available_count":2,"credits":[{"id":"a","status":"available","expires_at":null},{"id":"b","status":"unknown","expires_at":null}]}"#
                )
            }
            return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 27, resetCount: 2))
        }
        for _ in 0..<2 {
            let base = try await service.fetchUsage()
            let result = try await service.fetchResetCreditDetails(for: base)
            let summary = try XCTUnwrap(ResetCreditSummary.codex(result.usage))
            XCTAssertEqual(summary.availableCount, 2)
            XCTAssertEqual(summary.items.map(\.id), ["a"])
            XCTAssertEqual(result.usage.resetCreditMetadata?.status, .partial)
            XCTAssertEqual(summary.expirationDescription(), "일부 상세 정보 없음")
            XCTAssertFalse(summary.identityDetailsComplete)
        }
        XCTAssertEqual(detailCalls.withLock { $0 }, 2)
    }

    func testMissingUsageCountKeepsLastCountButStillRefreshesDetails() async throws {
        let (_, manager) = try fixture()
        let usageCalls = OSAllocatedUnfairLock(initialState: 0)
        let detailCalls = OSAllocatedUnfairLock(initialState: 0)
        let service = service(manager) { request in
            if request.url?.path.hasSuffix("rate-limit-reset-credits") == true {
                detailCalls.withLock { $0 += 1 }
                return httpResponse(for: request, statusCode: 200, body: detailJSON(count: 2))
            }
            let call = usageCalls.withLock {
                $0 += 1; return $0
            }
            return httpResponse(
                for: request, statusCode: 200, body: usageJSON(primary: 27, resetCount: call == 1 ? 2 : nil))
        }
        let first = try await service.fetchUsage()
        _ = try await service.fetchResetCreditDetails(for: first)
        let missing = try await service.fetchUsage()
        XCTAssertEqual(missing.usage.resetCredits?.availableCount(), 2)
        XCTAssertEqual(missing.usage.resetCreditMetadata?.countIsCurrent, false)
        let refreshed = try await service.fetchResetCreditDetails(for: missing)
        XCTAssertEqual(refreshed.usage.resetCreditMetadata?.countIsCurrent, true)
        XCTAssertEqual(detailCalls.withLock { $0 }, 2)
    }

    func testDetailTimeoutAndNetworkFailureHaveSeparateDiagnosticsAndLeaveUsageValid() async throws {
        for failure in [URLError(.timedOut), URLError(.notConnectedToInternet)] {
            let (_, manager) = try fixture()
            let service = service(manager) { request in
                if request.url?.path.hasSuffix("rate-limit-reset-credits") == true { throw failure }
                return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 27, resetCount: 2))
            }
            let base = try await service.fetchUsage()
            let result = try await service.fetchResetCreditDetails(for: base)
            let reason: CodexResetCreditFailure = failure.code == .timedOut ? .timeout : .network
            XCTAssertEqual(result.usage.resetCreditMetadata?.status, .failed(reason))
            XCTAssertEqual(result.usage.primaryPercentage, 27)
            XCTAssertEqual(result.usage.resetCredits?.availableCount(), 2)
            let diagnostic = OperationalDiagnostic.codexResetCredits(try XCTUnwrap(result.usage.resetCreditMetadata))
            XCTAssertEqual(diagnostic.code, "codex.resetCredits." + reason.diagnosticCode)
            XCTAssertFalse(String(describing: diagnostic).contains("access-a"))
            XCTAssertFalse(String(describing: diagnostic).contains("account-a"))
        }
    }

    func testDetailBudgetExpiryIsSupplementaryFailureNotQuotaFailure() async throws {
        let (_, manager) = try fixture()
        let started = expectation(description: "detail started")
        let service = service(manager) { request in
            if request.url?.path.hasSuffix("rate-limit-reset-credits") == true {
                started.fulfill()
                try? await Task.sleep(for: .seconds(30))
            }
            return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 27, resetCount: 2))
        }
        let base = try await service.fetchUsage()
        let result = try await service.fetchResetCreditDetails(for: base, budget: CodexRequestBudget(timeout: 0.05))
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(result.usage.resetCreditMetadata?.status, .failed(.timeout))
        XCTAssertEqual(result.usage.primaryPercentage, 27)
    }

    func testCancelledWaiterDoesNotCancelSharedDetailRequest() async throws {
        let (_, manager) = try fixture()
        let started = expectation(description: "detail started")
        let gate = CodexTestGate()
        let service = service(manager) { request in
            if request.url?.path.hasSuffix("rate-limit-reset-credits") == true {
                started.fulfill()
                await gate.wait()
                return httpResponse(for: request, statusCode: 200, body: detailJSON(count: 2))
            }
            return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 27, resetCount: 2))
        }
        let base = try await service.fetchUsage()
        let one = Task { try await service.fetchResetCreditDetails(for: base) }
        let two = Task { try await service.fetchResetCreditDetails(for: base) }
        await fulfillment(of: [started], timeout: 2)
        // Give both continuations a chance to register while the owned HTTP task is gated.
        try await Task.sleep(for: .milliseconds(30))
        one.cancel()
        do { _ = try await one.value; XCTFail("cancelled waiter must stop") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await gate.open()
        let surviving = try await two.value
        XCTAssertEqual(surviving.usage.resetCredits?.availableCount(), 2)
        await service.shutdown()
    }

    func testControllerPublishesUsageBeforeDetailAndDoesNotRepublishQuotaOnDetailFailure() async throws {
        let (_, manager) = try fixture()
        let basicShown = expectation(description: "quota shown")
        let detailStarted = expectation(description: "detail started")
        let detailShown = expectation(description: "supplementary failure shown")
        let gate = CodexTestGate()
        let service = service(manager) { request in
            if request.url?.path.hasSuffix("rate-limit-reset-credits") == true {
                detailStarted.fulfill()
                await gate.wait()
                return httpResponse(for: request, statusCode: 403, body: "{}")
            }
            return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 27, resetCount: 2))
        }
        var basicCalls = 0
        var detailCalls = 0
        let controller = CodexRefreshController(
            authManager: manager, apiService: service, isEnabled: { true }, prepare: { _ in true },
            clearPresentation: {},
            applySuccess: { result in
                basicCalls += 1
                XCTAssertEqual(result.usage.primaryPercentage, 27)
                basicShown.fulfill()
            }, applyFailure: { _ in XCTFail("supplement failure must not become quota/login failure") },
            applyDetails: { result in
                detailCalls += 1
                XCTAssertEqual(result.usage.resetCreditMetadata?.status, .failed(.http(403)))
                detailShown.fulfill()
            })
        controller.refresh(force: true)
        await fulfillment(of: [basicShown, detailStarted], timeout: 2)
        XCTAssertEqual(basicCalls, 1)
        XCTAssertEqual(detailCalls, 0)
        await gate.open()
        await fulfillment(of: [detailShown], timeout: 2)
        XCTAssertEqual(basicCalls, 1)
        XCTAssertEqual(detailCalls, 1)
        await controller.shutdown()
    }

    func testControllerRejectsOldSupplementAfterLoginChanges() async throws {
        let (path, manager) = try fixture()
        let firstShown = expectation(description: "old quota initially shown")
        let detailStarted = expectation(description: "old details started")
        let newShown = expectation(description: "new quota shown")
        let newDetailShown = expectation(description: "new details shown")
        let gate = CodexTestGate()
        let service = service(manager) { request in
            let old = request.value(forHTTPHeaderField: "Authorization") == "Bearer access-a"
            if request.url?.path.hasSuffix("rate-limit-reset-credits") == true {
                if old { detailStarted.fulfill(); await gate.wait() }
                return httpResponse(for: request, statusCode: 200, body: detailJSON(count: old ? 2 : 1))
            }
            return httpResponse(
                for: request, statusCode: 200, body: usageJSON(primary: old ? 27 : 68, resetCount: old ? 2 : 1))
        }
        let controller = CodexRefreshController(
            authManager: manager, apiService: service, isEnabled: { true }, prepare: { _ in true },
            clearPresentation: {},
            applySuccess: { result in
                if result.credential.token.accountID == "account-a" {
                    firstShown.fulfill()
                } else {
                    XCTAssertEqual(result.usage.primaryPercentage, 68); newShown.fulfill()
                }
            }, applyFailure: { _ in XCTFail("login change must retry") },
            applyDetails: { result in
                XCTAssertEqual(result.credential.token.accountID, "account-b")
                XCTAssertEqual(result.usage.resetCredits?.availableCount(), 1)
                newDetailShown.fulfill()
            })
        controller.refresh(force: true)
        await fulfillment(of: [firstShown, detailStarted], timeout: 2)
        try writeAuthJSON(accessToken: "access-b", refreshToken: "refresh-b", to: path, accountID: "account-b")
        await gate.open()
        await fulfillment(of: [newShown, newDetailShown], timeout: 3)
        await controller.shutdown()
    }
}

private func detailJSON(count: Int, expiresAt: Date? = nil, accountID: String? = nil) -> String {
    let expiry = expiresAt.map { "\"" + ISO8601DateFormatter().string(from: $0) + "\"" } ?? "null"
    let rows = (0..<max(0, count)).map { #"{"id":"credit-\#($0)","status":"available","expires_at":\#(expiry)}"# }
        .joined(separator: ",")
    let account = accountID.map { ",\"account_id\":\"" + $0 + "\"" } ?? ""
    return #"{"available_count":\#(count),"credits":[\#(rows)]\#(account)}"#
}
