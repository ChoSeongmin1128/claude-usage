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
                    panelTabBar

                    Divider()

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
            refreshIntervalText = String(Int(settings.refreshInterval))
            alertPresetTexts = settings.sortedNotificationPresets.map { String($0.threshold) }
            selectedOrganizationID = settings.preferredOrganizationID
            selectedPanel = SettingsProviderPanel(rawValue: settings.settingsLastTab) ?? .common
            selectedClaudeTab = settings.providerSettingsLastTab(for: .claude)
            selectedCodexTab = settings.providerSettingsLastTab(for: .codex)
            selectedGeminiTab = settings.providerSettingsLastTab(for: .gemini)
            selectedAntigravityTab = settings.providerSettingsLastTab(for: .antigravity)
            loadUsageHealthSnapshot()
            checkCodexAuth()
            refreshUpdateEnginePresentation()
            // Settings 창이 뜬 순간부터 백그라운드에서 환경 감지 warm-up.
            // UI 스레드는 블로킹되지 않고, warm-up 완료 시 Notification 로 재렌더.
            ProviderEnvironmentDetector.refreshAllInBackground()
            AntigravityStatusProbe.refreshAllInBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeSessionKeyDidChange)) { _ in
            syncStoredSessionKeyState()
            loadUsageHealthSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .providerEnvironmentUpdated)) { _ in
            // 백그라운드 환경 감지 결과가 들어왔을 때 SettingsView 를 재렌더.
            // 각 패널의 runtimeEnvironmentRefreshTick 읽기가 dependency 를 만듦.
            runtimeEnvironmentRefreshTick &+= 1
        }
        .onChange(of: sessionKey) { _, _ in
            testResult = nil
            lastVerifiedSessionKey = nil
            scheduleSessionKeyPersistence()
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
                ProviderEnvironmentDetector.refreshStatusInBackground(for: .antigravity)
                ProviderEnvironmentDetector.refreshAntigravitySignalsInBackground()
                AntigravityStatusProbe.refreshAllInBackground()
            default:
                break
            }
        }
        .onChange(of: selectedClaudeTab) { _, tab in
            settings.setProviderSettingsLastTab(tab, for: .claude)
            if tab == .overview, organizations.isEmpty, !isLoadingOrganizations {
                loadOrganizations(forceRefresh: false)
            }
        }
        .onChange(of: selectedCodexTab) { _, tab in
            settings.setProviderSettingsLastTab(tab, for: .codex)
        }
        .onChange(of: selectedGeminiTab) { _, tab in
            settings.setProviderSettingsLastTab(tab, for: .gemini)
            // 탭 전환 시 환경 정보가 오래됐을 수 있으므로 백그라운드 갱신 예약.
            ProviderEnvironmentDetector.refreshStatusInBackground(for: .gemini)
            ProviderEnvironmentDetector.refreshGeminiSignalsInBackground()
        }
        .onChange(of: selectedAntigravityTab) { _, tab in
            settings.setProviderSettingsLastTab(tab, for: .antigravity)
            // Antigravity 는 /bin/ps · NSWorkspace · SQLite 를 건드리므로
            // 탭 전환 직전에 background warm-up 을 걸어서 UI 블로킹을 막는다.
            ProviderEnvironmentDetector.refreshStatusInBackground(for: .antigravity)
            ProviderEnvironmentDetector.refreshAntigravitySignalsInBackground()
            AntigravityStatusProbe.refreshAllInBackground()
        }
        .onChange(of: settings.updateCheckInterval) { _, _ in
            refreshUpdateEnginePresentation()
        }
        .onChange(of: settings.providerStates) { _, _ in
            checkCodexAuth()
        }
        .onReceive(settings.$shouldRevealClaudeAdvancedAuth.removeDuplicates()) { shouldReveal in
            guard shouldReveal else { return }
            selectedPanel = .claude
            selectedClaudeTab = .advanced
            withAnimation(.easeInOut(duration: 0.15)) {
                isAdvancedAuthExpanded = true
            }
            settings.shouldRevealClaudeAdvancedAuth = false
        }
        .onDisappear {
            flushPendingSessionKeyPersistence()
            flushPendingOrganizationPersistence()
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        switch selectedPanel {
        case .common:
            switch selectedCommonTab {
            case .display:
                commonDisplaySection
            case .refreshPower:
                refreshSection
                Divider()
                powerSection
            case .alerts:
                commonAlertSection
            case .app:
                updateSection
                Divider()
                generalSection
            }
        case .claude:
            switch selectedClaudeTab {
            case .overview:
                claudeOverviewSection
            case .display:
                claudeDisplayConfigurationSection
            case .alerts:
                claudeOverviewSection
            case .advanced:
                claudeAdvancedSettingsSection
            }
        case .codex:
            switch selectedCodexTab {
            case .overview:
                codexOverviewSection
            case .display:
                codexDisplayConfigurationSection
            case .alerts:
                codexOverviewSection
            case .advanced:
                codexAdvancedSection
            }
        case .gemini:
            runtimeProviderPanel(for: .gemini, tab: selectedGeminiTab)
        case .antigravity:
            runtimeProviderPanel(for: .antigravity, tab: selectedAntigravityTab)
        }
    }

    private var contentIdentity: String {
        switch selectedPanel {
        case .common:
            return "common-\(selectedCommonTab.rawValue)"
        case .claude:
            return "claude-\(selectedClaudeTab.rawValue)"
        case .codex:
            return "codex-\(selectedCodexTab.rawValue)"
        case .gemini:
            return "gemini-\(selectedGeminiTab.rawValue)"
        case .antigravity:
            return "antigravity-\(selectedAntigravityTab.rawValue)"
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("설정")
                .font(.headline)
                .padding(.horizontal, 8)
                .padding(.top, 4)

            ForEach(SettingsProviderRegistry.sidebarPanels) { panel in
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
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(panel.title)
                                    .font(.subheadline)
                                if let badge = panel.availability.badgeTitle {
                                    Text(badge)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let detail = panel.availability.detailMessage {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(selectedPanel == panel.panel ? Color.accentColor.opacity(0.16) : Color.clear)
                    .foregroundStyle(selectedPanel == panel.panel ? Color.accentColor : .primary)
                    .cornerRadius(8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(12)
        .frame(width: 156)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private var panelTabBar: some View {
        HStack(spacing: 8) {
            switch selectedPanel {
            case .common:
                ForEach(CommonTab.allCases) { tab in
                    segmentedTabButton(title: tab.title, isSelected: selectedCommonTab == tab) {
                        selectedCommonTab = tab
                    }
                }
            case .claude:
                ForEach(ProviderSettingsTab.tabs(for: .claude)) { tab in
                    segmentedTabButton(title: tab.title, isSelected: selectedClaudeTab == tab) {
                        selectedClaudeTab = tab
                    }
                }
            case .codex:
                ForEach(ProviderSettingsTab.tabs(for: .codex)) { tab in
                    segmentedTabButton(title: tab.title, isSelected: selectedCodexTab == tab) {
                        selectedCodexTab = tab
                    }
                }
            case .gemini:
                ForEach(ProviderSettingsTab.tabs(for: .gemini)) { tab in
                    segmentedTabButton(title: tab.title, isSelected: selectedGeminiTab == tab) {
                        selectedGeminiTab = tab
                    }
                }
            case .antigravity:
                ForEach(ProviderSettingsTab.tabs(for: .antigravity)) { tab in
                    segmentedTabButton(title: tab.title, isSelected: selectedAntigravityTab == tab) {
                        selectedAntigravityTab = tab
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}
