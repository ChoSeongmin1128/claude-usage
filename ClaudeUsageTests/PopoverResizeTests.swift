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
        _ body: (AppSettings, AppPopoverCoordinator, NSViewController, NSView) throws -> Void
    ) throws {
        let suite = "PopoverResizeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.setProviderEnabled(true, for: .claude)
        settings.setProviderEnabled(true, for: .codex)
        settings.setProviderEnabled(true, for: .antigravity)
        settings.popoverCompact = true
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
        coordinator.viewModel.selectService(service)
        coordinator.rebuildPopover()
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
