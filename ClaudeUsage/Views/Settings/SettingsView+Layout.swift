import AppKit
import SwiftUI
import Combine

extension SettingsView {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar

                Divider()

                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            panelContent
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(contentIdentity)
                    }
                }
            }

            HStack {
                Spacer()
                Button("기본값 복원") { pendingDestructiveAction = .resetDefaults }
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .frame(width: 760, height: 600)
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
        .onAppear {
            resetClaudeAuthDisclosureState()
            syncStoredSessionKeyState()
            testResult = nil
            syncClaudeAccountsState()
            selectedOrganizationID = appliedPreferredOrganizationID
            selectedPanel = normalizedPanel(SettingsProviderPanel(rawValue: settings.settingsLastTab) ?? .common)
            loadUsageHealthSnapshot()
            inspectClaudeOAuthMigration()
            checkCodexAuth()
            Task {
                await antigravitySettings.load()
            }
            updateRuntimeState.bootstrapIfNeeded()
        }
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
        .onChange(of: settings.updateCheckInterval) { _, _ in
            updateRuntimeState.refreshEngineStatus()
        }
        .onChange(of: settings.providerStates) { _, _ in
            checkCodexAuth()
        }
        .onChange(of: settings.additionalRuntimeProvidersEnabled) { _, isEnabled in
            checkCodexAuth()
            guard !isEnabled,
                  let provider = SettingsProviderRegistry.descriptor(for: selectedPanel).providerKind,
                  provider.requiresAdditionalProviderOptIn else { return }
            selectedPanel = .common
        }
        .onReceive(settings.$shouldRevealClaudeAdvancedAuth.removeDuplicates()) { shouldReveal in
            guard shouldReveal else { return }
            selectedPanel = .claude
            withAnimation(.easeInOut(duration: 0.15)) {
                isAdvancedAuthExpanded = true
            }
            settings.shouldRevealClaudeAdvancedAuth = false
        }
        .onDisappear {
            codexAuthCheckTask?.cancel()
            antigravitySettings.stopObserving()
            cancelOrganizationLoad()
            flushPendingOrganizationPersistence()
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
        case .common:
            commonServicesSection
            Divider()
            commonAlertSection
            Divider()
            updateSection
            Divider()
            commonDisplaySection
        case .claude:
            claudeOverviewSection
            Divider()
            providerMenuBarDisplaySection(for: .claude)
            Divider()
            providerPopoverDisplaySection(for: .claude)
            Divider()
            providerAlertSection(for: .claude)
        case .codex:
            codexOverviewSection
            Divider()
            providerMenuBarDisplaySection(for: .codex)
            Divider()
            providerPopoverDisplaySection(for: .codex)
            Divider()
            providerAlertSection(for: .codex)
        case .antigravity:
            runtimeProviderPanel(for: .antigravity)
            Divider()
            providerMenuBarDisplaySection(for: .antigravity)
            Divider()
            providerPopoverDisplaySection(for: .antigravity)
            Divider()
            providerAlertSection(for: .antigravity)
        }
    }

    private var contentIdentity: String {
        "\(selectedPanel.rawValue)-panel"
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("설정")
                .font(.headline)
                .padding(.horizontal, 8)
                .padding(.top, 4)

            ForEach(SettingsProviderRegistry.sidebarPanels(exposurePolicy: settings.providerExposurePolicy)) { panel in
                sidebarRow(panel)
            }

            Spacer()
        }
        .padding(12)
        .frame(width: 190)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func sidebarRow(_ panel: SettingsProviderPanelDescriptor) -> some View {
        HStack(spacing: 6) {
            Button {
                selectedPanel = panel.panel
            } label: {
                HStack(spacing: 8) {
                    if let provider = panel.providerKind {
                        ProviderBrandIconView(provider: provider, kind: .settings, size: 16)
                            .frame(width: 16)
                    } else {
                        Image(systemName: panel.icon)
                            .frame(width: 16)
                    }
                    Text(panel.title)
                        .font(.subheadline)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(selectedPanel == panel.panel ? Color.accentColor : .primary)

            if let provider = panel.providerKind {
                Toggle("", isOn: providerEnabledBinding(for: provider))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel("\(provider.displayName) 사용")
                    .help(settings.isProviderEnabled(provider) ? "\(provider.displayName) 사용 중" : "\(provider.displayName) 사용 안 함")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selectedPanel == panel.panel ? Color.accentColor.opacity(0.16) : Color.clear)
        .cornerRadius(8)
    }

    private func providerEnabledBinding(for provider: AppProviderKind) -> Binding<Bool> {
        Binding(
            get: { settings.isProviderEnabled(provider) },
            set: { settings.setProviderEnabled($0, for: provider) }
        )
    }

    private func normalizedPanel(_ panel: SettingsProviderPanel) -> SettingsProviderPanel {
        guard let provider = SettingsProviderRegistry.descriptor(for: panel).providerKind,
              !settings.isProviderExposed(provider) else {
            return panel
        }
        return .common
    }
}
