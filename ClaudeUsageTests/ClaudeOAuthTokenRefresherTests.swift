import XCTest
@testable import ClaudeUsage

/// `ClaudeOAuthTokenRefresher` 가 다음 책임을 흔들림 없이 유지하는지 고정한다:
///   - 성공 응답 디코딩 + 새 credential 생성
///   - `invalid_grant` 응답 시 해당 refresh token만 terminal disposition
///   - 일시적 실패(5xx, 네트워크) 시 cooldown 진입 (이후 호출은 cooldown 메시지)
///   - 동시 호출 시 in-flight task 결과 공유 (HTTP 호출 1회만)
///   - refresh_token 누락 시 즉시 `missingRefreshToken` 에러
@MainActor
final class ClaudeOAuthTokenRefresherTests: XCTestCase {
    func testSuccessReturnsNewCredentialAndPreservesRefreshTokenWhenServerOmitsIt() async throws {
        let json = """
        {"access_token":"new-access","expires_in":3600}
        """
        let runner = MockRunner(scriptedResponses: [
            .success(body: json, statusCode: 200)
        ])
        let refresher = ClaudeOAuthTokenRefresher(
            httpRunner: runner.run,
            cooldownInterval: 60,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        let credential = ClaudeCodeOAuthCredential(
            accessToken: "old-access",
            refreshToken: "rt-existing",
            expiresAt: Date(timeIntervalSince1970: 999_000),
            source: .file(URL(fileURLWithPath: "/tmp/x.json"))
        )

        let refreshed = try await refresher.refresh(credential)

        XCTAssertEqual(refreshed.accessToken, "new-access")
        XCTAssertEqual(refreshed.refreshToken, "rt-existing", "응답에서 refresh_token 이 빠지면 기존 값을 그대로 유지")
        XCTAssertEqual(refreshed.expiresAt, Date(timeIntervalSince1970: 1_003_600))
        XCTAssertEqual(refreshed.source, credential.source)
        let count = await runner.totalCalls()
        XCTAssertEqual(count, 1)
    }

    func testServerProvidedRefreshTokenReplacesOldOne() async throws {
        let json = """
        {"access_token":"new-access","refresh_token":"rt-new","expires_in":1800}
        """
        let runner = MockRunner(scriptedResponses: [.success(body: json, statusCode: 200)])
        let refresher = ClaudeOAuthTokenRefresher(httpRunner: runner.run, cooldownInterval: 60)
        let credential = ClaudeCodeOAuthCredential(
            accessToken: "old", refreshToken: "rt-old",
            expiresAt: nil, source: .refreshed
        )

        let refreshed = try await refresher.refresh(credential)

        XCTAssertEqual(refreshed.refreshToken, "rt-new")
    }

    func testInvalidGrantRecordsTerminalDispositionAndBlocksFurtherAttempts() async {
        let runner = MockRunner(scriptedResponses: [
            .success(body: #"{"error":"invalid_grant","error_description":"refresh token revoked"}"#, statusCode: 400)
        ])
        let refresher = ClaudeOAuthTokenRefresher(httpRunner: runner.run, cooldownInterval: 60)
        let credential = ClaudeCodeOAuthCredential(
            accessToken: "x", refreshToken: "rt", expiresAt: nil, source: .refreshed
        )

        do {
            _ = try await refresher.refresh(credential)
            XCTFail("invalid_grant 응답에서는 throw 가 발생해야 함")
        } catch let error as ClaudeOAuthTokenRefresher.RefreshError {
            XCTAssertEqual(error, .invalidGrant)
        } catch {
            XCTFail("RefreshError 가 아님: \(error)")
        }

        // 두 번째 호출은 terminal disposition 으로 즉시 차단되어야 함.
        do {
            _ = try await refresher.refresh(credential)
            XCTFail("terminal 상태에서 두 번째 호출도 throw 해야 함")
        } catch let error as ClaudeOAuthTokenRefresher.RefreshError {
            XCTAssertEqual(error, .invalidGrant)
        } catch {
            XCTFail("RefreshError 가 아님: \(error)")
        }

        let count = await runner.totalCalls()
        XCTAssertEqual(count, 1, "terminal 이후엔 HTTP 호출 자체가 일어나지 않아야 함")
    }

    func testNewRefreshTokenLineageRecoversWithoutRestartAfterInvalidGrant() async throws {
        let runner = MockRunner(scriptedResponses: [
            .success(body: #"{"error":"invalid_grant"}"#, statusCode: 400),
            .success(body: #"{"access_token":"recovered","refresh_token":"rt-newer","expires_in":600}"#, statusCode: 200)
        ])
        let refresher = ClaudeOAuthTokenRefresher(httpRunner: runner.run, cooldownInterval: 60)
        let rejected = ClaudeCodeOAuthCredential(
            accessToken: "old",
            refreshToken: "rt-old",
            source: .refreshed
        )
        let relogged = ClaudeCodeOAuthCredential(
            accessToken: "new-login",
            refreshToken: "rt-new",
            source: .file(URL(fileURLWithPath: "/tmp/.credentials.json"))
        )

        _ = try? await refresher.refresh(rejected)
        let refreshed = try await refresher.refresh(relogged)

        XCTAssertEqual(refreshed.accessToken, "recovered")
        XCTAssertEqual(refreshed.refreshToken, "rt-newer")
        XCTAssertEqual(refreshed.source, relogged.source)
        let count = await runner.totalCalls()
        XCTAssertEqual(count, 2)
    }

    func testTransientFailureSchedulesCooldownAndBlocksImmediateRetry() async {
        let runner = MockRunner(scriptedResponses: [
            .success(body: "internal server error", statusCode: 500)
        ])
        let currentTime = Date(timeIntervalSince1970: 1_000_000)
        let refresher = ClaudeOAuthTokenRefresher(
            httpRunner: runner.run,
            cooldownInterval: 60,
            now: { currentTime }
        )
        let credential = ClaudeCodeOAuthCredential(
            accessToken: "x", refreshToken: "rt", expiresAt: nil, source: .refreshed
        )

        do {
            _ = try await refresher.refresh(credential)
            XCTFail("5xx 에서는 throw")
        } catch let error as ClaudeOAuthTokenRefresher.RefreshError {
            guard case .temporary = error else {
                XCTFail("temporary 가 아닌 \(error)")
                return
            }
        } catch {
            XCTFail("RefreshError 가 아님: \(error)")
        }

        // 같은 시각: cooldown 으로 차단되어야 함. HTTP 호출은 추가로 일어나지 않음.
        do {
            _ = try await refresher.refresh(credential)
            XCTFail("cooldown 중에도 throw")
        } catch let error as ClaudeOAuthTokenRefresher.RefreshError {
            guard case .temporary = error else {
                XCTFail("temporary 가 아닌 \(error)")
                return
            }
        } catch {
            XCTFail("RefreshError 가 아님: \(error)")
        }

        let count = await runner.totalCalls()
        XCTAssertEqual(count, 1, "cooldown 중에는 HTTP 호출이 추가로 일어나지 않음")
    }

    func testMissingRefreshTokenFailsImmediatelyWithoutNetworkCall() async {
        let runner = MockRunner(scriptedResponses: [])
        let refresher = ClaudeOAuthTokenRefresher(httpRunner: runner.run, cooldownInterval: 60)
        let credential = ClaudeCodeOAuthCredential(
            accessToken: "x", refreshToken: nil, expiresAt: nil, source: .refreshed
        )

        do {
            _ = try await refresher.refresh(credential)
            XCTFail("refresh_token 이 없으면 throw 해야 함")
        } catch let error as ClaudeOAuthTokenRefresher.RefreshError {
            XCTAssertEqual(error, .missingRefreshToken)
        } catch {
            XCTFail("RefreshError 가 아님: \(error)")
        }

        let count = await runner.totalCalls()
        XCTAssertEqual(count, 0)
    }

    func testConcurrentRefreshCallsCoalesceIntoSingleHTTPRequest() async throws {
        let json = """
        {"access_token":"shared-access","expires_in":1200}
        """
        // 같은 응답을 2번 스크립트에 넣어 두지만, 정상 흐름이면 1번만 소비되어야 한다.
        let runner = MockRunner(scriptedResponses: [
            .delayed(body: json, statusCode: 200, delaySeconds: 0.05),
            .success(body: json, statusCode: 200)
        ])
        let refresher = ClaudeOAuthTokenRefresher(httpRunner: runner.run, cooldownInterval: 60)
        let credential = ClaudeCodeOAuthCredential(
            accessToken: "old", refreshToken: "rt", expiresAt: nil, source: .refreshed
        )

        async let first = refresher.refresh(credential)
        async let second = refresher.refresh(credential)
        let (a, b) = try await (first, second)

        XCTAssertEqual(a.accessToken, "shared-access")
        XCTAssertEqual(b.accessToken, "shared-access")
        let count = await runner.totalCalls()
        XCTAssertEqual(count, 1, "동시 두 호출이 inFlight 로 합쳐져 HTTP 는 1번만")
    }

    func testResetStateClearsTerminalAndCooldown() async {
        let runner = MockRunner(scriptedResponses: [
            .success(body: #"{"error":"invalid_grant"}"#, statusCode: 400),
            .success(body: #"{"access_token":"after-reset","expires_in":600}"#, statusCode: 200)
        ])
        let refresher = ClaudeOAuthTokenRefresher(httpRunner: runner.run, cooldownInterval: 60)
        let credential = ClaudeCodeOAuthCredential(
            accessToken: "x", refreshToken: "rt", expiresAt: nil, source: .refreshed
        )

        _ = try? await refresher.refresh(credential)
        let blockedBefore = await refresher.currentBlockReason()
        XCTAssertEqual(blockedBefore, .invalidGrant)

        await refresher.resetState()
        let blockedAfter = await refresher.currentBlockReason()
        XCTAssertNil(blockedAfter)

        let refreshed = try? await refresher.refresh(credential)
        XCTAssertEqual(refreshed?.accessToken, "after-reset")
    }
}

// MARK: - Mock HTTP runner

private actor MockRunner {
    enum Scripted {
        case success(body: String, statusCode: Int)
        case delayed(body: String, statusCode: Int, delaySeconds: TimeInterval)
        case networkFailure
    }

    private var scripted: [Scripted]
    private var calls: Int = 0

    init(scriptedResponses: [Scripted]) {
        self.scripted = scriptedResponses
    }

    nonisolated var run: @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { [self] request in
            try await self.consume(request: request)
        }
    }

    func totalCalls() -> Int { calls }

    private func consume(request: URLRequest) async throws -> (Data, URLResponse) {
        calls += 1
        guard !scripted.isEmpty else {
            throw URLError(.notConnectedToInternet)
        }
        let next = scripted.removeFirst()
        switch next {
        case .success(let body, let statusCode):
            return Self.makeResponse(body: body, statusCode: statusCode, url: request.url!)
        case .delayed(let body, let statusCode, let delay):
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return Self.makeResponse(body: body, statusCode: statusCode, url: request.url!)
        case .networkFailure:
            throw URLError(.notConnectedToInternet)
        }
    }

    private static func makeResponse(body: String, statusCode: Int, url: URL) -> (Data, URLResponse) {
        let data = body.data(using: .utf8) ?? Data()
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}
