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
                Button("기본값 복원") { resetToDefaults() }
                    .foregroundStyle(.secondary)
                Spacer()
                Button("취소") { onCancel?() }
                    .keyboardShortcut(.cancelAction)
                Button("적용") { applyChanges() }
                Button("확인") { confirmChanges() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
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
            selectedClaudeTab = ClaudeTab(rawValue: settings.providerSettingsLastTab(for: .claude)) ?? .auth
            selectedCodexTab = CodexTab(rawValue: settings.providerSettingsLastTab(for: .codex)) ?? .auth
            selectedGeminiTab = RuntimeProviderTab(rawValue: settings.providerSettingsLastTab(for: .gemini)) ?? .auth
            selectedAntigravityTab = RuntimeProviderTab(rawValue: settings.providerSettingsLastTab(for: .antigravity)) ?? .auth
            loadUsageHealthSnapshot()
            checkCodexAuth()
            refreshUpdateEnginePresentation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeSessionKeyDidChange)) { _ in
            syncStoredSessionKeyState()
            loadUsageHealthSnapshot()
        }
        .onChange(of: selectedPanel) { _, panel in
            settings.settingsLastTab = panel.rawValue
            if panel == .codex {
                checkCodexAuth()
            }
        }
        .onChange(of: selectedClaudeTab) { _, tab in
            settings.setProviderSettingsLastTab(tab.rawValue, for: .claude)
            if tab == .organizations, organizations.isEmpty, !isLoadingOrganizations {
                loadOrganizations(forceRefresh: false)
            }
        }
        .onChange(of: selectedCodexTab) { _, tab in
            settings.setProviderSettingsLastTab(tab.rawValue, for: .codex)
        }
        .onChange(of: selectedGeminiTab) { _, tab in
            settings.setProviderSettingsLastTab(tab.rawValue, for: .gemini)
        }
        .onChange(of: selectedAntigravityTab) { _, tab in
            settings.setProviderSettingsLastTab(tab.rawValue, for: .antigravity)
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
            selectedClaudeTab = .auth
            withAnimation(.easeInOut(duration: 0.15)) {
                isClaudeAdvancedSectionExpanded = true
                isAdvancedAuthExpanded = true
            }
            settings.shouldRevealClaudeAdvancedAuth = false
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
            case .auth:
                authSection
            case .display:
                claudeDisplaySection
            case .status:
                statusSection
            case .organizations:
                organizationSection
            case .popover:
                popoverItemsSection
            case .alerts:
                alertSection
            }
        case .codex:
            switch selectedCodexTab {
            case .auth:
                codexAuthSection
            case .display:
                codexDisplaySection
            case .popover:
                codexPopoverItemsSection
            case .alerts:
                codexAlertSection
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
                ForEach(ClaudeTab.allCases) { tab in
                    segmentedTabButton(title: tab.title, isSelected: selectedClaudeTab == tab) {
                        selectedClaudeTab = tab
                    }
                }
            case .codex:
                ForEach(CodexTab.allCases) { tab in
                    segmentedTabButton(title: tab.title, isSelected: selectedCodexTab == tab) {
                        selectedCodexTab = tab
                    }
                }
            case .gemini:
                ForEach(RuntimeProviderTab.allCases) { tab in
                    segmentedTabButton(title: tab.title, isSelected: selectedGeminiTab == tab) {
                        selectedGeminiTab = tab
                    }
                }
            case .antigravity:
                ForEach(RuntimeProviderTab.allCases) { tab in
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
