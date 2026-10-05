import AppKit

extension AppDelegate {
    // MARK: - Popover

    func setupPopovers() {
        popoverCoordinator.configure(
            initialService: resolvedPopoverService(),
            onRefreshService: { [weak self] service in
                self?.refresh(service: service, force: true)
            },
            onOpenSettingsDestination: { [weak self] destination in
                self?.closePopover()
                self?.showSettingsWindow(destination: destination)
            },
            onServiceSelected: { [weak self] service in
                guard let self else { return }
                ServiceSelectionHelper.setActivePopoverService(service, settings: AppSettings.shared)
                self.refreshVisiblePopoverSizeForCurrentState()
                self.refreshServiceIfNeededOnTabSwitch(service)
            },
            onLayoutChanged: { [weak self] service, reason in
                self?.refreshPopoverSizeIfShown(service: service, reason: reason)
            },
            onPinChanged: { _, isPinned in
                AppSettings.shared.popoverPinned = isPinned
            },
            onStartClaudeLogin: { [weak self] in
                self?.closePopover()
                self?.reconnectClaude()
            }
        )

        applyPopoverBehavior()
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
            popoverCoordinator.rebuildPopover()
            guard let popover = popover else {
                isPresentingPopover = false
                return
            }
            applyPopoverBehavior()
            updatePopoverViewModel()
            let initialSize = popoverLayoutSpec(for: service).size
            // show() 전에 크기를 명시적으로 설정하여 fittingSize에 의한 확장 방지
            popover.contentViewController?.preferredContentSize = initialSize
            popover.contentSize = initialSize
            logPopoverPresentationState("before-show", button: button, requestedSize: initialSize)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popoverCoordinator.beginWindowDiagnosticsIfNeeded()
            logPopoverPresentationState("after-show", button: button, requestedSize: initialSize)
            refreshVisiblePopoverSizeForCurrentState()
            lastPopoverOpenedAt = Date()
            refreshServiceIfNeededOnTabSwitch(service)
            syncRefreshTimerState()
            NSApp.activate()
            DispatchQueue.main.async { [weak self] in
                self?.isPresentingPopover = false
            }
            applyPopoverBehavior()
        }
    }

    func closePopover() {
        isPresentingPopover = false
        popoverCoordinator.close()
        stopGlobalClickMonitor()
    }

    func updatePopoverViewModel() {
        popoverViewModel.update(
            snapshots: runtimeProviderSnapshots(),
            setupPresentation: claudeSetupPresentation
        )
        popoverViewModel.systemStatus = systemStatus
        popoverViewModel.nextUsageRetryAt = nextUsageRefreshAllowedAt
        popoverViewModel.multiAccount = multiAccountPresentations()
        refreshVisiblePopoverSizeForCurrentState()
    }

    func resolvedPopoverService() -> PopoverService {
        ServiceSelectionHelper.resolvedPopoverService(settings: AppSettings.shared)
    }

    func resolvedMenuBarService() -> PopoverService? {
        ServiceSelectionHelper.resolvedMenuBarService(
            settings: AppSettings.shared,
            isVisible:
                isRuntimeProviderVisibleInMenuBar
        )
    }

    var isPopoverPinned: Bool {
        AppSettings.shared.popoverPinned
    }

    func applyPopoverBehavior() {
        let isPinned = isPopoverPinned
        popover?.behavior = isPinned ? .applicationDefined : .transient
        if isPinned || popover?.isShown != true {
            stopGlobalClickMonitor()
        } else {
            startGlobalClickMonitor()
        }
    }

    func refreshServiceIfNeededOnTabSwitch(_ service: PopoverService) {
        resetCreditViewedServices.insert(service)
        usageAccountsController.refreshIfNeeded()
        guard let action = RefreshOrchestration.actionForTabSwitch(
                state: runtimePresentationState(for: service)
        ) else { return }

        performRuntimeAction(action)
    }

    func refreshPopoverSizeIfShown(service: PopoverService, reason: PopoverLayoutRefreshReason) {
        let requestedSize = popoverLayoutSpec(for: service).size
        logPopoverPresentationState(
            "request-size reason=\(reason.rawValue) service=\(service.rawValue)", requestedSize: requestedSize)
        popoverCoordinator.refreshSizeIfShown()
    }

    func popoverLayoutSpec(for service: PopoverService) -> PopoverLayoutSpec {
        popoverViewModel.layoutSpec(for: service, settings: AppSettings.shared)
    }

    func refreshVisiblePopoverSizeForCurrentState() {
        popoverCoordinator.refreshSizeIfShown()
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
