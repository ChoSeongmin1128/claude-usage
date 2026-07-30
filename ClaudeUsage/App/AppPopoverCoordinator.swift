import AppKit
import SwiftUI

@MainActor
final class AppPopoverCoordinator {
    let viewModel = PopoverViewModel()
    private(set) var popover = NSPopover()
    private var presentationRevision: Int = 0
    private weak var observedWindow: NSWindow?
    private var windowObservationTokens: [NSObjectProtocol] = []
    private var pendingResizeWorkItem: DispatchWorkItem?

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

        rebuildPopover(for: initialService)
    }

    func close() {
        presentationRevision += 1
        pendingResizeWorkItem?.cancel()
        pendingResizeWorkItem = nil
        endWindowDiagnostics()
        popover.close()
    }

    func invalidate() {
        presentationRevision += 1
        pendingResizeWorkItem?.cancel()
        pendingResizeWorkItem = nil
    }

    func applyBehavior(isPinned: Bool) {
        popover.behavior = isPinned ? .applicationDefined : .transient
    }

    func rebuildPopover(for service: PopoverService) {
        pendingResizeWorkItem?.cancel()
        pendingResizeWorkItem = nil
        endWindowDiagnostics()
        presentationRevision += 1

        let newPopover = NSPopover()
        let popoverView = PopoverView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: popoverView)
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = [.preferredContentSize]
        }

        newPopover.contentViewController = hostingController
        newPopover.animates = true
        popover = newPopover
    }

    func refreshSizeIfShown(size: CGSize) {
        guard popover.isShown else { return }
        pendingResizeWorkItem?.cancel()
        let revision = presentationRevision
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.presentationRevision == revision else { return }
            guard self.popover.isShown else { return }
            self.logGeometry("refresh-size requested=\(describe(size: size))")
            self.applyPopoverSizeIfNeeded(size: size, force: false)
        }
        pendingResizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    /// 고정 너비 기반으로 콘텐츠 높이만 측정합니다.
    /// width는 layoutSpec에서 결정된 고정값(296/368pt)을 그대로 사용하고,
    /// fittingSize.width는 하위 뷰의 maxWidth: .infinity에 의해 팽창하므로 무시합니다.
    func measuredHostedContentSize() -> CGSize? {
        guard let contentView = popover.contentViewController?.view else { return nil }
        contentView.layoutSubtreeIfNeeded()

        let width = popover.contentViewController?.preferredContentSize.width
            ?? popover.contentSize.width
        guard width > 0 else { return nil }

        let fitting = contentView.fittingSize
        let height = fitting.height > 0 ? fitting.height
            : popover.contentViewController?.preferredContentSize.height ?? 0
        guard height > 0 else { return nil }

        return CGSize(width: width, height: height)
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

    private func applyPopoverSizeIfNeeded(size: CGSize, force: Bool) {
        let screenMaxWidth = max(300, (NSScreen.main?.visibleFrame.width ?? 1440) - 80)
        let targetSize = NSSize(
            width: min(size.width, screenMaxWidth),
            height: size.height
        )

        let changed = abs(popover.contentSize.width - targetSize.width) > 0.5 ||
            abs(popover.contentSize.height - targetSize.height) > 0.5
        logGeometry(
            "apply-size current=\(describe(size: popover.contentSize)) target=\(describe(size: targetSize)) force=\(force) changed=\(changed)"
        )
        if force || changed {
            popover.contentViewController?.preferredContentSize = targetSize
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
