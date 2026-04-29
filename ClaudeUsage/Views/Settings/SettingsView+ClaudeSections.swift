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
                compactAuthStatusCard
                authPrimaryActionsCard
                if shouldShowOrganizationSection {
                    organizationSection
                }
                if shouldShowManualInputSection {
                    manualSessionKeySection
                }
            } else {
                Text("Claude 사용이 꺼져 있습니다. 켜면 메뉴바와 사용량 확인이 다시 동작합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
        }
    }

    private var compactAuthStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionCardHeader(title: "현재 인증 상태")

            if let snapshot = usageHealthSnapshot {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        chip(
                            title: "사용 중",
                            value: compactRuntimePathLabel(snapshot),
                            color: runtimePathColor(snapshot.runtime.activePath)
                        )
                        if let oauthChip = oauthStatusChip(snapshot) {
                            chip(title: "Claude Code", value: oauthChip.value, color: oauthChip.color)
                        } else if snapshot.runtime.credentialAvailability.sessionCredentialAvailable {
                            chip(title: "브라우저", value: "준비됨", color: .green)
                        }
                    }

                    Text(authSummaryLine(snapshot))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("인증 상태를 아직 불러오지 못했습니다. 먼저 가져오기 또는 로그인부터 진행하시면 됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private var authPrimaryActionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasReadyClaudeCredential {
                HStack(spacing: 8) {
                    Button("상태 새로고침") {
                        loadUsageHealthSnapshot()
                    }
                    .buttonStyle(.borderedProminent)

                    if shouldShowOrganizationAction {
                        Button("조직 선택") {
                            revealOrganizationControls()
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("다시 로그인") { onOpenLogin?() }
                        .buttonStyle(.bordered)
                }

                HStack(spacing: 8) {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                        Text("연결 상태를 확인하고 있습니다")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let result = testResult {
                        switch result {
                        case .success:
                            Label("최근 연결 확인됨", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        case .failure(let msg):
                            Label(msg, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                        }
                    } else if let summary = claudeNotificationPolicySummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("로그아웃") { handleLogoutAction() }
                        .foregroundStyle(.red)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Button(action: { onOpenClaudeInChrome?() }) {
                        Label("Chrome 로그인 가져오기", systemImage: "globe")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    HStack(spacing: 8) {
                        Button(action: { onOpenLogin?() }) {
                            Label("웹 로그인 열기", systemImage: "person.crop.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
        .cornerRadius(8)
    }

    private var shouldShowOrganizationAction: Bool {
        hasReadyClaudeCredential
    }

    private var shouldShowOrganizationSection: Bool {
        hasReadyClaudeCredential
            || !appliedPreferredOrganizationID.isEmpty
            || hasPendingOrganizationChange
            || isOrganizationAdvancedExpanded
            || organizations.count > 1
    }

    private var manualSessionKeySection: some View {
        DisclosureGroup(isExpanded: $isAdvancedAuthExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("자동 가져오기가 안 될 때만 마지막 수단으로 직접 입력해 주세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("브라우저 로그인 값")
                    .font(.subheadline)

                TextField("브라우저 로그인 값 붙여넣기", text: $sessionKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))

                Text("로그인 값만 붙여넣고 연결 테스트를 눌러 확인하세요.")
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
                        case .success(let message):
                            Label(message, systemImage: "checkmark.circle.fill")
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
                    Text("수동 입력 (마지막 수단)")
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

    var hasReadyClaudeCredential: Bool {
        appliedClaudeSetupPresentation.progress.hasReadyCredential
    }

    var appliedPreferredOrganizationID: String {
        normalizeOrganizationID(settings.preferredOrganizationID)
    }

    private var hasClaudeCredentialInput: Bool {
        SetupCompletionPolicy.hasReadyCredential(
            sessionCredentialAvailable: !(normalizeSessionKey(storedSessionKey ?? "").isEmpty)
                || (usageHealthSnapshot?.runtime.credentialAvailability.sessionCredentialAvailable ?? false),
            oauthCredentialAvailable: usageHealthSnapshot?.runtime.credentialAvailability.oauthCredentialAvailable ?? false
        )
    }

    private var hasChromeApp: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil
    }

    var appliedClaudeSetupPresentation: ClaudeSetupPresentation {
        SetupCompletionPolicy.resolvePresentation(
            hasReadyCredential: hasClaudeCredentialInput,
            hasSuccessfulFetch: hasSuccessfulClaudeFetch,
            preferredOrganizationID: appliedPreferredOrganizationID,
            cachedMetadata: profileMetadata,
            hasChromeApp: hasChromeApp
        )
    }

    private var hasPendingManualSessionKey: Bool {
        let normalized = normalizeSessionKey(sessionKey)
        guard !normalized.isEmpty else { return false }
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

    private func authSummaryLine(_ snapshot: ClaudeAPIService.UsageHealthSnapshot) -> String {
        if !hasSuccessfulClaudeFetch {
            return "아직 성공 조회가 없습니다. 먼저 가져오기 또는 로그인 후 상태 새로고침이 필요합니다."
        }

        if snapshot.runtime.credentialAvailability.oauthCredentialAvailable,
           snapshot.oauth.lastSuccessAt != nil {
            return "Claude Code 로그인이 최근 정상적으로 확인됐고 조회도 성공했습니다."
        }

        if snapshot.runtime.credentialAvailability.oauthCredentialAvailable,
           snapshot.oauth.lastFailureAt != nil,
           snapshot.oauth.lastSuccessAt == nil {
            return "Claude Code 로그인은 보이지만 아직 제대로 확인되지 않았습니다. 필요하면 `claude login`을 다시 진행해 주세요."
        }

        if snapshot.runtime.credentialAvailability.oauthCredentialAvailable {
            return "Claude Code 로그인이 확인됐습니다. 필요하면 테스트로 실제 동작을 확인해 보세요."
        }

        if snapshot.runtime.credentialAvailability.sessionCredentialAvailable {
            return "브라우저 로그인 값으로 최근 조회가 성공했습니다."
        }

        return "자격 준비 상태를 다시 확인해 주세요."
    }

    private func oauthStatusChip(
        _ snapshot: ClaudeAPIService.UsageHealthSnapshot
    ) -> (value: String, color: Color)? {
        guard snapshot.runtime.credentialAvailability.oauthCredentialAvailable else { return nil }

        if snapshot.oauth.lastSuccessAt != nil {
            return ("검증됨", .blue)
        }

        if snapshot.oauth.lastFailureAt != nil {
            return ("확인 필요", .orange)
        }

        return ("감지됨", .blue)
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
        case .unauthenticated:
            return "인증 없음"
        case .sessionPrimary:
            return "브라우저 로그인"
        case .oauthPreferred, .oauthFallback:
            if snapshot.oauth.lastSuccessAt != nil {
                return "Claude Code 로그인"
            }
            return "Claude Code 로그인"
        }
    }

    var organizationSection: some View {
        ClaudeOrganizationStatusSectionShell(
            title: "조직 선택",
            systemImage: "building.2"
        ) {
            organizationModeSummaryCard
            if shouldShowOrganizationAdvancedControls {
                organizationLoadActions
                organizationTargetPicker
            }
            organizationMessages
        }
    }

    private var shouldShowOrganizationAdvancedControls: Bool {
        isOrganizationAdvancedExpanded || hasPendingOrganizationChange
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

    private var organizationModeSummaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("현재")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                chip(
                    title: "모드",
                    value: currentOrganizationModeLabel,
                    color: appliedPreferredOrganizationID.isEmpty ? .green : .blue
                )
                Spacer(minLength: 0)
            }

            if appliedPreferredOrganizationID.isEmpty {
                Text("자동으로 추가 사용량이 켜진 조직을 우선 사용합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("직접 고른 조직으로 사용합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if hasPendingOrganizationChange {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("변경 예정")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    chip(
                        title: "모드",
                        value: pendingOrganizationModeLabel,
                        color: pendingOrganizationID.isEmpty ? .green : .orange
                    )
                    Spacer(minLength: 0)
                }

                Text(pendingOrganizationID.isEmpty ? "자동 선택으로 되돌릴 예정입니다." : "직접 선택으로 바꿀 예정입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button(shouldShowOrganizationAdvancedControls ? "선택 닫기" : "직접 선택") {
                    if shouldShowOrganizationAdvancedControls {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isOrganizationAdvancedExpanded = false
                        }
                    } else {
                        revealOrganizationControls()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if !pendingOrganizationID.isEmpty {
                    Button("자동 선택으로 되돌리기") {
                        selectedOrganizationID = ""
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isOrganizationAdvancedExpanded = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
        .cornerRadius(8)
    }

    private func revealOrganizationControls() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isOrganizationAdvancedExpanded = true
        }
        if organizations.isEmpty && !isLoadingOrganizations {
            loadOrganizations(forceRefresh: false)
        }
    }

    private var organizationLoadActions: some View {
        HStack(spacing: 8) {
            Button("목록 불러오기") { loadOrganizations(forceRefresh: false) }
                .disabled(isLoadingOrganizations)
            Button("다시 불러오기") { loadOrganizations(forceRefresh: true) }
                .disabled(isLoadingOrganizations)
            if isLoadingOrganizations {
                ProgressView()
                    .controlSize(.small)
            }
            if !organizations.isEmpty {
                Text("\(organizations.count)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("자동 선택") {
                selectedOrganizationID = ""
                withAnimation(.easeInOut(duration: 0.15)) {
                    isOrganizationAdvancedExpanded = false
                }
            }
            .disabled(selectedOrganizationID.isEmpty)
        }
    }

    private var organizationTargetPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("직접 선택")
                .font(.subheadline.weight(.semibold))

            Picker("조회 대상", selection: $selectedOrganizationID) {
                Text("자동 선택").tag("")
                if !selectedOrganizationID.isEmpty && !organizations.contains(where: { $0.id == selectedOrganizationID }) {
                    Text("현재 선택된 조직").tag(selectedOrganizationID)
                }
                ForEach(organizations, id: \.id) { org in
                    Text(organizationPickerLabel(for: org)).tag(org.id)
                }
            }
            .labelsHidden()
            .disabled(organizations.isEmpty)

            Text("조직이 하나면 그대로 두시는 편이 낫습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

    var appliedOrganizationValidationChipValue: String {
        if !hasSuccessfulClaudeFetch {
            return "조회 전"
        }
        if appliedPreferredOrganizationID.isEmpty {
            return "자동"
        }
        return appliedClaudeSetupPresentation.progress.isOrganizationReady ? "검증됨" : "확인 필요"
    }

    var appliedOrganizationValidationChipColor: Color {
        if !hasSuccessfulClaudeFetch {
            return .orange
        }
        if appliedPreferredOrganizationID.isEmpty {
            return .green
        }
        return appliedClaudeSetupPresentation.progress.isOrganizationReady ? .green : .orange
    }
}
