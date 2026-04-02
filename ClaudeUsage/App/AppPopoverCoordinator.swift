import AppKit
import SwiftUI

@MainActor
final class AppPopoverCoordinator {
    let viewModel = PopoverViewModel()
    let popover = NSPopover()

    private var resizeWorkItem: DispatchWorkItem?
    private var adjustingServices = Set<PopoverService>()

    func configure(
        initialService: PopoverService,
        onRefreshService: @escaping (PopoverService) -> Void,
        onOpenSettingsForService: @escaping (PopoverService) -> Void,
        onServiceSelected: @escaping (PopoverService) -> Void,
        onLayoutChanged: @escaping (PopoverService) -> Void,
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
        popover.animates = true
    }

    func close() {
        popover.close()
    }

    func invalidate() {
        resizeWorkItem?.cancel()
        resizeWorkItem = nil
        adjustingServices.removeAll()
    }

    func applyBehavior(isPinned: Bool) {
        popover.behavior = isPinned ? .applicationDefined : .transient
    }

    func refreshSizeIfShown(service: PopoverService, compact: Bool) {
        guard popover.isShown else { return }

        resizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.popover.isShown,
                  let hosting = self.popover.contentViewController as? NSHostingController<PopoverView> else {
                return
            }
            guard !self.adjustingServices.contains(service) else { return }

            self.adjustingServices.insert(service)
            defer { self.adjustingServices.remove(service) }

            hosting.view.layoutSubtreeIfNeeded()
            let fitting = hosting.view.fittingSize
            guard fitting.width > 0, fitting.height > 0 else { return }

            let screenMaxWidth = (NSScreen.main?.visibleFrame.width ?? 1440) - 80
            let width = min(
                PopoverView.resolvedPopoverWidth(
                    for: service,
                    compact: compact,
                    fittingWidth: fitting.width
                ),
                max(300, screenMaxWidth)
            )
            let minHeight: CGFloat = compact ? 120 : 280
            let maxHeight = max(minHeight, (NSScreen.main?.visibleFrame.height ?? 900) - 100)
            let height: CGFloat
            if compact {
                let currentHeight = self.popover.contentSize.height > 0 ? self.popover.contentSize.height : minHeight
                height = min(max(max(fitting.height, minHeight), currentHeight), maxHeight)
            } else {
                height = min(max(fitting.height, minHeight), maxHeight)
            }
            let targetSize = NSSize(width: width, height: height)

            let changed = abs(self.popover.contentSize.width - targetSize.width) > 0.5 ||
                abs(self.popover.contentSize.height - targetSize.height) > 0.5
            if changed {
                self.popover.contentSize = targetSize
            }
        }

        resizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now(), execute: workItem)
    }
}
