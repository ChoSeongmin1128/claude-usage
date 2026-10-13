import AppKit

struct ServiceStatusPanelAnchor: Equatable {
    /// 메뉴바 아이템의 화면 좌표
    let itemFrame: NSRect
    let visibleFrame: NSRect

    /// An input event relates the remote item's local coordinates to the actual screen position.
    /// This remains usable when the status item's client window is only a zero-height proxy.
    static func itemFrame(localPointer: NSPoint, screenPointer: NSPoint, bounds: NSRect) -> NSRect? {
        guard bounds.width > 0, bounds.height > 0,
            localPointer.x >= bounds.minX, localPointer.x <= bounds.maxX,
            localPointer.y >= bounds.minY, localPointer.y <= bounds.maxY,
            [localPointer.x, localPointer.y, screenPointer.x, screenPointer.y].allSatisfy(\.isFinite)
        else { return nil }
        return NSRect(
            x: screenPointer.x - (localPointer.x - bounds.minX),
            y: screenPointer.y - (localPointer.y - bounds.minY),
            width: bounds.width, height: bounds.height)
    }

    static func isMenuBarFrame(
        _ frame: NSRect, on screen: NSRect, menuBarHeight: CGFloat = NSStatusBar.system.thickness
    ) -> Bool {
        guard !frame.isEmpty,
            [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
        else { return false }
        let band = NSRect(
            x: screen.minX, y: screen.maxY - menuBarHeight,
            width: screen.width, height: menuBarHeight)
        return band.contains(NSPoint(x: frame.midX, y: frame.midY))
    }
}

@MainActor
struct ServiceStatusPanelEventAnchorSample {
    let frame: NSRect
    let bounds: NSRect
    let window: NSWindow
    let screenFrames: [NSRect]

    func isCurrent(bounds: NSRect, window: NSWindow?, screenFrames: [NSRect]) -> Bool {
        self.bounds == bounds && self.window === window && self.screenFrames == screenFrames
    }
}

enum ServiceStatusPanelPlacement {
    static let gap: CGFloat = 4

    /// 아이템 왼쪽 아래에 붙이고 화면의 보이는 영역 안으로 당긴다.
    static func frame(size: NSSize, anchor: ServiceStatusPanelAnchor) -> NSRect {
        let visible = anchor.visibleFrame
        let width = min(size.width, visible.width)
        let x = max(visible.minX, min(anchor.itemFrame.minX, visible.maxX - width))
        let top = min(anchor.itemFrame.minY - gap, visible.maxY)
        let y = max(visible.minY, top - size.height)
        return NSRect(x: x, y: y, width: width, height: max(0, min(size.height, top - visible.minY)))
    }
}

enum ServiceStatusHoverRegion {
    /// Keep only the item, panel, and narrow vertical connection between them.
    static func contains(_ point: NSPoint, item: NSRect, panel: NSRect) -> Bool {
        if item.contains(point) || panel.contains(point) { return true }
        let left = max(item.minX, panel.minX)
        let right = min(item.maxX, panel.maxX)
        guard right > left else { return false }
        let bridge = NSRect(
            x: left, y: panel.maxY, width: right - left,
            height: max(0, item.minY - panel.maxY))
        return bridge.contains(point)
    }
}

@MainActor
protocol ServiceStatusPanelPresenting: AnyObject {
    var isVisible: Bool { get }
    var visibleFrame: NSRect? { get }
    func show(_ content: ServiceStatusPanelContent, anchor: ServiceStatusPanelAnchor)
    func hide()
}

extension ServiceStatusPanelPresenting {
    var visibleFrame: NSRect? { nil }
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

/// 메뉴바 아이템에 설정한 시간 동안 머물면 서비스 상태 패널을 띄운다.
/// 벗어나거나 누르면 바로 닫고, 다시 들어오기 전까지는 띄우지 않는다.
@MainActor
final class ServiceStatusHoverController {
    var showDelayProvider: () -> TimeInterval = { MenuBarHoverDelay.defaultValue }

    var contentProvider: () -> ServiceStatusPanelContent? = { nil }
    /// 팝오버나 메뉴가 열려 있으면 참이다.
    var isSuppressed: () -> Bool = { false }
    var anchorProvider: () -> ServiceStatusPanelAnchor? = { nil }
    var pointerLocationProvider: () -> NSPoint = { NSEvent.mouseLocation }

    private let presenter: any ServiceStatusPanelPresenting
    private let scheduler: any ServiceStatusHoverScheduling
    private var pendingShow: (any ServiceStatusHoverCancellable)?
    private var tracker: StatusItemHoverTracker?
    private weak var trackedButton: NSStatusBarButton?
    private var trackingArea: NSTrackingArea?
    private var mouseDownMonitor: Any?
    private var outsideMouseDownMonitor: Any?
    private var pointerTimer: Timer?
    private var eventAnchorSample: ServiceStatusPanelEventAnchorSample?

    init(
        presenter: any ServiceStatusPanelPresenting,
        scheduler: any ServiceStatusHoverScheduling = MainRunLoopHoverScheduler()
    ) {
        self.presenter = presenter
        self.scheduler = scheduler
    }

    isolated deinit { detach() }

    var hasPendingShow: Bool {
        pendingShow != nil
    }

    func attach(to button: NSStatusBarButton) {
        detach()
        let tracker = StatusItemHoverTracker(
            onEnter: { [weak self] event in
                self?.captureItemFrame(from: event)
                self?.pointerEntered()
            },
            onExit: { [weak self] in self?.pointerExited() },
            onMove: { [weak self] event in self?.captureItemFrame(from: event) }
        )
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: tracker,
            userInfo: nil
        )
        button.addTrackingArea(area)
        self.tracker = tracker
        trackingArea = area
        trackedButton = button
        anchorProvider = { [weak self, weak button] in
            guard let button else { return nil }
            let sample = self?.eventAnchorSample
            let eventFrame =
                sample?.isCurrent(
                    bounds: button.bounds, window: button.window, screenFrames: NSScreen.screens.map(\.frame)) == true
                ? sample?.frame : nil
            return Self.anchor(for: button, eventItemFrame: eventFrame)
        }
        // 버튼 동작은 손을 뗄 때 오므로 누르는 순간에 닫아야 누른 채 대기 시간이 끝나도 패널이 뜨지 않는다.
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            if let window = event.window, window === self?.trackedButton?.window {
                self?.hide()
            }
            return event
        }
        outsideMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hide() }
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
        if let outsideMouseDownMonitor { NSEvent.removeMonitor(outsideMouseDownMonitor) }
        outsideMouseDownMonitor = nil
        mouseDownMonitor = nil
        trackingArea = nil
        tracker = nil
        trackedButton = nil
        eventAnchorSample = nil
        anchorProvider = { nil }
    }

    func pointerEntered() {
        cancelPendingShow()
        guard !isSuppressed() else { return }
        pendingShow = scheduler.schedule(after: MenuBarHoverDelay.normalized(showDelayProvider())) { [weak self] in
            self?.showIfAllowed()
        }
    }

    func pointerExited() {
        if presenter.isVisible { pointerMoved(to: pointerLocationProvider()) } else { hide() }
    }

    func pointerMoved(to point: NSPoint) {
        guard presenter.isVisible, let panel = presenter.visibleFrame, let anchor = anchorProvider(),
            !isSuppressed(), ServiceStatusHoverRegion.contains(point, item: anchor.itemFrame, panel: panel)
        else { hide(); return }
    }

    private func startPointerTracking() {
        pointerTimer?.invalidate()
        pointerTimer = Timer.scheduledOnMainRunLoop(interval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pointerMoved(to: self.pointerLocationProvider())
            }
        }
    }

    func hide() {
        eventAnchorSample = nil
        pointerTimer?.invalidate()
        pointerTimer = nil
        cancelPendingShow()
        if presenter.isVisible {
            presenter.hide()
        }
    }

    /// 떠 있는 동안 상태가 바뀌면 새 내용으로 다시 그린다.
    func contentDidChange() {
        guard presenter.isVisible else { return }
        guard !isSuppressed(), let content = contentProvider(), let anchor = anchorProvider() else {
            hide()
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
        startPointerTracking()
    }

    private func cancelPendingShow() {
        pendingShow?.cancel()
        pendingShow = nil
    }

    private func captureItemFrame(from event: NSEvent) {
        guard let button = trackedButton, let window = button.window, event.window === window,
            let cgEvent = event.cgEvent, let primary = NSScreen.screens.first
        else {
            eventAnchorSample = nil
            return
        }
        let localPointer = button.convert(event.locationInWindow, from: nil)
        // Both positions must belong to the same event, never to the current pointer sample.
        let screenPointer = NSPoint(x: cgEvent.location.x, y: primary.frame.maxY - cgEvent.location.y)
        guard
            let frame = ServiceStatusPanelAnchor.itemFrame(
                localPointer: localPointer, screenPointer: screenPointer, bounds: button.bounds)
        else {
            eventAnchorSample = nil
            return
        }
        eventAnchorSample = ServiceStatusPanelEventAnchorSample(
            frame: frame, bounds: button.bounds, window: window, screenFrames: NSScreen.screens.map(\.frame))
    }

    private static func anchor(for button: NSStatusBarButton, eventItemFrame: NSRect?) -> ServiceStatusPanelAnchor? {
        let convertedFrame = button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
        let candidates = [button.accessibilityFrame(), convertedFrame, eventItemFrame].compactMap { $0 }
        for frame in candidates {
            if let screen = NSScreen.screens.first(where: {
                ServiceStatusPanelAnchor.isMenuBarFrame(frame, on: $0.frame)
            }) {
                return ServiceStatusPanelAnchor(itemFrame: frame, visibleFrame: screen.visibleFrame)
            }
        }
        return nil
    }
}

private final class StatusItemHoverTracker: NSResponder {
    private let onEnter: (NSEvent) -> Void
    private let onExit: () -> Void
    private let onMove: (NSEvent) -> Void

    init(onEnter: @escaping (NSEvent) -> Void, onExit: @escaping () -> Void, onMove: @escaping (NSEvent) -> Void) {
        self.onEnter = onEnter
        self.onExit = onExit
        self.onMove = onMove
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(onEnter:onExit:)") }

    override func mouseEntered(with event: NSEvent) {
        onEnter(event)
    }

    override func mouseExited(with event: NSEvent) {
        onExit()
    }

    override func mouseMoved(with event: NSEvent) {
        onMove(event)
    }
}
