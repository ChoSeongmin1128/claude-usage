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

    private func assertNativeResize(service: PopoverService) throws {
        let suite = "PopoverResizeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.setProviderEnabled(true, for: .claude)
        settings.setProviderEnabled(true, for: .codex)
        settings.setProviderEnabled(true, for: .antigravity)
        settings.popoverCompact = true
        let coordinator = AppPopoverCoordinator(settings: settings)
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
        let anchorWindow = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 400, height: 100),
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
        popover.show(relativeTo: NSRect(x: 180, y: 50, width: 20, height: 20), of: anchor, preferredEdge: .maxY)
        host.view.window?.alphaValue = 0
        XCTAssertTrue(popover.isShown)

        for compact in [false, true, false] {
            settings.popoverCompact = compact
            let target = coordinator.viewModel.layoutSpec(for: service, settings: settings).size
            coordinator.refreshSizeIfShown(size: target)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            host.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(popover.contentSize.width, target.width, accuracy: 0.5)
            XCTAssertEqual(popover.contentSize.height, target.height, accuracy: 0.5)
            XCTAssertEqual(host.preferredContentSize.width, target.width, accuracy: 0.5)
            XCTAssertEqual(host.preferredContentSize.height, target.height, accuracy: 0.5)
            XCTAssertEqual(host.view.bounds.width, target.width, accuracy: 0.5)
            XCTAssertEqual(host.view.bounds.height, target.height, accuracy: 0.5)
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            let image = NSImage(size: host.view.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Native \(service.rawValue) popover after \(compact ? "collapse" : "expansion")"
            attachment.lifetime = .keepAlways
            add(attachment)
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
