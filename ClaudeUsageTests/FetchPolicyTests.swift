import XCTest
@testable import ClaudeUsage

final class FetchPolicyTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_900_000_000)

    private func usage(fiveHourResetIn seconds: TimeInterval) -> ClaudeUsageResponse {
        let reset = ISO8601DateFormatter().string(from: fetchedAt.addingTimeInterval(seconds))
        return ClaudeUsageResponse(
            fiveHour: UsageWindow(utilization: 100, resetsAt: reset),
            sevenDay: UsageWindow(utilization: 40, resetsAt: nil))
    }

    func testOAuthCacheIsReusedOnlyWithinTheIntervalAndBeforeAnyReset() {
        let pending = usage(fiveHourResetIn: 3600)
        XCTAssertTrue(
            ClaudeAPIService.canReuseOAuthUsage(pending, fetchedAt: fetchedAt, now: fetchedAt.addingTimeInterval(120)))
        XCTAssertFalse(
            ClaudeAPIService.canReuseOAuthUsage(pending, fetchedAt: fetchedAt, now: fetchedAt.addingTimeInterval(300)))

        let resetSoon = usage(fiveHourResetIn: 60)
        XCTAssertTrue(
            ClaudeAPIService.canReuseOAuthUsage(resetSoon, fetchedAt: fetchedAt, now: fetchedAt.addingTimeInterval(30)))
        XCTAssertFalse(
            ClaudeAPIService.canReuseOAuthUsage(resetSoon, fetchedAt: fetchedAt, now: fetchedAt.addingTimeInterval(65)),
            "초기화 시각이 지나면 캐시는 초기화 전 값입니다")
    }

    func testExhaustedLimitsDoNotKeepTheShortestInterval() {
        XCTAssertTrue(AdaptiveRefreshPolicy.isLowRemaining(usedPercentage: 95))
        XCTAssertTrue(AdaptiveRefreshPolicy.isLowRemaining(usedPercentage: 90))
        XCTAssertFalse(AdaptiveRefreshPolicy.isLowRemaining(usedPercentage: 89))
        XCTAssertFalse(AdaptiveRefreshPolicy.isLowRemaining(usedPercentage: 100))
        XCTAssertFalse(AdaptiveRefreshPolicy.isLowRemaining(usedPercentage: 130))
    }

    func testCodexRateLimitKeepsRetryAfterAndIsTemporary() {
        let error = CodexHTTPFailure(status: 429, retryAfter: 120).apiError
        guard case .rateLimited(let retryAfter) = error else { return XCTFail("429는 재시도 대기여야 합니다") }
        XCTAssertEqual(retryAfter, 120)
        XCTAssertTrue(error.isTemporaryFailure)
        guard case .invalidSessionKey = CodexHTTPFailure(status: 403).apiError else { return XCTFail() }
        guard case .serverError(500) = CodexHTTPFailure(status: 500).apiError else { return XCTFail() }
    }

    func testClaudeWebRequestsDoNotStoreSessionCookies() {
        var request = URLRequest(url: URL(string: "https://claude.ai/api/account")!)
        ClaudeEndpoints.applyWebHeaders(to: &request, sessionKey: "sk-test")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sessionKey=sk-test")
    }
}
