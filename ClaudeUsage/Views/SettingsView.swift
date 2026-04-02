//
//  SettingsView.swift
//  ClaudeUsage
//
//  Phase 3: 완전한 설정 창
//

import SwiftUI
import Combine
import UniformTypeIdentifiers


struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @StateObject private var settingsViewModel = SettingsViewModel()
    @State private var sessionKey: String = ""
    @State private var storedSessionKey: String?
    @State private var testResult: TestResult?
    @State private var isTesting: Bool = false
    @State private var refreshIntervalText: String = ""
    @State private var showKeyHelp: Bool = false
    @State private var alertPresetTexts: [String] = []
    @State private var draggingItemID: String?
    @State private var codexDraggingItemID: String?
    @State private var compactConfigTab: Int = 0
    @State private var codexCompactConfigTab: Int = 0
    @State private var selectedOrganizationID: String = ""
    @State private var organizations: [ClaudeAPIService.OrganizationSummary] = []
    @State private var organizationPreviews: [ClaudeAPIService.OrganizationPreview] = []
    @State private var isLoadingOrganizations = false
    @State private var isLoadingOrganizationPreviews = false
    @State private var organizationMessage: String?
    @State private var organizationOAuthFallbackSummary: String?
    @State private var usageHealthSnapshot: ClaudeAPIService.UsageHealthSnapshot?
    @State private var profileMetadata: ClaudeProfileMetadata?
    @State private var selectedPanel: SettingsProviderPanel = .common
    @State private var selectedCommonTab: CommonTab = .display
    @State private var selectedClaudeTab: ClaudeTab = .auth
    @State private var selectedCodexTab: CodexTab = .auth
    @State private var isAdvancedAuthExpanded = false
    @State private var isClaudeAdvancedSectionExpanded = false
    @State private var isOAuthGuideExpanded = false
    @State private var isAuthFAQExpanded = false
    @State private var isMessagesFallbackExpanded = false
    @State private var isTestingMessagesFallback = false
    @State private var messagesFallbackStatus: String?
    @State private var codexAuthStatus: CodexAuthStatus = .checking

    var onSave: (() -> Void)?
    var onApply: (() -> Void)?
    var onCancel: (() -> Void)?
    var onOpenLogin: (() -> Void)?
    var onOpenClaudeInChrome: (() -> Void)?
    var onLogout: (() -> Void)?
    var onCodexLogout: (() -> Void)?

    enum TestResult {
        case success
        case failure(String)
    }

    enum CommonTab: String, CaseIterable, Identifiable {
        case display
        case refreshPower
        case alerts
        case app

        var id: String { rawValue }

        var title: String {
            switch self {
            case .display: return "표시"
            case .refreshPower: return "갱신/전원"
            case .alerts: return "알림"
            case .app: return "앱"
            }
        }
    }

    enum ClaudeTab: String, CaseIterable, Identifiable {
        case auth
        case display
        case status
        case organizations
        case popover
        case alerts

        var id: String { rawValue }

        var title: String {
            switch self {
            case .auth: return "인증"
            case .display: return "표시"
            case .status: return "상태"
            case .organizations: return "Organization"
            case .popover: return "표시 항목"
            case .alerts: return "알림"
            }
        }
    }

    enum CodexTab: String, CaseIterable, Identifiable {
        case auth
        case display
        case popover
        case alerts

        var id: String { rawValue }

        var title: String {
            switch self {
            case .auth: return "인증"
            case .display: return "표시"
            case .popover: return "표시 항목"
            case .alerts: return "알림"
            }
        }
    }

    private enum CodexAuthStatus {
        case checking
        case authenticated
        case notInstalled
        case notLoggedIn
        case expired
    }

    private var isRefreshIntervalValid: Bool {
        guard let val = Int(refreshIntervalText) else { return false }
        return val >= 5 && val <= 120
    }

    private var sessionKeyFormatWarning: String? {
        guard !sessionKey.isEmpty else { return nil }
        let normalized = normalizeSessionKey(sessionKey)
        if !normalized.hasPrefix("sk-ant-") {
            return "세션 키는 보통 sk-ant-로 시작합니다"
        }
        return nil
    }

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

            // 하단 버튼
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
            if let key = KeychainManager.shared.load() {
                storedSessionKey = key
                sessionKey = key
            } else {
                storedSessionKey = nil
                sessionKey = ""
            }
            testResult = nil
            refreshIntervalText = String(Int(settings.refreshInterval))
            alertPresetTexts = settings.sortedNotificationPresets.map { String($0.threshold) }
            selectedOrganizationID = settings.preferredOrganizationID
            selectedPanel = SettingsProviderPanel(rawValue: settings.settingsLastTab) ?? .common
            selectedClaudeTab = ClaudeTab(rawValue: settings.providerSettingsLastTab(for: .claude)) ?? .auth
            selectedCodexTab = CodexTab(rawValue: settings.providerSettingsLastTab(for: .codex)) ?? .auth
            refreshSetupWizardState()
            loadUsageHealthSnapshot()
            checkCodexAuth()
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
        .onChange(of: settings.providerStates) { _, _ in
            checkCodexAuth()
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
        case .gemini, .antigravity:
            comingSoonSection
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
        case .gemini, .antigravity:
            return "\(selectedPanel.rawValue)-coming-soon"
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
                        Image(systemName: panel.icon)
                            .frame(width: 16)
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
            case .gemini, .antigravity:
                Label("추가 provider 준비 상태", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
                    .cornerRadius(8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var selectedPanelDescriptor: SettingsProviderPanelDescriptor {
        SettingsProviderRegistry.descriptor(for: selectedPanel)
    }

    private var selectedProviderKind: AppProviderKind? {
        switch selectedPanel {
        case .common:
            return nil
        case .claude:
            return .claude
        case .codex:
            return .codex
        case .gemini:
            return .gemini
        case .antigravity:
            return .antigravity
        }
    }

    private var comingSoonSection: some View {
        let descriptor = selectedPanelDescriptor
        let shellDescriptor: ProviderShellDescriptor? = {
            guard let provider = selectedProviderKind else { return nil }
            return SettingsProviderRegistry.providerShellDescriptor(for: provider)
        }()
        let selectionState = settings.providerSelectionState
        return VStack(alignment: .leading, spacing: 12) {
            Label(descriptor.title, systemImage: descriptor.icon)
                .font(.headline)

            if let message = descriptor.availability.detailMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let shellDescriptor {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(shellDescriptor.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let badge = shellDescriptor.role.badgeTitle {
                            Text(badge)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let detail = shellDescriptor.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
            }

            if let provider = selectedProviderKind,
               let environmentStatus = ProviderEnvironmentDetector.status(for: provider)
            {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: environmentStatus.isDetected ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(environmentStatus.isDetected ? .green : .orange)
                        .padding(.top, 1)
                    Text(environmentStatus.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
            }

            if let provider = selectedProviderKind {
                Toggle(
                    "\(descriptor.title) provider 활성화",
                    isOn: Binding(
                        get: { settings.isProviderEnabled(provider) },
                        set: { settings.setProviderEnabled($0, for: provider) }
                    )
                )

                Text(shellSectionFootnote(for: provider, selectionState: selectionState))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func segmentedTabButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor.opacity(0.18) : Color(NSColor.controlBackgroundColor).opacity(0.45))
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 인증 섹션

    private var authSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("인증", systemImage: "key")
                .font(.headline)

            Toggle(
                "Claude 모니터링 활성화",
                isOn: Binding(
                    get: { settings.isProviderEnabled(.claude) },
                    set: { settings.setProviderEnabled($0, for: .claude) }
                )
            )

            if settings.isProviderEnabled(.claude) {
                if shouldShowAuthSetupFlow {
                    authSetupFlowCard
                }
                generalAuthGuidanceCard
                authStatusSection

                if let storedSessionKey, !storedSessionKey.isEmpty {
                    // 저장된 세션 키 존재
                    HStack(spacing: 8) {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                            Text("확인 중...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let result = testResult {
                            switch result {
                            case .success:
                                Label("연결 확인됨", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            case .failure(let msg):
                                Label(msg, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                            }
                        } else {
                            Label("세션 키 저장됨", systemImage: "key.fill")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Text("세션 키: \(String(storedSessionKey.prefix(20)))...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if case .success = testResult {} else {
                            Button("다시 로그인") { onOpenLogin?() }
                        }
                        Button("로그아웃") { handleLogoutAction() }
                            .foregroundStyle(.red)
                    }
                } else {
                    Button(action: { onOpenLogin?() }) {
                        Label("Chrome 또는 웹 로그인", systemImage: "person.crop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text("먼저 Chrome 자동 가져오기를 시도하고, 실패하면 웹 로그인으로 sessionKey를 추출합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                claudeAdvancedSection
            } else {
                Text("Claude 모니터링이 비활성화되어 있습니다. 활성화하면 메뉴바와 조회가 다시 동작합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
        }
    }

    private var claudeAdvancedSection: some View {
        DisclosureGroup(isExpanded: $isClaudeAdvancedSectionExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                manualSessionKeySection
                messagesFallbackSection
                authFAQSection
            }
            .padding(.top, 4)
        } label: {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isClaudeAdvancedSectionExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("고급 설정")
                    Spacer(minLength: 0)
                    Text("수동 입력 · fallback · FAQ")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .font(.subheadline)
    }

    private var generalAuthGuidanceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionCardHeader(
                title: "일반 사용자 흐름",
                subtitle: "빠른 시작 · 인증 방식 · 표시 기준"
            )

            authNoticeCard
            oauthQuickGuideSection
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private var authStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionCardHeader(
                title: "인증 상태",
                subtitle: "세션키 · OAuth · 계정 메타데이터"
            )

            authChecklistCard
            profileMetadataCard
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private var manualSessionKeySection: some View {
        DisclosureGroup(isExpanded: $isAdvancedAuthExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Chrome import가 실패했을 때만 이 값을 직접 입력합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Text("세션 키 직접 입력")
                        .font(.subheadline)
                    Button(action: { showKeyHelp.toggle() }) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showKeyHelp) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("수동 입력 방법")
                                .font(.headline)
                            Text("1. claude.ai에 로그인")
                            Text("2. ⌘⌥I (Cmd+Opt+I)로 개발자 도구 열기")
                            Text("3. Application 탭 → Cookies → https://claude.ai")
                            Text("4. sessionKey의 값만 복사")
                        }
                        .font(.callout)
                        .padding(16)
                        .frame(width: 320)
                    }
                }

                TextField("sk-ant-... 값만 붙여넣기", text: $sessionKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))

                Text("전체 쿠키 문자열이 아니라 sessionKey 값만 입력하고, 저장 후 적용됩니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let warning = sessionKeyFormatWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Button("연결 테스트") { testConnection() }
                        .disabled(sessionKey.isEmpty || isTesting)

                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let result = testResult {
                        switch result {
                        case .success:
                            Label("연결 성공", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        case .failure(let msg):
                            Label(msg, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isAdvancedAuthExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("수동 sessionKey")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .font(.subheadline)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("조회 상태", systemImage: "waveform.path.ecg")
                .font(.headline)

            runtimeStatusSummaryCard
            usageHealthSection
        }
    }

    private var authChecklistCard: some View {
        let hasSessionCredential = !(storedSessionKey ?? "").isEmpty || !normalizeSessionKey(sessionKey).isEmpty
        let hasOAuthCredential = usageHealthSnapshot?.runtime.credentialAvailability.oauthCredentialAvailable ?? false
        let hasOAuthSuccess = usageHealthSnapshot?.oauth.lastSuccessAt != nil
        let hasAnySuccessfulFetch = hasSuccessfulClaudeFetch
        let organizationReady = isOrganizationSelectionReady

        return VStack(alignment: .leading, spacing: 8) {
            Text("인증 체크리스트")
                .font(.caption)
                .foregroundStyle(.secondary)

            checklistRow(
                title: "자격 준비",
                detail: hasSessionCredential ? "세션키 감지됨" : (hasOAuthCredential ? "OAuth 자격 감지됨" : (hasOAuthSuccess ? "OAuth 성공 이력 감지됨" : "세션키 또는 OAuth 준비 필요")),
                state: hasSessionCredential || hasOAuthCredential || hasOAuthSuccess ? .ok : .warning
            )
            checklistRow(
                title: "조회 검증",
                detail: hasAnySuccessfulFetch ? "최근 성공 조회 있음" : "연결 테스트 또는 상태 새로고침이 필요합니다",
                state: hasAnySuccessfulFetch ? .ok : .warning
            )
            checklistRow(
                title: "Organization 확인",
                detail: organizationChecklistDetail,
                state: organizationReady ? .ok : .warning
            )
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private var authSetupFlowCard: some View {
        SetupWizardView(
            currentStep: currentSetupWizardStep,
            hasReadyCredential: hasReadyClaudeCredential,
            isAdvancedExpanded: isAdvancedAuthExpanded,
            onOpenChrome: {
                onOpenClaudeInChrome?()
            },
            onOpenWebLogin: {
                onOpenLogin?()
            },
            onOpenAdvanced: {
                isClaudeAdvancedSectionExpanded = true
                isAdvancedAuthExpanded = true
            },
            onDismiss: {
                settings.hasCompletedSetupWizard = true
            }
        )
    }

    private var hasReadyClaudeCredential: Bool {
        let normalized = normalizeSessionKey(sessionKey)
        let hasOAuthCredential = usageHealthSnapshot?.runtime.credentialAvailability.oauthCredentialAvailable ?? false
        return !(storedSessionKey ?? "").isEmpty || !normalized.isEmpty || hasOAuthCredential || usageHealthSnapshot?.lastOverallSuccessAt != nil
    }

    private var hasSuccessfulClaudeFetch: Bool {
        usageHealthSnapshot?.lastOverallSuccessAt != nil
    }

    private var isOrganizationSelectionReady: Bool {
        guard hasSuccessfulClaudeFetch else { return false }
        if selectedOrganizationID.isEmpty {
            return true
        }
        if organizations.contains(where: { $0.id == selectedOrganizationID }) {
            return true
        }
        return organizationPreviews.contains(where: { $0.id == selectedOrganizationID })
    }

    private var organizationChecklistDetail: String {
        guard hasSuccessfulClaudeFetch else {
            return "첫 성공 조회 후 organization 상태를 확인합니다"
        }
        if selectedOrganizationID.isEmpty {
            return "자동 선택 모드"
        }
        return isOrganizationSelectionReady ? "선택한 organization이 유효합니다" : "선택값이 목록에 없습니다"
    }

    private var shouldShowAuthSetupFlow: Bool {
        !settings.hasCompletedSetupWizard || !hasReadyClaudeCredential || !hasSuccessfulClaudeFetch || !isOrganizationSelectionReady
    }

    private var currentSetupWizardStep: SetupWizardView.Step {
        if hasReadyClaudeCredential {
            return .chromeImport
        }
        if isAdvancedAuthExpanded || !(storedSessionKey ?? "").isEmpty || !normalizeSessionKey(sessionKey).isEmpty {
            return .manualSessionKey
        }
        if isOAuthGuideExpanded {
            return .webLogin
        }
        return .chromeImport
    }

    private var authNoticeCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("안내")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("일반 경로는 Chrome import와 웹 로그인입니다. 수동 sessionKey와 Messages fallback은 고급 설정에서만 다룹니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.55))
        .cornerRadius(6)
    }

    @ViewBuilder
    private var profileMetadataCard: some View {
        if let metadata = profileMetadata, !metadata.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("감지된 계정 메타데이터")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let updatedAt = metadata.lastUpdatedAt {
                        Text(shortRelativeTimestamp(updatedAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                LazyVGrid(columns: [
                    GridItem(.flexible(minimum: 140), alignment: .leading),
                    GridItem(.flexible(minimum: 140), alignment: .leading)
                ], alignment: .leading, spacing: 8) {
                    metadataField(title: "Organization", value: metadata.organizationUUID)
                    metadataField(title: "구독", value: metadata.subscriptionType)
                    metadataField(title: "Rate Limit Tier", value: metadata.rateLimitTier)
                    metadataField(title: "Billing", value: metadata.billingType)
                    metadataField(
                        title: "추가 사용량",
                        value: metadata.hasExtraUsageEnabled.map { $0 ? "활성" : "비활성" }
                    )
                    metadataField(title: "계정 생성", value: formattedMetadataDate(metadata.accountCreatedAt))
                    metadataField(title: "구독 시작", value: formattedMetadataDate(metadata.subscriptionCreatedAt))
                }
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)
        }
    }

    private var oauthQuickGuideSection: some View {
        DisclosureGroup(isExpanded: $isOAuthGuideExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                Text("1. `Chrome 또는 웹 로그인`을 누릅니다.")
                Text("2. 로그인 창에서 `Chrome에서 가져오기`를 먼저 시도합니다.")
                Text("3. 실패하면 같은 창에서 웹 로그인으로 sessionKey 추출을 시도합니다.")
                Text("4. 계속 실패하면 고급 설정에서 sessionKey 값만 직접 입력합니다.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        } label: {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isOAuthGuideExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("권장 일반 경로")
                    Spacer(minLength: 0)
                    Text("Chrome import → 웹 로그인")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .font(.subheadline)
    }

    private func sectionCardHeader(title: String, subtitle: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var authFAQSection: some View {
        DisclosureGroup(isExpanded: $isAuthFAQExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Q. Claude CLI는 어떻게 설치하나요?")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("A. macOS에서는 `brew install --cask claude-code`를 권장합니다. 대안으로 `curl -fsSL https://claude.ai/install.sh | bash`도 사용할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Q. `claude` 명령어가 없다고 나옵니다.")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("A. Claude CLI가 설치되지 않은 상태입니다. CLI 설치 후 `claude login`을 다시 실행해 주세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Q. 로그인했는데 앱에 반영되지 않습니다.")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("A. 앱을 완전히 종료 후 다시 실행하거나, 이 화면에서 '상태 새로고침'을 눌러주세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Q. 세션키는 왜 실패하나요?")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("A. 세션키 경로는 서비스 제한(429/Cloudflare/서버 오류)에 영향을 받을 수 있어 OAuth보다 불안정할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        } label: {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isAuthFAQExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("자주 묻는 질문 (FAQ)")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .font(.subheadline)
    }

    private var messagesFallbackSection: some View {
        DisclosureGroup(isExpanded: $isMessagesFallbackExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("동작:", selection: $settings.claudeMessagesFallbackPolicy) {
                    ForEach(ClaudeMessagesFallbackPolicy.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)

                if settings.claudeMessagesFallbackPolicy == .automatic {
                    HStack(alignment: .center, spacing: 8) {
                        Text("자동 중지 기준")
                            .font(.subheadline)
                        Stepper(
                            value: Binding(
                                get: { settings.claudeMessagesFallbackAutoDisableBelowPercent },
                                set: { settings.claudeMessagesFallbackAutoDisableBelowPercent = settingsViewModel.clampFallbackThreshold($0) }
                            ),
                            in: 0...100,
                            step: 5
                        ) {
                            Text("\(settings.claudeMessagesFallbackAutoDisableBelowPercent)% 미만")
                                .font(.subheadline)
                        }
                        .labelsHidden()
                    }

                    Text(settingsViewModel.messagesFallbackThresholdHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if settings.claudeMessagesFallbackPolicy == .manual {
                    Text("수동 보조 모드에서는 사용자가 직접 fallback 경로를 사용할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("기능이 꺼져 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if settings.claudeMessagesFallbackPolicy != .off {
                    HStack(spacing: 10) {
                        Button(isTestingMessagesFallback ? "복구 확인 중..." : "보조 복구 테스트") {
                            runMessagesFallbackTest()
                        }
                        .disabled(isTestingMessagesFallback)

                        if let messagesFallbackStatus {
                            Text(messagesFallbackStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text("보조 사용량 복구")
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .help(settingsViewModel.messagesFallbackHelpText)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .font(.subheadline)
    }

    private var usageHealthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("경로 상태")
                    .font(.subheadline)
                Spacer()
                Button("상태 새로고침") {
                    loadUsageHealthSnapshot()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            if let snapshot = usageHealthSnapshot {
                Text("마지막 성공 조회: \(formattedTimestamp(snapshot.lastOverallSuccessAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    authPathHealthRow(title: "세션키 경로", snapshot: snapshot.session)
                    authPathHealthRow(title: "OAuth 경로", snapshot: snapshot.oauth)
                }
                .padding(.top, 2)
            } else {
                Text("조회 상태 정보를 불러오는 중입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func authPathHealthRow(title: String, snapshot: ClaudeAPIService.AuthPathHealthSnapshot) -> some View {
        let statusText: String
        let statusColor: Color
        if !snapshot.hasAttempt {
            statusText = "시도 기록 없음"
            statusColor = .secondary
        } else if snapshot.isUnstable {
            statusText = "불안정"
            statusColor = .orange
        } else {
            statusText = "정상"
            statusColor = .green
        }

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                Text(statusText)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(statusColor.opacity(0.16))
                    .foregroundStyle(statusColor)
                    .cornerRadius(4)
                if snapshot.consecutiveFailures > 0 {
                    Text("연속 실패 \(snapshot.consecutiveFailures)회")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Text("마지막 성공: \(formattedTimestamp(snapshot.lastSuccessAt))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let lastFailureAt = snapshot.lastFailureAt {
                Text("최근 실패: \(formattedTimestamp(lastFailureAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let failureRate = snapshot.failureRatePercent {
                Text("실패율: \(failureRate)% (\(snapshot.totalFailures)/\(snapshot.totalAttempts))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage = snapshot.lastErrorMessage, snapshot.isUnstable {
                Text("오류: \(errorMessage)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
        .cornerRadius(6)
    }

    private var runtimeStatusSummaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("런타임 상태")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let snapshot = usageHealthSnapshot {
                HStack(spacing: 6) {
                    chip(
                        title: "활성 경로",
                        value: runtimePathLabel(snapshot.runtime.activePath),
                        color: runtimePathColor(snapshot.runtime.activePath)
                    )
                    if snapshot.runtime.credentialAvailability.sessionCredentialAvailable {
                        chip(title: "세션", value: "준비됨", color: .green)
                    }
                    if snapshot.runtime.credentialAvailability.oauthCredentialAvailable {
                        chip(title: "OAuth", value: "준비됨", color: .blue)
                    }
                    if let cooldown = snapshot.runtime.sessionCooldownRemaining {
                        chip(title: "세션 재시도", value: formatDuration(seconds: cooldown), color: .orange)
                    }
                    if let preferred = snapshot.runtime.oauthPreferredRemaining {
                        chip(title: "OAuth 우선", value: formatDuration(seconds: preferred), color: .blue)
                    }
                }

                let unstablePaths = unstablePathSummary(snapshot)
                if !unstablePaths.isEmpty {
                    Text("불안정 경로: \(unstablePaths)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("상태를 불러오는 중입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private enum ChecklistState {
        case ok
        case warning
    }

    private func checklistRow(title: String, detail: String, state: ChecklistState) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: state == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(state == .ok ? .green : .orange)
                .font(.caption)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(title: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.caption2)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.16))
        .foregroundStyle(color)
        .cornerRadius(6)
    }

    private func metadataField(title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value?.isEmpty == false ? value! : "없음")
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runtimePathLabel(_ path: ClaudeAPIService.RuntimeAuthSnapshot.ActivePath) -> String {
        switch path {
        case .unauthenticated:
            return "인증 없음"
        case .sessionPrimary:
            return "세션키"
        case .oauthPreferred:
            return "OAuth(우선)"
        case .oauthFallback:
            return "OAuth(폴백)"
        }
    }

    private func runtimePathColor(_ path: ClaudeAPIService.RuntimeAuthSnapshot.ActivePath) -> Color {
        switch path {
        case .unauthenticated:
            return .secondary
        case .sessionPrimary:
            return .green
        case .oauthPreferred:
            return .blue
        case .oauthFallback:
            return .orange
        }
    }

    private func unstablePathSummary(_ snapshot: ClaudeAPIService.UsageHealthSnapshot) -> String {
        var labels: [String] = []
        if snapshot.session.isUnstable { labels.append("세션키") }
        if snapshot.oauth.isUnstable { labels.append("OAuth") }
        return labels.joined(separator: ", ")
    }

    private func formatDuration(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)초" }
        let minutes = seconds / 60
        let remain = seconds % 60
        if remain == 0 { return "\(minutes)분" }
        return "\(minutes)분 \(remain)초"
    }

    private var organizationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            organizationHeader
            organizationLoadActions
            organizationTargetPicker
            organizationHealthChips
            organizationPreviewList
            organizationMessages
        }
    }

    private var organizationHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Organization 선택")
                .font(.subheadline)
            Text("여러 organization을 사용하는 경우 조회 대상을 선택할 수 있습니다. 비워두면 자동 선택됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var organizationLoadActions: some View {
        HStack(spacing: 8) {
            Button("목록 불러오기") { loadOrganizations(forceRefresh: false) }
                .disabled(isLoadingOrganizations || isLoadingOrganizationPreviews)
            Button("강제 새로고침") { loadOrganizations(forceRefresh: true) }
                .disabled(isLoadingOrganizations || isLoadingOrganizationPreviews)
            if isLoadingOrganizations || isLoadingOrganizationPreviews {
                ProgressView()
                    .controlSize(.small)
            }
            if !organizations.isEmpty {
                Text("\(organizations.count)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("자동 선택") { selectedOrganizationID = "" }
                .disabled(selectedOrganizationID.isEmpty)
        }
    }

    private var organizationTargetPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("조회 대상", selection: $selectedOrganizationID) {
                Text("자동 선택").tag("")
                if !selectedOrganizationID.isEmpty && !organizations.contains(where: { $0.id == selectedOrganizationID }) {
                    Text("직접 입력값 (\(selectedOrganizationID))").tag(selectedOrganizationID)
                }
                ForEach(organizations, id: \.id) { org in
                    Text(org.displayName).tag(org.id)
                }
            }
            .labelsHidden()
            .disabled(organizations.isEmpty)

            TextField("Organization UUID 직접 입력 (선택)", text: $selectedOrganizationID)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
        }
    }

    @ViewBuilder
    private var organizationHealthChips: some View {
        if let snapshot = usageHealthSnapshot {
            HStack(spacing: 6) {
                chip(title: "최근 성공", value: shortRelativeTimestamp(snapshot.lastOverallSuccessAt), color: .secondary)
                if let sessionRate = snapshot.session.failureRatePercent {
                    chip(title: "세션 실패율", value: "\(sessionRate)%", color: snapshot.session.isUnstable ? .orange : .green)
                }
                if let oauthRate = snapshot.oauth.failureRatePercent {
                    chip(title: "OAuth 실패율", value: "\(oauthRate)%", color: snapshot.oauth.isUnstable ? .orange : .blue)
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var organizationPreviewList: some View {
        if !organizationPreviews.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("조회 미리보기")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(Array(organizationPreviews), id: \.id) { preview in
                    organizationPreviewRow(preview)
                }
            }
            .padding(.top, 4)
        }
    }

    private func organizationPreviewRow(_ preview: ClaudeAPIService.OrganizationPreview) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(preview.organization.displayName)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                if selectedOrganizationID == preview.id {
                    Text("선택됨")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18))
                        .foregroundStyle(Color.accentColor)
                        .cornerRadius(4)
                }
            }

            if let err = preview.usageErrorMessage {
                Text("조회 실패: \(err)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                let fiveHour = preview.fiveHourPercentage.map { String(format: "%.0f%%", $0) } ?? "-"
                let weekly = preview.weeklyPercentage.map { String(format: "%.0f%%", $0) } ?? "-"
                Text("현재 \(fiveHour) · 주간 \(weekly) · 최근 성공 \(shortRelativeTimestamp(usageHealthSnapshot?.lastOverallSuccessAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(selectedOrganizationID == preview.id ? Color.accentColor.opacity(0.10) : Color(NSColor.controlBackgroundColor).opacity(0.45))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedOrganizationID = preview.id
        }
    }

    @ViewBuilder
    private var organizationMessages: some View {
        if let message = organizationMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(message.contains("실패") || message.contains("없음") ? .orange : .secondary)
        }

        if let oauthSummary = organizationOAuthFallbackSummary {
            Text(oauthSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
                .cornerRadius(6)
        }
    }

    // MARK: - Codex 섹션

    private var codexAuthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Codex 인증", systemImage: "bubble.left.and.bubble.right")
                .font(.headline)

            Toggle(
                "Codex 모니터링 활성화",
                isOn: Binding(
                    get: { settings.isProviderEnabled(.codex) },
                    set: { settings.setProviderEnabled($0, for: .codex) }
                )
            )

            if settings.isProviderEnabled(.codex) {
                HStack(spacing: 8) {
                    switch codexAuthStatus {
                    case .checking:
                        ProgressView()
                            .controlSize(.small)
                        Text("확인 중...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .authenticated:
                        Label("연결됨 (auth.json)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .expired:
                        Label("토큰 만료됨", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    case .notInstalled:
                        Label("Codex CLI 미설치", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    case .notLoggedIn:
                        Label("로그인 필요", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }

                if codexAuthStatus == .notInstalled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Codex CLI를 먼저 설치하세요:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        codexCommandRow("brew install --cask codex", label: "Homebrew")
                        codexCommandRow("npm i -g @openai/codex", label: "npm")
                    }
                }

                if codexAuthStatus == .notInstalled || codexAuthStatus == .notLoggedIn {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("터미널에서 로그인하세요:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        codexCommandRow("codex login", label: "로그인")
                    }
                }

                if codexAuthStatus == .expired {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("토큰이 만료되었습니다. 다시 로그인하세요:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        codexCommandRow("codex login", label: "재로그인")
                    }
                }

                HStack(spacing: 8) {
                    Button("인증 상태 새로고침") {
                        checkCodexAuth()
                    }

                    if codexAuthStatus == .authenticated {
                        Button("Codex 로그아웃") {
                            onCodexLogout?()
                            checkCodexAuth()
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func codexCommandRow(_ command: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("\(label) 명령어 복사")
        }
    }

    private func checkCodexAuth() {
        if !settings.isProviderEnabled(.codex) {
            codexAuthStatus = .notLoggedIn
            return
        }

        if CodexAuthManager.shared.authJsonExists {
            if let token = CodexAuthManager.shared.getToken() {
                codexAuthStatus = token.isExpired ? .expired : .authenticated
            } else {
                codexAuthStatus = .notLoggedIn
            }
            return
        }

        let codexInstalled = FileManager.default.isExecutableFile(atPath: "/usr/local/bin/codex")
            || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/codex")
            || FileManager.default.isExecutableFile(atPath: "\(NSHomeDirectory())/.npm-global/bin/codex")
            || {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                process.arguments = ["codex"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                try? process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            }()

        codexAuthStatus = codexInstalled ? .notLoggedIn : .notInstalled
    }

    private var codexDisplaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Codex 표시", systemImage: "slider.horizontal.3")
                .font(.headline)

            Toggle("Codex 아이콘", isOn: $settings.showCodexIcon)
            Picker("퍼센트:", selection: $settings.codexPercentageDisplay) {
                ForEach(PercentageDisplay.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Picker("리셋 시간:", selection: $settings.codexResetTimeDisplay) {
                ForEach(ResetTimeDisplay.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            if settings.codexResetTimeDisplay != .none {
                Picker("시간 형식:", selection: $settings.codexTimeFormat) {
                    ForEach(TimeFormatStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            }

            Divider()

            Picker("아이콘:", selection: $settings.codexMenuBarStyle) {
                Text("없음").tag(MenuBarStyle.none)
                Section("개별 세션") {
                    Text("배터리바").tag(MenuBarStyle.batteryBar)
                    Text("원형").tag(MenuBarStyle.circular)
                }
                Section("동시 표시 (현재 세션 + 주간)") {
                    Text("동심원").tag(MenuBarStyle.concentricRings)
                    Text("이중 배터리").tag(MenuBarStyle.dualBattery)
                    Text("좌우 배터리").tag(MenuBarStyle.sideBySideBattery)
                }
            }
            .onChange(of: settings.codexMenuBarStyle) { _, newValue in
                if newValue == .batteryBar || newValue == .dualBattery || newValue == .sideBySideBattery {
                    settings.codexCircularDisplayMode = .remaining
                } else if newValue == .none {
                    settings.codexCircularDisplayMode = .usage
                }
            }

            if isCodexBatteryWithPercent {
                Toggle("배터리 내부 숫자", isOn: $settings.codexShowBatteryPercent)
                    .padding(.leading, 20)
            }
            if isCodexSingleMetricStyle {
                Picker("아이콘 기준:", selection: $settings.codexIconMetric) {
                    ForEach(IconMetric.allCases, id: \.self) { metric in
                        Text(metric.displayName).tag(metric)
                    }
                }
                .pickerStyle(.radioGroup)
                .padding(.leading, 20)
            }
            if isCodexCircularStyle {
                Picker("표시 기준:", selection: $settings.codexCircularDisplayMode) {
                    ForEach(CircularDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .padding(.leading, 20)
            }
        }
    }

    private var isCodexBatteryWithPercent: Bool {
        switch settings.codexMenuBarStyle {
        case .batteryBar, .dualBattery, .sideBySideBattery: return true
        default: return false
        }
    }

    private var isCodexCircularStyle: Bool {
        settings.codexMenuBarStyle == .circular || settings.codexMenuBarStyle == .concentricRings
    }

    private var isCodexSingleMetricStyle: Bool {
        settings.codexMenuBarStyle == .batteryBar || settings.codexMenuBarStyle == .circular
    }

    private var isEditingCodexCompact: Bool {
        settings.separateCompactConfig && codexCompactConfigTab == 1
    }

    private var codexPopoverItemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Codex 표시 항목", systemImage: "list.bullet.indent")
                .font(.headline)

            Text("Codex 항목의 표시 여부와 순서를 설정합니다")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("기본/간소화 개별 설정", isOn: $settings.separateCompactConfig)

            if settings.separateCompactConfig {
                Picker("", selection: $codexCompactConfigTab) {
                    Text("기본").tag(0)
                    Text("간소화").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            codexItemsList(isCompact: isEditingCodexCompact)
        }
    }

    private func codexItemsList(isCompact: Bool) -> some View {
        let items = isCompact ? settings.codexCompactPopoverItems : settings.codexPopoverItems
        return VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14)

                        Button {
                            if isCompact {
                                settings.codexCompactPopoverItems[index].visible.toggle()
                            } else {
                                settings.codexPopoverItems[index].visible.toggle()
                            }
                        } label: {
                            Image(systemName: item.visible ? "eye" : "eye.slash")
                                .foregroundStyle(item.visible ? .primary : .tertiary)
                                .font(.system(size: 12))
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.borderless)

                        Text(item.displayName)
                            .font(.subheadline)
                            .foregroundStyle(item.visible ? .primary : .tertiary)
                        Spacer()
                    }
                    .frame(height: 26)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())

                    if index < items.count - 1 {
                        Divider().padding(.horizontal, 8)
                    }
                }
                .background(codexDraggingItemID == item.id ? Color.accentColor.opacity(0.1) : Color.clear)
                .cornerRadius(4)
                .onDrag {
                    codexDraggingItemID = item.id
                    return NSItemProvider(object: item.id as NSString)
                }
                .onDrop(of: [.text], delegate: PopoverItemDropDelegate(
                    targetID: item.id,
                    settings: settings,
                    isCompact: isCompact,
                    provider: .codex,
                    draggingItemID: $codexDraggingItemID
                ))
            }
        }
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    private var codexAlertSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Codex 알림", systemImage: "bell.badge")
                .font(.headline)

            Toggle("Codex 알림 사용", isOn: $settings.codexAlertEnabled)

            Text("퍼센트 프리셋은 공통 > 알림에서 관리하고, 여기서는 Codex 알림을 보낼지만 결정합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !settings.notificationsEnabled {
                Label("전체 알림이 꺼져 있어 실제 알림은 발송되지 않습니다.", systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button {
                selectedPanel = .common
                selectedCommonTab = .alerts
            } label: {
                Label("공통 알림 설정 열기", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - 디스플레이 섹션

    private var commonDisplaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("공통 표시", systemImage: "paintbrush")
                .font(.headline)

            Toggle("메뉴바 보조 텍스트 강조", isOn: $settings.menuBarTextHighContrast)
            Text("메뉴바의 리셋 시간, 구분자 등을 기본 텍스트와 동일한 색상으로 표시")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var isBatteryWithPercent: Bool {
        settings.menuBarStyle == .batteryBar || settings.menuBarStyle == .sideBySideBattery
    }

    private var styleDescription: String? {
        switch settings.menuBarStyle {
        case .none: return nil
        case .batteryBar: return "남은 사용량을 배터리 형태로 표시"
        case .circular: return "원형 링이 채워진 만큼이 사용량"
        case .concentricRings: return "바깥 링: 현재 세션 · 안쪽 링: 주간"
        case .dualBattery: return "위: 현재 세션 · 아래: 주간"
        case .sideBySideBattery: return "왼쪽: 현재 세션 · 오른쪽: 주간"
        }
    }

    private var isCircularStyle: Bool {
        settings.menuBarStyle == .circular || settings.menuBarStyle == .concentricRings
    }

    private var isSingleMetricStyle: Bool {
        settings.menuBarStyle == .batteryBar || settings.menuBarStyle == .circular
    }

    private var claudeDisplaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("디스플레이", systemImage: "paintbrush")
                    .font(.headline)
                Spacer()
                Text("실시간 미리보기")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Claude 아이콘", isOn: $settings.showClaudeIcon)
                Picker("퍼센트:", selection: $settings.percentageDisplay) {
                    ForEach(PercentageDisplay.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("리셋 시간:", selection: $settings.resetTimeDisplay) {
                    ForEach(ResetTimeDisplay.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if settings.resetTimeDisplay != .none {
                    Picker("시간 형식:", selection: $settings.timeFormat) {
                        ForEach(TimeFormatStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                }

                Divider()

                Picker("아이콘:", selection: $settings.menuBarStyle) {
                    Text("없음").tag(MenuBarStyle.none)

                    Section("개별 세션") {
                        Text("배터리바").tag(MenuBarStyle.batteryBar)
                        Text("원형").tag(MenuBarStyle.circular)
                    }

                    Section("동시 표시 (현재 세션 + 주간)") {
                        Text("동심원").tag(MenuBarStyle.concentricRings)
                        Text("이중 배터리").tag(MenuBarStyle.dualBattery)
                        Text("좌우 배터리").tag(MenuBarStyle.sideBySideBattery)
                    }
                }
                .onChange(of: settings.menuBarStyle) { _, newValue in
                    if newValue == .batteryBar || newValue == .dualBattery || newValue == .sideBySideBattery {
                        settings.circularDisplayMode = .remaining
                    } else if newValue == .none {
                        settings.circularDisplayMode = .usage
                    }
                }

                if let desc = styleDescription {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }

                // 배터리 하위: 내부 숫자
                if isBatteryWithPercent {
                    Toggle("배터리 내부 숫자", isOn: $settings.showBatteryPercent)
                        .padding(.leading, 20)
                }

                if isSingleMetricStyle {
                    Picker("아이콘 기준:", selection: $settings.iconMetric) {
                        ForEach(IconMetric.allCases, id: \.self) { metric in
                            Text(metric.displayName).tag(metric)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .padding(.leading, 20)
                }

                // 원형 하위: 표시 기준
                if isCircularStyle {
                    Picker("표시 기준:", selection: $settings.circularDisplayMode) {
                        ForEach(CircularDisplayMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .padding(.leading, 20)
                }

                Text(settingsViewModel.weeklyDisplayHelpText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)

            }
        }
    }

    // MARK: - 표시 항목 섹션

    private var isEditingCompact: Bool {
        settings.separateCompactConfig && compactConfigTab == 1
    }

    private var popoverItemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("표시 항목", systemImage: "list.bullet")
                .font(.headline)

            Text("항목의 표시 여부와 순서를 설정합니다")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("기본/간소화 개별 설정", isOn: $settings.separateCompactConfig)

            if settings.separateCompactConfig {
                Picker("", selection: $compactConfigTab) {
                    Text("기본").tag(0)
                    Text("간소화").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            itemsList(isCompact: isEditingCompact)
        }
    }

    private func itemsList(isCompact: Bool) -> some View {
        let items = isCompact ? settings.compactPopoverItems : settings.popoverItems

        return VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14)

                        Button {
                            if isCompact {
                                settings.compactPopoverItems[index].visible.toggle()
                            } else {
                                settings.popoverItems[index].visible.toggle()
                            }
                        } label: {
                            Image(systemName: item.visible ? "eye" : "eye.slash")
                                .foregroundStyle(item.visible ? .primary : .tertiary)
                                .font(.system(size: 12))
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.borderless)

                        Text(item.displayName)
                            .font(.subheadline)
                            .foregroundStyle(item.visible ? .primary : .tertiary)

                        Spacer()
                    }
                    .frame(height: 26)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())

                    if index < items.count - 1 {
                        Divider().padding(.horizontal, 8)
                    }
                }
                .background(draggingItemID == item.id ? Color.accentColor.opacity(0.1) : Color.clear)
                .cornerRadius(4)
                .onDrag {
                    draggingItemID = item.id
                    return NSItemProvider(object: item.id as NSString)
                }
                .onDrop(of: [.text], delegate: PopoverItemDropDelegate(
                    targetID: item.id,
                    settings: settings,
                    isCompact: isCompact,
                    provider: .claude,
                    draggingItemID: $draggingItemID
                ))
            }
        }
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    // MARK: - 새로고침 섹션

    private var refreshSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("새로고침", systemImage: "arrow.clockwise")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("간격:")
                        .font(.subheadline)
                    TextField("30", text: $refreshIntervalText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    !refreshIntervalText.isEmpty && !isRefreshIntervalValid ? Color.red : Color.clear,
                                    lineWidth: 1
                                )
                        )
                        .onChange(of: refreshIntervalText) { _, newValue in
                            if let val = TimeInterval(newValue), val >= 5, val <= 120 {
                                settings.refreshInterval = val
                            }
                        }
                    Text("초")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !refreshIntervalText.isEmpty && !isRefreshIntervalValid {
                    Label("5~120 사이의 값을 입력하세요", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Toggle("자동 새로고침", isOn: $settings.autoRefresh)
            }
        }
    }

    // MARK: - 알림 섹션

    private var commonAlertSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("알림", systemImage: "bell")
                .font(.headline)

            Toggle("전체 알림 사용", isOn: $settings.notificationsEnabled)

            if !settings.notificationsEnabled {
                Label("전체 알림이 꺼져 있어 Claude/Codex 알림이 모두 중지됩니다.", systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Provider 알림")
                .font(.subheadline.weight(.semibold))
                Toggle("Claude 알림 사용", isOn: $settings.claudeAlertEnabled)
                Toggle("Codex 알림 사용", isOn: $settings.codexAlertEnabled)
                Text("퍼센트 프리셋은 아래 공통 목록을 두 provider가 함께 사용합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.notificationsEnabled)
            .opacity(settings.notificationsEnabled ? 1.0 : 0.6)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("공통 알림 프리셋")
                    .font(.subheadline.weight(.semibold))
                ForEach(Array(settings.sortedNotificationPresets.enumerated()), id: \.element.id) { index, preset in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { preset.isEnabled },
                            set: { newValue in
                                updateNotificationPreset(id: preset.id) { $0.isEnabled = newValue }
                            }
                        ))
                        .labelsHidden()

                        TextField("", text: Binding(
                            get: { index < alertPresetTexts.count ? alertPresetTexts[index] : String(preset.threshold) },
                            set: { newValue in
                                guard index < alertPresetTexts.count else { return }
                                alertPresetTexts[index] = newValue
                                if let threshold = Int(newValue), (1...100).contains(threshold) {
                                    updateNotificationPreset(id: preset.id) { $0.threshold = threshold }
                                }
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 52)

                        Text(settings.alertRemainingMode ? "% 남았을 때" : "% 사용 시")
                            .font(.subheadline)

                        Spacer()

                        Button {
                            removeNotificationPreset(id: preset.id)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red.opacity(0.7))
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        addNotificationPreset()
                    } label: {
                        Label("프리셋 추가", systemImage: "plus.circle.fill")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)

                    Picker("기준:", selection: $settings.alertRemainingMode) {
                        Text("사용량").tag(false)
                        Text("남은 사용량").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .onChange(of: settings.alertRemainingMode) { _, _ in
                        settings.notificationPresets = settings.notificationPresets.map {
                            NotificationPreset(
                                id: $0.id,
                                threshold: max(1, min(100 - $0.threshold, 99)),
                                isEnabled: $0.isEnabled
                            )
                        }
                        alertPresetTexts = settings.sortedNotificationPresets.map { String($0.threshold) }
                    }
                }

                Toggle("현재 세션 알림", isOn: $settings.alertFiveHourEnabled)
                Toggle("주간 세션 알림", isOn: $settings.alertWeeklyEnabled)
            }
            .disabled(!settings.notificationsEnabled)
            .opacity(settings.notificationsEnabled ? 1.0 : 0.6)

            Divider()

            Text("시스템 설정 → 알림 → ClaudeUsage에서 알림을 허용해야 합니다.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var alertSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Claude 알림", systemImage: "bell.badge")
                .font(.headline)

            Toggle("Claude 알림 사용", isOn: $settings.claudeAlertEnabled)

            Text("퍼센트 프리셋은 공통 > 알림에서 관리하고, 여기서는 Claude 알림을 보낼지만 결정합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !settings.notificationsEnabled {
                Label("전체 알림이 꺼져 있어 실제 알림은 발송되지 않습니다.", systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button {
                selectedPanel = .common
                selectedCommonTab = .alerts
            } label: {
                Label("공통 알림 설정 열기", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - 절전 섹션

    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("절전 모드", systemImage: "battery.75percent")
                .font(.headline)

            Toggle("배터리 사용 시 새로고침 감소", isOn: $settings.reducedRefreshOnBattery)

            Text("배터리 모드에서 새로고침 간격이 최소 60초로 제한됩니다")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 업데이트 섹션

    @State private var isCheckingUpdate = false
    @State private var updateCheckResult: String?

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("업데이트", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)

            Picker("자동 확인", selection: $settings.updateCheckInterval) {
                ForEach(UpdateCheckInterval.allCases, id: \.self) { interval in
                    Text(interval.displayName).tag(interval)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                Text("현재 버전: v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if isCheckingUpdate {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("지금 확인") {
                        isCheckingUpdate = true
                        updateCheckResult = nil
                        Task {
                            let result = await UpdateService.shared.checkForUpdates()
                            await MainActor.run {
                                isCheckingUpdate = false
                                switch result {
                                case .available(let info):
                                    updateCheckResult = "v\(info.version) 업데이트 가능"
                                    AppSettings.shared.availableUpdate = info
                                case .upToDate:
                                    updateCheckResult = "최신 버전입니다"
                                    AppSettings.shared.availableUpdate = nil
                                case .error(let msg):
                                    updateCheckResult = "확인 실패: \(msg)"
                                }
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let result = updateCheckResult {
                HStack {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("가능") ? .orange : result.contains("실패") ? .red : .green)
                    if result.contains("가능") {
                        Button("다운로드") {
                            Task {
                                let url = await UpdateService.shared.latestDownloadURL()
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("업데이트 설치 가이드")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("1. '다운로드'를 눌러 최신 앱을 받습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("2. 실행 중인 ClaudeUsage를 완전히 종료합니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("3. 기존 앱 파일을 새 앱으로 교체(덮어쓰기)합니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("4. 다시 실행합니다. 최초 실행에서 차단되면 시스템 설정 > 개인정보 보호 및 보안 > 그래도 열기를 선택하세요.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)
        }
    }

    // MARK: - 일반 섹션

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("일반", systemImage: "gearshape.2")
                .font(.headline)

            providerOverviewCard

            Toggle("로그인 시 자동 시작", isOn: $settings.launchAtLogin)

            Text("시스템 설정 → 일반 → 로그인 항목에서도 관리할 수 있습니다")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var providerOverviewCard: some View {
        let selectionState = settings.providerSelectionState
        let items = AppProviderKind.allCases.map { provider in
            ProviderOverviewCardView.Item(
                id: provider.rawValue,
                title: provider.displayName,
                isEnabled: settings.isProviderEnabled(provider),
                isActive: settings.providerState(for: provider).isActive,
                summary: providerRuntimeSummary(provider, selectionState: selectionState)
            )
        }
        return ProviderOverviewCardView(
            title: "Provider 상태",
            subtitle: "실동작 \(selectionState.runtimeEnabledKinds.count) · 설정 shell \(selectionState.shellEnabledKinds.count)",
            items: items
        )
    }

    private func providerRuntimeSummary(_ provider: AppProviderKind, selectionState: ProviderSelectionState) -> String {
        if provider.isRuntimeProvider {
            if selectionState.activeRuntimeKind == provider {
                return "실동작 · 기본"
            }
            return "실동작"
        }
        return settings.isProviderEnabled(provider) ? "설정 shell · 저장됨" : "설정 shell"
    }

    private func shellSectionFootnote(for provider: AppProviderKind, selectionState: ProviderSelectionState) -> String {
        if provider.isRuntimeProvider {
            return "이 provider는 실동작 경로를 가집니다. 일반 패널에서 인증과 표시 방식을 바로 조정할 수 있습니다."
        }

        let environmentStatus = ProviderEnvironmentDetector.status(for: provider)

        if selectionState.shellEnabledKinds.contains(provider) {
            if let environmentStatus, environmentStatus.isDetected {
                return "로컬 환경은 감지됐지만 아직 설정 shell 단계입니다. 다음 단계에서 메뉴바/조회 경로와 직접 연결할 예정입니다."
            }
            return "현재는 설정 shell만 준비되어 있습니다. 활성화 상태는 저장되지만 메뉴바/조회 경로는 다음 단계에서 연결됩니다."
        }

        if let environmentStatus, environmentStatus.isDetected {
            return "로컬 환경이 이미 감지됩니다. 활성화해 두면 다음 단계에서 연결 상태를 그대로 이어받을 수 있습니다."
        }

        return "아직 설정 shell 단계입니다. 미리 활성화해 두면 다음 단계에서 연결 상태를 이어받을 수 있습니다."
    }

    // MARK: - Actions

    private func handleLogoutAction() {
        onLogout?()
        storedSessionKey = nil
        sessionKey = ""
        settings.hasCompletedSetupWizard = false
        testResult = nil
        organizations = []
        organizationPreviews = []
        organizationOAuthFallbackSummary = nil
        organizationMessage = "로그아웃되었습니다. 다시 로그인하거나 세션 키를 입력해 주세요."
    }

    private func testConnection() {
        let normalizedKey = normalizeSessionKey(sessionKey)
        guard !normalizedKey.isEmpty else { return }
        if normalizedKey != sessionKey {
            sessionKey = normalizedKey
        }
        isTesting = true
        testResult = nil

        Task {
            do {
                let service = ClaudeAPIService(sessionKey: normalizedKey)
                await service.updatePreferredOrganizationID(normalizeOrganizationID(selectedOrganizationID))
                let _ = try await service.fetchUsage()
                await MainActor.run {
                    testResult = .success
                    isTesting = false
                    // 연결 성공 시 자동 저장
                    do {
                        try KeychainManager.shared.save(normalizedKey)
                        storedSessionKey = normalizedKey
                        Logger.info("연결 테스트 성공, 세션 키 자동 저장됨")
                    } catch {
                        Logger.error("세션 키 저장 실패: \(error)")
                    }
                    refreshSetupWizardState()
                    loadUsageHealthSnapshot()
                }
            } catch {
                await MainActor.run {
                    testResult = .failure(error.localizedDescription)
                    isTesting = false
                    loadUsageHealthSnapshot()
                }
            }
        }
    }

    private func runMessagesFallbackTest() {
        guard !isTestingMessagesFallback else { return }
        isTestingMessagesFallback = true
        messagesFallbackStatus = nil

        Task {
            do {
                let service = ClaudeAPIService()
                let usage = try await service.fetchUsageUsingMessagesFallback()
                let fiveHour = String(format: "%.0f%%", usage.fiveHour.utilization)
                let weekly = String(format: "%.0f%%", usage.sevenDay?.utilization ?? 0)
                await MainActor.run {
                    messagesFallbackStatus = "현재 \(fiveHour) · 주간 \(weekly)"
                    isTestingMessagesFallback = false
                    loadUsageHealthSnapshot()
                }
            } catch {
                await MainActor.run {
                    messagesFallbackStatus = "실패: \(error.localizedDescription)"
                    isTestingMessagesFallback = false
                    loadUsageHealthSnapshot()
                }
            }
        }
    }

    private func applyChanges() {
        persistChanges()
        onApply?()
    }

    private func confirmChanges() {
        persistChanges()
        onSave?()
    }

    private func persistChanges() {
        let normalizedKey = normalizeSessionKey(sessionKey)
        if normalizedKey != sessionKey {
            sessionKey = normalizedKey
        }

        // 세션 키 저장
        if !normalizedKey.isEmpty {
            do {
                try KeychainManager.shared.save(normalizedKey)
                storedSessionKey = normalizedKey
                settings.hasCompletedSetupWizard = false
            } catch {
                Logger.error("세션 키 저장 실패: \(error)")
            }
        } else {
            try? KeychainManager.shared.delete()
            storedSessionKey = nil
            settings.hasCompletedSetupWizard = false
            testResult = nil
        }

        // 새로고침 간격 유효성
        if let val = TimeInterval(refreshIntervalText), val >= 5, val <= 120 {
            settings.refreshInterval = val
        }

        let normalizedOrganizationID = normalizeOrganizationID(selectedOrganizationID)
        if normalizedOrganizationID != selectedOrganizationID {
            selectedOrganizationID = normalizedOrganizationID
        }
        settings.preferredOrganizationID = normalizedOrganizationID
    }

    private func normalizeSessionKey(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let prefixRange = value.range(of: "sessionKey=", options: [.anchored, .caseInsensitive]) {
            value = String(value[prefixRange.upperBound...])
        }

        if let semiIndex = value.firstIndex(of: ";") {
            value = String(value[..<semiIndex])
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }

        return value
    }

    private func normalizeOrganizationID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadOrganizations(forceRefresh: Bool = false) {
        let normalizedKey: String = {
            if !sessionKey.isEmpty {
                return normalizeSessionKey(sessionKey)
            }
            if let storedSessionKey, !storedSessionKey.isEmpty {
                return normalizeSessionKey(storedSessionKey)
            }
            return ""
        }()

        guard !normalizedKey.isEmpty else {
            organizationMessage = "세션 키가 없어 organization 목록을 불러올 수 없습니다."
            loadUsageHealthSnapshot()
            return
        }

        isLoadingOrganizations = true
        isLoadingOrganizationPreviews = false
        organizationMessage = nil
        organizationOAuthFallbackSummary = nil

        Task {
            let service = ClaudeAPIService(sessionKey: normalizedKey)
            var resolvedOrganizations: [ClaudeAPIService.OrganizationSummary] = []

            if !forceRefresh {
                let cachedOrganizations = await service.cachedOrganizationsForDisplay()
                if !cachedOrganizations.isEmpty {
                    await MainActor.run {
                        let cachedIDs = Set(cachedOrganizations.map(\.id))
                        organizations = cachedOrganizations
                        organizationPreviews = organizationPreviews.filter { cachedIDs.contains($0.id) }
                        isLoadingOrganizations = false
                        isLoadingOrganizationPreviews = false
                        organizationOAuthFallbackSummary = nil
                        organizationMessage = "캐시된 organization \(cachedOrganizations.count)개를 표시합니다. 변경 시 강제 새로고침을 눌러주세요."
                        loadUsageHealthSnapshot()
                    }
                    return
                }
            }

            do {
                resolvedOrganizations = try await service.fetchOrganizations()
            } catch {
                resolvedOrganizations = await service.cachedOrganizationsForDisplay()
                await MainActor.run {
                    if !resolvedOrganizations.isEmpty {
                        organizationMessage = "organization 목록 조회 실패로 캐시 목록을 표시합니다."
                    }
                }
            }

            await MainActor.run {
                organizations = resolvedOrganizations
                isLoadingOrganizations = false
                organizationPreviews = []
                organizationOAuthFallbackSummary = nil
            }

            guard !resolvedOrganizations.isEmpty else {
                do {
                    let fallbackUsage = try await service.fetchUsage()
                    await MainActor.run {
                        organizationMessage = "organization 목록 조회 실패로 OAuth 기준 사용량만 표시합니다."
                        let fiveHour = String(format: "%.0f%%", fallbackUsage.fiveHour.utilization)
                        let weekly = String(format: "%.0f%%", fallbackUsage.sevenDay?.utilization ?? 0)
                        organizationOAuthFallbackSummary = "OAuth 기준: 현재 \(fiveHour) · 주간 \(weekly)"
                    }
                } catch {
                    await MainActor.run {
                        organizationOAuthFallbackSummary = nil
                        organizationMessage = "organization 목록 조회 실패: \(error.localizedDescription)"
                    }
                }
                await MainActor.run {
                    loadUsageHealthSnapshot()
                }
                return
            }

            await MainActor.run {
                isLoadingOrganizationPreviews = true
                organizationMessage = "organization \(resolvedOrganizations.count)개 목록을 불러왔습니다. 상세 조회 중..."
            }

            let previews = await service.fetchOrganizationPreviews(for: resolvedOrganizations)
            await MainActor.run {
                organizationPreviews = previews
                isLoadingOrganizationPreviews = false

                let exists = selectedOrganizationID.isEmpty || previews.contains { $0.id == selectedOrganizationID }
                if !exists {
                    organizationMessage = "현재 선택한 organization이 목록에 없어 자동 선택으로 동작합니다."
                    return
                }

                let failedCount = previews.filter { $0.usageErrorMessage != nil }.count
                if failedCount > 0 {
                    organizationMessage = "organization \(previews.count)개 중 \(failedCount)개는 상세 조회에 실패했습니다."
                } else {
                    organizationMessage = "organization \(previews.count)개의 상세를 불러왔습니다."
                }
                loadUsageHealthSnapshot()
            }
        }
    }

    private func loadUsageHealthSnapshot() {
        Task {
            let service = ClaudeAPIService()
            async let snapshot = service.fetchUsageHealthSnapshot()
            async let metadata = service.fetchCachedProfileMetadata()
            let resolvedSnapshot = await snapshot
            let resolvedMetadata = await metadata
            await MainActor.run {
                usageHealthSnapshot = resolvedSnapshot
                profileMetadata = resolvedMetadata
                refreshSetupWizardState()
            }
        }
    }

    private func refreshSetupWizardState() {
        settings.hasCompletedSetupWizard = hasReadyClaudeCredential && hasSuccessfulClaudeFetch && isOrganizationSelectionReady
    }

    private func formattedMetadataDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func formattedTimestamp(_ date: Date?) -> String {
        guard let date else { return "기록 없음" }
        let absolute = date.formatted(date: .abbreviated, time: .shortened)
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.unitsStyle = .short
        let relative = relativeFormatter.localizedString(for: date, relativeTo: Date())
        return "\(absolute) (\(relative))"
    }

    private func shortRelativeTimestamp(_ date: Date?) -> String {
        guard let date else { return "기록 없음" }
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.unitsStyle = .short
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func updateNotificationPreset(id: String, mutate: (inout NotificationPreset) -> Void) {
        guard let index = settings.notificationPresets.firstIndex(where: { $0.id == id }) else { return }
        var presets = settings.notificationPresets
        mutate(&presets[index])
        settings.notificationPresets = presets
        alertPresetTexts = settings.sortedNotificationPresets.map { String($0.threshold) }
    }

    private func removeNotificationPreset(id: String) {
        guard settings.notificationPresets.count > 1 else { return }
        settings.notificationPresets.removeAll { $0.id == id }
        alertPresetTexts = settings.sortedNotificationPresets.map { String($0.threshold) }
    }

    private func addNotificationPreset() {
        let existing = Set(settings.notificationPresets.map(\.threshold))
        let candidates = [50, 60, 70, 75, 80, 85, 90, 95, 100]
        let next = candidates.first(where: { !existing.contains($0) })
            ?? min((settings.notificationPresets.map(\.threshold).max() ?? 90) + 5, 100)
        settings.notificationPresets.append(NotificationPreset(threshold: next, isEnabled: true))
        alertPresetTexts = settings.sortedNotificationPresets.map { String($0.threshold) }
    }

    private func resetToDefaults() {
        settings.resetToDefaults()
        refreshIntervalText = String(Int(settings.refreshInterval))
        alertPresetTexts = settings.sortedNotificationPresets.map { String($0.threshold) }
        selectedOrganizationID = settings.preferredOrganizationID
        organizationPreviews = []
        isLoadingOrganizationPreviews = false
        organizationMessage = nil
        organizationOAuthFallbackSummary = nil
        codexCompactConfigTab = 0
        compactConfigTab = 0
        checkCodexAuth()
    }
}

// MARK: - Drag & Drop Delegate

struct PopoverItemDropDelegate: DropDelegate {
    enum Provider {
        case claude
        case codex
    }

    let targetID: String
    let settings: AppSettings
    let isCompact: Bool
    let provider: Provider
    @Binding var draggingItemID: String?

    func performDrop(info: DropInfo) -> Bool {
        draggingItemID = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggingID = draggingItemID, draggingID != targetID else { return }

        let items: [PopoverItemConfig]
        switch (provider, isCompact) {
        case (.claude, false): items = settings.popoverItems
        case (.claude, true): items = settings.compactPopoverItems
        case (.codex, false): items = settings.codexPopoverItems
        case (.codex, true): items = settings.codexCompactPopoverItems
        }
        guard let fromIndex = items.firstIndex(where: { $0.id == draggingID }),
              let toIndex = items.firstIndex(where: { $0.id == targetID })
        else { return }

        withAnimation(.easeInOut(duration: 0.15)) {
            let offset = toIndex > fromIndex ? toIndex + 1 : toIndex
            switch (provider, isCompact) {
            case (.claude, false):
                settings.popoverItems.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: offset)
            case (.claude, true):
                settings.compactPopoverItems.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: offset)
            case (.codex, false):
                settings.codexPopoverItems.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: offset)
            case (.codex, true):
                settings.codexCompactPopoverItems.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: offset)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
