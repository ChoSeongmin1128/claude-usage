import AppKit
import SwiftUI

@MainActor
final class AppPopoverCoordinator {
    let viewModel = PopoverViewModel()
    private(set) var popover: NSPopover
    private let makePopover: () -> NSPopover
    private let reduceMotion: () -> Bool
    private weak var observedWindow: NSWindow?
    private var windowObservationTokens: [NSObjectProtocol] = []

    init(
        makePopover: @escaping () -> NSPopover = { NSPopover() },
        reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    ) {
        self.makePopover = makePopover
        self.reduceMotion = reduceMotion
        self.popover = makePopover()
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
        endWindowDiagnostics()
        popover.close()
    }

    func invalidate() {
        endWindowDiagnostics()
    }

    func applyBehavior(isPinned: Bool) {
        popover.behavior = isPinned ? .applicationDefined : .transient
    }

    func rebuildPopover() {
        endWindowDiagnostics()

        let newPopover = makePopover()
        let popoverView = PopoverView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: popoverView)
        // The coordinator owns the window size. Automatic preferred sizing would race
        // with contentSize when SwiftUI switches between compact and standard layouts.
        hostingController.sizingOptions = []

        newPopover.contentViewController = hostingController
        newPopover.animates = !reduceMotion()
        popover = newPopover
    }

    func refreshSizeIfShown(size: CGSize) {
        guard popover.isShown else { return }
        // Update in the same event as the content change, before SwiftUI's next layout.
        // AppKit owns the native transition; there is no delayed second resize.
        popover.animates = !reduceMotion()
        applyPopoverSizeIfNeeded(size: size)
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
        if changed {
            popover.contentSize = targetSize
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
