import AppKit
import QuartzCore

@MainActor
final class AppPopoverCoordinator: NSObject, NSPopoverDelegate {
    let viewModel = PopoverViewModel()
    private let settings: AppSettings
    private(set) var popover = NSPopover()
    private let reduceMotion: () -> Bool
    private var resizeRevision = 0
    private var sizeRequestRevision = 0
    private var pendingSizeUpdate: Task<Void, Never>?
    private var isResizing = false
    private var acceptsSizeUpdates = false
    private weak var observedWindow: NSWindow?
    private var windowObservationTokens: [NSObjectProtocol] = []

    init(
        settings: AppSettings = .shared,
        reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    ) {
        self.settings = settings
        self.reduceMotion = reduceMotion
        super.init()
    }

    func configure(
        initialService: PopoverService,
        onRefreshService: @escaping (PopoverService) -> Void,
        onOpenSettingsDestination: @escaping (SettingsDestination) -> Void,
        onServiceSelected: @escaping (PopoverService) -> Void,
        onLayoutChanged: @escaping (PopoverService, PopoverLayoutRefreshReason) -> Void,
        onPinChanged: @escaping (PopoverService, Bool) -> Void,
        onStartClaudeLogin: (() -> Void)? = nil
    ) {
        viewModel.onRefreshService = onRefreshService
        viewModel.onOpenSettingsDestination = onOpenSettingsDestination
        viewModel.onServiceSelected = onServiceSelected
        viewModel.onLayoutChanged = onLayoutChanged
        viewModel.onPinChanged = onPinChanged
        viewModel.onStartClaudeLogin = onStartClaudeLogin
        viewModel.selectedService = initialService

        rebuildPopover()
    }

    func close() {
        let wasResizing = isResizing || pendingSizeUpdate != nil
        invalidate()
        popover.animates = !wasResizing && animates(.popoverPresentation)
        popover.close()
    }

    func invalidate() {
        pendingSizeUpdate?.cancel()
        pendingSizeUpdate = nil
        sizeRequestRevision += 1
        resizeRevision += 1
        isResizing = false
        acceptsSizeUpdates = false
        endWindowDiagnostics()
    }

    func applyBehavior(isPinned: Bool) {
        popover.behavior = isPinned ? .applicationDefined : .transient
    }

    func rebuildPopover() {
        invalidate()

        viewModel.isDesignIntroductionPresented =
            !settings.menuBarDesignIntroductionDismissed
            && settings.menuBarDesign == .classic
        let newPopover = NSPopover()
        let popoverView = PopoverView(
            viewModel: viewModel,
            settings: settings,
            fillsViewport: true,
            onLayoutSizeChange: { [weak self, weak newPopover] in
                guard let self, let newPopover, self.popover === newPopover else { return }
                self.refreshSizeIfShown()
            },
            onServiceSelectionRequest: { [weak self] service in
                self?.requestServiceSelection(service)
            },
            onCompactToggleRequest: { [weak self] in
                self?.requestCompactToggle()
            }
        )
        let hostingController = NSViewController()
        hostingController.view = PopoverViewportView(rootView: popoverView)

        newPopover.contentViewController = hostingController
        newPopover.animates = animates(.popoverPresentation)
        newPopover.delegate = self
        popover = newPopover
        acceptsSizeUpdates = true
    }

    func refreshSizeIfShown() {
        guard acceptsSizeUpdates, popover.isShown else { return }
        sizeRequestRevision += 1
        scheduleSizeUpdateIfNeeded()
    }

    private func scheduleSizeUpdateIfNeeded() {
        guard pendingSizeUpdate == nil, acceptsSizeUpdates, popover.isShown else { return }
        let requestedPopover = popover
        pendingSizeUpdate = Task { @MainActor [weak self, weak requestedPopover] in
            guard let self, let requestedPopover, !Task.isCancelled,
                self.popover === requestedPopover
            else { return }
            guard self.acceptsSizeUpdates, requestedPopover.isShown else {
                self.pendingSizeUpdate = nil
                return
            }
            let requestRevision = self.sizeRequestRevision
            let size = self.viewModel.layoutSpec(for: self.viewModel.selectedService, settings: self.settings).size
            self.applyPopoverSizeIfNeeded(size: size, to: requestedPopover)
            guard !Task.isCancelled, self.popover === requestedPopover else { return }
            self.pendingSizeUpdate = nil
            if self.sizeRequestRevision != requestRevision {
                self.scheduleSizeUpdateIfNeeded()
            }
        }
    }

    func requestServiceSelection(_ service: PopoverService) {
        guard service != viewModel.selectedService else { return }
        commitServiceSelection(service)
    }

    func requestCompactToggle() {
        commitCompactValue(!settings.popoverCompact)
    }

    func popoverWillClose(_ notification: Notification) {
        guard let closingPopover = notification.object as? NSPopover,
            closingPopover === popover
        else { return }
        if acceptsSizeUpdates {
            popover.animates = !(isResizing || pendingSizeUpdate != nil) && animates(.popoverPresentation)
        }
        invalidate()
    }

    func beginWindowDiagnosticsIfNeeded() {
        guard PopoverGeometryDiagnostics.isEnabled else { return }
        guard let window = popover.contentViewController?.view.window else { return }
        guard observedWindow !== window else { return }

        endWindowDiagnostics()
        observedWindow = window

        let center = NotificationCenter.default
        windowObservationTokens = [
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.logWindowFrame("window-did-move")
                }
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.logWindowFrame("window-did-resize")
                }
            },
        ]
        logWindowFrame("window-observing-started")
    }

    private func commitServiceSelection(_ service: PopoverService) {
        guard service != viewModel.selectedService else { return }
        viewModel.selectService(service)
        viewModel.requestLayoutRefresh(
            for: service,
            reason: .serviceSelection
        )
    }

    private func commitCompactValue(_ value: Bool) {
        guard settings.popoverCompact != value else { return }
        settings.popoverCompact = value
        viewModel.requestLayoutRefresh(reason: .compactToggle)
    }

    private func animates(_ category: AppMotionCategory) -> Bool {
        settings.motion.allows(category, reduceMotion: reduceMotion())
    }

    private func applyPopoverSizeIfNeeded(size: CGSize, to popover: NSPopover) {
        let screenMaxWidth = max(
            300,
            (popover.contentViewController?.view.window?.screen?.visibleFrame.width ?? NSScreen.main?.visibleFrame.width
                ?? 1440) - 80)
        let targetSize = NSSize(
            width: min(size.width, screenMaxWidth),
            height: size.height
        )

        let changed =
            abs(popover.contentSize.width - targetSize.width) > 0.5
            || abs(popover.contentSize.height - targetSize.height) > 0.5
        logGeometry(
            "apply-size current=\(describe(size: popover.contentSize)) target=\(describe(size: targetSize)) changed=\(changed)"
        )
        guard changed else { return }
        let shouldAnimate = animates(.popoverResize)
        let instantFrame = shouldAnimate ? nil : nativeFrame(forContentSize: targetSize, popover: popover)
        popover.animates = shouldAnimate
        if !isResizing {
            (popover.contentViewController?.view as? PopoverViewportView)?.prepareForResize()
        }
        resizeRevision += 1
        let revision = resizeRevision
        isResizing = true
        // Update the explicit controller size and native container in one transaction.
        // PopoverViewportView keeps SwiftUI inside the visible area during the transition.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shouldAnimate ? AppDesign.Motion.popoverResizeDuration : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = shouldAnimate || instantFrame != nil
            popover.contentViewController?.preferredContentSize = targetSize
            popover.contentSize = targetSize
            if let instantFrame {
                popover.contentViewController?.view.window?.animator().setFrame(instantFrame, display: true)
            }
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.popover === popover, self.resizeRevision == revision, popover.isShown else {
                    return
                }
                self.finishResize(revision: revision)
            }
        }
        if !shouldAnimate {
            finishResize(revision: revision)
        }
    }

    private func nativeFrame(forContentSize size: CGSize, popover: NSPopover) -> CGRect? {
        guard let viewport = popover.contentViewController?.view as? PopoverViewportView,
            let window = viewport.window,
            let visibleSize = viewport.nativeVisibleContentSize
        else { return nil }
        let currentFrame = window.frame
        let chromeWidth = currentFrame.width - visibleSize.width
        let chromeHeight = currentFrame.height - visibleSize.height
        guard chromeWidth >= 0, chromeHeight >= 0 else { return nil }
        let frameSize = CGSize(width: size.width + chromeWidth, height: size.height + chromeHeight)
        var frame = CGRect(
            x: currentFrame.midX - frameSize.width / 2, y: currentFrame.maxY - frameSize.height,
            width: frameSize.width, height: frameSize.height)
        if let screen = window.screen {
            let visible = screen.visibleFrame
            frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
        }
        return frame
    }

    private func finishResize(revision: Int) {
        guard resizeRevision == revision, popover.isShown else { return }
        isResizing = false
        popover.animates = animates(.popoverPresentation)
        (popover.contentViewController?.view as? PopoverViewportView)?.finishResize()
    }

    private func logGeometry(_ message: String) {
        PopoverGeometryDiagnostics.log("PopoverCoordinator \(message)")
    }

    private func describe(size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    private func logWindowFrame(_ label: String) {
        guard let window = observedWindow else { return }
        PopoverGeometryDiagnostics.log(
            "PopoverCoordinator \(label) frame=\(NSStringFromRect(window.frame)) contentSize=\(describe(size: popover.contentSize))"
        )
    }

    private func endWindowDiagnostics() {
        let center = NotificationCenter.default
        windowObservationTokens.forEach { center.removeObserver($0) }
        windowObservationTokens.removeAll()
        observedWindow = nil
    }
}
