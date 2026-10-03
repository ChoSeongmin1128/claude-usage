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

extension SettingsView {
    var body: some View {
        settingsLayoutWithChanges
            .disclosureGroupStyle(AppDisclosureGroupStyle())
            .background(SettingsFocusDismissalMonitor())
    }

    private var settingsLayout: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                if settings.welcomeState != .completed {
                    Label("빠른 시작", systemImage: "sparkles").tag(SettingsProviderPanel.welcome)
                }
                ForEach(SettingsProviderRegistry.sidebarPanels) { panel in
                    Label(panel.title, systemImage: panel.icon ?? "circle").tag(panel.panel)
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppDesign.Space.section) {
                        panelContent
                    }
                    .padding(AppDesign.Space.window)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(contentIdentity)
                    .transition(.opacity)
                    .animation(
                        settings.motion.animation(for: .navigation, reduceMotion: reduceMotion),
                        value: contentIdentity)
                }

                HStack {
                    Spacer()
                    Button("기본값 복원") { pendingDestructiveAction = .resetDefaults }
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, AppDesign.Space.page)
                .padding(.vertical, AppDesign.Space.content)
            }
        }
        .frame(
            minWidth: AppDesign.Window.settingsMinimum.width,
            idealWidth: AppDesign.Window.settingsIdeal.width,
            minHeight: AppDesign.Window.settingsMinimum.height,
            idealHeight: AppDesign.Window.settingsIdeal.height
        )
    }

    private var settingsLayoutWithDialog: some View {
        settingsLayout
        .confirmationDialog(
            pendingDestructiveAction?.title ?? "확인",
            isPresented: Binding(
                get: { pendingDestructiveAction != nil },
                set: { if !$0 { pendingDestructiveAction = nil } }
            ),
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
            if let action = pendingDestructiveAction {
                Text(action.detail)
            }
        }
    }

    private var settingsLayoutWithLifecycle: some View {
        settingsLayoutWithDialog
        .onAppear {
            resetClaudeAuthDisclosureState()
            syncStoredSessionKeyState()
            testResult = nil
            syncClaudeAccountsState()
            selectedOrganizationID = appliedPreferredOrganizationID
                let storedPanel = SettingsProviderPanel.resolve(storedValue: settings.settingsLastTab)
                selectedPanel = initialPanel ?? storedPanel?.panel ?? .common
                if let provider = storedPanel?.provider {
                    selectedAccountProvider = provider
                }
            if selectedPanel == .display,
               let activeProvider =
                settings
                    .providerSelectionState
                    .activeRuntimeKind
            {
                selectedDisplayProvider =
                    activeProvider
            }
            loadUsageHealthSnapshot()
            inspectClaudeOAuthMigration()
            checkCodexAuth()
            Task {
                await antigravitySettings.load()
            }
            updateRuntimeState.bootstrapIfNeeded()
        }
        .onDisappear {
            codexAuthCheckTask?.cancel()
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
            let currentState = ClaudeAccountStore.shared.state()
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
                guard snapshot.activeAccountID == ClaudeAccountStore.shared.state().activeAccountID else { return }
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
            NotificationCenter.default
                .publisher(
                    for:
                        .settingsDisplayProviderRequested
                )
                .receive(on: RunLoop.main)
        ) { notification in
            guard let provider =
                    notification.object
                        as? AppProviderKind
            else {
                return
            }
            selectedDisplayProvider =
                provider
        }
        .onReceive(settings.$shouldRevealClaudeAdvancedAuth.removeDuplicates()) { shouldReveal in
            guard shouldReveal else { return }
                selectedPanel = .accounts
                selectedAccountProvider = .claude
                withAnimation(settings.motion.animation(for: .disclosure, reduceMotion: reduceMotion)) {
                isAdvancedAuthExpanded = true
            }
            settings.shouldRevealClaudeAdvancedAuth = false
        }
    }

    private var settingsLayoutWithChanges:
        some View
    {
        settingsLayoutWithNotifications
        .onChange(of: sessionKey) { _, _ in
            testResult = nil
            lastVerifiedSessionKey = nil
        }
        .onChange(of: selectedOrganizationID) { _, _ in
            schedulePreferredOrganizationPersistence()
        }
        .onChange(of: selectedPanel) { _, panel in
            settings.settingsLastTab = panel.rawValue
                if panel == .accounts {
                    accountProviderDidAppear(selectedAccountProvider)
            }
        }
            .onChange(of: selectedAccountProvider) { _, provider in
                accountProviderDidAppear(provider)
            }
        .onChange(of: settings.settingsLastTab) { _, rawValue in
                guard let resolved = SettingsProviderPanel.resolve(storedValue: rawValue) else { return }
                if let provider = resolved.provider {
                    selectedAccountProvider = provider
                }
                if resolved.panel != selectedPanel {
                    selectedPanel = resolved.panel
            }
        }
        .onChange(of: settings.updateCheckInterval) { _, _ in
            updateRuntimeState.refreshEngineStatus()
        }
        .onChange(of: settings.providerStates) { _, _ in
            checkCodexAuth()
        }
    }

    private func performDestructiveAction(_ action: SettingsDestructiveAction) {
        switch action {
        case .resetDefaults:
            resetToDefaults()
        case .clearBrowserSession:
            handleClearBrowserSessionAction()
        case .deleteClaudeAccount(let account):
            deleteClaudeWebAccount(account)
        case .disconnectAntigravityAccount:
            disconnectSelectedAntigravityAccount()
        case .disconnectAllAntigravityAccounts:
            disconnectAllAntigravityAccounts()
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
            providerTimeFormatSection(for: selectedDisplayProvider)
            Divider()
            appDataResetSection
        case .accounts:
            ProviderSettingsPicker(selection: $selectedAccountProvider)
            Divider()
            if let usageAccounts, let service = selectedAccountProvider.runtimeService, service != .antigravity {
                UsageAccountsSection(
                    controller: usageAccounts, service: service,
                    onLoginClaude: { onImportClaudeFromBrowser?(nil) },
                    onOpenClaudeInAppLogin: { onOpenLogin?() },
                    onEnterClaudeSessionKey: {
                        withAnimation(settings.motion.animation(for: .disclosure, reduceMotion: reduceMotion)) {
                            isAdvancedAuthExpanded = true
                        }
                    },
                    onDeleteWebLogin: { webID in
                        if let account = ClaudeAccountStore.shared.accounts().first(where: { $0.id == webID }) {
                            deleteClaudeWebAccount(account)
                        }
                    })
                Divider()
            }
            switch selectedAccountProvider {
            case .claude: claudeOverviewSection
            case .codex: codexOverviewSection
            case .antigravity: runtimeProviderPanel(for: .antigravity)
            }
        case .limits:
            limitsPanel
        case .display:
            commonDisplaySection
            Divider()
            displayProviderSection
            Divider()
            AppMotionSettingsView(settings: settings)
        case .updates:
            updateSection
        }
    }

    private var sidebarSelection: Binding<SettingsProviderPanel?> {
        Binding(get: { selectedPanel }, set: { if let panel = $0 { selectedPanel = panel } })
    }

    private func accountProviderDidAppear(_ provider: AppProviderKind) {
        switch provider {
        case .codex: checkCodexAuth()
        case .antigravity: Task { await antigravitySettings.load() }
        case .claude: break
        }
    }

    private var contentIdentity: String {
        switch selectedPanel {
        case .display: return "\(selectedPanel.rawValue)-\(selectedDisplayProvider.rawValue)-panel"
        case .accounts: return "\(selectedPanel.rawValue)-\(selectedAccountProvider.rawValue)-panel"
        default: return "\(selectedPanel.rawValue)-panel"
        }
    }

    private var displayProviderSection:
        some View
    {
        VStack(
            alignment: .leading,
            spacing: 16
        ) {
            VStack(
                alignment: .leading,
                spacing: 5
            ) {
                Text("서비스별 표시")
                    .font(AppDesign.Typography.headline)
                Text(
                    "서비스를 선택해 메뉴바와 팝오버 구성을 조정합니다."
                )
                .font(AppDesign.Typography.caption)
                .foregroundStyle(.secondary)
            }

            ProviderSettingsPicker(
                selection:
                    $selectedDisplayProvider
            )

            Divider()

            providerMenuBarDisplaySection(
                for:
                    selectedDisplayProvider
            )

            Divider()

            providerPopoverDisplaySection(
                for:
                    selectedDisplayProvider
            )
        }
    }
}
