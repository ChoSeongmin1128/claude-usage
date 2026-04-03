import AppKit
import SwiftUI

@MainActor
final class AppPopoverCoordinator {
    let viewModel = PopoverViewModel()
    let popover = NSPopover()
    private var pendingSizeRefreshWorkItem: DispatchWorkItem?

    func configure(
        initialService: PopoverService,
        onRefreshService: @escaping (PopoverService) -> Void,
        onOpenSettingsForService: @escaping (PopoverService) -> Void,
        onServiceSelected: @escaping (PopoverService) -> Void,
        onLayoutChanged: @escaping (PopoverService, PopoverLayoutRefreshReason) -> Void,
        onPinChanged: @escaping (PopoverService, Bool) -> Void
    ) {
        viewModel.onRefreshService = onRefreshService
        viewModel.onOpenSettingsForService = onOpenSettingsForService
        viewModel.onServiceSelected = onServiceSelected
        viewModel.onLayoutChanged = onLayoutChanged
        viewModel.onPinChanged = onPinChanged
        viewModel.selectedService = initialService

        let popoverView = PopoverView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: popoverView)
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = [.preferredContentSize]
        }

        popover.contentViewController = hostingController
        popover.animates = false
        let initialCompact = AppSettings.shared.isPopoverCompact(for: initialService.providerKind)
        applyPopoverSizeIfNeeded(compact: initialCompact, force: true)
    }

    func close() {
        pendingSizeRefreshWorkItem?.cancel()
        popover.close()
    }

    func invalidate() {
        pendingSizeRefreshWorkItem?.cancel()
    }

    func applyBehavior(isPinned: Bool) {
        popover.behavior = isPinned ? .applicationDefined : .transient
    }

    func prepareSizeForPresentation(compact: Bool) {
        pendingSizeRefreshWorkItem?.cancel()
        applyPopoverSizeIfNeeded(compact: compact, force: true)
    }

    func refreshSizeIfShown(service: PopoverService, compact: Bool) {
        guard popover.isShown else { return }
        _ = service
        pendingSizeRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.popover.isShown else { return }
            self.applyPopoverSizeIfNeeded(compact: compact, force: false)
        }
        pendingSizeRefreshWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func applyPopoverSizeIfNeeded(compact: Bool, force: Bool) {
        let screenMaxWidth = max(300, (NSScreen.main?.visibleFrame.width ?? 1440) - 80)
        let preferredSize = PopoverView.resolvedPopoverSize(compact: compact)
        let targetSize = NSSize(
            width: min(preferredSize.width, screenMaxWidth),
            height: preferredSize.height
        )

        let changed = abs(popover.contentSize.width - targetSize.width) > 0.5 ||
            abs(popover.contentSize.height - targetSize.height) > 0.5
        if force || changed {
            popover.contentSize = targetSize
        }
    }
}
