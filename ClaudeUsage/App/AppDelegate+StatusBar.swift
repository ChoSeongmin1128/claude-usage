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
        let menu = StatusContextMenuBuilder.build(
            settings: AppSettings.shared,
            runtimeServices: ServiceSelectionHelper.exposedServices(settings: AppSettings.shared),
            refreshableServiceSet: Set(refreshableServices),
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
        let highContrast = AppSettings.shared.menuBarTextHighContrast
        let secondaryColor = MenuBarIconFactory.secondaryTextColor(highContrast: highContrast)

        let runtimeKinds = ServiceSelectionHelper
            .enabledRuntimeProviderKinds(settings: settings)
            .filter { settings.isProviderVisibleInMenuBar($0) }
        let compactSnapshots = runtimeKinds.compactMap {
            menuBarProviderSnapshot(
                for: $0,
                iconSize: NSSize(width: 14, height: 14),
                secondaryColor: secondaryColor
            )
        }

        if compactSnapshots.count > 1 {
            let content = MenuBarStatusComposer.multipleProviderContent(
                snapshots: compactSnapshots,
                secondaryColor: secondaryColor
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
            secondaryColor: secondaryColor
        ) else {
            applyMenuBarContent(MenuBarStatusComposer.placeholder(secondaryColor: secondaryColor), to: button)
            return
        }
        let content = MenuBarStatusComposer.singleProviderContent(
            snapshot: snapshot,
            secondaryColor: secondaryColor
        )
        applyMenuBarContent(content, to: button)
    }

    func menuBarProviderSnapshot(
        for kind: AppProviderKind,
        iconSize: NSSize,
        secondaryColor: NSColor
    ) -> MenuBarProviderSnapshot? {
        guard AppSettings.shared.isProviderVisibleInMenuBar(kind) else { return nil }
        guard let service = kind.runtimeService else { return nil }
        let runtimeSnapshot = runtimeProviderSnapshot(for: service)
        switch kind {
        case .claude:
            guard let config = AppSettings.shared.menuBarDisplayConfig(for: .claude) else { return nil }
            return MenuBarStatusComposer.claudeSnapshot(
                config: config,
                usage: runtimeSnapshot.claudeUsage,
                error: runtimeSnapshot.error,
                hasAuthError: runtimeSnapshot.hasAuthError,
                hasCredential: runtimeSnapshot.hasCredential,
                secondaryColor: secondaryColor,
                icon: config.showIcon ? MenuBarIconFactory.providerMenuBarIcon(for: .claude, size: iconSize) : nil,
                systemStatus: providerSystemStatus(for: .claude)
            )
        case .codex:
            guard let config = AppSettings.shared.menuBarDisplayConfig(for: .codex) else { return nil }
            return MenuBarStatusComposer.codexSnapshot(
                config: config,
                usage: runtimeSnapshot.codexUsage,
                error: runtimeSnapshot.error,
                hasAuthError: runtimeSnapshot.hasAuthError,
                isAuthenticated: runtimeSnapshot.hasCredential,
                secondaryColor: secondaryColor,
                icon: config.showIcon ? MenuBarIconFactory.providerMenuBarIcon(for: .codex, size: iconSize) : nil,
                systemStatus: providerSystemStatus(for: .codex)
            )
        case .antigravity:
            guard let config = AppSettings.shared.menuBarDisplayConfig(for: .antigravity) else { return nil }
            return MenuBarStatusComposer.antigravitySnapshot(
                config: config,
                usage: runtimeSnapshot.antigravityUsage,
                error: runtimeSnapshot.error,
                hasAuthError: runtimeSnapshot.hasAuthError,
                hasCredential: runtimeSnapshot.hasCredential,
                secondaryColor: secondaryColor,
                icon: config.showIcon ? MenuBarIconFactory.providerMenuBarIcon(for: .antigravity, size: iconSize) : nil,
                systemStatus: providerSystemStatus(for: .antigravity)
            )
        }
    }

    func applyMenuBarContent(_ content: MenuBarRenderedContent, to button: NSStatusBarButton) {
        button.image = content.image
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString(string: "")
        button.toolTip = content.tooltip
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
