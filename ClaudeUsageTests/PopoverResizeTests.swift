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

    func testViewportUsesTheNativeParentAfterAnEarlyResizeCompletion() throws {
        try withDetachedViewport { viewport, parent in
            viewport.frame = CGRect(x: 4, y: 4, width: 310, height: 152)
            viewport.needsLayout = true
            viewport.layoutSubtreeIfNeeded()
            viewport.prepareForResize()
            viewport.setFrameSize(CGSize(width: 370, height: 210))
            viewport.finishResize()

            for size in [
                CGSize(width: 318, height: 160), .init(width: 346, height: 190), .init(width: 378, height: 218),
            ] {
                parent.setFrameSize(size)
                viewport.needsLayout = true
                viewport.layoutSubtreeIfNeeded()
                let hosted = viewport.convert(viewport.hostingView.frame, to: parent)
                XCTAssertTrue(parent.bounds.contains(hosted))
                XCTAssertEqual(parent.bounds.maxY - hosted.maxY, 4, accuracy: 0.01)
                XCTAssertEqual(hosted.minX - parent.bounds.minX, 4, accuracy: 0.01)
            }
            XCTAssertEqual(viewport.hostingView.bounds.size, CGSize(width: 370, height: 210))
        }
    }

    func testViewportKeepsKnownMarginsDuringAnEarlyShrinkingCompletion() throws {
        try withDetachedViewport { viewport, parent in
            parent.setFrameSize(CGSize(width: 378, height: 218))
            viewport.frame = CGRect(x: 4, y: 4, width: 370, height: 210)
            viewport.needsLayout = true
            viewport.layoutSubtreeIfNeeded()
            viewport.prepareForResize()
            viewport.setFrameSize(CGSize(width: 310, height: 152))
            viewport.finishResize()

            for size in [
                CGSize(width: 378, height: 218), .init(width: 346, height: 190), .init(width: 318, height: 160),
            ] {
                parent.setFrameSize(size)
                viewport.needsLayout = true
                viewport.layoutSubtreeIfNeeded()
                let hosted = viewport.convert(viewport.hostingView.frame, to: parent)
                XCTAssertTrue(parent.bounds.contains(hosted))
                XCTAssertEqual(parent.bounds.maxY - hosted.maxY, 4, accuracy: 0.01)
                XCTAssertEqual(hosted.minX - parent.bounds.minX, 4, accuracy: 0.01)
            }
            XCTAssertEqual(viewport.hostingView.bounds.size, CGSize(width: 310, height: 152))
        }
    }

    func testViewportClipsToTheNativeParentBeforeMarginsAreAvailable() throws {
        try withDetachedViewport { viewport, parent in
            viewport.frame = CGRect(x: 4, y: 4, width: 370, height: 210)
            viewport.finishResize()
            viewport.layoutSubtreeIfNeeded()
            var hosted = viewport.convert(viewport.hostingView.frame, to: parent)
            XCTAssertTrue(parent.bounds.contains(hosted))
            XCTAssertEqual(hosted.maxX, parent.bounds.maxX, accuracy: 0.01)
            XCTAssertEqual(hosted.maxY, parent.bounds.maxY, accuracy: 0.01)

            viewport.frame.origin = CGPoint(x: 400, y: 400)
            viewport.needsLayout = true
            viewport.layoutSubtreeIfNeeded()
            XCTAssertEqual(viewport.visibleContentRect, .zero)
            XCTAssertEqual(viewport.hostingView.frame, .zero)

            viewport.frame.origin = CGPoint(x: 4, y: 4)
            parent.setFrameSize(CGSize(width: 378, height: 218))
            viewport.needsLayout = true
            viewport.layoutSubtreeIfNeeded()
            hosted = viewport.convert(viewport.hostingView.frame, to: parent)
            XCTAssertTrue(parent.bounds.contains(hosted))
            XCTAssertEqual(parent.bounds.maxY - hosted.maxY, 4, accuracy: 0.01)
            XCTAssertEqual(viewport.hostingView.bounds.size, CGSize(width: 370, height: 210))
        }
    }

    private func withDetachedViewport(_ body: (PopoverViewportView, NSView) throws -> Void) throws {
        let suite = "PopoverResizeTests.detached.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AppPopoverCoordinator(settings: AppSettings(defaults: defaults))
        coordinator.rebuildPopover()
        let viewport = try XCTUnwrap(coordinator.popover.contentViewController?.view as? PopoverViewportView)
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 318, height: 160))
        parent.addSubview(viewport)
        try body(viewport, parent)
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
                onOpenSettingsDestination: { _ in },
                onServiceSelected: { [weak coordinator] selected in
                    guard let coordinator else { return }
                    ServiceSelectionHelper.setActivePopoverService(selected, settings: settings)
                    coordinator.refreshSizeIfShown()
                },
                onLayoutChanged: { [weak coordinator] selected, _ in
                    guard let coordinator else { return }
                    coordinator.refreshSizeIfShown()
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
        anchorWindow.animationBehavior = .none
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        anchorWindow.contentView = anchor
        anchorWindow.orderBack(nil)
        anchorWindow.displayIfNeeded()
        defer {
            coordinator.close()
            anchorWindow.close()
        }
        popover.show(relativeTo: NSRect(x: 180, y: 50, width: 20, height: 20), of: anchor, preferredEdge: .minY)
        let popoverWindow = try XCTUnwrap(host.view.window)
        popoverWindow.displayIfNeeded()
        host.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(anchorWindow.isKeyWindow)
        XCTAssertFalse(anchorWindow.isMainWindow)
        XCTAssertFalse(popoverWindow.isKeyWindow)
        XCTAssertFalse(NSApplication.shared.isActive)
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
                coordinator.refreshSizeIfShown()
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
            coordinator.refreshSizeIfShown()
            _ = try observeTransition(host: host, duration: 0.45)

            settings.popoverCompact = true
            let target = coordinator.viewModel.layoutSpec(for: .claude, settings: settings).size
            coordinator.refreshSizeIfShown()

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

    func testDisplayItemChangesResizeTheExistingPopover() throws {
        for (compact, motion, pinned) in [(true, AppMotionMode.smooth, true), (false, .instant, false)] {
            try withNativePopover(
                service: .claude, transitionStyle: motion, compact: compact, pinned: pinned,
                connectSelectionCallbacks: true
            ) { settings, coordinator, host, _ in
                let originalPopover = coordinator.popover
                let original = coordinator.viewModel.layoutSpec(for: .claude, settings: settings)
                let baseline = try geometryBaseline(coordinator: coordinator, host: host)
                let items =
                    (compact
                    ? settings.compactPopoverItems(for: .claude)
                    : settings.popoverItems(for: .claude)).map {
                    PopoverItemConfig(id: $0.id, visible: $0.id == "weeklyLimit" ? false : $0.visible)
                }
                if compact {
                    settings.setCompactPopoverItems(items, for: .claude)
                } else {
                    settings.setPopoverItems(items, for: .claude)
                }
                let target = coordinator.viewModel.layoutSpec(for: .claude, settings: settings)
                XCTAssertLessThan(target.bodyContentHeight, original.bodyContentHeight)
                coordinator.refreshSizeIfShown()
                try waitForResize(coordinator: coordinator, host: host, target: target.size, baseline: baseline)
                XCTAssertTrue(coordinator.popover === originalPopover)
                assertFinalSize(host: host, popover: coordinator.popover, target: target.size)
            }
        }
    }

    func testServiceSelectionUsesCallbacksAndFinalNativeGeometry() throws {
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
                    let originalSelection = coordinator.viewModel.onServiceSelected
                    let originalLayout = coordinator.viewModel.onLayoutChanged
                    var selectedServices: [PopoverService] = []
                    var layoutServices: [PopoverService] = []
                    coordinator.viewModel.onServiceSelected = { selected in
                        selectedServices.append(selected)
                        originalSelection?(selected)
                    }
                    coordinator.viewModel.onLayoutChanged = { selected, reason in
                        layoutServices.append(selected)
                        originalLayout?(selected, reason)
                    }

                    let baseline = try geometryBaseline(coordinator: coordinator, host: host)
                    coordinator.requestServiceSelection(destination)
                    XCTAssertEqual(coordinator.viewModel.selectedService, destination)
                    let target = coordinator.viewModel.layoutSpec(for: destination, settings: settings).size
                    try waitForResize(coordinator: coordinator, host: host, target: target, baseline: baseline)
                    XCTAssertEqual(selectedServices, [destination])
                    XCTAssertEqual(layoutServices, [destination])
                    XCTAssertEqual(ServiceSelectionHelper.resolvedPopoverService(settings: settings), destination)
                    assertFinalSize(host: host, popover: coordinator.popover, target: target)
                    coordinator.viewModel.onServiceSelected = originalSelection
                    coordinator.viewModel.onLayoutChanged = originalLayout
                }
            }
        }
    }

    func testRapidServiceRequestsUseTheFinalSelectionImmediately() throws {
        try withNativePopover(service: .claude, connectSelectionCallbacks: true) { settings, coordinator, host, _ in
            let baseline = try geometryBaseline(coordinator: coordinator, host: host)
            coordinator.requestServiceSelection(.antigravity)
            coordinator.requestServiceSelection(.codex)
            XCTAssertEqual(coordinator.viewModel.selectedService, .codex)
            let target = coordinator.viewModel.layoutSpec(for: .codex, settings: settings).size
            try waitForResize(coordinator: coordinator, host: host, target: target, baseline: baseline)
            XCTAssertEqual(ServiceSelectionHelper.resolvedPopoverService(settings: settings), .codex)
            assertFinalSize(host: host, popover: coordinator.popover, target: target)
        }
    }

    func testQueuedSizeChangesApplyOnlyTheLatestCanonicalLayoutOutsideTheRequest() throws {
        try withNativePopover(service: .claude, transitionStyle: .instant) { settings, coordinator, host, _ in
            let originalSize = coordinator.popover.contentSize
            let baseline = try geometryBaseline(coordinator: coordinator, host: host)
            settings.popoverCompact = false
            coordinator.refreshSizeIfShown()
            XCTAssertEqual(coordinator.popover.contentSize, originalSize)

            let supersededTarget = coordinator.viewModel.layoutSpec(for: .claude, settings: settings).size
            coordinator.viewModel.selectService(.antigravity)
            coordinator.refreshSizeIfShown()
            XCTAssertEqual(coordinator.popover.contentSize, originalSize)
            let target = coordinator.viewModel.layoutSpec(for: .antigravity, settings: settings).size
            XCTAssertNotEqual(target, originalSize)
            XCTAssertNotEqual(target, supersededTarget)
            try waitForResize(coordinator: coordinator, host: host, target: target, baseline: baseline)
            assertFinalSize(host: host, popover: coordinator.popover, target: target)
        }
    }

    func testQueuedSizeUpdateCannotMutateARebuiltPopoverAfterClose() throws {
        try withNativePopover(service: .claude) { settings, coordinator, _, _ in
            settings.popoverCompact = false
            coordinator.refreshSizeIfShown()
            coordinator.close()
            coordinator.rebuildPopover()
            let replacement = coordinator.popover
            let size = replacement.contentSize
            coordinator.refreshSizeIfShown()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            XCTAssertTrue(coordinator.popover === replacement)
            XCTAssertFalse(replacement.isShown)
            XCTAssertEqual(replacement.contentSize, size)
        }
    }

    func testNativeResizeNotificationDrainsTheLatestInstantLayout() throws {
        try withNativePopover(service: .antigravity) { settings, coordinator, host, _ in
            let window = try XCTUnwrap(host.view.window)
            let baseline = try geometryBaseline(coordinator: coordinator, host: host)
            let initialFrame = window.frame
            let observation = NativeResizeObservation()
            observation.token = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: nil
            ) { _ in
                MainActor.assumeIsolated {
                    guard let token = observation.token else { return }
                    NotificationCenter.default.removeObserver(token)
                    observation.token = nil
                    observation.receivedCount += 1
                    observation.receivedFrame = window.frame
                    settings.motion.mode = .instant
                    settings.popoverCompact = true
                    coordinator.refreshSizeIfShown()
                }
            }
            defer {
                if let token = observation.token { NotificationCenter.default.removeObserver(token) }
                observation.token = nil
            }
            settings.popoverCompact = false
            coordinator.refreshSizeIfShown()
            XCTAssertTrue(waitUntil { observation.receivedCount == 1 })
            XCTAssertNotEqual(try XCTUnwrap(observation.receivedFrame).size, initialFrame.size)
            let target = coordinator.viewModel.layoutSpec(for: .antigravity, settings: settings).size
            try waitForResize(coordinator: coordinator, host: host, target: target, baseline: baseline)
            assertFinalSize(host: host, popover: coordinator.popover, target: target)
            XCTAssertEqual(observation.receivedCount, 1)
            XCTAssertFalse(coordinator.popover.animates)
        }
    }

    func testRepeatedTargetRequestsDoNotRestartTheNativeTransition() throws {
        try withNativePopover(service: .claude) { settings, coordinator, host, _ in
            settings.popoverCompact = false
            let target = coordinator.viewModel.layoutSpec(for: .claude, settings: settings).size
            coordinator.refreshSizeIfShown()
            let frames = try observeTransition(host: host, duration: 0.5) {
                coordinator.refreshSizeIfShown()
            }
            XCTAssertGreaterThan(Set(frames.map { Int($0.width.rounded()) }).count, 3)
            assertFinalSize(host: host, popover: coordinator.popover, target: target)
        }
    }

    func testRapidReversalServiceSwitchAndCloseCannotLeaveStaleViewportGeometry() throws {
        try withNativePopover(service: .antigravity) { settings, coordinator, host, _ in
            for (compact, wait) in [(false, 0.09), (true, 0.07), (false, 0.08)] {
                settings.popoverCompact = compact
                coordinator.refreshSizeIfShown()
                _ = try observeTransition(host: host, duration: wait)
            }
            coordinator.viewModel.selectService(.claude)
            let target = coordinator.viewModel.layoutSpec(for: .claude, settings: settings).size
            coordinator.refreshSizeIfShown()
            _ = try observeTransition(host: host, duration: 0.5)
            assertFinalSize(host: host, popover: coordinator.popover, target: target)
            settings.popoverCompact = true
            coordinator.refreshSizeIfShown()
            coordinator.close()
            coordinator.refreshSizeIfShown()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            XCTAssertFalse(coordinator.popover.isShown)
            XCTAssertLessThan(coordinator.popover.contentSize.width, 500)
        }
    }

    func testReducedMotionReachesTheFinalSizeWithoutAnAnimatedViewport() throws {
        try withNativePopover(service: .claude, reduceMotion: true) { settings, coordinator, host, _ in
            let baseline = try geometryBaseline(coordinator: coordinator, host: host)
            settings.popoverCompact = false
            let target = coordinator.viewModel.layoutSpec(for: .claude, settings: settings).size
            coordinator.refreshSizeIfShown()
            try waitForResize(coordinator: coordinator, host: host, target: target, baseline: baseline)
            assertFinalSize(host: host, popover: coordinator.popover, target: target)
            XCTAssertFalse(coordinator.popover.animates)
            let frames = try observeTransition(host: host, duration: 0.3)
            XCTAssertLessThanOrEqual(Set(frames.map { Int($0.width.rounded()) }).count, 2)
        }
    }

    func testInstantPreferenceAndChangingPreferenceReuseTheSameHost() throws {
        try withNativePopover(service: .antigravity, transitionStyle: .instant) { settings, coordinator, host, _ in
            let baseline = try geometryBaseline(coordinator: coordinator, host: host)
            let originalPopover = coordinator.popover
            settings.popoverCompact = false
            var target = coordinator.viewModel.layoutSpec(for: .antigravity, settings: settings).size
            coordinator.refreshSizeIfShown()
            try waitForResize(coordinator: coordinator, host: host, target: target, baseline: baseline)
            assertFinalSize(host: host, popover: coordinator.popover, target: target)
            XCTAssertFalse(coordinator.popover.animates)
            let instantFrames = try observeTransition(host: host, duration: 0.3)
            XCTAssertLessThanOrEqual(Set(instantFrames.map { Int($0.width.rounded()) }).count, 2)

            settings.motion.mode = .smooth
            settings.popoverCompact = true
            target = coordinator.viewModel.layoutSpec(for: .antigravity, settings: settings).size
            coordinator.refreshSizeIfShown()
            let smoothFrames = try observeTransition(host: host, duration: 0.45)
            XCTAssertGreaterThan(Set(smoothFrames.map { Int($0.width.rounded()) }).count, 3)
            assertFinalSize(host: host, popover: coordinator.popover, target: target)
            XCTAssertTrue(coordinator.popover === originalPopover)
            XCTAssertTrue(coordinator.popover.contentViewController === host)
        }
    }

    func testInstantResizeAtTheScreenEdgeKeepsTheLatestTargetVisible() throws {
        try withNativePopover(service: .antigravity, transitionStyle: .instant) { settings, coordinator, host, anchor in
            let window = try XCTUnwrap(host.view.window)
            let screen = try XCTUnwrap(window.screen)
            let anchorWindow = try XCTUnwrap(anchor.window)
            var positioningRect = coordinator.popover.positioningRect
            positioningRect.origin.x = anchor.bounds.maxX - positioningRect.width
            coordinator.popover.positioningRect = positioningRect
            anchorWindow.setFrameOrigin(
                CGPoint(x: screen.visibleFrame.maxX - anchor.bounds.width, y: anchorWindow.frame.minY))
            _ = try observeTransition(host: host, duration: 0.3)
            let top = window.frame.maxY

            for compact in [false, true, false] {
                settings.popoverCompact = compact
                let target = coordinator.viewModel.layoutSpec(for: .antigravity, settings: settings).size
                coordinator.refreshSizeIfShown()
                _ = try observeTransition(host: host, duration: 0.3)
                assertFinalSize(host: host, popover: coordinator.popover, target: target)
                XCTAssertGreaterThanOrEqual(window.frame.minX, screen.visibleFrame.minX)
                XCTAssertLessThanOrEqual(window.frame.maxX, screen.visibleFrame.maxX + 1)
                XCTAssertEqual(window.frame.maxY, top, accuracy: 2)
            }
        }
    }

    func testSwitchingToInstantDuringResizeSettlesTheLatestTarget() throws {
        try withNativePopover(service: .antigravity) { settings, coordinator, host, _ in
            let baseline = try geometryBaseline(coordinator: coordinator, host: host)
            settings.popoverCompact = false
            coordinator.refreshSizeIfShown()
            _ = try observeTransition(host: host, duration: 0.08)
            settings.motion.mode = .instant
            settings.popoverCompact = true
            let target = coordinator.viewModel.layoutSpec(for: .antigravity, settings: settings).size
            coordinator.refreshSizeIfShown()
            try waitForResize(coordinator: coordinator, host: host, target: target, baseline: baseline)
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
                coordinator.refreshSizeIfShown()
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
            coordinator.refreshSizeIfShown()
            coordinator.popover.performClose(nil)
            coordinator.refreshSizeIfShown()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            XCTAssertFalse(coordinator.popover.isShown)
            XCTAssertLessThan(host.preferredContentSize.width, 500)
        }
    }

    func testResizeDuringInitialPresentationKeepsTheFinalViewportAligned() throws {
        try withNativePopover(service: .claude, settleInitialPresentation: false) { settings, coordinator, host, _ in
            settings.popoverCompact = false
            let target = coordinator.viewModel.layoutSpec(for: .claude, settings: settings).size
            coordinator.refreshSizeIfShown()
            _ = try observeTransition(host: host, duration: 0.5)
            assertFinalSize(host: host, popover: coordinator.popover, target: target)
        }
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

    private func waitForResize(
        coordinator: AppPopoverCoordinator, host: NSViewController, target: CGSize,
        baseline: GeometryBaseline
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
            return abs(coordinator.popover.contentSize.width - target.width) <= 0.5
                && abs(coordinator.popover.contentSize.height - target.height) <= 0.5
                && abs(window.frame.height - target.height - baseline.windowChromeHeight) <= 1
                && abs(viewport.hostingView.bounds.width - target.width) <= 0.5
                && abs(viewport.hostingView.bounds.height - target.height) <= 0.5
        }
        XCTAssertTrue(settled, "The final native popover geometry must complete")
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
            let geometry =
                "window=\(String(describing: viewport.window?.frame)) parent=\(String(describing: viewport.superview?.bounds)) viewport=\(viewport.frame) hosted=\(viewport.hostingView.frame) target=\(target)"
            XCTAssertEqual(viewport.hostingView.bounds.width, target.width, accuracy: 1, geometry)
            XCTAssertEqual(viewport.hostingView.bounds.height, target.height, accuracy: 1, geometry)
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
                transport: .cliUsageReport, endpointOwner: .managed, accountIdentity: identity,
                capability: .groupedQuotaSummary, processIdentity: nil), fetchedAt: now)
        return AntigravityRuntimeSnapshot(
            readiness: .ready,
            settings: .init(connection: .default, display: .default), presentationState: .ready(quota),
            quotaPresentation: .content(
                AntigravityQuotaPresentationMapper.map(
                    snapshot: quota, settings: .default, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)),
            managedRuntimeAvailability: .available(displayPath: "fixture/agy"),
            lastAttemptAt: now, lastSuccessfulAt: now)
    }

}

@MainActor
private final class NativeResizeObservation {
    var token: NSObjectProtocol?
    var receivedCount = 0
    var receivedFrame: CGRect?
}
