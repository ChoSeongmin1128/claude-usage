import XCTest
@testable import ClaudeUsage

final class AntigravityBootSessionIdentityTests: XCTestCase {
    func testSystemProviderReturnsCurrentBootSessionUUID() {
        XCTAssertNotNil(
            AntigravitySystemBootSessionIdentityProvider()
                .currentBootSessionID()
        )
    }
}
