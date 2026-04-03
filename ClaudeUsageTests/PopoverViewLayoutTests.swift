import XCTest
@testable import ClaudeUsage

final class PopoverViewLayoutTests: XCTestCase {
    func testStandardPopoverWidthIsReducedTo368() {
        XCTAssertEqual(PopoverView.preferredPopoverWidth(compact: false), 368)
        XCTAssertEqual(PopoverLayoutMetrics.standardPopoverWidth, 368)
    }

    func testCompactPopoverWidthRemainsUnchanged() {
        XCTAssertEqual(PopoverView.preferredPopoverWidth(compact: true), 296)
    }

    func testCompactUsageRowMetricsAreFixed() {
        XCTAssertEqual(PopoverLayoutMetrics.compactRowLabelWidth, 108)
        XCTAssertEqual(PopoverLayoutMetrics.compactRowMeterWidth, 140)
        XCTAssertEqual(PopoverLayoutMetrics.compactRowSpacing, 8)
    }
}
