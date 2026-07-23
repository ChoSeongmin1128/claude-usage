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
                // 「계정 변경」 별도 섹션은 제거. 「계정 관리」 펼침 안에서 통합 행으로 처리.
                if shouldShowOrganizationSection {
                    organizationSection
                }
                if shouldShowClaudeAccountManagementSection {
                    claudeAccountManagementSection
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
        VStack(alignment: .leading, spacing: 10) {
            if let account = activeClaudeAccount() {
                let presentation = ClaudeAccountSettingsPresentation.resolve(
                    account: account,
                    isActive: true,
                    organizations: organizations
                )

                sectionCardHeader(
                    title: "Claude 연결됨",
                    subtitle: "현재 계정의 사용량만 조회합니다"
                )

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: presentation.systemImage)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(presentation.primaryTitle)
                                .font(.headline)
                                .lineLimit(1)
                            chip(title: "", value: presentation.statusText, color: color(for: presentation.statusTone))
                        }

                        if let secondaryLine = presentation.secondaryLine {
                            Text(secondaryLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)
                }

                HStack(spacing: 8) {
                    Button("사용량 새로고침") {
                        refreshClaudeUsageFromSettings()
                    }
                    .buttonStyle(.borderedProminent)

                    if account.kind == .claudeCodeExternal,
                       !claudeOAuthMigrationState.replacesStandardClaudeCodeReconnectAction {
                        Button("Claude Code 다시 연결") {
                            onReconnectClaudeCode?()
                        }
                        .buttonStyle(.bordered)
                        .help("터미널에서 Claude Code 계정을 바꿨다면 새 인증을 다시 가져옵니다")
                    }

                    if shouldShowClaudeAccountManagementSection {
                        // 「계정 변경」 은 별도 버튼이 아니라 「계정 관리」 펼침 안의
                        // 각 계정 행에서 직접 [사용] 버튼으로 처리한다 (Hick's Law).
                        Button(isClaudeAccountManagementExpanded ? "계정 관리 닫기" : "계정 관리") {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isClaudeAccountManagementExpanded.toggle()
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    if account.kind == .webSession {
                        Button("조직 변경") {
                            revealOrganizationControls()
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer(minLength: 0)
                }

                accountMessageView
            } else {
                sectionCardHeader(
                    title: "Claude 연결 필요",
                    subtitle: "Chrome 로그인 가져오기를 먼저 시도해 주세요"
                )

                Text("연결된 Claude 계정이 없습니다. 연결이 끝나면 사용량을 바로 조회합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button(action: { onImportClaudeFromChrome?() }) {
                        Label("Chrome에서 가져오기", systemImage: "globe")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: { onOpenLogin?() }) {
                        Label("앱에서 로그인", systemImage: "person.crop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button("직접 입력") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isAdvancedAuthExpanded.toggle()
                        }
                    }
                    .buttonStyle(.bordered)
                }

                accountMessageView
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private var shouldShowClaudeAccountManagementSection: Bool {
        !claudeAccounts.isEmpty
    }

    private var shouldShowClaudeOAuthMigrationCard: Bool {
        guard let activeAccount = activeClaudeAccount() else { return true }
        return activeAccount.kind == .claudeCodeExternal
    }

    @ViewBuilder
    private var accountMessageView: some View {
        if let message = claudeAccountMessage {
            // 메시지는 행동 결과(toast 비슷)이므로 영구 노출하지 않는다.
            // - X 버튼으로 명시적 닫기
            // - authSection 의 .task(id:) 로 일정 시간 후 자동 dismiss
            HStack(alignment: .top, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message.contains("실패") || message.contains("필요") ? .orange : .secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button(action: { claudeAccountMessage = nil }) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("이 안내 닫기")
            }
        }
    }

    private var claudeAccountManagementSection: some View {
        SettingsDisclosureControl(
            isExpanded: $isClaudeAccountManagementExpanded,
            accessibilityLabel: "계정 관리"
        ) {
            HStack(spacing: 8) {
                Text("계정 관리")
                    .font(.subheadline.weight(.semibold))
                if claudeAccounts.count > 1 {
                    chip(title: "", value: "\(claudeAccounts.count)개", color: .secondary)
                }
                Spacer(minLength: 0)
                Text(isClaudeAccountManagementExpanded ? "접기" : "펼치기")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                connectedClaudeAccountsCard
                accountAddCard
                advancedClaudeDiagnosticsSection
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.35))
        .cornerRadius(8)
    }

    private var connectedClaudeAccountsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionCardHeader(
                title: "연결된 계정",
                subtitle: "사용할 계정을 선택하거나 상세 정보·삭제·재로그인을 진행합니다"
            )

            if claudeAccounts.isEmpty {
                Text("연결된 계정이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(claudeAccounts) { account in
                        claudeAccountRow(account)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private func claudeAccountRow(_ account: ClaudeAccount) -> some View {
        let isActive = account.id == activeClaudeAccountID
        let presentation = ClaudeAccountSettingsPresentation.resolve(
            account: account,
            isActive: isActive,
            organizations: organizations
        )
        let managementActions = presentation.managementActions
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: presentation.systemImage)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.primaryTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    if let secondaryLine = presentation.secondaryLine {
                        Text(secondaryLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                chip(title: "", value: presentation.statusText, color: color(for: presentation.statusTone))

                if isActive {
                    chip(title: "", value: "현재 사용 중", color: .green)
                } else if let switchAction = presentation.switchAction {
                    // 별도 「계정 변경」 디스클로저 없이 같은 행에서 한 번에 활성화. (Hick's Law)
                    Button(switchAction.title) {
                        handleClaudeAccountAction(switchAction, account: account)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(presentation.detailRows, id: \.self) { row in
                        accountDetailRow(row)
                    }

                    if !managementActions.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(managementActions, id: \.self) { action in
                                Button(action.title) {
                                    handleClaudeAccountAction(action, account: account)
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("상세")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(isActive ? Color.accentColor.opacity(0.08) : Color(NSColor.windowBackgroundColor).opacity(0.35))
        .cornerRadius(8)
    }

    private func accountDetailRow(_ row: ClaudeAccountSettingsDetailRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.title)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(row.value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    private var accountAddCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionCardHeader(
                title: "계정 추가",
                subtitle: "새 Claude 계정을 연결하거나 마지막 수단으로 직접 입력합니다"
            )

            HStack(spacing: 8) {
                Button(action: { onImportClaudeFromChrome?() }) {
                    Label("Chrome에서 가져오기", systemImage: "globe")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: { onOpenLogin?() }) {
                    Label("앱에서 로그인", systemImage: "person.crop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button("고급: 직접 입력") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isAdvancedAuthExpanded.toggle()
                    }
                }
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
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
        .cornerRadius(8)
    }

    private var advancedClaudeDiagnosticsSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if let snapshot = usageHealthSnapshot {
                    Text(authSummaryLine(snapshot))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    sourceStatusRows(snapshot)
                } else {
                    Text("인증 상태를 아직 불러오지 못했습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .padding(.vertical, 2)

                Text("조회 방식은 현재 선택한 계정 안에서 자동으로 결정됩니다. 다른 계정의 로그인 정보로 자동 전환하지 않습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("브라우저 로그인 값 삭제") { pendingDestructiveAction = .clearBrowserSession }
                        .disabled(!(usageHealthSnapshot?.runtime.credentialAvailability.sessionCredentialAvailable ?? false))

                    Button("Claude Code 다시 로그인 안내") { showClaudeCodeLoginGuidance() }
                        .disabled(!(usageHealthSnapshot?.runtime.credentialAvailability.oauthCredentialAvailable ?? false))
                }
            }
            .padding(.top, 6)
        } label: {
            Text("고급 진단")
                .font(.subheadline)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.35))
        .cornerRadius(8)
    }

    private func handleClaudeAccountAction(_ action: ClaudeAccountSettingsAction, account: ClaudeAccount) {
        switch action {
        case .use:
            setActiveClaudeAccount(account)
        case .deleteWebSession:
            pendingDestructiveAction = .deleteClaudeAccount(account)
        case .showClaudeCodeLoginGuidance:
            showClaudeCodeLoginGuidance()
        }
    }

    private func color(for tone: ClaudeAccountStatusTone) -> Color {
        switch tone {
        case .neutral:
            return .secondary
        case .success:
            return .green
        case .warning:
            return .orange
        }
    }

    private var shouldShowOrganizationSection: Bool {
        (activeClaudeWebAccount() != nil && isOrganizationAdvancedExpanded)
            || hasPendingOrganizationChange
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

                Text("로그인 값만 붙여넣고 연결 테스트를 통과한 뒤 저장하세요. 입력만으로는 저장되지 않습니다.")
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
                                .font(.caption)
                        case .failure(let msg):
                            Label(msg, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }

                    if hasPendingManualSessionKey && testResult == nil {
                        Label("저장되지 않은 입력", systemImage: "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

    var hasSessionCredentialAvailable: Bool {
        activeClaudeWebAccount() != nil
            && !(normalizeSessionKey(storedSessionKey ?? "").isEmpty)
            || (usageHealthSnapshot?.runtime.credentialAvailability.sessionCredentialAvailable ?? false)
    }

    var claudeNotificationPolicySummary: String? {
        SetupCompletionPolicy.notificationPolicy(from: profileMetadata)?.summaryLine
    }

    private func authSummaryLine(_ snapshot: ClaudeAPIService.UsageHealthSnapshot) -> String {
        let availability = snapshot.runtime.credentialAvailability

        if !availability.hasAnyCredential {
            return "로그인 정보가 없습니다. Chrome 로그인 가져오기 또는 Claude Code 로그인이 필요합니다."
        }

        switch snapshot.runtime.activePath {
        case .sessionPrimary:
            if snapshot.runtime.sessionValidationState == .failed {
                return "브라우저 로그인 값 확인이 필요합니다. Claude.ai 에서 다시 로그인해 주세요."
            }
            if snapshot.runtime.sessionValidationState == .verified {
                return "브라우저 로그인 값으로 최근 조회가 성공했습니다."
            }
            return "브라우저 로그인 값이 저장되어 있습니다. 사용량 새로고침으로 실제 조회를 확인하세요."
        case .oauthPreferred, .oauthFallback:
            if snapshot.runtime.oauthValidationState == .failed {
                return "Claude Code 로그인을 갱신하지 못했습니다. 터미널에서 `claude auth login`을 다시 실행해 주세요."
            }
            if snapshot.runtime.oauthValidationState == .verified {
                return "Claude Code 로그인으로 최근 조회가 성공했습니다."
            }
            return "Claude Code 로그인 정보가 저장되어 있습니다. 사용량 새로고침으로 실제 조회를 확인하세요."
        case .unauthenticated:
            if snapshot.runtime.sessionValidationState == .failed {
                return "브라우저 로그인 값 확인이 필요합니다. Claude.ai 에서 다시 로그인해 주세요."
            }
            if snapshot.runtime.oauthValidationState == .failed {
                return "Claude Code 로그인을 갱신하지 못했습니다. 터미널에서 `claude auth login`을 다시 실행해 주세요."
            }
        }

        if snapshot.runtime.sessionValidationState == .verified {
            return "브라우저 로그인 값으로 최근 조회가 성공했습니다."
        }

        if availability.oauthCredentialAvailable {
            return "Claude Code 로그인 정보가 저장되어 있습니다. 사용량 새로고침으로 실제 조회를 확인하세요."
        }

        return "브라우저 로그인 값이 저장되어 있습니다. 사용량 새로고침으로 실제 조회를 확인하세요."
    }

    private func sourceStatusRows(_ snapshot: ClaudeAPIService.UsageHealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sourceStatusRow(
                title: "브라우저 로그인",
                value: validationStatusLabel(snapshot.runtime.sessionValidationState),
                color: validationStatusColor(snapshot.runtime.sessionValidationState)
            )
            sourceStatusRow(
                title: "Claude Code 로그인",
                value: validationStatusLabel(snapshot.runtime.oauthValidationState),
                color: validationStatusColor(snapshot.runtime.oauthValidationState)
            )
            sourceStatusRow(
                title: "현재 사용 경로",
                value: compactRuntimePathLabel(snapshot),
                color: runtimePathColor(snapshot.runtime.activePath)
            )
        }
        .font(.caption2)
    }

    private func sourceStatusRow(title: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
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
            return "감지됨"
        case .verified:
            return "최근 조회 성공"
        case .failed:
            return "확인 필요"
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
            organizationCurrentStatus
            if organizations.count <= 1 && !hasPendingOrganizationChange {
                // 조직이 0~1 개면 picker 자체가 무의미. 안내 + 조직 1개일 때는 그 이름 표시.
                organizationSingleOrEmptyHint
            } else {
                organizationPickerInline
            }
            if hasPendingOrganizationChange {
                organizationPendingFootnote
            }
            organizationMessages
        }
    }

    /// 조직 변경 섹션을 펼치고 필요 시 lazy 로드. 계정 카드 「조직 변경」 버튼에서 호출.
    private func revealOrganizationControls() {
        withAnimation(.easeInOut(duration: 0.15)) {
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            chip(
                title: "현재",
                value: currentOrganizationModeLabel,
                color: appliedPreferredOrganizationID.isEmpty ? .green : .blue
            )
            if let activeOrgLabel = currentlyAppliedOrganizationLabel {
                Text(activeOrgLabel)
                    .font(.caption)
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
            Text("조직 목록을 아직 불러오지 못했습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let only = organizations.first {
            HStack(spacing: 8) {
                Image(systemName: "building.2")
                    .foregroundStyle(.secondary)
                Text(only.displayName)
                    .font(.subheadline)
                Spacer(minLength: 0)
                Text("조직이 하나뿐이라 별도 선택이 필요 없습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var organizationPickerInline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: $selectedOrganizationID) {
                Text("자동 선택").tag("")
                if !selectedOrganizationID.isEmpty,
                   !organizations.contains(where: { $0.id == selectedOrganizationID })
                {
                    Text("현재 선택된 조직").tag(selectedOrganizationID)
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

    private var organizationPendingFootnote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.right.circle")
                .foregroundStyle(.orange)
            Text("변경 예정: ")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(pendingOrganizationModeLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(pendingOrganizationID.isEmpty ? .green : .orange)
            if !pendingOrganizationID.isEmpty,
               let label = label(for: pendingOrganizationID)
            {
                Text("· \(label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
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
            Text(message)
                .font(.caption)
                .foregroundStyle(message.contains("실패") || message.contains("없음") ? .orange : .secondary)
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
