import AppKit
import SwiftUI

@MainActor
final class AppPopoverCoordinator {
    let viewModel = PopoverViewModel()
    let popover = NSPopover()
    private var presentationRevision: Int = 0

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

        popover.contentViewController = hostingController
        popover.animates = false
        let initialSize = viewModel.preferredPopoverSize(for: initialService, settings: AppSettings.shared)
        applyPopoverSizeIfNeeded(size: initialSize, force: true)
    }

    func close() {
        presentationRevision += 1
        popover.close()
    }

    func invalidate() {
        presentationRevision += 1
    }

    func applyBehavior(isPinned: Bool) {
        popover.behavior = isPinned ? .applicationDefined : .transient
    }

    func prepareSizeForPresentation(size: CGSize) {
        applyPopoverSizeIfNeeded(size: size, force: true)
    }

    func refreshSizeIfShown(size: CGSize) {
        guard popover.isShown else { return }
        applyPopoverSizeIfNeeded(size: size, force: false)
    }

    func finalizeSizeAfterPresentation(sizeProvider: @escaping () -> CGSize) {
        presentationRevision += 1
        let revision = presentationRevision
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.presentationRevision == revision else { return }
            guard self.popover.isShown else { return }
            self.popover.contentViewController?.view.layoutSubtreeIfNeeded()
            self.applyPopoverSizeIfNeeded(size: sizeProvider(), force: true)
        }
    }

    private func applyPopoverSizeIfNeeded(size: CGSize, force: Bool) {
        let screenMaxWidth = max(300, (NSScreen.main?.visibleFrame.width ?? 1440) - 80)
        let targetSize = NSSize(
            width: min(size.width, screenMaxWidth),
            height: size.height
        )

        let changed = abs(popover.contentSize.width - targetSize.width) > 0.5 ||
            abs(popover.contentSize.height - targetSize.height) > 0.5
        if force || changed {
            popover.contentViewController?.preferredContentSize = targetSize
            popover.contentSize = targetSize
        }
    }
}
