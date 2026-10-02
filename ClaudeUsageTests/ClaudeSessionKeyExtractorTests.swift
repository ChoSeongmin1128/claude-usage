import Foundation
import XCTest
@testable import ClaudeUsage

final class ClaudeSessionKeyExtractorTests: XCTestCase {
    private let extractor = ClaudeSessionKeyExtractor()

    private let sessionKeyValue = "sk-ant-sid01-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA-BBBBBBBB"
    private let sessionKeyV3Value = "sk-ant-sid02-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC-DDDDDDDD"

    // claude.ai sets these before the user signs in. Several contain "session".
    private var preLoginCookies: [HTTPCookie] {
        [
            cookie("activitySessionId", "3f1c2a9e-7b4d-4e5f-9a8b-1c2d3e4f5a6b", domain: "claude.ai"),
            cookie("intercom-session-lupk8zyo", "dGhpcy1pcy1hLWZha2UtaW50ZXJjb20tc2Vzc2lvbg==", domain: ".claude.ai"),
            cookie("sessionKeyLC", "1790900000000", domain: ".claude.ai"),
            cookie("anthropic-device-id", "0a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d", domain: "claude.ai"),
            cookie("__cf_bm", "ZmFrZS1jbG91ZGZsYXJlLWJvdC1tYW5hZ2VtZW50LWNvb2tpZS12YWx1ZQ", domain: ".claude.ai"),
        ]
    }

    func testPreLoginCookiesAreNotTakenAsSessionKey() {
        XCTAssertNil(extractor.extractSessionKey(from: preLoginCookies))
    }

    func testSessionKeyCookieIsSelectedAmongPreLoginCookies() {
        let cookies = preLoginCookies + [cookie("sessionKey", sessionKeyValue, domain: ".claude.ai")]

        XCTAssertEqual(extractor.extractSessionKey(from: cookies)?.value, sessionKeyValue)
    }

    func testSessionKeyIsPreferredOverSessionKeyV3RegardlessOfOrder() {
        let cookies = [
            cookie("sessionKeyV3", sessionKeyV3Value, domain: ".claude.ai"),
            cookie("sessionKey", sessionKeyValue, domain: ".claude.ai"),
        ]

        XCTAssertEqual(extractor.extractSessionKey(from: cookies)?.value, sessionKeyValue)
    }

    func testPreLoginCookieHeaderIsNotTakenAsSessionKey() {
        let header =
            "activitySessionId=3f1c2a9e-7b4d-4e5f-9a8b-1c2d3e4f5a6b; "
            + "intercom-session-lupk8zyo=dGhpcy1pcy1hLWZha2UtaW50ZXJjb20tc2Vzc2lvbg==; sessionKeyLC=1790900000000"

        XCTAssertNil(extractor.extractSessionKey(fromCookieHeader: header))
    }

    func testCookieHeaderPrefersSessionKeyOverSessionKeyV3() {
        let header =
            "sessionKeyV3=\(sessionKeyV3Value); activitySessionId=3f1c2a9e-7b4d-4e5f-9a8b-1c2d3e4f5a6b; "
            + "sessionKey=\(sessionKeyValue)"

        XCTAssertEqual(extractor.extractSessionKey(fromCookieHeader: header), sessionKeyValue)
    }

    func testPastedSessionKeyValueIsStillAccepted() {
        XCTAssertEqual(extractor.extractSessionKey(fromCookieHeader: "sessionKey=\(sessionKeyValue)"), sessionKeyValue)
        XCTAssertEqual(extractor.extractLikelySessionKey(from: sessionKeyValue), sessionKeyValue)
    }

    private func cookie(_ name: String, _ value: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/"])!
    }
}
