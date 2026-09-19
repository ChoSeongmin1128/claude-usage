import AppKit
import SwiftUI

private struct PopoverDisplayEditorHostView: View {
    @ObservedObject var settings: AppSettings
    let service: PopoverService
    @State private var mode: PopoverDisplayEditorMode

    init(
        settings: AppSettings,
        service: PopoverService,
        initialMode: PopoverDisplayEditorMode
    ) {
        self.settings = settings
        self.service = service
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        PopoverDisplayEditorView(
            settings: settings,
            service: service,
            selectedMode: $mode
        )
    }
}

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

    private var displayEditorPopover: NSPopover?
    private var pendingServiceSelection: PopoverService?
    private var pendingCompactValue: Bool?
    private var deferredSize: CGSize?
    private var isCompletingDisplayEditorClose = false

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
        pendingServiceSelection = nil
        pendingCompactValue = nil
        deferredSize = nil
        closeDisplayEditor(animated: false)
        let wasResizing = isResizing
        invalidate()
        popover.animates = !wasResizing && animates(.popoverPresentation)
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
        pendingServiceSelection = nil
        pendingCompactValue = nil
        deferredSize = nil
        closeDisplayEditor(animated: false)
        invalidate()

        viewModel.isDesignIntroductionPresented =
            !settings.menuBarDesignIntroductionDismissed
            && settings.menuBarDesign == .classic
        let newPopover = NSPopover()
        let popoverView = PopoverView(
            viewModel: viewModel,
            settings: settings,
            fillsViewport: true,
            onTargetSizeChange: { [weak self] size in
                self?.refreshSizeIfShown(size: size)
            },
            onServiceSelectionRequest: { [weak self] service in
                self?.requestServiceSelection(service)
            },
            onCompactToggleRequest: { [weak self] in
                self?.requestCompactToggle()
            },
            onDisplayEditorRequest: { [weak self] anchor, service, mode in
                self?.presentDisplayEditor(
                    anchor: anchor,
                    service: service,
                    mode: mode
                )
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

    func refreshSizeIfShown(size: CGSize) {
        guard acceptsSizeUpdates, popover.isShown else { return }
        if displayEditorIsActive || isCompletingDisplayEditorClose {
            deferredSize = size
            return
        }
        applyPopoverSizeIfNeeded(size: size)
    }

    func requestServiceSelection(_ service: PopoverService) {
        guard service != viewModel.selectedService else { return }
        if displayEditorIsActive || isCompletingDisplayEditorClose {
            pendingServiceSelection = service
            closeDisplayEditor(animated: false)
            return
        }
        commitServiceSelection(service)
    }

    func requestCompactToggle() {
        let requestedValue = !(pendingCompactValue ?? settings.popoverCompact)
        if displayEditorIsActive || isCompletingDisplayEditorClose {
            pendingCompactValue = requestedValue
            closeDisplayEditor(animated: false)
            return
        }
        commitCompactValue(requestedValue)
    }

    func presentDisplayEditor(
        anchor: NSView,
        service: PopoverService,
        mode: PopoverDisplayEditorMode
    ) {
        guard acceptsSizeUpdates, popover.isShown, service != .antigravity else { return }

        if displayEditorIsActive {
            if service == viewModel.selectedService {
                closeDisplayEditor()
                return
            }
            pendingServiceSelection = service
            closeDisplayEditor(animated: false)
            return
        }

        let editor = NSPopover()
        editor.behavior = .transient
        editor.animates = animates(.popoverPresentation)
        editor.delegate = self
        editor.contentViewController = NSHostingController(
            rootView: PopoverDisplayEditorHostView(
                settings: settings,
                service: service,
                initialMode: mode
            )
        )
        displayEditorPopover = editor
        editor.show(
            relativeTo: anchor.bounds,
            of: anchor,
            preferredEdge: .maxY
        )
    }

    func closeDisplayEditor(animated: Bool = true) {
        guard let editor = displayEditorPopover else { return }
        editor.animates = animated && animates(.popoverPresentation)
        if editor.isShown {
            editor.close()
        } else {
            displayEditorPopover = nil
            finishDisplayEditorCloseIfNeeded()
        }
    }

    var displayEditorIsActive: Bool {
        guard let displayEditorPopover else { return false }
        return displayEditorPopover.isShown || isCompletingDisplayEditorClose
    }

    func popoverWillClose(_ notification: Notification) {
        guard let closingPopover = notification.object as? NSPopover else { return }
        if closingPopover === popover {
            // close() has already chosen the safe closing policy and invalidated this session.
            // Only a native outside-click close needs to choose it here.
            if acceptsSizeUpdates {
                popover.animates = !isResizing && animates(.popoverPresentation)
            }
            pendingServiceSelection = nil
            pendingCompactValue = nil
            deferredSize = nil
            closeDisplayEditor(animated: false)
            invalidate()
            return
        }

        if closingPopover === displayEditorPopover {
            isCompletingDisplayEditorClose = true
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover,
            closedPopover === displayEditorPopover
        else {
            return
        }
        displayEditorPopover = nil
        finishDisplayEditorCloseIfNeeded()
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

    private func finishDisplayEditorCloseIfNeeded() {
        defer {
            isCompletingDisplayEditorClose = false
        }
        guard acceptsSizeUpdates, popover.isShown else {
            pendingServiceSelection = nil
            pendingCompactValue = nil
            deferredSize = nil
            return
        }

        if let service = pendingServiceSelection {
            pendingServiceSelection = nil
            commitServiceSelection(service)
        }
        if let compact = pendingCompactValue {
            pendingCompactValue = nil
            commitCompactValue(compact)
        }

        if let size = deferredSize {
            deferredSize = nil
            applyPopoverSizeIfNeeded(size: size)
        }
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

    private func applyPopoverSizeIfNeeded(size: CGSize) {
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
                self.finishResize(revision: revision)
            }
        }
        if !shouldAnimate {
            finishResize(revision: revision)
        }
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
