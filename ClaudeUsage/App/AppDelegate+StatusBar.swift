import AppKit

extension AppDelegate {
    // MARK: - Status Item

    func setupStatusItems() {
        rebuildStatusItems()
        Logger.info("메뉴바 아이템 생성 완료")
    }

    func rebuildStatusItems() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        appearanceObservation = nil

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
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
            refreshableServiceSet: Set(refreshableServices),
            styleConfigurations:
                statusContextStyleConfigurations(
                    for: runtimeServices,
                    settings: settings
                ),
            actions: StatusContextMenuActions(
                refreshAll: #selector(refreshClicked),
                settings: #selector(settingsClicked),
                openUsage: #selector(openUsagePage),
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
                self?.openUsagePageAction()
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

    @objc func openUsagePage() {
        openUsagePageAction()
    }

    func openUsagePageAction() {
        if let url = URL(string: "https://claude.ai/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func quitClicked() {
        NSApplication.shared.terminate(nil)
    }
}
