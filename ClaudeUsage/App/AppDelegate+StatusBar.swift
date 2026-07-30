import AppKit

extension AppDelegate {
    // MARK: - Status Item

    func setupStatusItems() {
        rebuildStatusItems()
        Logger.info("메뉴바 아이템 생성 완료")
        scheduleStatusItemPlacementCheck()
    }

    // MARK: - Placement Watchdog

    /// macOS 26의 ControlCenter가 상태 아이템 scene을 차단하거나 생성하지
    /// 못하는 경우를 시작 직후 한 번 복구합니다. 반복 재생성은 ControlCenter
    /// 저장 상태를 더 손상시킬 수 있으므로 최대 한 번만 시도합니다.
    func scheduleStatusItemPlacementCheck() {
        statusItemPlacementCheckTask?.cancel()
        statusItemPlacementCheckTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    for:
                        StatusItemPlacementRecoveryPolicy
                            .startupCheckDelay
                )
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.isStatusItemPlacementBlocked
            else {
                return
            }

            Logger.error(
                "메뉴바 아이템이 생성되지 않았습니다. "
                    + self.statusItemPlacementEvidence
                        .description
            )
            self.rebuildStatusItems()
            self.updateMenuBar(force: true)

            do {
                try await Task.sleep(
                    for:
                        StatusItemPlacementRecoveryPolicy
                            .recreationSettleDelay
                )
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.isStatusItemPlacementBlocked
            else {
                Logger.info(
                    "메뉴바 아이템 재생성 후 배치가 복구됐습니다."
                )
                return
            }

            Logger.error(
                "메뉴바 아이템이 한 차례 재생성 후에도 차단 상태입니다. "
                    + self.statusItemPlacementEvidence
                        .description
            )
            self.presentStatusItemPlacementGuidance()
        }
    }

    var statusItemPlacementSnapshot:
        StatusItemPlacementSnapshot
    {
        let button = statusItem?.button
        let screen = button?.window?.screen
        return StatusItemPlacementSnapshot(
            // ClaudeUsage는 provider가 비어 있어도 placeholder를 표시하므로
            // status item이 존재하는 동안 항상 표시 의도가 있습니다.
            expectsVisibility: statusItem != nil,
            reportsVisible:
                statusItem?.isVisible == true,
            hasButton: button != nil,
            hasWindow: button?.window != nil,
            hasScreen: screen != nil,
            isOnCurrentScreen:
                screen.map {
                    currentScreensContain($0)
                }
                ?? false,
            buttonWidth: button?.frame.width ?? 0
        )
    }

    var statusItemPlacementEvidence:
        StatusItemPlacementEvidence
    {
        let autosaveName =
            statusItem?.autosaveName ?? ""
        return StatusItemPlacementEvidence(
            autosaveName: autosaveName,
            visibilityDefault:
                StatusItemPlacementRecoveryPolicy
                    .visibilityDefault(
                        defaults:
                            UserDefaults.standard,
                        autosaveName:
                            autosaveName
                    ),
            snapshot:
                statusItemPlacementSnapshot,
            windowSnapshots:
                StatusItemWindowProbe.snapshots(
                    matching:
                        Set([autosaveName])
                )
        )
    }

    var isStatusItemPlacementBlocked: Bool {
        StatusItemPlacementRecoveryPolicy
            .isBlocked(
                statusItemPlacementEvidence,
                detectTahoeBlockedStatusItem:
                    ProcessInfo.processInfo
                        .operatingSystemVersion
                        .majorVersion
                        >= 26
            )
    }

    private func currentScreensContain(
        _ screen: NSScreen
    ) -> Bool {
        let key =
            NSDeviceDescriptionKey(
                "NSScreenNumber"
            )
        let screenNumber =
            screen.deviceDescription[key]
                as? NSNumber
        return NSScreen.screens.contains {
            let candidateNumber =
                $0.deviceDescription[key]
                    as? NSNumber
            if let screenNumber,
               let candidateNumber
            {
                return screenNumber
                    == candidateNumber
            }
            return $0 === screen
        }
    }

    func presentStatusItemPlacementGuidance(
        force: Bool = false
    ) {
        let defaults = UserDefaults.standard
        guard force
            || StatusItemPlacementRecoveryPolicy
                .shouldShowGuidance(
                    defaults: defaults
                )
        else {
            return
        }
        StatusItemPlacementRecoveryPolicy
            .markGuidanceShown(
                defaults: defaults
            )

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText =
            "\(AppDistribution.current.appName)를 메뉴 막대에 표시하지 못했습니다"
        alert.informativeText =
            "앱은 실행 중이지만 macOS가 상태 아이템을 차단했습니다. "
            + "시스템 설정 > 메뉴 막대에서 \(AppDistribution.current.appName)를 켜 주세요. "
            + "이미 켜져 있는데도 계속 보이지 않으면 앱 설정에서 업데이트를 확인하거나 문제를 보고해 주세요."
        alert.alertStyle = .warning
        alert.addButton(
            withTitle: "메뉴 막대 설정 열기"
        )
        alert.addButton(
            withTitle: "앱 설정 열기"
        )
        alert.addButton(
            withTitle: "닫기"
        )

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.MenuBarSettings"
            ) {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            showSettingsWindow(
                settingsPanelRawValue: "updates"
            )
        default:
            break
        }
    }

    func rebuildStatusItems() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        appearanceObservation = nil

        let autosaveName =
            AppDistribution.current.channel
                == .staging
            ? "claudeusage-staging"
            : "claudeusage"
        let repairedKeys =
            StatusItemPlacementRecoveryPolicy
                .clearInvalidPreferredPosition(
                    defaults:
                        UserDefaults.standard,
                    autosaveName: autosaveName,
                    legacyDefaultItemIndex: 0,
                    maximumPreferredPosition:
                        NSScreen.screens
                            .map {
                                Double(
                                    $0.frame.maxX
                                )
                            }
                            .max()
                )
        if !repairedKeys.isEmpty {
            Logger.warning(
                "잘못된 메뉴바 위치 기본값을 정리했습니다: "
                    + repairedKeys.joined(
                        separator: ", "
                    )
            )
        }

        let item =
            NSStatusBar.system.statusItem(
                withLength:
                    NSStatusItem.variableLength
            )
        item.autosaveName = autosaveName
        statusItem = item
        if let button = item.button {
            button.title = "..."
            button.toolTip = "ClaudeUsage"
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.updateMenuBar()
                }
            }
        }
    }

    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showUnifiedContextMenu()
        } else {
            toggleUnifiedPopover()
        }
    }

    func showUnifiedContextMenu() {
        let settings = AppSettings.shared
        let runtimeServices =
            ServiceSelectionHelper.exposedServices(
                settings: settings
            )
        let menu = StatusContextMenuBuilder.build(
            settings: settings,
            runtimeServices: runtimeServices,
            selectedService: popoverViewModel.selectedService,
            refreshableServiceSet: Set(refreshableServices),
            styleConfigurations:
                statusContextStyleConfigurations(
                    for: runtimeServices,
                    settings: settings
                ),
            actions: StatusContextMenuActions(
                refreshAll: #selector(refreshClicked),
                settings: #selector(settingsClicked),
                openProviderExternalAction:
                    #selector(openProviderExternalActionClicked(_:)),
                quit: #selector(quitClicked),
                toggleProvider: #selector(toggleProviderClicked(_:)),
                refreshProvider: #selector(refreshProviderClicked(_:)),
                changeProviderStyle: #selector(changeProviderStyleClicked(_:))
            )
        )
        applyContextMenuTarget(self, to: menu)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func applyContextMenuTarget(_ target: AppDelegate, to menu: NSMenu) {
        for item in menu.items {
            if item.action != nil {
                item.target = target
            }
            if let submenu = item.submenu {
                applyContextMenuTarget(target, to: submenu)
            }
        }
    }

    @objc func changeProviderStyleClicked(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ProviderStyleMenuSelection else { return }
        applyMenuBarStyle(payload.style, for: payload.service.providerKind)
    }

    func applyMenuBarStyle(_ style: MenuBarStyle, for kind: AppProviderKind) {
        if kind == .antigravity {
            guard let typedStyle =
                    antigravityMenuBarStyle(
                        from: style
                    )
            else {
                return
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await antigravityRuntime
                        .runtimeController
                        .updateMenuBarStyle(
                            typedStyle
                        )
                } catch {
                    Logger.warning(
                        "Antigravity 메뉴바 스타일 저장 실패: \(error.localizedDescription)"
                    )
                }
            }
            return
        }
        AppSettings.shared.setMenuBarStyle(style, for: kind)
        updateMenuBar()
    }

    @objc func refreshProviderClicked(_ sender: NSMenuItem) {
        guard let service = menuService(from: sender) else { return }
        refresh(service: service, force: true)
    }

    @objc func toggleProviderClicked(_ sender: NSMenuItem) {
        guard let service = menuService(from: sender) else { return }
        toggleProviderEnabled(service)
    }

    func toggleProviderEnabled(_ service: PopoverService) {
        let settings = AppSettings.shared
        let kind = ServiceSelectionHelper.providerKind(for: service)
        settings.setProviderEnabled(!settings.isProviderEnabled(kind), for: kind)
    }

    func menuService(from item: NSMenuItem) -> PopoverService? {
        guard let rawValue = item.representedObject as? String else { return nil }
        return PopoverService(rawValue: rawValue)
    }

    // MARK: - Menu Bar Update

    func updateMenuBar(force: Bool = false) {
        PopoverGeometryDiagnostics.log(
            "MenuBar update force=\(force) popoverShown=\(popover?.isShown == true) presenting=\(isPresentingPopover)"
        )

        let settings = AppSettings.shared
        guard let button = statusItem?.button else { return }
        let appearance = button.effectiveAppearance
        let highContrast = AppSettings.shared.menuBarTextHighContrast
        let secondaryColor = MenuBarIconFactory.secondaryTextColor(highContrast: highContrast)

        let runtimeKinds = ServiceSelectionHelper
            .enabledRuntimeProviderKinds(settings: settings)
            .filter(isRuntimeProviderVisibleInMenuBar)
        PopoverGeometryDiagnostics.log(
            "MenuBar decision enabled=\(ServiceSelectionHelper.enabledRuntimeProviderKinds(settings: settings)) "
                + "rendered=\(runtimeKinds) claudeStyle=\(settings.menuBarStyle.rawValue) "
                + "claudePct=\(settings.percentageDisplay.rawValue) claudeReset=\(settings.resetTimeDisplay.rawValue)"
        )
        let compactSnapshots = runtimeKinds.compactMap {
            menuBarProviderSnapshot(
                for: $0,
                iconSize: NSSize(width: 14, height: 14),
                secondaryColor: secondaryColor,
                appearance: appearance
            )
        }

        if compactSnapshots.count > 1 {
            let content = MenuBarStatusComposer.multipleProviderContent(
                snapshots: compactSnapshots,
                secondaryColor: secondaryColor,
                appearance: appearance
            )
            applyMenuBarContent(content, to: button)
            return
        }

        guard let activeService = resolvedMenuBarService() else {
            applyMenuBarContent(MenuBarStatusComposer.placeholder(secondaryColor: secondaryColor), to: button)
            return
        }

        guard let snapshot = menuBarProviderSnapshot(
            for: activeService.providerKind,
            iconSize: NSSize(width: 18, height: 18),
            secondaryColor: secondaryColor,
            appearance: appearance
        ) else {
            applyMenuBarContent(MenuBarStatusComposer.placeholder(secondaryColor: secondaryColor), to: button)
            return
        }
        let content = MenuBarStatusComposer.singleProviderContent(
            snapshot: snapshot,
            secondaryColor: secondaryColor,
            appearance: appearance
        )
        applyMenuBarContent(content, to: button)
    }

    func menuBarProviderSnapshot(
        for kind: AppProviderKind,
        iconSize: NSSize,
        secondaryColor: NSColor,
        appearance: NSAppearance
    ) -> MenuBarProviderSnapshot? {
        guard isRuntimeProviderVisibleInMenuBar(kind) else {
            return nil
        }
        guard let service = kind.runtimeService else { return nil }
        switch kind {
        case .claude:
            let runtimeSnapshot = runtimeProviderSnapshot(for: service)
            guard let config = AppSettings.shared.menuBarDisplayConfig(for: .claude) else { return nil }
            return MenuBarStatusComposer.claudeSnapshot(
                config: config,
                usage: runtimeSnapshot.claudeUsage,
                error: runtimeSnapshot.error,
                hasAuthError: runtimeSnapshot.hasAuthError,
                hasCredential: runtimeSnapshot.hasCredential,
                secondaryColor: secondaryColor,
                icon: config.showIcon ? MenuBarIconFactory.providerMenuBarIcon(
                    for: .claude,
                    size: iconSize,
                    appearance: appearance
                ) : nil,
                systemStatus: providerSystemStatus(for: .claude)
            )
        case .codex:
            let runtimeSnapshot = runtimeProviderSnapshot(for: service)
            guard let config = AppSettings.shared.menuBarDisplayConfig(for: .codex) else { return nil }
            return MenuBarStatusComposer.codexSnapshot(
                config: config,
                usage: runtimeSnapshot.codexUsage,
                error: runtimeSnapshot.error,
                hasAuthError: runtimeSnapshot.hasAuthError,
                isAuthenticated: runtimeSnapshot.hasCredential,
                secondaryColor: secondaryColor,
                icon: config.showIcon ? MenuBarIconFactory.providerMenuBarIcon(
                    for: .codex,
                    size: iconSize,
                    appearance: appearance
                ) : nil,
                systemStatus: providerSystemStatus(for: .codex)
            )
        case .antigravity:
            guard case .content(let presentation) =
                    currentAntigravityRuntimeSnapshot
                        .quotaPresentation
            else {
                return nil
            }
            return MenuBarStatusComposer.antigravitySnapshot(
                presentation: presentation.menuBar,
                context: presentation.context,
                icon: MenuBarIconFactory.providerMenuBarIcon(
                    for: .antigravity,
                    size: iconSize,
                    appearance: appearance
                )
            )
        }
    }

    func isRuntimeProviderVisibleInMenuBar(
        _ kind: AppProviderKind
    ) -> Bool {
        if kind == .antigravity {
            return currentAntigravityRuntimeSnapshot
                .settings?
                .display
                .menuBar
                .isVisible
                == true
        }
        return AppSettings.shared
            .isProviderVisibleInMenuBar(kind)
    }

    private func statusContextStyleConfigurations(
        for services: [PopoverService],
        settings: AppSettings
    ) -> [
        PopoverService:
            ProviderStyleMenuConfiguration
    ] {
        Dictionary(
            uniqueKeysWithValues:
                services.compactMap { service in
                    if service == .antigravity {
                        guard
                            let style =
                                currentAntigravityRuntimeSnapshot
                                    .settings?
                                    .display
                                    .menuBar
                                    .style
                        else {
                            return nil
                        }
                        return (
                            service,
                            ProviderStyleMenuConfiguration(
                                currentStyle:
                                    menuBarStyle(
                                        from: style
                                    ),
                                availableStyles: [
                                    .none,
                                    .batteryBar,
                                    .circular,
                                ]
                            )
                        )
                    }
                    guard
                        let style = settings
                            .menuBarStyle(
                                for:
                                    service.providerKind
                            )
                    else {
                        return nil
                    }
                    return (
                        service,
                        ProviderStyleMenuConfiguration(
                            currentStyle: style,
                            availableStyles:
                                MenuBarStyle.allCases
                        )
                    )
                }
        )
    }

    private func antigravityMenuBarStyle(
        from style: MenuBarStyle
    ) -> AntigravityDisplaySettings
        .MenuBarPresentationIntent.Style?
    {
        switch style {
        case .none:
            return AntigravityDisplaySettings
                .MenuBarPresentationIntent
                .Style
                .none
        case .batteryBar:
            return .batteryBar
        case .circular:
            return .circular
        case .concentricRings,
             .dualBattery,
             .sideBySideBattery:
            return nil
        }
    }

    private func menuBarStyle(
        from style: AntigravityDisplaySettings
            .MenuBarPresentationIntent.Style
    ) -> MenuBarStyle {
        switch style {
        case .none:
            return .none
        case .batteryBar:
            return .batteryBar
        case .circular:
            return .circular
        }
    }

    func applyMenuBarContent(_ content: MenuBarRenderedContent, to button: NSStatusBarButton) {
        button.image = content.image
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString(string: "")
        button.toolTip = content.tooltip
        content.applyAccessibility(to: button)
        if PopoverGeometryDiagnostics.isEnabled {
            let buttonScreenFrame = button.window.map {
                NSStringFromRect($0.convertToScreen(button.convert(button.bounds, to: nil)))
            } ?? "nil"
            let buttonWindowFrame = button.window.map { NSStringFromRect($0.frame) } ?? "nil"
            let imageSize = NSStringFromSize(content.image.size)
            PopoverGeometryDiagnostics.log(
                "MenuBar apply-content imageSize=\(imageSize) buttonScreen=\(buttonScreenFrame) buttonWindow=\(buttonWindowFrame) tooltip=\(content.tooltip)"
            )
        }
    }

    // MARK: - Keyboard Shortcuts

    func setupKeyboardShortcuts() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command) else { return event }

            switch event.charactersIgnoringModifiers {
            case "r":
                self?.refreshAll(force: true)
                return nil
            case ",":
                self?.showSettingsWindow()
                return nil
            case "u":
                guard self?.openSelectedProviderUsagePageAction() == true else {
                    return event
                }
                return nil
            default:
                return event
            }
        }
    }

    // MARK: - Actions

    @objc func settingsClicked() {
        showSettingsWindow()
    }

    @objc func refreshClicked() {
        if shouldPollRuntimeProviders {
            refreshAll(force: true)
        } else {
            showInitialClaudeSetupFlow()
        }
    }

    @objc func openProviderExternalActionClicked(
        _ sender: NSMenuItem
    ) {
        guard
            let destination = sender.representedObject as? String,
            let action = AppProviderKind.allCases
                .flatMap({ $0.descriptor.externalActions })
                .first(where: {
                    $0.destination.absoluteString == destination
                })
        else {
            return
        }
        NSWorkspace.shared.open(action.destination)
    }

    @discardableResult
    func openSelectedProviderUsagePageAction() -> Bool {
        guard
            let action = popoverViewModel.selectedService
                .providerKind.descriptor.externalActions
                .first(where: { $0.kind == .usage })
        else {
            return false
        }
        NSWorkspace.shared.open(action.destination)
        return true
    }

    @objc func quitClicked() {
        NSApplication.shared.terminate(nil)
    }
}
