import LocalAuthentication
import Security
import XCTest
@testable import ClaudeUsage

final class KeychainAccessPreflightTests: XCTestCase {
    func testNoUIQueryCombinesAuthenticationContextAndExplicitFailPolicy() {
        var query: [String: Any] = [:]

        KeychainAccessPreflight.applyNoUI(to: &query)

        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        XCTAssertEqual(context?.interactionNotAllowed, true)
        XCTAssertEqual(
            query[kSecUseAuthenticationUI as String] as? String,
            KeychainAccessPreflight.authenticationUIFailPolicyForTesting()
        )
    }
}
