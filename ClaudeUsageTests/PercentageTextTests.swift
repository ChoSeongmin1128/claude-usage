import XCTest
@testable import ClaudeUsage

final class PercentageTextTests: XCTestCase {
    func testOnlyRealEndsShowZeroOrHundred() {
        XCTAssertEqual(PercentageText.string(0), "0%")
        XCTAssertEqual(PercentageText.string(0.3), "1%")
        XCTAssertEqual(PercentageText.string(42.5), "43%")
        XCTAssertEqual(PercentageText.string(99.6), "99%")
        XCTAssertEqual(PercentageText.string(100), "100%")
    }

    func testRemainingBasisAlsoKeepsEndsHonest() {
        XCTAssertEqual(UsageValueBasis.remaining.text(fromUsed: 99.7), "1%")
        XCTAssertEqual(UsageValueBasis.remaining.text(fromUsed: 0.2), "99%")
        XCTAssertEqual(UsageValueBasis.used.spokenValue(fromUsed: 99.8), "99퍼센트 사용")
    }

    func testTenthsStopBeforeEnds() {
        XCTAssertEqual(PercentageText.tenths(99.96), 99.9)
        XCTAssertEqual(PercentageText.tenths(0.02), 0.1)
        XCTAssertEqual(PercentageText.tenths(42.34), 42.3)
    }
}
