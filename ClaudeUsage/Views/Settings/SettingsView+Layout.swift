import AppKit
import SwiftUI
import Combine

extension SettingsView {
    var body: some View {
        settingsLayoutWithChanges
            .disclosureGroupStyle(AppDisclosureGroupStyle())
    }

    private var settingsLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar

                Divider()

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
                }
            }

            HStack {
                Spacer()
                Button("기본값 복원") { pendingDestructiveAction = .resetDefaults }
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppDesign.Space.page)
            .padding(.vertical, AppDesign.Space.content)
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
            selectedPanel = normalizedPanel(
                initialPanel
                    ?? SettingsProviderPanel(
                        rawValue: settings.settingsLastTab
                    )
                    ?? .common
            )
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
            selectedPanel = .claude
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
            if panel == .codex {
                checkCodexAuth()
            }
            // 패널 자체가 .antigravity 로 바뀌는 경우 background warm-up.
            switch panel {
            case .antigravity:
                Task {
                    await antigravitySettings.load()
                }
            default:
                break
            }
        }
        .onChange(of: settings.settingsLastTab) { _, rawValue in
            guard let panel = SettingsProviderPanel(
                rawValue: rawValue
            ), panel != selectedPanel else {
                return
            }
            selectedPanel = normalizedPanel(panel)
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
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        switch selectedPanel {
        case .welcome:
            welcomeSection
        case .common:
            commonServicesSection
        case .display:
            commonDisplaySection
            Divider()
            displayProviderSection
        case .notifications:
            commonAlertSection
            Divider()
            notificationThresholdSection
            Divider()
            notificationServicesSection
        case .updates:
            updateSection
        case .claude:
            claudeOverviewSection
        case .codex:
            codexOverviewSection
        case .antigravity:
            runtimeProviderPanel(for: .antigravity)
        }
    }

    private var contentIdentity: String {
        if selectedPanel == .display {
            return "\(selectedPanel.rawValue)-\(selectedDisplayProvider.rawValue)-panel"
        }
        return "\(selectedPanel.rawValue)-panel"
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

            providerTimeFormatSection(
                for:
                    selectedDisplayProvider
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            Text("설정")
                .font(AppDesign.Typography.headline)
                .padding(.horizontal, AppDesign.Space.row)
                .padding(.top, AppDesign.Space.compact)

            let panels = SettingsProviderRegistry.sidebarPanels
            ForEach(panels.filter { $0.providerKind == nil }) { panel in
                sidebarRow(panel)
            }

            Text("서비스")
                .font(AppDesign.Typography.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppDesign.Space.label)
                .padding(.top, AppDesign.Space.label)

            ForEach(panels.filter { $0.providerKind != nil }) { panel in
                sidebarRow(panel)
            }

            Spacer()
        }
        .padding(AppDesign.Space.content)
        .frame(width: 190)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func sidebarRow(_ panel: SettingsProviderPanelDescriptor) -> some View {
        Button {
            selectedPanel = panel.panel
        } label: {
            HStack(spacing: AppDesign.Space.row) {
                if let provider = panel.providerKind {
                    ProviderBrandIconView(provider: provider, kind: .settings, size: 16)
                        .frame(width: 16)
                } else if let icon = panel.icon {
                    Image(systemName: icon)
                        .frame(width: 16)
                }
                Text(panel.title)
                    .font(AppDesign.Typography.subheadline)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedPanel == panel.panel ? Color.accentColor : .primary)
        .padding(.horizontal, AppDesign.Space.label)
        .padding(.vertical, AppDesign.Space.row)
        .background(selectedPanel == panel.panel ? Color.accentColor.opacity(0.16) : Color.clear)
        .cornerRadius(AppDesign.Radius.group)
    }

    private func normalizedPanel(_ panel: SettingsProviderPanel) -> SettingsProviderPanel {
        panel
    }
}
