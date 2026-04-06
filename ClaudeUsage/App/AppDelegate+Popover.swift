import AppKit

extension AppDelegate {
    // MARK: - Popover

    func setupPopovers() {
        popoverCoordinator.configure(
            initialService: resolvedPopoverService(),
            onRefreshService: { [weak self] service in
                self?.refresh(service: service, force: true)
            },
            onOpenSettingsForService: { [weak self] service in
                self?.closePopover()
                self?.openSettingsForAuth(service: service)
            },
            onServiceSelected: { [weak self] service in
                ServiceSelectionHelper.setActivePopoverService(service, settings: AppSettings.shared)
                if self?.popover?.isShown == true {
                    self?.pendingMenuBarRefreshAfterPopoverClose = true
                } else {
                    self?.updateMenuBar()
                }
                self?.refreshServiceIfNeededOnTabSwitch(service)
            },
            onLayoutChanged: { [weak self] service, reason in
                self?.refreshPopoverSizeIfShown(service: service, reason: reason)
            },
            onPinChanged: { [weak self] service, isPinned in
                guard let self else { return }
                AppSettings.shared.setPopoverPinned(isPinned, for: ServiceSelectionHelper.providerKind(for: service))
                self.applyPopoverBehavior(for: service)
                if isPinned {
                    self.stopGlobalClickMonitor()
                } else if self.popover?.isShown == true {
                    self.startGlobalClickMonitor()
                }
            }
        )

        applyPopoverBehavior(for: popoverViewModel.selectedService)
    }

    func toggleUnifiedPopover() {
        guard let popover, let button = statusItem?.button else { return }

        if !ServiceSelectionHelper.hasAnyEnabledService(settings: AppSettings.shared) {
            showSettingsWindow()
            return
        }

        if popover.isShown {
            closePopover()
        } else {
            isPresentingPopover = true
            let service = resolvedPopoverService()
            popoverViewModel.selectService(service)
            applyPopoverBehavior(for: service)
            updatePopoverViewModel(overage: currentOverage)
            NSApp.activate()
            button.window?.contentView?.layoutSubtreeIfNeeded()
            button.layoutSubtreeIfNeeded()
            let initialSize = preferredPopoverSize(for: service)
            popoverCoordinator.prepareSizeForPresentation(size: initialSize)
            popover.show(relativeTo: popoverAnchorRect(for: button), of: button, preferredEdge: .minY)
            popoverCoordinator.finalizeSizeAfterPresentation(sizeProvider: { [weak self] in
                guard let self else { return initialSize }
                return self.preferredPopoverSize(for: self.popoverViewModel.selectedService)
            }, completion: { [weak self] in
                self?.isPresentingPopover = false
            })
            DispatchQueue.main.async { [weak self] in
                self?.isPresentingPopover = false
            }
            if !isPopoverPinned(for: service) {
                startGlobalClickMonitor()
            }
        }
    }

    func closePopover() {
        let shouldRefreshMenuBar = pendingMenuBarRefreshAfterPopoverClose
        isPresentingPopover = false
        popoverCoordinator.close()
        stopGlobalClickMonitor()
        pendingMenuBarRefreshAfterPopoverClose = false
        if shouldRefreshMenuBar {
            updateMenuBar(force: true)
        }
    }

    func updatePopoverViewModel(overage: OverageSpendLimitResponse? = nil) {
        popoverViewModel.update(
            snapshots: runtimeProviderSnapshots(),
            overage: overage,
            setupPresentation: claudeSetupPresentation
        )
        popoverViewModel.systemStatus = systemStatus
        popoverViewModel.nextUsageRetryAt = nextUsageRefreshAllowedAt
        refreshVisiblePopoverSizeForCurrentState()
    }

    func resolvedPopoverService() -> PopoverService {
        ServiceSelectionHelper.resolvedPopoverService(settings: AppSettings.shared)
    }

    func resolvedMenuBarService() -> PopoverService? {
        ServiceSelectionHelper.resolvedMenuBarService(settings: AppSettings.shared)
    }

    func isPopoverPinned(for service: PopoverService) -> Bool {
        ServiceSelectionHelper.isPinned(service, settings: AppSettings.shared)
    }

    func applyPopoverBehavior(for service: PopoverService) {
        popover?.behavior = isPopoverPinned(for: service) ? .applicationDefined : .transient
    }

    func refreshServiceIfNeededOnTabSwitch(_ service: PopoverService) {
        guard let action = RefreshOrchestration.actionForTabSwitch(
            state: runtimePresentationState(for: service),
            refreshInterval: AppSettings.shared.refreshInterval
        ) else { return }

        performRuntimeAction(action)
    }

    func openSettingsForAuth(service: PopoverService) {
        let kind = ServiceSelectionHelper.providerKind(for: service)
        AppSettings.shared.settingsLastTab = ServiceSelectionHelper.settingsRootTab(for: service)
        AppSettings.shared.setProviderSettingsLastTab(ServiceSelectionHelper.settingsAuthTab(), for: kind)
        showSettingsWindow()
    }

    func refreshPopoverSizeIfShown(service: PopoverService, reason: PopoverLayoutRefreshReason) {
        switch reason {
        case .serviceSelection, .compactToggle:
            break
        }
        popoverCoordinator.refreshSizeIfShown(size: preferredPopoverSize(for: service))
    }

    func preferredPopoverSize(for service: PopoverService) -> CGSize {
        popoverViewModel.preferredPopoverSize(for: service, settings: AppSettings.shared)
    }

    func refreshVisiblePopoverSizeForCurrentState() {
        guard popover?.isShown == true else { return }
        popoverCoordinator.refreshSizeIfShown(size: preferredPopoverSize(for: popoverViewModel.selectedService))
    }

    func popoverAnchorRect(for button: NSStatusBarButton) -> NSRect {
        let anchorWidth = min(max(button.bounds.height, 28), button.bounds.width)
        let anchorX = floor((button.bounds.width - anchorWidth) / 2)
        return NSRect(x: anchorX, y: button.bounds.minY, width: anchorWidth, height: button.bounds.height)
    }

    func startGlobalClickMonitor() {
        stopGlobalClickMonitor()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    func stopGlobalClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }
}
