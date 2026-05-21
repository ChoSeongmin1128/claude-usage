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
                Button("기본값 복원") { resetToDefaults() }
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .frame(width: 760, height: 600)
        .onAppear {
            resetClaudeAuthDisclosureState()
            syncStoredSessionKeyState()
            testResult = nil
            syncClaudeAccountsState()
            selectedOrganizationID = appliedPreferredOrganizationID
            selectedPanel = SettingsProviderPanel(rawValue: settings.settingsLastTab) ?? .common
            loadUsageHealthSnapshot()
            checkCodexAuth()
            antigravityOAuthSettings.refreshAccounts()
            updateRuntimeState.bootstrapIfNeeded()
            // Settings 창이 뜬 순간부터 백그라운드에서 환경 감지 warm-up.
            // UI 스레드는 블로킹되지 않고, warm-up 완료 시 Notification 로 재렌더.
            ProviderEnvironmentDetector.refreshAllInBackground()
            AntigravityStatusProbe.refreshAllInBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeSessionKeyDidChange).receive(on: RunLoop.main)) { _ in
            syncStoredSessionKeyState()
            syncClaudeAccountsState()
            selectedOrganizationID = appliedPreferredOrganizationID
            loadUsageHealthSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeAccountsDidChange).receive(on: RunLoop.main)) { _ in
            syncClaudeAccountsState()
            selectedOrganizationID = appliedPreferredOrganizationID
            loadUsageHealthSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .providerEnvironmentUpdated).receive(on: RunLoop.main)) { _ in
            // 백그라운드 환경 감지 결과가 들어왔을 때 SettingsView 를 재렌더.
            // 각 패널의 runtimeEnvironmentRefreshTick 읽기가 dependency 를 만듦.
            runtimeEnvironmentRefreshTick &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .runtimeProviderStateUpdated).receive(on: RunLoop.main)) { notification in
            guard notification.object as? PopoverService == .antigravity else { return }
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
            // 패널 자체가 .gemini / .antigravity 로 바뀌는 경우 background warm-up.
            switch panel {
            case .gemini:
                ProviderEnvironmentDetector.refreshStatusInBackground(for: .gemini)
                ProviderEnvironmentDetector.refreshGeminiSignalsInBackground()
            case .antigravity:
                antigravityOAuthSettings.refreshAccounts()
                ProviderEnvironmentDetector.refreshStatusInBackground(for: .antigravity)
                ProviderEnvironmentDetector.refreshAntigravitySignalsInBackground()
                AntigravityStatusProbe.refreshAllInBackground()
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
            antigravityOAuthSettings.cancelLogin()
            cancelOrganizationLoad()
            flushPendingOrganizationPersistence()
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
        case .gemini:
            runtimeProviderPanel(for: .gemini)
            Divider()
            providerMenuBarDisplaySection(for: .gemini)
            Divider()
            providerPopoverDisplaySection(for: .gemini)
            Divider()
            providerAlertSection(for: .gemini)
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

            ForEach(SettingsProviderRegistry.sidebarPanels) { panel in
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
}
