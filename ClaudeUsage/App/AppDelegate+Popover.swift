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
                guard let self else { return }
                ServiceSelectionHelper.setActivePopoverService(service, settings: AppSettings.shared)
                self.applyPopoverBehavior(for: service)
                if self.popover?.isShown == true {
                    if self.isPopoverPinned(for: service) {
                        self.stopGlobalClickMonitor()
                    } else {
                        self.startGlobalClickMonitor()
                    }
                }
                self.refreshVisiblePopoverSizeForCurrentState()
                self.refreshServiceIfNeededOnTabSwitch(service)
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
        guard let button = statusItem?.button else { return }
        guard let currentPopover = popover else { return }

        if !ServiceSelectionHelper.hasAnyEnabledService(settings: AppSettings.shared) {
            showSettingsWindow()
            return
        }

        if currentPopover.isShown {
            closePopover()
        } else {
            isPresentingPopover = true
            let service = resolvedPopoverService()
            PopoverGeometryDiagnostics.resetSession("show service=\(service.rawValue)")
            popoverViewModel.selectService(service)
            popoverCoordinator.rebuildPopover(for: service)
            guard let popover = popover else {
                isPresentingPopover = false
                return
            }
            applyPopoverBehavior(for: service)
            updatePopoverViewModel(overage: currentOverage)
            let initialSize = presentedPopoverSize(for: service, isShown: false)
            // show() 전에 크기를 명시적으로 설정하여 fittingSize에 의한 확장 방지
            popover.contentViewController?.preferredContentSize = initialSize
            popover.contentSize = initialSize
            popoverCoordinator.beginWindowDiagnosticsIfNeeded()
            logPopoverPresentationState("before-show", button: button, requestedSize: initialSize)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            logPopoverPresentationState("after-show", button: button, requestedSize: initialSize)
            refreshVisiblePopoverSizeForCurrentState()
            NSApp.activate()
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
        AppSettings.shared.setProviderSettingsLastTab(ServiceSelectionHelper.settingsOverviewTab(), for: kind)
        showSettingsWindow()
    }

    func refreshPopoverSizeIfShown(service: PopoverService, reason: PopoverLayoutRefreshReason) {
        switch reason {
        case .serviceSelection, .compactToggle:
            break
        }
        let requestedSize = presentedPopoverSize(for: service, isShown: true)
        logPopoverPresentationState("refresh-size reason=\(reason.rawValue) service=\(service.rawValue)", requestedSize: requestedSize)
        popoverCoordinator.refreshSizeIfShown(size: requestedSize)
        logPopoverPresentationState("after-refresh reason=\(reason.rawValue) service=\(service.rawValue)")
    }

    func popoverLayoutSpec(for service: PopoverService) -> PopoverLayoutSpec {
        popoverViewModel.layoutSpec(for: service, settings: AppSettings.shared)
    }

    func refreshVisiblePopoverSizeForCurrentState() {
        guard popover?.isShown == true else { return }
        let requestedSize = presentedPopoverSize(for: popoverViewModel.selectedService, isShown: true)
        popoverCoordinator.refreshSizeIfShown(size: requestedSize)
    }

    func presentedPopoverSize(
        for service: PopoverService,
        isShown: Bool
    ) -> CGSize {
        let policy = PopoverPresentationPolicy(
            layoutSpec: popoverLayoutSpec(for: service),
            isShown: isShown,
            measuredContentSize: popoverCoordinator.measuredHostedContentSize(),
            screenVisibleFrame: NSScreen.main?.visibleFrame
        )
        return policy.targetSize()
    }

    func logPopoverPresentationState(
        _ label: String,
        button: NSStatusBarButton? = nil,
        requestedSize: CGSize? = nil
    ) {
        let buttonFrame = button.map { NSStringFromRect($0.bounds) } ?? "nil"
        let buttonWindowFrame = button?.window.map { NSStringFromRect($0.frame) } ?? "nil"
        let buttonScreenFrame = button.flatMap { button in
            button.window.map { window in
                NSStringFromRect(window.convertToScreen(button.convert(button.bounds, to: nil)))
            }
        } ?? "nil"
        let windowFrame = popover?.contentViewController?.view.window.map { NSStringFromRect($0.frame) } ?? "nil"
        let contentSize = popover.map { "\($0.contentSize.width.rounded())x\($0.contentSize.height.rounded())" } ?? "nil"
        let requested = requestedSize.map { "\($0.width.rounded())x\($0.height.rounded())" } ?? "nil"

        PopoverGeometryDiagnostics.log(
            "PopoverGeometry \(label) service=\(popoverViewModel.selectedService.rawValue) shown=\(popover?.isShown == true) requested=\(requested) contentSize=\(contentSize) buttonBounds=\(buttonFrame) buttonWindow=\(buttonWindowFrame) buttonScreen=\(buttonScreenFrame) popoverWindow=\(windowFrame)"
        )
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
