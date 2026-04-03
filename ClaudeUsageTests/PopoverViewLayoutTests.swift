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
        XCTAssertEqual(PopoverLayoutMetrics.compactRowLabelWidth, 100)
        XCTAssertEqual(PopoverLayoutMetrics.compactRowMeterWidth, 150)
        XCTAssertEqual(PopoverLayoutMetrics.compactRowSpacing, 6)
    }

    func testStandardPopoverHeightShrinksForShortOrEmptyStates() {
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: false, phase: .authRequired, rowCount: 0),
            292
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: false, phase: .content, rowCount: 2),
            292
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: false, phase: .content, rowCount: 3),
            336
        )
    }

    func testCompactPopoverHeightUsesShorterStatusVariant() {
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: true, phase: .empty, rowCount: 0),
            116
        )
        XCTAssertEqual(
            PopoverLayoutMetrics.preferredPopoverHeight(compact: true, phase: .content, rowCount: 2),
            124
        )
    }
}
