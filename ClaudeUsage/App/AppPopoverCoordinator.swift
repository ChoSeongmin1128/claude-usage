import AppKit
import SwiftUI

@MainActor
final class AppPopoverCoordinator: NSObject, NSPopoverDelegate {
    let viewModel = PopoverViewModel()
    private let settings: AppSettings
    private(set) var popover = NSPopover()
    private let reduceMotion: () -> Bool
    private var resizeRevision = 0
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
        onOpenSettingsForService: @escaping (PopoverService) -> Void,
        onOpenSettingsPanel: @escaping (SettingsProviderPanel) -> Void,
        onServiceSelected: @escaping (PopoverService) -> Void,
        onLayoutChanged: @escaping (PopoverService, PopoverLayoutRefreshReason) -> Void,
        onPinChanged: @escaping (PopoverService, Bool) -> Void,
        onStartClaudeLogin: (() -> Void)? = nil
    ) {
        viewModel.onRefreshService = onRefreshService
        viewModel.onOpenSettingsForService = onOpenSettingsForService
        viewModel.onOpenSettingsPanel = onOpenSettingsPanel
        viewModel.onServiceSelected = onServiceSelected
        viewModel.onLayoutChanged = onLayoutChanged
        viewModel.onPinChanged = onPinChanged
        viewModel.onStartClaudeLogin = onStartClaudeLogin
        viewModel.selectedService = initialService

        rebuildPopover()
    }

    func close() {
        let wasResizing = isResizing
        invalidate()
        if wasResizing { popover.animates = false }
        popover.close()
    }

    func invalidate() {
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

        let newPopover = NSPopover()
        let popoverView = PopoverView(
            viewModel: viewModel, settings: settings, fillsViewport: true,
            onTargetSizeChange: { [weak self] size in self?.refreshSizeIfShown(size: size) })
        let hostingController = NSViewController()
        hostingController.view = PopoverViewportView(rootView: popoverView)

        newPopover.contentViewController = hostingController
        newPopover.animates = !reduceMotion()
        newPopover.delegate = self
        popover = newPopover
        acceptsSizeUpdates = true
    }

    func refreshSizeIfShown(size: CGSize) {
        guard acceptsSizeUpdates, popover.isShown else { return }
        applyPopoverSizeIfNeeded(size: size)
    }

    func popoverWillClose(_ notification: Notification) {
        guard notification.object as? NSPopover === popover else { return }
        let wasResizing = isResizing
        invalidate()
        if wasResizing { popover.animates = false }
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

    private func applyPopoverSizeIfNeeded(size: CGSize) {
        let screenMaxWidth = max(
            300,
            (popover.contentViewController?.view.window?.screen?.visibleFrame.width ?? NSScreen.main?.visibleFrame.width
                ?? 1440) - 80)
        let targetSize = NSSize(
            width: min(size.width, screenMaxWidth),
            height: size.height
        )

        let changed = abs(popover.contentSize.width - targetSize.width) > 0.5 ||
            abs(popover.contentSize.height - targetSize.height) > 0.5
        logGeometry(
            "apply-size current=\(describe(size: popover.contentSize)) target=\(describe(size: targetSize)) changed=\(changed)"
        )
        guard changed else { return }
        let shouldAnimate = !reduceMotion()
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
            context.allowsImplicitAnimation = shouldAnimate
            popover.contentViewController?.preferredContentSize = targetSize
            popover.contentSize = targetSize
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.resizeRevision == revision, self.popover.isShown else { return }
                self.isResizing = false
                (self.popover.contentViewController?.view as? PopoverViewportView)?.finishResize()
            }
        }
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
