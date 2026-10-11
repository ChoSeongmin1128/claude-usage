import XCTest
@testable import ClaudeUsage

final class HTTPResponseClassificationTests: XCTestCase {
    private func response(retryAfter: String?) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.test")!, statusCode: 429, httpVersion: nil,
            headerFields: retryAfter.map { ["Retry-After": $0] })!
    }

    func testRetryAfterReadsSecondsAndHTTPDates() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        XCTAssertEqual(HTTPResponseClassification.retryAfterSeconds(response(retryAfter: " 120 "), now: now), 120)
        let date = "Sun, 17 Mar 2030 08:01:40 GMT"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let target = formatter.date(from: date)!
        XCTAssertEqual(
            HTTPResponseClassification.retryAfterSeconds(
                response(retryAfter: date), now: target.addingTimeInterval(-90)), 90)
        XCTAssertNil(HTTPResponseClassification.retryAfterSeconds(response(retryAfter: date), now: target))
        XCTAssertNil(HTTPResponseClassification.retryAfterSeconds(response(retryAfter: "0"), now: now))
        XCTAssertNil(HTTPResponseClassification.retryAfterSeconds(response(retryAfter: "soon"), now: now))
        XCTAssertNil(HTTPResponseClassification.retryAfterSeconds(response(retryAfter: nil), now: now))
    }

    func testCloudflareChallengeIsNotALoginFailure() {
        XCTAssertTrue(HTTPResponseClassification.isCloudflareChallenge(Data("<title>Just a moment...</title>".utf8)))
        XCTAssertFalse(HTTPResponseClassification.isCloudflareChallenge(Data(#"{"error":"forbidden"}"#.utf8)))
        XCTAssertFalse(HTTPResponseClassification.isCloudflareChallenge(nil))
    }
}
