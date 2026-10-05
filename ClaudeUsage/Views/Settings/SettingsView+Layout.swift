import AppKit
import SwiftUI
import Combine

@MainActor
enum SettingsFocusDismissal {
    static func handleMouseDown(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window,
            let editor = window.firstResponder as? NSTextView,
            editor.isFieldEditor
        else {
            return event
        }

        let location = editor.convert(event.locationInWindow, from: nil)
        guard !editor.bounds.contains(location) else { return event }
        window.makeFirstResponder(nil)
        return event
    }
}

private struct SettingsFocusDismissalMonitor: NSViewRepresentable {
    final class Coordinator {
        private var monitor: Any?

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
                SettingsFocusDismissal.handleMouseDown($0)
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }
}

struct SettingsDataPreparationRequest: Equatable {
    let provider: AppProviderKind
    let isEnabled: Bool
}

private struct SettingsSectionNavigationRequest: Equatable {
    let revision: Int
    let section: SettingsSection?
    let isPrepared: Bool
}

extension SettingsView {
    var body: some View {
        settingsLayoutWithChanges
            .background(SettingsFocusDismissalMonitor())
    }

    var settingsLayout: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                if settings.welcomeState != .completed {
                    NavigationLink(value: SettingsProviderPanel.welcome) {
                        Label("시작하기", systemImage: "sparkles")
                    }
                    .tag(SettingsProviderPanel.welcome)
                }
                Section("앱") {
                    ForEach(SettingsProviderRegistry.appPanels) { panel in
                        NavigationLink(value: panel.panel) {
                            Label(panel.title, systemImage: panel.icon)
                        }
                        .tag(panel.panel)
                        .accessibilityIdentifier("settings-panel-\(panel.panel.rawValue)")
                    }
                }
                Section("서비스") {
                    ForEach(SettingsProviderRegistry.servicePanels) { panel in
                        if let provider = panel.providerKind {
                            NavigationLink(value: panel.panel) {
                                HStack(spacing: AppDesign.Space.row) {
                                    ProviderBrandIconView(provider: provider, kind: .settings, size: 16)
                                    Text(panel.title)
                                }
                            }
                            .tag(panel.panel)
                            .accessibilityIdentifier("settings-panel-\(panel.panel.rawValue)")
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: AppDesign.Space.section) {
                    panelContent
                }
                .padding(AppDesign.Space.window)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(selectedPanel)
                .transition(.opacity)
                .animation(
                    settings.motion.animation(for: .navigation, reduceMotion: reduceMotion),
                    value: selectedPanel)
            }
            .scrollPosition(id: $sectionScrollPosition, anchor: .top)
            .task(id: settingsSectionNavigationRequest) {
                let request = settingsSectionNavigationRequest
                guard request.isPrepared, let section = request.section, !Task.isCancelled else { return }
                sectionScrollPosition = section
                requestedSection = nil
            }
            .disclosureGroupStyle(AppDisclosureGroupStyle())
        }
        .frame(
            minWidth: AppDesign.Window.settingsMinimum.width,
            idealWidth: AppDesign.Window.settingsIdeal.width,
            minHeight: AppDesign.Window.settingsMinimum.height,
            idealHeight: AppDesign.Window.settingsIdeal.height)
    }

    var settingsLayoutWithDataPreparation: some View {
        settingsLayout
            .task(id: settingsDataPreparationRequest) {
                preparedSettingsDataRequest = nil
                guard let request = settingsDataPreparationRequest else { return }
                await prepareSettingsData(for: request.provider)
                guard !Task.isCancelled, request == settingsDataPreparationRequest else { return }
                preparedSettingsDataRequest = request
            }
    }

    var settingsDataPreparationRequest: SettingsDataPreparationRequest? {
        let provider: AppProviderKind
        if let serviceProvider = selectedPanel.providerKind {
            provider = serviceProvider
        } else {
            guard selectedProvider == .antigravity else { return nil }
            switch selectedPanel {
            case .display:
                provider = .antigravity
            case .welcome:
                guard settings.welcomeStep == .appearance,
                    settings.isProviderEnabled(.antigravity),
                    welcomeStatuses?()[.antigravity] == .verified
                else { return nil }
                provider = .antigravity
            default:
                return nil
            }
        }
        return SettingsDataPreparationRequest(provider: provider, isEnabled: settings.isProviderEnabled(provider))
    }

    private var settingsSectionNavigationRequest: SettingsSectionNavigationRequest {
        let preparation = settingsDataPreparationRequest
        let isRuntimeReady = preparation?.provider != .antigravity || !antigravitySettings.state.isRuntimeLoading
        return SettingsSectionNavigationRequest(
            revision: navigationRevision, section: requestedSection,
            isPrepared: (preparation == nil || preparation == preparedSettingsDataRequest) && isRuntimeReady)
    }

    private var settingsLayoutWithDialog: some View {
        settingsLayoutWithDataPreparation
            .confirmationDialog(
                pendingDestructiveAction?.title ?? "확인",
                isPresented: Binding(
                    get: { pendingDestructiveAction != nil },
                    set: { if !$0 { pendingDestructiveAction = nil } }),
                titleVisibility: .visible
            ) {
                if let action = pendingDestructiveAction {
                    Button(action.actionTitle, role: .destructive) {
                        performDestructiveAction(action)
                        pendingDestructiveAction = nil
                    }
                }
                Button("취소", role: .cancel) { pendingDestructiveAction = nil }
            } message: {
                if let action = pendingDestructiveAction { Text(action.detail) }
            }
    }

    private var settingsLayoutWithLifecycle: some View {
        settingsLayoutWithDialog
            .onAppear {
                resetClaudeAuthDisclosureState()
                testResult = nil
                let resolved = SettingsProviderPanel.resolve(
                    storedValue: settings.settingsLastTab,
                    fallbackProvider: settings.activeProviderKind ?? .claude)
                navigate(
                    to: SettingsDestination(
                        panel: initialPanel ?? resolved?.panel ?? .common,
                        section: initialSection))
                updateRuntimeState.bootstrapIfNeeded()
            }
            .onDisappear {
                codexAuthCheckTask?.cancel()
                stopBrowserLoginWatch()
                antigravitySettings.stopObserving()
                cancelOrganizationLoad()
                flushPendingOrganizationPersistence()
            }
    }

    private var settingsLayoutWithNotifications:
        some View
    {
        settingsLayoutWithLifecycle
        .onReceive(NotificationCenter.default.publisher(for: .claudeSessionKeyDidChange).receive(on: RunLoop.main)) { _ in
            syncStoredSessionKeyState()
            syncClaudeAccountsState()
            selectedOrganizationID = appliedPreferredOrganizationID
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeAccountsDidChange).receive(on: RunLoop.main)) { _ in
            syncClaudeAccountsState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeAccountDidChange).receive(on: RunLoop.main)) { _ in
            cancelOrganizationLoad(clearState: true)
            cancelUsageHealthLoad(clearSnapshot: true)
            profileMetadata = nil
            syncStoredSessionKeyState()
            syncClaudeAccountsState()
            selectedOrganizationID = appliedPreferredOrganizationID
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeUsageHealthSnapshotDidChange).receive(on: RunLoop.main)) { notification in
            guard let snapshot = notification.object as? ClaudeAPIService.UsageHealthSnapshot else { return }
                let currentState = claudeAccountStore.state()
            guard let resolvedAccountState = ClaudeAccountSnapshotPresentationPolicy.resolve(
                snapshotActiveAccountID: snapshot.activeAccountID,
                currentState: currentState
            ) else { return }
            usageHealthSnapshot = snapshot
            claudeAccounts = resolvedAccountState.accounts
            activeClaudeAccountID = resolvedAccountState.activeAccountID
            let service = claudeAPIService
            Task {
                let metadata = await service.fetchCachedProfileMetadata()
                    guard snapshot.activeAccountID == claudeAccountStore.state().activeAccountID else { return }
                profileMetadata = metadata
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .runtimeProviderStateUpdated).receive(on: RunLoop.main)) { notification in
            guard notification.object as? PopoverService != nil else { return }
            // Claude/Codex 미리보기도 AppDelegate의 최신 runtime payload closure를
            // 다시 읽어야 한다. 계정 경계에서 payload가 초기화됐는데 이 tick이
            // 갱신되지 않으면 설정 창에 이전 계정 사용량이 남아 보인다.
            runtimeEnvironmentRefreshTick &+= 1
        }
            .onReceive(
                NotificationCenter.default.publisher(for: .settingsDestinationRequested).receive(on: RunLoop.main)
            ) {
                notification in
                guard let destination = notification.object as? SettingsDestination else { return }
                navigate(to: destination)
        }
        .onReceive(settings.$shouldRevealClaudeAdvancedAuth.removeDuplicates()) { shouldReveal in
            guard shouldReveal else { return }
                navigate(to: SettingsDestination(panel: .claude, section: .connection))
                withAnimation(settings.motion.animation(for: .disclosure, reduceMotion: reduceMotion)) {
                isAdvancedAuthExpanded = true
            }
            settings.shouldRevealClaudeAdvancedAuth = false
        }
    }

    private var settingsLayoutWithChanges: some View {
        settingsLayoutWithNotifications
            .onChange(of: sessionKey) { _, _ in
                testResult = nil
                lastVerifiedSessionKey = nil
            }
            .onChange(of: selectedOrganizationID) { _, _ in
                schedulePreferredOrganizationPersistence()
            }
            .onChange(of: selectedPanel, initial: true) { _, panel in
                if settings.settingsLastTab != panel.rawValue {
                    settings.settingsLastTab = panel.rawValue
                }
            }
            .onChange(of: settings.settingsLastTab) { _, rawValue in
                guard
                    let resolved = SettingsProviderPanel.resolve(
                        storedValue: rawValue, fallbackProvider: settings.activeProviderKind ?? .claude)
                else { return }
                if resolved.panel != selectedPanel {
                    navigate(to: SettingsDestination(panel: resolved.panel))
                }
            }
            .onChange(of: settings.updateCheckInterval) { _, _ in
                updateRuntimeState.refreshEngineStatus()
            }
    }

    private func performDestructiveAction(_ action: SettingsDestructiveAction) {
        switch action {
        case .resetDefaults: resetToDefaults()
        case .resetAllData(let plan):
            AppDataResetRequest.pending = plan
            NSApplication.shared.terminate(nil)
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        switch selectedPanel {
        case .welcome:
            welcomeSection
        case .common:
            commonServicesSection
            Divider()
            commonAlertSection
            notificationThresholdSection
            Divider()
            appDataResetSection
        case .display:
            commonDisplaySection
            Divider()
            timeFormatSection
            Divider()
            commonPopoverSection
            Divider()
            AppMotionSettingsView(settings: settings)
        case .updates:
            updateSection
        case .claude, .codex, .antigravity:
            if let provider = selectedPanel.providerKind { serviceSettingsPage(for: provider) }
        }
    }

    private func serviceSettingsPage(for provider: AppProviderKind) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.section) {
            VStack(alignment: .leading, spacing: AppDesign.Space.content) {
                switch provider {
                case .claude: authSection
                case .codex: codexAuthSection
                case .antigravity: antigravityConnectionSection
                }
                if let usageAccounts, let service = provider.runtimeService,
                    usageAccounts.supportsMultipleAccounts(service), settings.isProviderEnabled(provider)
                {
                    UsageAccountsSection(
                        controller: usageAccounts, service: service, onAdd: startAddingAccount,
                        onDeleteWebLogin: { webID in
                            if let account = claudeAccountStore.accounts().first(where: { $0.id == webID }) {
                                deleteClaudeWebAccount(account)
                            }
                        })
                }
            }
            .id(SettingsSection.connection)
            if settings.isProviderEnabled(provider) {
                Divider()
                providerMenuBarDisplaySection(for: provider)
                    .id(SettingsSection.menuBar)
                Divider()
                providerLimitsSection(for: provider)
                    .id(SettingsSection.limits)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings-section-limits")
                Divider()
                DisclosureGroup("팝오버 항목과 순서", isExpanded: $isPopoverSettingsExpanded) {
                    providerPopoverDisplaySection(for: provider)
                }
                .font(AppDesign.Typography.headline)
                .id(SettingsSection.popover)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings-section-popover")
            }
        }
        .scrollTargetLayout()
    }

    private func startAddingAccount(_ method: UsageAccountAddMethod) {
        switch method {
        case .browserImport: onImportClaudeFromBrowser?(nil)
        case .inAppLogin: onOpenLogin?()
        case .sessionKey:
            withAnimation(settings.motion.animation(for: .disclosure, reduceMotion: reduceMotion)) {
                isAdvancedAuthExpanded = true
            }
        case .deviceLogin, .folder: break
        }
    }

    private var sidebarSelection: Binding<SettingsProviderPanel?> {
        Binding(
            get: { selectedPanel },
            set: { panel in
                if let panel { navigate(to: SettingsDestination(panel: panel)) }
            })
    }

    func navigate(to destination: SettingsDestination) {
        selectedPanel = destination.panel
        if let provider = destination.panel.providerKind {
            selectedProvider = provider
        }
        sectionScrollPosition = nil
        requestedSection = destination.section
        isPopoverSettingsExpanded = destination.section == .popover
        navigationRevision &+= 1
    }

    private func prepareSettingsData(for provider: AppProviderKind) async {
        switch provider {
        case .claude:
            syncStoredSessionKeyState()
            syncClaudeAccountsState()
            selectedOrganizationID = appliedPreferredOrganizationID
            loadUsageHealthSnapshot()
            inspectClaudeOAuthMigration()
            await usageHealthLoadTask?.value
            await claudeOAuthMigrationTask?.value
        case .codex:
            checkCodexAuth()
            await codexAuthCheckTask?.value
        case .antigravity: await antigravitySettings.load()
        }
    }
}
