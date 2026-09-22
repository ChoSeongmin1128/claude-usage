import AppKit
import SwiftUI
import XCTest

@testable import ClaudeUsage

@MainActor
final class PopoverResizeTests: XCTestCase {
    func testNativeClaudePopoverKeepsHostAndContainerAlignedAcrossDensityChanges() throws {
        try assertNativeResize(service: .claude)
    }

    func testNativeAntigravityGroupsKeepHostAndContainerAlignedAcrossDensityChanges() throws {
        try assertNativeResize(service: .antigravity)
    }

    private func withNativePopover(
        service: PopoverService, reduceMotion: Bool = false, settleInitialPresentation: Bool = true,
        transitionStyle: AppMotionMode = .smooth, customCategories: Set<AppMotionCategory> = [],
        compact: Bool = true, pinned: Bool = true, connectSelectionCallbacks: Bool = false,
        _ body: (AppSettings, AppPopoverCoordinator, NSViewController, NSView) throws -> Void
    ) throws {
        let suite = "PopoverResizeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.setProviderEnabled(true, for: .claude)
        settings.setProviderEnabled(true, for: .codex)
        settings.setProviderEnabled(true, for: .antigravity)
        settings.popoverCompact = compact
        settings.motion = AppMotionPreferences(mode: transitionStyle, enabledCategories: customCategories)
        let coordinator = AppPopoverCoordinator(settings: settings, reduceMotion: { reduceMotion })
        coordinator.viewModel.update(snapshots: [
            .init(
                service: .claude,
                payload: .claude(
                    .init(
                        fiveHour: .init(utilization: 26, resetsAt: nil),
                        sevenDay: .init(utilization: 71, resetsAt: nil))),
                lastUpdated: Date(), credentialState: .usable, isDetected: true,
                canAttemptRefresh: true, hasAuthError: false)
        ])
        coordinator.viewModel.antigravityRuntimeSnapshot = antigravitySnapshot()
        if connectSelectionCallbacks {
            coordinator.configure(
                initialService: service,
                onRefreshService: { _ in },
                onOpenSettingsForService: { _ in },
                onOpenSettingsPanel: { _ in },
                onServiceSelected: { [weak coordinator] selected in
                    guard let coordinator else { return }
                    ServiceSelectionHelper.setActivePopoverService(selected, settings: settings)
                    coordinator.refreshSizeIfShown(
                        size: coordinator.viewModel.layoutSpec(for: selected, settings: settings).size)
                },
                onLayoutChanged: { [weak coordinator] selected, _ in
                    guard let coordinator else { return }
                    coordinator.refreshSizeIfShown(
                        size: coordinator.viewModel.layoutSpec(for: selected, settings: settings).size)
                },
                onPinChanged: { _, _ in }
            )
        } else {
            coordinator.viewModel.selectService(service)
            coordinator.rebuildPopover()
        }
        coordinator.applyBehavior(isPinned: pinned)
        let popover = coordinator.popover
        let host = try XCTUnwrap(popover.contentViewController)
        let initialSize = coordinator.viewModel.layoutSpec(for: service, settings: settings).size
        host.preferredContentSize = initialSize
        popover.contentSize = initialSize
        let screen = try XCTUnwrap(NSScreen.main)
        let anchorWindow = NSWindow(
            contentRect: NSRect(
                x: screen.visibleFrame.minX + 200, y: screen.visibleFrame.maxY - 160, width: 400, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        anchorWindow.isReleasedWhenClosed = false
        anchorWindow.alphaValue = 0
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        anchorWindow.contentView = anchor
        anchorWindow.orderBack(nil)
        defer {
            coordinator.close()
            anchorWindow.close()
        }
        popover.show(relativeTo: NSRect(x: 180, y: 50, width: 20, height: 20), of: anchor, preferredEdge: .minY)
        host.view.window?.alphaValue = 0
        XCTAssertTrue(popover.isShown)

        if settleInitialPresentation { RunLoop.current.run(until: Date().addingTimeInterval(0.35)) }
        try body(settings, coordinator, host, anchor)
    }

    private func assertNativeResize(service: PopoverService) throws {
        try withNativePopover(service: service) { settings, coordinator, host, _ in
            let viewport = try XCTUnwrap(host.view as? PopoverViewportView)
            let window = try XCTUnwrap(host.view.window)
            for compact in [false, true, false] {
                let initialFrame = window.frame
                settings.popoverCompact = compact
                let target = coordinator.viewModel.layoutSpec(for: service, settings: settings).size
                coordinator.refreshSizeIfShown(size: target)
                let frames = try observeTransition(host: host, duration: 0.45)
                XCTAssertGreaterThan(Set(frames.map { Int($0.width.rounded()) }).count, 3)
                for frame in frames {
                    XCTAssertEqual(frame.maxY, initialFrame.maxY, accuracy: 2)
                    XCTAssertEqual(frame.midX, initialFrame.midX, accuracy: 2)
                }
                assertFinalSize(host: host, popover: coordinator.popover, target: target)
                XCTAssertEqual(viewport.hostingView.bounds.width, target.width, accuracy: 1)
                XCTAssertEqual(viewport.hostingView.bounds.height, target.height, accuracy: 1)
            }
        }
    }

    func testSmoothResizeKeepsHostedTopInsetStable() throws {
        try withNativePopover(service: .claude) { settings, coordinator, host, _ in
            settings.popoverCompact = false
            coordinator.refreshSizeIfShown(
                size: coordinator.viewModel.layoutSpec(for: .claude, settings: settings).size
            )
            _ = try observeTransition(host: host, duration: 0.45)

            settings.popoverCompact = true
            let target = coordinator.viewModel.layoutSpec(for: .claude, settings: settings).size
            coordinator.refreshSizeIfShown(size: target)

            let viewport = try XCTUnwrap(host.view as? PopoverViewportView)
            let parent = try XCTUnwrap(viewport.superview)
            var topInsets: [CGFloat] = []
            let end = Date().addingTimeInterval(0.45)
            while Date() < end {
                RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 120))
                viewport.layoutSubtreeIfNeeded()
                let hosted = viewport.convert(viewport.hostingView.frame, to: parent)
                topInsets.append(parent.bounds.maxY - hosted.maxY)
            }

            let minimum = try XCTUnwrap(topInsets.min())
            let maximum = try XCTUnwrap(topInsets.max())
            XCTAssertLessThanOrEqual(
                maximum - minimum,
                0.25,
                "hosted content top inset must not wobble while the native popover shrinks"
            )
            assertFinalSize(host: host, popover: coordinator.popover, target: target)
        }
    }

    func testNestedDisplayEditorDefersMainResizeUntilNativeClose() throws {
        for (compact, motion, pinned) in [(true, AppMotionMode.smooth, true), (false, .instant, false)] {
            try withNativePopover(
                service: .claude, transitionStyle: motion, compact: compact, pinned: pinned,
                connectSelectionCallbacks: true
            ) { settings, coordinator, host, _ in
                let lifecycle = NativeEditorLifecycle(mainPopover: coordinator.popover)
                defer { lifecycle.stop() }
                try openNestedEditor(coordinator: coordinator, host: host, compact: compact, lifecycle: lifecycle)

                let original = coordinator.popover.contentSize
                let items = settings.popoverItems(for: .claude).map {
                    PopoverItemConfig(id: $0.id, visible: $0.id == "weeklyLimit" ? false : $0.visible)
                }
                settings.setPopoverItems(items, for: .claude)
                let target = coordinator.viewModel.layoutSpec(for: .claude, settings: settings).size
                XCTAssertLessThan(target.height, original.height)
                coordinator.refreshSizeIfShown(size: target)
                XCTAssertEqual(coordinator.popover.contentSize, original)
                XCTAssertTrue(coordinator.displayEditorIsActive)

                let baseline = try geometryBaseline(coordinator: coordinator, host: host)
                coordinator.closeDisplayEditor(animated: false)
                try waitForNestedResize(
                    coordinator: coordinator, host: host, target: target, lifecycle: lifecycle, baseline: baseline)
                XCTAssertFalse(coordinator.displayEditorIsActive)
                assertFinalSize(host: host, popover: coordinator.popover, target: target)
            }
        }
    }

    func testNestedDisplayEditorServiceSwitchUsesCallbacksAndFinalNativeGeometry() throws {
        for (compact, motion, pinned) in [(true, AppMotionMode.smooth, true), (false, .instant, false)] {
            try withNativePopover(
                service: .claude, transitionStyle: motion, compact: compact, pinned: pinned,
                connectSelectionCallbacks: true
            ) { settings, coordinator, host, _ in
                let codexUsage = try JSONDecoder().decode(
                    CodexUsageResponse.self,
                    from: Data(
                        #"{"rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000}}}"#.utf8)
                )
                var snapshots = Array(coordinator.viewModel.runtimeSnapshots.values)
                snapshots.append(
                    .init(
                        service: .codex, payload: .codex(codexUsage), lastUpdated: Date(),
                        credentialState: .usable, isDetected: true, canAttemptRefresh: true, hasAuthError: false))
                coordinator.viewModel.update(snapshots: snapshots)

                for destination in [PopoverService.codex, .claude] {
                    let lifecycle = NativeEditorLifecycle(mainPopover: coordinator.popover)
                    defer { lifecycle.stop() }
                    try openNestedEditor(coordinator: coordinator, host: host, compact: compact, lifecycle: lifecycle)
                    let editor = try XCTUnwrap(lifecycle.editor)
                    let originalSelection = coordinator.viewModel.onServiceSelected
                    let originalLayout = coordinator.viewModel.onLayoutChanged
                    var selectedServices: [PopoverService] = []
                    var layoutServices: [PopoverService] = []
                    coordinator.viewModel.onServiceSelected = { selected in
                        XCTAssertFalse(editor.isShown, "Selection must wait for the nested editor to close")
                        selectedServices.append(selected)
                        originalSelection?(selected)
                    }
                    coordinator.viewModel.onLayoutChanged = { selected, reason in
                        layoutServices.append(selected)
                        originalLayout?(selected, reason)
                    }

                    let baseline = try geometryBaseline(coordinator: coordinator, host: host)
                    coordinator.requestServiceSelection(destination)
                    let target = coordinator.viewModel.layoutSpec(for: destination, settings: settings).size
                    try waitForNestedResize(
                        coordinator: coordinator, host: host, target: target, lifecycle: lifecycle, baseline: baseline)
                    XCTAssertEqual(selectedServices, [destination])
                    XCTAssertEqual(layoutServices, [destination])
                    XCTAssertEqual(coordinator.viewModel.selectedService, destination)
                    XCTAssertEqual(ServiceSelectionHelper.resolvedPopoverService(settings: settings), destination)
                    assertFinalSize(host: host, popover: coordinator.popover, target: target)
                    coordinator.viewModel.onServiceSelected = originalSelection
                    coordinator.viewModel.onLayoutChanged = originalLayout
                }
            }
        }
    }

    func testNestedDisplayEditorServiceSwitchUsesLastRequestAfterClose() throws {
        try withNativePopover(service: .claude, connectSelectionCallbacks: true) { settings, coordinator, host, _ in
            let lifecycle = NativeEditorLifecycle(mainPopover: coordinator.popover)
            defer { lifecycle.stop() }
            try openNestedEditor(coordinator: coordinator, host: host, compact: true, lifecycle: lifecycle)
            let baseline = try geometryBaseline(coordinator: coordinator, host: host)

            coordinator.requestServiceSelection(.antigravity)
            coordinator.requestServiceSelection(.codex)
            let target = coordinator.viewModel.layoutSpec(for: .codex, settings: settings).size
            try waitForNestedResize(
                coordinator: coordinator, host: host, target: target, lifecycle: lifecycle, baseline: baseline)
            XCTAssertFalse(coordinator.displayEditorIsActive)
            XCTAssertEqual(coordinator.viewModel.selectedService, .codex)
            XCTAssertEqual(ServiceSelectionHelper.resolvedPopoverService(settings: settings), .codex)
            assertFinalSize(host: host, popover: coordinator.popover, target: target)
        }
    }

    func testRepeatedTargetRequestsDoNotRestartTheNativeTransition() throws {
        try withNativePopover(service: .claude) { settings, coordinator, host, _ in
            settings.popoverCompact = false
            let target = coordinator.viewModel.layoutSpec(for: .claude, settings: settings).size
            coordinator.refreshSizeIfShown(size: target)
            let frames = try observeTransition(host: host, duration: 0.5) {
                coordinator.refreshSizeIfShown(size: target)
            }
            XCTAssertGreaterThan(Set(frames.map { Int($0.width.rounded()) }).count, 3)
            assertFinalSize(host: host, popover: coordinator.popover, target: target)
        }
    }

    func testRapidReversalServiceSwitchAndCloseCannotLeaveStaleViewportGeometry() throws {
        try withNativePopover(service: .antigravity) { settings, coordinator, host, _ in
            for (compact, wait) in [(false, 0.09), (true, 0.07), (false, 0.08)] {
                settings.popoverCompact = compact
                coordinator.refreshSizeIfShown(
                    size: coordinator.viewModel.layoutSpec(for: .antigravity, settings: settings).size)
                _ = try observeTransition(host: host, duration: wait)
            }
            coordinator.viewModel.selectService(.claude)
            let target = coordinator.viewModel.layoutSpec(for: .claude, settings: settings).size
            coordinator.refreshSizeIfShown(size: target)
            _ = try observeTransition(host: host, duration: 0.5)
            assertFinalSize(host: host, popover: coordinator.popover, target: target)
            settings.popoverCompact = true
            coordinator.refreshSizeIfShown(
                size: coordinator.viewModel.layoutSpec(for: .claude, settings: settings).size)
            coordinator.close()
            coordinator.refreshSizeIfShown(size: CGSize(width: 999, height: 999))
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            XCTAssertFalse(coordinator.popover.isShown)
            XCTAssertLessThan(coordinator.popover.contentSize.width, 500)
        }
    }

    func testReducedMotionReachesTheFinalSizeWithoutAnAnimatedViewport() throws {
        try withNativePopover(service: .claude, reduceMotion: true) { settings, coordinator, host, _ in
            settings.popoverCompact = false
            let target = coordinator.viewModel.layoutSpec(for: .claude, settings: settings).size
            coordinator.refreshSizeIfShown(size: target)
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            assertFinalSize(host: host, popover: coordinator.popover, target: target)
            XCTAssertFalse(coordinator.popover.animates)
            let frames = try observeTransition(host: host, duration: 0.3)
            XCTAssertLessThanOrEqual(Set(frames.map { Int($0.width.rounded()) }).count, 2)
        }
    }

    func testInstantPreferenceAndChangingPreferenceReuseTheSameHost() throws {
        try withNativePopover(service: .antigravity, transitionStyle: .instant) { settings, coordinator, host, _ in
            let originalPopover = coordinator.popover
            settings.popoverCompact = false
            var target = coordinator.viewModel.layoutSpec(for: .antigravity, settings: settings).size
            coordinator.refreshSizeIfShown(size: target)
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            assertFinalSize(host: host, popover: coordinator.popover, target: target)
            XCTAssertFalse(coordinator.popover.animates)
            let instantFrames = try observeTransition(host: host, duration: 0.3)
            XCTAssertLessThanOrEqual(Set(instantFrames.map { Int($0.width.rounded()) }).count, 2)

            settings.motion.mode = .smooth
            settings.popoverCompact = true
            target = coordinator.viewModel.layoutSpec(for: .antigravity, settings: settings).size
            coordinator.refreshSizeIfShown(size: target)
            let smoothFrames = try observeTransition(host: host, duration: 0.45)
            XCTAssertGreaterThan(Set(smoothFrames.map { Int($0.width.rounded()) }).count, 3)
            assertFinalSize(host: host, popover: coordinator.popover, target: target)
            XCTAssertTrue(coordinator.popover === originalPopover)
            XCTAssertTrue(coordinator.popover.contentViewController === host)
        }
    }

    func testSwitchingToInstantDuringResizeSettlesTheLatestTarget() throws {
        try withNativePopover(service: .antigravity) { settings, coordinator, host, _ in
            settings.popoverCompact = false
            coordinator.refreshSizeIfShown(
                size: coordinator.viewModel.layoutSpec(for: .antigravity, settings: settings).size)
            _ = try observeTransition(host: host, duration: 0.08)
            settings.motion.mode = .instant
            settings.popoverCompact = true
            let target = coordinator.viewModel.layoutSpec(for: .antigravity, settings: settings).size
            coordinator.refreshSizeIfShown(size: target)
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            assertFinalSize(host: host, popover: coordinator.popover, target: target)
            _ = try observeTransition(host: host, duration: 0.4)
            assertFinalSize(host: host, popover: coordinator.popover, target: target)
            XCTAssertFalse(coordinator.popover.animates)
        }
    }

    func testDesignIntroductionResizesWithoutTakingSpaceFromUsageAndDismissesOnce() throws {
        try withNativePopover(service: .claude) { settings, coordinator, host, _ in
            let original = coordinator.viewModel.layoutSpec(for: .claude, settings: settings)
            settings.menuBarDesign = .classic
            settings.menuBarDesignIntroductionDismissed = false
            coordinator.viewModel.isDesignIntroductionPresented = true
            _ = try observeTransition(host: host, duration: 0.5)
            let introduced = coordinator.viewModel.layoutSpec(for: .claude, settings: settings)
            XCTAssertEqual(introduced.size.height, original.size.height + PopoverLayoutMetrics.designIntroductionHeight)
            XCTAssertEqual(introduced.bodyRegionHeight, original.bodyRegionHeight)
            assertFinalSize(host: host, popover: coordinator.popover, target: introduced.size)
            XCTAssertTrue(settings.menuBarDesignIntroductionDismissed)
            coordinator.viewModel.isDesignIntroductionPresented = false
            _ = try observeTransition(host: host, duration: 0.5)
            assertFinalSize(host: host, popover: coordinator.popover, target: original.size)
            XCTAssertEqual(settings.menuBarDesign, .classic)
        }
    }

    func testPresentationAndResizeMotionCanBeConfiguredIndependently() throws {
        for category in [AppMotionCategory.popoverPresentation, .popoverResize] {
            try withNativePopover(service: .claude, transitionStyle: .custom, customCategories: [category]) {
                settings, coordinator, host, _ in
                XCTAssertEqual(coordinator.popover.animates, category == .popoverPresentation)
                settings.popoverCompact = false
                let target = coordinator.viewModel.layoutSpec(for: .claude, settings: settings).size
                coordinator.refreshSizeIfShown(size: target)
                let frames = try observeTransition(host: host, duration: 0.5)
                if category == .popoverResize {
                    XCTAssertGreaterThan(Set(frames.map { Int($0.width.rounded()) }).count, 3)
                } else {
                    XCTAssertLessThanOrEqual(Set(frames.map { Int($0.width.rounded()) }).count, 2)
                }
                assertFinalSize(host: host, popover: coordinator.popover, target: target)
                XCTAssertEqual(coordinator.popover.animates, category == .popoverPresentation)
            }
        }
    }

    func testLayoutChangesReportTheirTargetWithoutAnExternalResizeRequest() throws {
        try withNativePopover(service: .claude) { settings, coordinator, host, _ in
            settings.popoverCompact = false
            _ = try observeTransition(host: host, duration: 0.5)
            let target = coordinator.viewModel.layoutSpec(for: .claude, settings: settings).size
            assertFinalSize(host: host, popover: coordinator.popover, target: target)
        }
    }

    func testNativeCloseRejectsLateResizeRequests() throws {
        try withNativePopover(service: .claude) { settings, coordinator, host, _ in
            settings.popoverCompact = false
            coordinator.refreshSizeIfShown(
                size: coordinator.viewModel.layoutSpec(for: .claude, settings: settings).size)
            coordinator.popover.performClose(nil)
            coordinator.refreshSizeIfShown(size: CGSize(width: 999, height: 999))
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            XCTAssertFalse(coordinator.popover.isShown)
            XCTAssertLessThan(host.preferredContentSize.width, 500)
        }
    }

    func testResizeDuringInitialPresentationKeepsTheFinalViewportAligned() throws {
        try withNativePopover(service: .claude, settleInitialPresentation: false) { settings, coordinator, host, _ in
            settings.popoverCompact = false
            let target = coordinator.viewModel.layoutSpec(for: .claude, settings: settings).size
            coordinator.refreshSizeIfShown(size: target)
            _ = try observeTransition(host: host, duration: 0.5)
            assertFinalSize(host: host, popover: coordinator.popover, target: target)
        }
    }

    private func openNestedEditor(
        coordinator: AppPopoverCoordinator, host: NSViewController, compact: Bool,
        lifecycle: NativeEditorLifecycle
    ) throws {
        let viewport = try XCTUnwrap(host.view as? PopoverViewportView)
        XCTAssertTrue(
            waitUntil {
                host.view.layoutSubtreeIfNeeded()
                return self.displayEditorAnchor(in: viewport.hostingView) != nil
            })
        let anchor = try XCTUnwrap(displayEditorAnchor(in: viewport.hostingView))
        XCTAssertTrue(anchor.isDescendant(of: viewport.hostingView))
        XCTAssertTrue(anchor.window === host.view.window)
        XCTAssertFalse(anchor.bounds.isEmpty)
        coordinator.presentDisplayEditor(
            anchor: anchor, service: coordinator.viewModel.selectedService, mode: compact ? .compact : .standard)
        XCTAssertTrue(waitUntil { lifecycle.didShow && coordinator.displayEditorIsActive })
        XCTAssertTrue(coordinator.popover.isShown, "Opening the nested editor must preserve its parent popover")
        XCTAssertNotNil(lifecycle.editor)
    }

    private func displayEditorAnchor(in view: NSView) -> NSView? {
        if view.identifier?.rawValue == "popover-display-editor-anchor" { return view }
        return view.subviews.lazy.compactMap { self.displayEditorAnchor(in: $0) }.first
    }

    private struct GeometryBaseline {
        let windowTop: CGFloat
        let hostedTopInset: CGFloat
        let windowChromeHeight: CGFloat
    }

    private func geometryBaseline(coordinator: AppPopoverCoordinator, host: NSViewController) throws -> GeometryBaseline
    {
        let window = try XCTUnwrap(host.view.window)
        let viewport = try XCTUnwrap(host.view as? PopoverViewportView)
        let parent = try XCTUnwrap(viewport.superview)
        viewport.layoutSubtreeIfNeeded()
        let hosted = viewport.convert(viewport.hostingView.frame, to: parent)
        return GeometryBaseline(
            windowTop: window.frame.maxY, hostedTopInset: parent.bounds.maxY - hosted.maxY,
            windowChromeHeight: window.frame.height - coordinator.popover.contentSize.height)
    }

    private func waitForNestedResize(
        coordinator: AppPopoverCoordinator, host: NSViewController, target: CGSize,
        lifecycle: NativeEditorLifecycle, baseline: GeometryBaseline
    ) throws {
        let window = try XCTUnwrap(host.view.window)
        let viewport = try XCTUnwrap(host.view as? PopoverViewportView)
        let parent = try XCTUnwrap(viewport.superview)
        var largestTopMovement: CGFloat = 0
        var largestInsetMovement: CGFloat = 0
        let settled = waitUntil {
            viewport.layoutSubtreeIfNeeded()
            let hosted = viewport.convert(viewport.hostingView.frame, to: parent)
            largestTopMovement = max(largestTopMovement, abs(window.frame.maxY - baseline.windowTop))
            largestInsetMovement = max(
                largestInsetMovement, abs(parent.bounds.maxY - hosted.maxY - baseline.hostedTopInset))
            return lifecycle.didClose && !coordinator.displayEditorIsActive
                && abs(coordinator.popover.contentSize.width - target.width) <= 0.5
                && abs(coordinator.popover.contentSize.height - target.height) <= 0.5
                && abs(window.frame.height - target.height - baseline.windowChromeHeight) <= 1
                && abs(viewport.hostingView.bounds.width - target.width) <= 0.5
                && abs(viewport.hostingView.bounds.height - target.height) <= 0.5
        }
        XCTAssertTrue(settled, "Native editor closure and final parent geometry must both complete")
        XCTAssertTrue(lifecycle.didClose, "Observe the real NSPopover close notification")
        XCTAssertLessThanOrEqual(largestTopMovement, 2, "The parent must retain its original top anchor")
        XCTAssertLessThanOrEqual(largestInsetMovement, 0.25, "Hosted content must not wobble within the parent")
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 120))
        }
        return true
    }

    private func observeTransition(
        host: NSViewController, duration: TimeInterval, eachFrame: () -> Void = {}
    ) throws -> [CGRect] {
        let window = try XCTUnwrap(host.view.window)
        let viewport = try XCTUnwrap(host.view as? PopoverViewportView)
        let parent = try XCTUnwrap(viewport.superview)
        var frames: [CGRect] = []
        let end = Date().addingTimeInterval(duration)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 120))
            eachFrame()
            viewport.layoutSubtreeIfNeeded()
            frames.append(window.frame)
            let hosted = viewport.convert(viewport.hostingView.frame, to: parent)
            XCTAssertGreaterThanOrEqual(hosted.minX, parent.bounds.minX)
            XCTAssertGreaterThanOrEqual(hosted.minY, parent.bounds.minY)
            XCTAssertLessThanOrEqual(hosted.maxX, parent.bounds.maxX + 1)
            XCTAssertLessThanOrEqual(hosted.maxY, parent.bounds.maxY + 1)
            XCTAssertFalse(viewport.hostingView.frame.isEmpty)
        }
        return frames
    }

    private func assertFinalSize(host: NSViewController, popover: NSPopover, target: CGSize) {
        XCTAssertEqual(popover.contentSize.width, target.width, accuracy: 0.5)
        XCTAssertEqual(popover.contentSize.height, target.height, accuracy: 0.5)
        XCTAssertEqual(host.preferredContentSize.width, target.width, accuracy: 0.5)
        XCTAssertEqual(host.preferredContentSize.height, target.height, accuracy: 0.5)
        XCTAssertEqual(host.view.bounds.width, target.width, accuracy: 0.5)
        XCTAssertEqual(host.view.bounds.height, target.height, accuracy: 0.5)
        if let viewport = host.view as? PopoverViewportView {
            XCTAssertEqual(viewport.hostingView.bounds.width, target.width, accuracy: 1)
            XCTAssertEqual(viewport.hostingView.bounds.height, target.height, accuracy: 1)
        } else {
            XCTFail("Missing live viewport")
        }
    }

    private func antigravitySnapshot() -> AntigravityRuntimeSnapshot {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = ProviderAccountIdentity(stableAccountID: "fixture", email: "fixture@example.com")
        let lanes: [AntigravityQuotaLane] = [
            (.geminiWeekly, AntigravityQuotaScope.gemini, 1.0),
            (.thirdPartyWeekly, AntigravityQuotaScope.thirdPartyModels, 0.808),
        ].map { id, scope, remaining in
            AntigravityQuotaLane(
                id: id, upstreamGroupID: id.rawValue, upstreamBucketID: id.rawValue,
                scope: scope, cadence: .weekly, remainingFraction: remaining,
                resetAt: now.addingTimeInterval(4 * 86400), resetDescription: nil, availability: .available)
        }
        let quota = AntigravityQuotaSnapshot(
            identity: identity, plan: nil, lanes: lanes, decodeIssues: [],
            provenance: .init(
                transport: .borrowedAGYRPC, endpointOwner: .borrowed, accountIdentity: identity,
                capability: .groupedQuotaSummary, processIdentity: nil), fetchedAt: now)
        return AntigravityRuntimeSnapshot(
            readiness: .ready, migrationStatus: nil, repositoryRevision: 1, accounts: [], activeAccountID: nil,
            settings: .init(connection: .default, display: .default), presentationState: .ready(quota),
            quotaPresentation: .content(
                AntigravityQuotaPresentationMapper.map(
                    snapshot: quota, settings: .default, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)),
            managedRuntimeAvailability: .available(displayPath: "fixture/agy"),
            lastAttemptAt: now, lastSuccessfulAt: now)
    }

}

@MainActor
private final class NativeEditorLifecycle: NSObject {
    private let mainPopover: NSPopover
    private(set) var editor: NSPopover?
    private(set) var didShow = false
    private(set) var didClose = false

    init(mainPopover: NSPopover) {
        self.mainPopover = mainPopover
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(willShow(_:)), name: NSPopover.willShowNotification, object: nil)
        center.addObserver(self, selector: #selector(didShow(_:)), name: NSPopover.didShowNotification, object: nil)
        center.addObserver(self, selector: #selector(didClose(_:)), name: NSPopover.didCloseNotification, object: nil)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func willShow(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover !== mainPopover else { return }
        editor = popover
        popover.contentViewController?.view.window?.alphaValue = 0
    }

    @objc private func didShow(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover === editor else { return }
        popover.contentViewController?.view.window?.alphaValue = 0
        didShow = true
    }

    @objc private func didClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover === editor else { return }
        didClose = true
    }
}
