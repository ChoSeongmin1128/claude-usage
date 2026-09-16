import AppKit
import SwiftUI
import XCTest
@testable import ClaudeUsage

@MainActor
final class PopoverResizeTests: XCTestCase {
    func testHostDoesNotResizeThePopoverIndependently() throws {
        let coordinator = AppPopoverCoordinator()
        coordinator.rebuildPopover()
        let host = try XCTUnwrap(coordinator.popover.contentViewController as? NSHostingController<PopoverView>)
        XCTAssertTrue(host.sizingOptions.isEmpty)
    }

    func testContentAndContainerResizeInTheSameEventWithoutASecondPreferredSizeWrite() {
        let popover = RecordingPopover()
        popover.contentViewController = NSViewController()
        let coordinator = AppPopoverCoordinator(makePopover: { popover })
        let size = CGSize(width: 368, height: 260)

        coordinator.refreshSizeIfShown(size: size)
        XCTAssertTrue(popover.resizeRequests.isEmpty, "Closed popovers must not resize")

        popover.visible = true
        coordinator.refreshSizeIfShown(size: size)
        XCTAssertEqual(popover.resizeRequests, [size], "The content change must not precede the resize by 50ms")
        XCTAssertEqual(popover.contentViewController?.preferredContentSize, .zero)
        coordinator.refreshSizeIfShown(size: size)
        XCTAssertEqual(popover.resizeRequests.count, 1, "Unchanged state must not restart the native transition")
    }

    func testRapidExpansionCollapseAndCloseLeaveNoDeferredResize() async throws {
        let popover = RecordingPopover()
        popover.visible = true
        var reducedMotion = false
        let coordinator = AppPopoverCoordinator(makePopover: { popover }, reduceMotion: { reducedMotion })
        let expanded = CGSize(width: 368, height: 260)
        let compact = CGSize(width: 296, height: 130)

        coordinator.refreshSizeIfShown(size: expanded)
        XCTAssertTrue(popover.animates)
        reducedMotion = true
        coordinator.refreshSizeIfShown(size: compact)
        XCTAssertFalse(popover.animates)
        coordinator.close()
        coordinator.refreshSizeIfShown(size: expanded)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(popover.resizeRequests, [expanded, compact])
        XCTAssertEqual(popover.contentSize, compact)
    }
}

@MainActor
private final class RecordingPopover: NSPopover {
    var visible = false
    var resizeRequests: [CGSize] = []
    private var requestedSize: CGSize = .zero

    override var isShown: Bool { visible }

    override var contentSize: NSSize {
        get { requestedSize }
        set {
            requestedSize = newValue
            resizeRequests.append(newValue)
        }
    }

    override func close() { visible = false }
}
