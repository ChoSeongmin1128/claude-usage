import AppKit
import SwiftUI

extension SettingsView {
    // MARK: - 인증 섹션

    var claudeOverviewSection: some View {
        authSection
    }

    var authSection: some View {
        ClaudeSetupSectionShell(presentation: appliedClaudeSetupPresentation) {
            settingsToggleRow(
                "Claude 사용",
                isOn: Binding(
                    get: { settings.isProviderEnabled(.claude) },
                    set: { settings.setProviderEnabled($0, for: .claude) }
                )
            )

            if settings.isProviderEnabled(.claude) {
                if shouldShowClaudeOAuthMigrationCard {
                    ClaudeOAuthMigrationCard(
                        state: claudeOAuthMigrationState,
                        onMigrate: migrateLegacyClaudeOAuthCredential,
                        onDefer: deferClaudeOAuthMigration,
                        onReconnectClaudeCode: { onReconnectClaudeCode?() }
                    )
                }
                claudeAccountSection
                // 계정 목록과 추가는 패널 위쪽 계정 목록 하나로 합쳤다. 여기는 사용 중 계정의 상세만 둔다.
                if shouldShowOrganizationSection {
                    organizationSection
                }
                claudeConnectionStatusLine
                if !claudeAccounts.isEmpty {
                    advancedClaudeDiagnosticsSection
                }
                if shouldShowManualInputSection {
                    manualSessionKeySection
                }
            }
        }
        // 행동 결과 메시지를 toast 처럼 자동 dismiss. 사용자가 X 로 닫으면 task 가 다시 시작되며
        // nil 상태에서는 조기 종료. 다른 메시지로 바뀌면 새 6초 카운트가 시작된다.
        .task(id: claudeAccountMessage) {
            guard claudeAccountMessage != nil else { return }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled {
                claudeAccountMessage = nil
            }
        }
    }

    private var claudeAccountSection: some View {
        claudeConnectionSummaryCard
    }

    private var claudeConnectionSummaryCard: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.label) {
            if let account = activeClaudeAccount() {
                let presentation = ClaudeAccountSettingsPresentation.resolve(
                    account: account,
                    isActive: true,
                    organizations: organizations,
                    claudeCodeCredentialIssue: usageHealthSnapshot?.runtime.claudeCodeCredentialIssue
                )

                HStack(spacing: AppDesign.Space.row) {
                    Image(systemName: presentation.systemImage)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                        Text(presentation.primaryTitle)
                            .font(AppDesign.Typography.subheadline.weight(.semibold))
                            .lineLimit(1).truncationMode(.middle)
                            .help(presentation.primaryTitle)
                        Text(
                            [presentation.sourceLabel, presentation.secondaryLine].compactMap { $0 }.joined(
                                separator: " · ")
                        )
                        .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: AppDesign.Space.row)
                    Text(presentation.statusText)
                        .font(AppDesign.Typography.caption)
                        .foregroundStyle(presentation.statusTone.color)
                    Button("새로고침") { refreshClaudeUsageFromSettings() }
                        .buttonStyle(.bordered).controlSize(.small)
                }

                if account.kind == .webSession {
                    Button("조직 선택") { revealOrganizationControls() }
                        .controlSize(.small)
                } else if !claudeOAuthMigrationState.replacesStandardClaudeCodeReconnectAction {
                    Button("Claude Code 다시 연결") { onReconnectClaudeCode?() }
                        .controlSize(.small)
                        .help("터미널에서 바꾼 Claude Code 로그인을 다시 가져옵니다")
                }

                accountMessageView
            } else {
                sectionCardHeader(title: "Claude 계정 연결")

                HStack(spacing: AppDesign.Space.row) {
                    Button(action: { onImportClaudeFromChrome?() }) {
                        Label("브라우저에서 가져오기", systemImage: "globe")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: { onOpenLogin?() }) {
                        Label("앱에서 로그인", systemImage: "person.crop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button("세션 키 직접 입력") {
                        withAnimation(settings.motion.animation(for: .disclosure, reduceMotion: reduceMotion)) {
                            isAdvancedAuthExpanded.toggle()
                        }
                    }
                    .buttonStyle(.bordered)
                }

                accountMessageView
            }
        }
        .padding(AppDesign.Space.content)
        .appPanelStyle()
    }

    private var shouldShowClaudeOAuthMigrationCard: Bool {
        guard let activeAccount = activeClaudeAccount() else { return true }
        return activeAccount.kind == .claudeCodeExternal
    }

    @ViewBuilder
    private var accountMessageView: some View {
        if let message = claudeAccountMessage {
            // 동작 결과라 X로 닫거나 authSection의 .task(id:)가 잠시 뒤 지운다.
            HStack(alignment: .top, spacing: AppDesign.Space.control) {
                Text(message.text)
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(message.isWarning ? .orange : .secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button(action: { claudeAccountMessage = nil }) {
                    Image(systemName: "xmark")
                        .font(AppDesign.Typography.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("닫기")
            }
        }
    }

    /// 조직 플랜의 알림 기준. 세션 키 연결 확인 결과는 직접 입력 칸 옆에만 보인다.
    @ViewBuilder
    private var claudeConnectionStatusLine: some View {
        if !isTesting, testResult == nil, let summary = claudeNotificationPolicySummary {
            Text(summary)
                .font(AppDesign.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var advancedClaudeDiagnosticsSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: AppDesign.Space.row) {
                if let snapshot = usageHealthSnapshot {
                    if let problem = authProblemLine(snapshot) {
                        Text(problem)
                            .font(AppDesign.Typography.caption)
                            .foregroundStyle(.orange)
                    }
                    sourceStatusRows(snapshot)
                } else {
                    Text("불러오는 중")
                        .font(AppDesign.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, AppDesign.Space.control)
        } label: {
            Text("고급 진단")
                .font(AppDesign.Typography.subheadline)
        }
    }


    private var shouldShowOrganizationSection: Bool {
        (activeClaudeWebAccount() != nil && isOrganizationAdvancedExpanded)
            || hasPendingOrganizationChange
    }

    private var manualSessionKeySection: some View {
        DisclosureGroup(isExpanded: $isAdvancedAuthExpanded) {
            VStack(alignment: .leading, spacing: AppDesign.Space.row) {
                SecureField("세션 키(sessionKey) 붙여넣기", text: $sessionKey)
                    .textFieldStyle(.roundedBorder)
                    .font(AppDesign.Typography.compactValue)

                if let warning = sessionKeyFormatWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(AppDesign.Typography.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Button("연결 테스트") { testConnection() }
                        .disabled(sessionKey.isEmpty || isTesting)

                    Button("저장") { saveVerifiedSessionKey() }
                        .disabled(!canSaveVerifiedSessionKey)

                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let result = testResult {
                        switch result {
                        case .success(let message):
                            Label(message, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(AppDesign.Typography.caption)
                        case .failure(let msg):
                            Label(msg, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(AppDesign.Typography.caption)
                                .lineLimit(1)
                        }
                    }

                    if hasPendingManualSessionKey && testResult == nil {
                        Label("저장 안 됨", systemImage: "pencil")
                            .font(AppDesign.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, AppDesign.Space.compact)
        } label: {
            Text("세션 키 직접 입력")
        }
        .font(AppDesign.Typography.subheadline)
    }

    var hasReadyClaudeCredential: Bool {
        appliedClaudeSetupPresentation.progress.hasReadyCredential
    }

    var appliedPreferredOrganizationID: String {
        normalizeOrganizationID(activeClaudePreferredOrganizationID())
    }

    private var hasClaudeCredentialInput: Bool {
        SetupCompletionPolicy.hasReadyCredential(
            sessionCredentialAvailable: activeClaudeWebAccount() != nil
                && !(normalizeSessionKey(storedSessionKey ?? "").isEmpty)
                || (usageHealthSnapshot?.runtime.credentialAvailability.sessionCredentialAvailable ?? false),
            oauthCredentialAvailable: usageHealthSnapshot?.runtime.credentialAvailability.oauthCredentialAvailable ?? false
        )
    }

    var appliedClaudeSetupPresentation: ClaudeSetupPresentation {
        SetupCompletionPolicy.resolvePresentation(
            hasReadyCredential: hasClaudeCredentialInput,
            hasSuccessfulFetch: hasSuccessfulClaudeFetch,
            preferredOrganizationID: appliedPreferredOrganizationID,
            cachedMetadata: profileMetadata
        )
    }

    private var hasPendingManualSessionKey: Bool {
        let normalized = normalizeSessionKey(sessionKey)
        guard !normalized.isEmpty else { return false }
        return normalized != normalizeSessionKey(storedSessionKey ?? "")
    }

    private var canSaveVerifiedSessionKey: Bool {
        let normalized = normalizeSessionKey(sessionKey)
        guard !normalized.isEmpty else { return false }
        guard normalized == lastVerifiedSessionKey else { return false }
        return normalized != normalizeSessionKey(storedSessionKey ?? "")
    }

    var shouldShowAdvancedAuthSection: Bool {
        isAdvancedAuthExpanded || hasPendingManualSessionKey || settings.shouldRevealClaudeAdvancedAuth
    }

    private var shouldShowManualInputSection: Bool {
        shouldShowAdvancedAuthSection
    }

    var hasSuccessfulClaudeFetch: Bool {
        usageHealthSnapshot?.lastOverallSuccessAt != nil
    }

    var hasOAuthCredential: Bool {
        usageHealthSnapshot?.runtime.credentialAvailability.oauthCredentialAvailable ?? false
    }

    var claudeNotificationPolicySummary: String? {
        SetupCompletionPolicy.notificationPolicy(from: profileMetadata)?.summaryLine
    }

    /// 고칠 일이 있을 때만 한 줄. 정상 상태는 아래 행이 보여준다.
    private func authProblemLine(_ snapshot: ClaudeAPIService.UsageHealthSnapshot) -> String? {
        let runtime = snapshot.runtime
        guard runtime.credentialAvailability.hasAnyCredential else {
            return "로그인이 없습니다. 브라우저에서 가져오거나 Claude Code에 로그인하세요."
        }
        let webExpired = "웹 로그인이 만료됐습니다. claude.ai에 다시 로그인한 뒤 가져오세요."
        let claudeCodeExpired = "Claude Code 로그인이 만료됐습니다. 터미널에서 `claude auth login`을 실행하세요."
        switch runtime.activePath {
        case .sessionPrimary:
            return runtime.sessionValidationState == .failed ? webExpired : nil
        case .oauthPreferred, .oauthFallback:
            return runtime.oauthValidationState == .failed ? claudeCodeExpired : nil
        case .unauthenticated:
            if runtime.sessionValidationState == .failed { return webExpired }
            return runtime.oauthValidationState == .failed ? claudeCodeExpired : nil
        }
    }

    private func sourceStatusRows(_ snapshot: ClaudeAPIService.UsageHealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.compact) {
            sourceStatusRow(
                title: "웹 로그인",
                value: validationStatusLabel(snapshot.runtime.sessionValidationState),
                color: validationStatusColor(snapshot.runtime.sessionValidationState)
            )
            sourceStatusRow(
                title: "Claude Code 로그인",
                value: validationStatusLabel(snapshot.runtime.oauthValidationState),
                color: validationStatusColor(snapshot.runtime.oauthValidationState)
            )
            sourceStatusRow(
                title: "조회에 쓰는 로그인",
                value: compactRuntimePathLabel(snapshot),
                color: runtimePathColor(snapshot.runtime.activePath)
            )
        }
        .font(AppDesign.Typography.caption2)
    }

    private func sourceStatusRow(title: String, value: String, color: Color) -> some View {
        HStack(spacing: AppDesign.Space.control) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(color)
        }
    }

    private func validationStatusLabel(_ state: ClaudeCredentialValidationState) -> String {
        switch state {
        case .unavailable:
            return "없음"
        case .detected:
            return "저장됨"
        case .verified:
            return "연결됨"
        case .failed:
            return "다시 로그인 필요"
        }
    }

    private func validationStatusColor(_ state: ClaudeCredentialValidationState) -> Color {
        switch state {
        case .unavailable:
            return .secondary
        case .detected, .verified:
            return .green
        case .failed:
            return .orange
        }
    }

    private func sectionCardHeader(title: String, subtitle: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                Text(title)
                    .font(AppDesign.Typography.subheadline.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(AppDesign.Typography.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
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

    private func compactRuntimePathLabel(_ snapshot: ClaudeAPIService.UsageHealthSnapshot) -> String {
        switch snapshot.runtime.activePath {
        case .unauthenticated: return "없음"
        case .sessionPrimary: return "웹 로그인"
        case .oauthPreferred, .oauthFallback: return "Claude Code 로그인"
        }
    }

    var organizationSection: some View {
        ClaudeOrganizationStatusSectionShell(
            title: "조직 선택",
            systemImage: "building.2"
        ) {
            organizationCurrentStatus
            if organizations.count <= 1 && !hasPendingOrganizationChange {
                // 조직이 0~1 개면 picker 자체가 무의미. 안내 + 조직 1개일 때는 그 이름 표시.
                organizationSingleOrEmptyHint
            } else {
                organizationPickerInline
            }
            organizationMessages
        }
    }

    /// 조직 변경 섹션을 펼치고 필요 시 lazy 로드. 계정 카드 「조직 변경」 버튼에서 호출.
    private func revealOrganizationControls() {
        withAnimation(settings.motion.animation(for: .disclosure, reduceMotion: reduceMotion)) {
            isOrganizationAdvancedExpanded = true
        }
        if organizations.isEmpty && !isLoadingOrganizations {
            loadOrganizations(forceRefresh: false)
        }
    }

    private var pendingOrganizationID: String {
        normalizeOrganizationID(selectedOrganizationID)
    }

    private var hasPendingOrganizationChange: Bool {
        pendingOrganizationID != appliedPreferredOrganizationID
    }

    private var currentOrganizationModeLabel: String {
        appliedPreferredOrganizationID.isEmpty ? "자동 선택" : "직접 선택"
    }

    private var pendingOrganizationModeLabel: String {
        pendingOrganizationID.isEmpty ? "자동 선택" : "직접 선택"
    }

    /// 현재 상태 한 줄 + 자동 ↔ 직접 토글 1개. 「선택 닫기」 같은 메타 버튼은 제거.
    /// 사용자가 한눈에 "지금 모드가 뭐고 어떻게 바꾸지?" 알 수 있게.
    private var organizationCurrentStatus: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppDesign.Space.row) {
            chip(
                title: "현재",
                value: currentOrganizationModeLabel,
                color: appliedPreferredOrganizationID.isEmpty ? .green : .blue
            )
            if let activeOrgLabel = currentlyAppliedOrganizationLabel {
                Text(activeOrgLabel)
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isLoadingOrganizations {
                ProgressView().controlSize(.small)
            } else {
                Button("목록 새로고침") { loadOrganizations(forceRefresh: true) }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
            }
        }
        .onAppear {
            // 조직 섹션이 보이면 lazy 로드. 사용자가 명시 액션 안 해도 picker 가 채워져 있게.
            if organizations.isEmpty && !isLoadingOrganizations {
                loadOrganizations(forceRefresh: false)
            }
        }
    }

    @ViewBuilder
    private var organizationSingleOrEmptyHint: some View {
        if organizations.isEmpty {
            if !isLoadingOrganizations {
                Text("조직 목록을 불러오지 못했습니다.")
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let only = organizations.first {
            HStack(spacing: AppDesign.Space.row) {
                Image(systemName: "building.2")
                    .foregroundStyle(.secondary)
                Text(only.displayName)
                    .font(AppDesign.Typography.subheadline)
                Spacer(minLength: 0)
            }
        }
    }

    private var organizationPickerInline: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.control) {
            Picker(selection: $selectedOrganizationID) {
                Text("자동 선택").tag("")
                if !selectedOrganizationID.isEmpty,
                   !organizations.contains(where: { $0.id == selectedOrganizationID })
                {
                    Text("목록에 없는 조직").tag(selectedOrganizationID)
                }
                ForEach(organizations, id: \.id) { org in
                    Text(organizationPickerLabel(for: org)).tag(org.id)
                }
            } label: {
                Text("조직")
            }
            .labelsHidden()
            .disabled(organizations.isEmpty)

            if !selectedOrganizationID.isEmpty {
                Button("자동 선택으로 되돌리기") {
                    selectedOrganizationID = ""
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var currentlyAppliedOrganizationLabel: String? {
        let id = appliedPreferredOrganizationID
        if id.isEmpty { return nil }
        return label(for: id)
    }

    private func label(for organizationID: String) -> String? {
        if let match = organizations.first(where: { $0.id == organizationID }) {
            return match.displayName
        }
        return nil
    }

    private func organizationPickerLabel(for organization: ClaudeAPIService.OrganizationSummary) -> String {
        guard let preview = organizationPreviews[organization.id] else {
            return organization.displayName
        }

        if preview.overageEnabled == true,
           let used = preview.overageUsed,
           let limit = preview.overageLimit {
            return "\(organization.displayName) · 추가 사용량 \(formatCurrency(used)) / \(formatCurrency(limit))"
        }

        if preview.overageEnabled == false {
            return "\(organization.displayName) · 추가 사용량 꺼짐"
        }

        return organization.displayName
    }

    private func formatCurrency(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    @ViewBuilder
    private var organizationMessages: some View {
        if let message = organizationMessage {
            Text(message.text)
                .font(AppDesign.Typography.caption)
                .foregroundStyle(message.isWarning ? .orange : .secondary)
        }
    }
}

extension ClaudeAccountStatusTone {
    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .success: return .green
        case .warning: return .orange
        }
    }
}
