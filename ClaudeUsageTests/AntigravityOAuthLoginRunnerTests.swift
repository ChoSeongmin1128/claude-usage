import XCTest
@testable import ClaudeUsage

final class AntigravityOAuthLoginRunnerTests: XCTestCase {
    func testCallbackParserAcceptsLoopbackGetWithExpectedState() {
        let callback = AntigravityOAuthCallbackParser.parse(
            from: request(
                line: "GET /oauth2callback?code=abc123&state=expected HTTP/1.1",
                host: "127.0.0.1:54321"
            ),
            expectedState: "expected",
            allowedHost: "127.0.0.1:54321"
        )

        XCTAssertEqual(callback.code, "abc123")
        XCTAssertEqual(callback.returnedState, "expected")
        XCTAssertNil(callback.error)
    }

    func testCallbackParserRejectsUnexpectedHost() {
        let callback = AntigravityOAuthCallbackParser.parse(
            from: request(
                line: "GET /oauth2callback?code=abc123&state=expected HTTP/1.1",
                host: "192.168.0.10:54321"
            ),
            expectedState: "expected",
            allowedHost: "127.0.0.1:54321"
        )

        XCTAssertNil(callback.code)
        XCTAssertEqual(callback.error, "callback host가 올바르지 않습니다.")
    }

    func testCallbackParserRejectsNonGetRequests() {
        let callback = AntigravityOAuthCallbackParser.parse(
            from: request(
                line: "POST /oauth2callback?code=abc123&state=expected HTTP/1.1",
                host: "127.0.0.1:54321"
            ),
            expectedState: "expected",
            allowedHost: "127.0.0.1:54321"
        )

        XCTAssertNil(callback.code)
        XCTAssertEqual(callback.error, "callback HTTP method가 올바르지 않습니다.")
    }

    func testCallbackParserRejectsUnexpectedState() {
        let callback = AntigravityOAuthCallbackParser.parse(
            from: request(
                line: "GET /oauth2callback?code=abc123&state=unexpected HTTP/1.1",
                host: "127.0.0.1:54321"
            ),
            expectedState: "expected",
            allowedHost: "127.0.0.1:54321"
        )

        XCTAssertEqual(callback.code, "abc123")
        XCTAssertEqual(callback.returnedState, "unexpected")
        XCTAssertEqual(callback.error, "state가 일치하지 않습니다.")
    }

    private func request(line: String, host: String) -> Data {
        Data("""
        \(line)\r
        Host: \(host)\r
        Connection: close\r
        \r
        """.utf8)
    }
}
