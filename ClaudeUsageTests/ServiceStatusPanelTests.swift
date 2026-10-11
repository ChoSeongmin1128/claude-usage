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

    func testIncidentRowsKeepInterpreterOrderAndCapWithOverflow() throws {
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

        XCTAssertEqual(service.rows.map(\.title), ["Incident 1", "Incident 2", "Incident 3"])
        XCTAssertEqual(service.rows.first?.detail, "claude.ai, Claude Code · 5분 전 업데이트")
        XCTAssertEqual(service.rows[1].detail, "10분 전 업데이트")
        XCTAssertEqual(service.overflowText, "+2건")
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

        XCTAssertEqual(rows.map(\.detail), ["방금 업데이트", "Images", nil])
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
            ])
        XCTAssertEqual(service.overflowText, "+1개")
    }

    func testIncidentsReplaceDegradedComponentRows() throws {
        let status = ProviderSystemStatus(
            indicator: .minor, description: "", activeIncidents: [incident("Delayed Costs data")],
            componentIssues: [.init(name: "Compliance API", indicator: .minor)], pageUpdatedAt: nil)

        let service = try XCTUnwrap(
            ServiceStatusPanelContent.make(statuses: [.codex: status], now: now)?.services.first)

        XCTAssertEqual(service.rows.map(\.title), ["Delayed Costs data"])
    }

    func testRealSummariesBuildBothBlocks() throws {
        let claude = try XCTUnwrap(
            StatusPageInterpreter.parseStatus(data: try statusFixture("claude-summary.json"), priorityRule: .claude))
        let codex = try XCTUnwrap(
            StatusPageInterpreter.parseStatus(data: try statusFixture("openai-summary.json"), priorityRule: .codex))
        let capturedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-11T15:30:00Z"))

        let content = try XCTUnwrap(
            ServiceStatusPanelContent.make(statuses: [.claude: claude, .codex: codex], now: capturedAt))

        XCTAssertEqual(
            content.services,
            [
                .init(
                    kind: .claude, name: "Claude", tone: .minor, stateText: "일부 성능 저하",
                    rows: [
                        .init(
                            title: "Elevated errors on platform.claude.com",
                            components: "Claude Console (platform.claude.com)", updatedText: "3일 전 업데이트")
                    ],
                    overflowText: nil),
                .init(
                    kind: .codex, name: "Codex", tone: .minor, stateText: "일부 성능 저하",
                    rows: [.init(title: "Delayed Costs data in the Compliance API", updatedText: "1일 전 업데이트")],
                    overflowText: nil),
            ])
        XCTAssertEqual(
            content.accessibilitySummary,
            "서비스 상태: Claude 일부 성능 저하, Elevated errors on platform.claude.com. "
                + "Codex 일부 성능 저하, Delayed Costs data in the Compliance API")
    }

    func testAccessibilitySummaryIncludesOverflowAndNormalServices() throws {
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
            "서비스 상태: Claude 정상. Codex 일부 성능 저하, Incident 1, Incident 2, Incident 3, +1건")
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
        XCTAssertLessThan(busy.height, 400)
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
