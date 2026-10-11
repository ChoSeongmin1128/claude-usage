import AppKit

struct ServiceStatusPanelAnchor: Equatable {
    /// 메뉴바 아이템의 화면 좌표
    let itemFrame: NSRect
    let visibleFrame: NSRect
}

enum ServiceStatusPanelPlacement {
    static let gap: CGFloat = 4

    /// 아이템 왼쪽 아래에 붙이고 화면의 보이는 영역 안으로 당긴다.
    static func frame(size: NSSize, anchor: ServiceStatusPanelAnchor) -> NSRect {
        let visible = anchor.visibleFrame
        let x = max(visible.minX, min(anchor.itemFrame.minX, visible.maxX - size.width))
        let top = min(anchor.itemFrame.minY - gap, visible.maxY)
        let y = max(visible.minY, top - size.height)
        return NSRect(x: x, y: y, width: size.width, height: min(size.height, top - visible.minY))
    }
}

@MainActor
protocol ServiceStatusPanelPresenting: AnyObject {
    var isVisible: Bool { get }
    func show(_ content: ServiceStatusPanelContent, anchor: ServiceStatusPanelAnchor)
    func hide()
}

@MainActor
protocol ServiceStatusHoverCancellable {
    func cancel()
}

@MainActor
protocol ServiceStatusHoverScheduling {
    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any ServiceStatusHoverCancellable
}

struct MainRunLoopHoverScheduler: ServiceStatusHoverScheduling {
    private struct TimerToken: ServiceStatusHoverCancellable {
        let timer: Timer

        func cancel() {
            timer.invalidate()
        }
    }

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any ServiceStatusHoverCancellable {
        let timer = Timer.scheduledOnMainRunLoop(interval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                action()
            }
        }
        return TimerToken(timer: timer)
    }
}

/// 메뉴바 아이템에 0.5초 머물면 서비스 상태 패널을 띄운다.
/// 벗어나거나 누르면 바로 닫고, 다시 들어오기 전까지는 띄우지 않는다.
@MainActor
final class ServiceStatusHoverController {
    static let showDelay: TimeInterval = 0.5

    var contentProvider: () -> ServiceStatusPanelContent? = { nil }
    /// 팝오버나 메뉴가 열려 있으면 참이다.
    var isSuppressed: () -> Bool = { false }
    var anchorProvider: () -> ServiceStatusPanelAnchor? = { nil }

    private let presenter: any ServiceStatusPanelPresenting
    private let scheduler: any ServiceStatusHoverScheduling
    private var pendingShow: (any ServiceStatusHoverCancellable)?
    private var tracker: StatusItemHoverTracker?
    private weak var trackedButton: NSStatusBarButton?
    private var trackingArea: NSTrackingArea?
    private var mouseDownMonitor: Any?

    init(
        presenter: any ServiceStatusPanelPresenting,
        scheduler: any ServiceStatusHoverScheduling = MainRunLoopHoverScheduler()
    ) {
        self.presenter = presenter
        self.scheduler = scheduler
    }

    var hasPendingShow: Bool {
        pendingShow != nil
    }

    func attach(to button: NSStatusBarButton) {
        detach()
        let tracker = StatusItemHoverTracker(
            onEnter: { [weak self] in self?.pointerEntered() },
            onExit: { [weak self] in self?.pointerExited() }
        )
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: tracker,
            userInfo: nil
        )
        button.addTrackingArea(area)
        self.tracker = tracker
        trackingArea = area
        trackedButton = button
        anchorProvider = { [weak button] in button.flatMap(Self.anchor(for:)) }
        // 버튼 동작은 손을 뗄 때 오므로 누르는 순간에 닫아야 누른 채 대기 시간이 끝나도 패널이 뜨지 않는다.
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            if let window = event.window, window === self?.trackedButton?.window {
                self?.hide()
            }
            return event
        }
    }

    func detach() {
        hide()
        if let trackingArea {
            trackedButton?.removeTrackingArea(trackingArea)
        }
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
        }
        mouseDownMonitor = nil
        trackingArea = nil
        tracker = nil
        trackedButton = nil
        anchorProvider = { nil }
    }

    func pointerEntered() {
        cancelPendingShow()
        guard !isSuppressed() else { return }
        pendingShow = scheduler.schedule(after: Self.showDelay) { [weak self] in
            self?.showIfAllowed()
        }
    }

    func pointerExited() {
        hide()
    }

    func hide() {
        cancelPendingShow()
        if presenter.isVisible {
            presenter.hide()
        }
    }

    /// 떠 있는 동안 상태가 바뀌면 새 내용으로 다시 그린다.
    func contentDidChange() {
        guard presenter.isVisible else { return }
        guard !isSuppressed(), let content = contentProvider(), let anchor = anchorProvider() else {
            presenter.hide()
            return
        }
        presenter.show(content, anchor: anchor)
    }

    private func showIfAllowed() {
        pendingShow = nil
        guard !isSuppressed(), let content = contentProvider(), let anchor = anchorProvider() else {
            return
        }
        presenter.show(content, anchor: anchor)
    }

    private func cancelPendingShow() {
        pendingShow?.cancel()
        pendingShow = nil
    }

    private static func anchor(for button: NSStatusBarButton) -> ServiceStatusPanelAnchor? {
        guard let window = button.window, let screen = window.screen ?? NSScreen.main else { return nil }
        let itemFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return ServiceStatusPanelAnchor(itemFrame: itemFrame, visibleFrame: screen.visibleFrame)
    }
}

private final class StatusItemHoverTracker: NSResponder {
    private let onEnter: () -> Void
    private let onExit: () -> Void

    init(onEnter: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.onEnter = onEnter
        self.onExit = onExit
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(onEnter:onExit:)") }

    override func mouseEntered(with event: NSEvent) {
        onEnter()
    }

    override func mouseExited(with event: NSEvent) {
        onExit()
    }
}
