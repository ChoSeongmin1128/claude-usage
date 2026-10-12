import AppKit
import SwiftUI
import XCTest
@testable import ClaudeUsage

@MainActor
final class ServiceStatusPanelContentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testShowsClaudeThenCodexEvenWhenEverythingIsNormal() throws {
        let content = try XCTUnwrap(
            ServiceStatusPanelContent.make(
                statuses: [.codex: normalStatus(), .claude: normalStatus()], now: now))

        XCTAssertEqual(content.services.map(\.kind), [.claude, .codex])
        XCTAssertEqual(content.services.map(\.name), ["Claude", "Codex"])
        XCTAssertEqual(content.services.map(\.stateText), ["정상", "정상"])
        XCTAssertEqual(content.services.map(\.tone), [.normal, .normal])
        XCTAssertTrue(content.services.allSatisfy { $0.rows.isEmpty && $0.overflowText == nil })
    }

    func testNeverReadServiceIsOmittedAndNoServiceMeansNoPanel() {
        XCTAssertEqual(
            ServiceStatusPanelContent.make(statuses: [.codex: normalStatus()], now: now)?.services.map(\.kind),
            [.codex])
        XCTAssertNil(ServiceStatusPanelContent.make(statuses: [:], now: now))
        XCTAssertNil(ServiceStatusPanelContent.make(statuses: [.antigravity: normalStatus()], now: now))
    }

    func testStateTextAndToneFollowEffectiveIndicator() throws {
        let cases: [(ProviderSystemStatus, String, ServiceStatusPanelContent.Tone)] = [
            (ProviderSystemStatus(indicator: .minor, description: "", pageUpdatedAt: nil), "일부 성능 저하", .minor),
            (ProviderSystemStatus(indicator: .major, description: "", pageUpdatedAt: nil), "서비스 장애", .major),
            (ProviderSystemStatus(indicator: .critical, description: "", pageUpdatedAt: nil), "심각한 장애", .major),
            (
                ProviderSystemStatus(
                    indicator: .none, description: "", activeIncidents: [incident("Billing delays")],
                    pageUpdatedAt: nil),
                "일부 성능 저하", .minor
            ),
        ]
        for (status, stateText, tone) in cases {
            let service = try XCTUnwrap(
                ServiceStatusPanelContent.make(statuses: [.claude: status], now: now)?.services.first)
            XCTAssertEqual(service.stateText, stateText)
            XCTAssertEqual(service.tone, tone)
        }
    }

    func testIncidentRowsKeepInterpreterOrderWithoutOmission() throws {
        let incidents = (1...5).map { index in
            incident(
                "Incident \(index)", components: index == 1 ? ["claude.ai", "Claude Code"] : [],
                updatedAt: now.addingTimeInterval(-Double(index) * 300), isPriority: index == 1)
        }
        let status = ProviderSystemStatus(
            indicator: .major, description: "", activeIncidents: incidents,
            componentIssues: [.init(name: "claude.ai", indicator: .major)], pageUpdatedAt: nil)

        let service = try XCTUnwrap(
            ServiceStatusPanelContent.make(statuses: [.claude: status], now: now)?.services.first)

        XCTAssertEqual(
            service.rows.map(\.title), ["Incident 1", "Incident 2", "Incident 3", "Incident 4", "Incident 5"])
        XCTAssertEqual(service.rows.first?.detail, "claude.ai, Claude Code · 조사 중 · 5분 전 업데이트")
        XCTAssertEqual(service.rows[1].detail, "조사 중 · 10분 전 업데이트")
        XCTAssertNil(service.overflowText)
    }

    func testIncidentDetailOmitsMissingParts() throws {
        let status = ProviderSystemStatus(
            indicator: .minor,
            description: "",
            activeIncidents: [
                incident("Just now", updatedAt: now.addingTimeInterval(-20)),
                incident("No time", components: ["Images"], updatedAt: nil),
                incident("Nothing known", updatedAt: nil),
            ],
            pageUpdatedAt: nil)

        let rows = try XCTUnwrap(
            ServiceStatusPanelContent.make(statuses: [.codex: status], now: now)?.services.first?.rows)

        XCTAssertEqual(rows.map(\.detail), ["조사 중 · 방금 업데이트", "Images · 조사 중", "조사 중"])
    }

    func testDegradedComponentsWithoutIncidentsBecomeRows() throws {
        let issues: [ProviderSystemStatus.ComponentIssue] = [
            .init(name: "Compliance API", indicator: .minor),
            .init(name: "Login", indicator: .critical),
            .init(name: "Images", indicator: .major),
            .init(name: "Batch", indicator: .minor),
        ]
        let status = ProviderSystemStatus(
            indicator: .critical, description: "", componentIssues: issues, pageUpdatedAt: nil)

        let service = try XCTUnwrap(
            ServiceStatusPanelContent.make(statuses: [.codex: status], now: now)?.services.first)

        XCTAssertEqual(
            service.rows,
            [
                .init(title: "Compliance API 일부 성능 저하"),
                .init(title: "Login 심각한 장애"),
                .init(title: "Images 서비스 장애"),
                .init(title: "Batch 일부 성능 저하"),
            ])
        XCTAssertNil(service.overflowText)
    }

    func testUncoveredDegradedComponentsStayVisibleBesideIncidents() throws {
        let status = ProviderSystemStatus(
            indicator: .minor, description: "", activeIncidents: [incident("Delayed Costs data")],
            componentIssues: [.init(name: "Compliance API", indicator: .minor)], pageUpdatedAt: nil)

        let service = try XCTUnwrap(
            ServiceStatusPanelContent.make(statuses: [.codex: status], now: now)?.services.first)

        XCTAssertEqual(service.rows.map(\.title), ["Delayed Costs data", "Compliance API 일부 성능 저하"])
    }

    func testRealSummariesBuildBothBlocks() throws {
        let claude = try XCTUnwrap(
            StatusPageInterpreter.parseStatus(data: try statusFixture("claude-summary.json"), priorityRule: .claude))
        let codex = try XCTUnwrap(
            StatusPageInterpreter.parseStatus(data: try statusFixture("openai-summary.json"), priorityRule: .codex))
        let capturedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-11T15:30:00Z"))

        let content = try XCTUnwrap(
            ServiceStatusPanelContent.make(statuses: [.claude: claude, .codex: codex], now: capturedAt))

        let visibleServices = content.services.map { service in
            var rows = service.rows
            for index in rows.indices { rows[index].incidentIdentity = nil }
            return ServiceStatusPanelContent.Service(
                kind: service.kind, name: service.name, tone: service.tone,
                stateText: service.stateText, rows: rows, overflowText: service.overflowText)
        }
        XCTAssertEqual(
            visibleServices,
            [
                .init(
                    kind: .claude, name: "Claude", tone: .minor, stateText: "일부 성능 저하",
                    rows: [
                        .init(
                            title: "Elevated errors on platform.claude.com",
                            components: "Claude Console (platform.claude.com)", updatedText: "3일 전 업데이트",
                            phase: "복구 확인 중")
                    ],
                    overflowText: nil),
                .init(
                    kind: .codex, name: "Codex", tone: .minor, stateText: "일부 성능 저하",
                    rows: [
                        .init(
                            title: "Delayed Costs data in the Compliance API", updatedText: "1일 전 업데이트",
                            phase: "복구 확인 중"),
                        .init(title: "Compliance API 일부 성능 저하"),
                    ],
                    overflowText: nil),
            ])
        XCTAssertEqual(
            content.accessibilitySummary,
            "서비스 상태: Claude 일부 성능 저하, Elevated errors on platform.claude.com. "
                + "Codex 일부 성능 저하, Delayed Costs data in the Compliance API, Compliance API 일부 성능 저하")
    }

    func testAccessibilitySummaryIncludesEveryIncidentAndNormalServices() throws {
        let incidents = (1...4).map { incident("Incident \($0)") }
        let content = try XCTUnwrap(
            ServiceStatusPanelContent.make(
                statuses: [
                    .claude: normalStatus(),
                    .codex: ProviderSystemStatus(
                        indicator: .minor, description: "", activeIncidents: incidents, pageUpdatedAt: nil),
                ],
                now: now))

        XCTAssertEqual(
            content.accessibilitySummary,
            "서비스 상태: Claude 정상. Codex 일부 성능 저하, Incident 1, Incident 2, Incident 3, Incident 4")
    }

    func testIncidentIdentitySurvivesTitleChangesAndReordering() throws {
        func incident(_ title: String, id: String) -> ProviderSystemStatus.IncidentSummary {
            .init(
                name: title, status: "investigating", impact: "minor", shortlink: nil,
                latestUpdateBody: nil, latestUpdateAt: now, affectedComponents: [], id: id)
        }
        let before = try XCTUnwrap(
            ServiceStatusPanelContent.make(statuses: [
                .claude: .init(
                    indicator: .minor, description: "", activeIncidents: [incident("Same title", id: "first")],
                    pageUpdatedAt: nil)
            ]))
        let after = try XCTUnwrap(
            ServiceStatusPanelContent.make(statuses: [
                .claude: .init(
                    indicator: .minor, description: "",
                    activeIncidents: [incident("Same title", id: "second"), incident("Renamed title", id: "first")],
                    pageUpdatedAt: nil)
            ]))
        XCTAssertEqual(before.services[0].rows[0].id, after.services[0].rows[1].id)
        XCTAssertNotEqual(after.services[0].rows[0].id, after.services[0].rows[1].id)
    }

    func testPanelViewHasFixedWidthAndGrowsWithRows() throws {
        func fittingSize(_ status: ProviderSystemStatus) throws -> NSSize {
            let content = try XCTUnwrap(
                ServiceStatusPanelContent.make(statuses: [.claude: normalStatus(), .codex: status], now: now))
            return NSHostingView(rootView: ServiceStatusPanelView(content: content)).fittingSize
        }
        let normal = try fittingSize(normalStatus())
        let longTitle = String(repeating: "Elevated errors affecting multiple products ", count: 3)
        let busy = try fittingSize(
            ProviderSystemStatus(
                indicator: .major, description: "",
                activeIncidents: [
                    incident(longTitle, components: ["Codex in ChatGPT Desktop"], updatedAt: now),
                    incident("Second", updatedAt: now),
                    incident("Third", updatedAt: now),
                    incident("Fourth", updatedAt: now),
                ],
                pageUpdatedAt: nil))

        XCTAssertEqual(normal.width, ServiceStatusPanelView.width)
        XCTAssertEqual(busy.width, ServiceStatusPanelView.width)
        XCTAssertGreaterThan(normal.height, 40)
        XCTAssertGreaterThan(busy.height, normal.height + 60)
        XCTAssertGreaterThan(busy.height, 100)  // View contains all rows; the panel viewport caps screen height.
    }

    private func normalStatus() -> ProviderSystemStatus {
        ProviderSystemStatus(indicator: .none, description: "All Systems Operational", pageUpdatedAt: nil)
    }

    private func incident(
        _ name: String,
        components: [String] = [],
        updatedAt: Date? = nil,
        isPriority: Bool = false
    ) -> ProviderSystemStatus.IncidentSummary {
        ProviderSystemStatus.IncidentSummary(
            name: name, status: "investigating", impact: "minor", shortlink: nil, latestUpdateBody: nil,
            latestUpdateAt: updatedAt, affectedComponents: components, isPriority: isPriority)
    }
}

@MainActor
final class ServiceStatusHoverControllerTests: XCTestCase {
    func testInputCoordinatesResolveTheItemWhenClientWindowIsAProxy() throws {
        let frame = try XCTUnwrap(
            ServiceStatusPanelAnchor.itemFrame(
                localPointer: NSPoint(x: 20, y: 11), screenPointer: NSPoint(x: 2020, y: 1429),
                bounds: NSRect(x: 0, y: 0, width: 70, height: 22)))
        XCTAssertEqual(frame, NSRect(x: 2000, y: 1418, width: 70, height: 22))
        XCTAssertTrue(ServiceStatusPanelAnchor.isMenuBarFrame(frame, on: NSRect(x: 0, y: 0, width: 2560, height: 1440)))
        XCTAssertFalse(
            ServiceStatusPanelAnchor.isMenuBarFrame(
                NSRect(x: 8, y: -11, width: 70, height: 22), on: NSRect(x: 0, y: 0, width: 2560, height: 1440)))
    }

    func testInputAnchorPreservesNegativeDisplayAndNonzeroLocalBounds() throws {
        let frame = try XCTUnwrap(
            ServiceStatusPanelAnchor.itemFrame(
                localPointer: NSPoint(x: 30, y: 21), screenPointer: NSPoint(x: -200, y: 899),
                bounds: NSRect(x: 10, y: 10, width: 70, height: 22)))
        XCTAssertEqual(frame, NSRect(x: -220, y: 888, width: 70, height: 22))
        XCTAssertTrue(
            ServiceStatusPanelAnchor.isMenuBarFrame(frame, on: NSRect(x: -1440, y: 0, width: 1440, height: 910)))
    }

    func testInputAnchorRejectsInvalidOrUnrelatedCoordinates() {
        let bounds = NSRect(x: 0, y: 0, width: 70, height: 22)
        XCTAssertNil(
            ServiceStatusPanelAnchor.itemFrame(
                localPointer: NSPoint(x: 100, y: 11), screenPointer: NSPoint(x: 2020, y: 1429), bounds: bounds))
        XCTAssertNil(
            ServiceStatusPanelAnchor.itemFrame(
                localPointer: .zero, screenPointer: NSPoint(x: CGFloat.infinity, y: 1429), bounds: bounds))
        XCTAssertFalse(
            ServiceStatusPanelAnchor.isMenuBarFrame(.zero, on: NSRect(x: 0, y: 0, width: 2560, height: 1440)))
    }

    func testMenuBarFrameAllowsNormalVerticalPadding() {
        XCTAssertTrue(
            ServiceStatusPanelAnchor.isMenuBarFrame(
                NSRect(x: 2005, y: 1412.5, width: 223.5, height: 24),
                on: NSRect(x: 0, y: 0, width: 2560, height: 1440), menuBarHeight: 28))
    }

    func testEventAnchorExpiresWhenBoundsWindowOrScreensChange() {
        let window = NSWindow()
        let otherWindow = NSWindow()
        window.isReleasedWhenClosed = false
        otherWindow.isReleasedWhenClosed = false
        let bounds = NSRect(x: 0, y: 0, width: 70, height: 22)
        let screens = [NSRect(x: 0, y: 0, width: 2560, height: 1440)]
        let sample = ServiceStatusPanelEventAnchorSample(
            frame: NSRect(x: 2000, y: 1418, width: 70, height: 22), bounds: bounds,
            window: window, screenFrames: screens)
        XCTAssertTrue(sample.isCurrent(bounds: bounds, window: window, screenFrames: screens))
        XCTAssertFalse(
            sample.isCurrent(bounds: NSRect(x: 0, y: 0, width: 90, height: 22), window: window, screenFrames: screens))
        XCTAssertFalse(sample.isCurrent(bounds: bounds, window: otherWindow, screenFrames: screens))
        XCTAssertFalse(sample.isCurrent(bounds: bounds, window: window, screenFrames: []))
        window.close()
        otherWindow.close()
    }

    private let anchor = ServiceStatusPanelAnchor(
        itemFrame: NSRect(x: 1000, y: 875, width: 60, height: 25),
        visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875))

    func testShowsOnlyAfterDelay() {
        let (controller, presenter, scheduler) = makeController()

        controller.pointerEntered()

        XCTAssertEqual(scheduler.delays, [ServiceStatusHoverController.showDelay])
        XCTAssertEqual(ServiceStatusHoverController.showDelay, 0.5)
        XCTAssertFalse(presenter.isVisible)
        scheduler.fireAll()
        XCTAssertTrue(presenter.isVisible)
        XCTAssertEqual(presenter.shown.count, 1)
        XCTAssertEqual(presenter.shown.first?.anchor, anchor)
    }

    func testLeavingBeforeDelayCancelsAndLeavingAfterShowHidesImmediately() {
        let (controller, presenter, scheduler) = makeController()

        controller.pointerEntered()
        controller.pointerExited()
        XCTAssertEqual(scheduler.cancelledCount, 1)
        XCTAssertFalse(controller.hasPendingShow)
        scheduler.fireAll()
        XCTAssertTrue(presenter.shown.isEmpty)

        controller.pointerEntered()
        scheduler.fireAll()
        XCTAssertTrue(presenter.isVisible)
        controller.pointerExited()
        XCTAssertFalse(presenter.isVisible)
    }

    func testClickHidesAndDoesNotReturnUntilPointerEntersAgain() {
        let (controller, presenter, scheduler) = makeController()
        controller.pointerEntered()
        scheduler.fireAll()

        controller.hide()

        XCTAssertFalse(presenter.isVisible)
        XCTAssertFalse(controller.hasPendingShow)
        controller.contentDidChange()
        XCTAssertFalse(presenter.isVisible)
        XCTAssertEqual(presenter.shown.count, 1)
    }

    func testClickDuringDelayCancelsPendingShow() {
        let (controller, presenter, scheduler) = makeController()
        controller.pointerEntered()

        controller.hide()
        scheduler.fireAll()

        XCTAssertTrue(presenter.shown.isEmpty)
        XCTAssertEqual(scheduler.cancelledCount, 1)
    }

    func testNeverShowsWhilePopoverOrMenuIsOpen() {
        let (controller, presenter, scheduler) = makeController()
        var suppressed = true
        controller.isSuppressed = { suppressed }

        controller.pointerEntered()
        XCTAssertTrue(scheduler.delays.isEmpty)

        suppressed = false
        controller.pointerEntered()
        suppressed = true
        scheduler.fireAll()
        XCTAssertTrue(presenter.shown.isEmpty)
    }

    func testNoContentMeansNoPanel() {
        let (controller, presenter, scheduler) = makeController()
        controller.contentProvider = { nil }

        controller.pointerEntered()
        scheduler.fireAll()

        XCTAssertTrue(presenter.shown.isEmpty)
    }

    func testStatusChangeWhileShownRedrawsOrHides() throws {
        let (controller, presenter, scheduler) = makeController()
        var content = try XCTUnwrap(panelContent(indicator: .none))
        controller.contentProvider = { content }
        controller.pointerEntered()
        scheduler.fireAll()

        content = try XCTUnwrap(panelContent(indicator: .major))
        controller.contentDidChange()
        XCTAssertEqual(presenter.shown.last?.content.services.first?.stateText, "서비스 장애")
        XCTAssertTrue(presenter.isVisible)

        controller.contentProvider = { nil }
        controller.contentDidChange()
        XCTAssertFalse(presenter.isVisible)
    }

    func testContentChangeDoesNotOpenHiddenPanel() {
        let (controller, presenter, _) = makeController()

        controller.contentDidChange()

        XCTAssertTrue(presenter.shown.isEmpty)
    }

    func testPanelSitsUnderItemLeftEdgeInsideVisibleFrame() {
        let size = NSSize(width: 300, height: 120)

        XCTAssertEqual(
            ServiceStatusPanelPlacement.frame(size: size, anchor: anchor),
            NSRect(x: 1000, y: 875 - ServiceStatusPanelPlacement.gap - 120, width: 300, height: 120))

        let nearRightEdge = ServiceStatusPanelAnchor(
            itemFrame: NSRect(x: 1400, y: 875, width: 30, height: 25), visibleFrame: anchor.visibleFrame)
        XCTAssertEqual(ServiceStatusPanelPlacement.frame(size: size, anchor: nearRightEdge).maxX, 1440)

        let secondScreen = ServiceStatusPanelAnchor(
            itemFrame: NSRect(x: -200, y: 1075, width: 30, height: 25),
            visibleFrame: NSRect(x: -100, y: 900, width: 1280, height: 175))
        let clamped = ServiceStatusPanelPlacement.frame(size: NSSize(width: 300, height: 400), anchor: secondScreen)
        XCTAssertEqual(clamped.minX, -100)
        XCTAssertEqual(clamped.minY, 900)
        XCTAssertEqual(clamped.maxY, 1075 - ServiceStatusPanelPlacement.gap)
    }

    func testPointerCanCrossBridgeAndStayInPanelButOutsideCloses() {
        let (controller, presenter, scheduler) = makeController()
        controller.pointerEntered()
        scheduler.fireAll()
        presenter.visibleFrame = ServiceStatusPanelPlacement.frame(
            size: NSSize(width: 296, height: 120), anchor: anchor)
        controller.pointerMoved(to: NSPoint(x: anchor.itemFrame.midX, y: anchor.itemFrame.minY - 2))
        XCTAssertTrue(presenter.isVisible)
        controller.pointerMoved(to: NSPoint(x: presenter.visibleFrame!.midX, y: presenter.visibleFrame!.midY))
        XCTAssertTrue(presenter.isVisible)
        controller.pointerMoved(to: NSPoint(x: presenter.visibleFrame!.maxX + 5, y: presenter.visibleFrame!.midY))
        XCTAssertFalse(presenter.isVisible)
    }

    func testScrollAnchorKeepsSameItemWhenEarlierRowsGrowOrMove() {
        let before: [String: CGRect] = [
            "first": CGRect(x: 0, y: 0, width: 200, height: 30),
            "selected": CGRect(x: 0, y: 30, width: 200, height: 50),
        ]
        let captured = HoverScrollAnchor.capture(top: 42, frames: before)
        XCTAssertEqual(captured, HoverScrollAnchor(id: "selected", offset: 12))
        let after = ["selected": CGRect(x: 0, y: 100, width: 200, height: 70)]
        XCTAssertEqual(captured?.restoredTop(in: after), 112)
        XCTAssertNil(captured?.restoredTop(in: [:]))
    }

    private func makeController() -> (ServiceStatusHoverController, FakePanelPresenter, ManualHoverScheduler) {
        let presenter = FakePanelPresenter()
        let scheduler = ManualHoverScheduler()
        let controller = ServiceStatusHoverController(presenter: presenter, scheduler: scheduler)
        let content = panelContent(indicator: .none)
        controller.contentProvider = { content }
        controller.anchorProvider = { [anchor] in anchor }
        return (controller, presenter, scheduler)
    }

    private func panelContent(indicator: StatusIndicator) -> ServiceStatusPanelContent? {
        ServiceStatusPanelContent.make(
            statuses: [.claude: ProviderSystemStatus(indicator: indicator, description: "", pageUpdatedAt: nil)])
    }
}

@MainActor
private final class FakePanelPresenter: ServiceStatusPanelPresenting {
    private(set) var isVisible = false
    var visibleFrame: NSRect?
    private(set) var shown: [(content: ServiceStatusPanelContent, anchor: ServiceStatusPanelAnchor)] = []

    func show(_ content: ServiceStatusPanelContent, anchor: ServiceStatusPanelAnchor) {
        shown.append((content, anchor))
        isVisible = true
    }

    func hide() {
        isVisible = false
    }
}

@MainActor
private final class ManualHoverScheduler: ServiceStatusHoverScheduling {
    private final class Token: ServiceStatusHoverCancellable {
        var isCancelled = false
        let onCancel: () -> Void

        init(onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
        }

        func cancel() {
            guard !isCancelled else { return }
            isCancelled = true
            onCancel()
        }
    }

    private(set) var delays: [TimeInterval] = []
    private(set) var cancelledCount = 0
    private var pending: [(token: Token, action: @MainActor () -> Void)] = []

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any ServiceStatusHoverCancellable {
        delays.append(delay)
        let token = Token { [weak self] in self?.cancelledCount += 1 }
        pending.append((token, action))
        return token
    }

    /// 취소된 예약은 실제 Timer처럼 실행하지 않는다.
    func fireAll() {
        let due = pending
        pending.removeAll()
        for entry in due where !entry.token.isCancelled {
            entry.action()
        }
    }
}

private func statusFixture(_ name: String) throws -> Data {
    try Data(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/StatusPage/\(name)"))
}
