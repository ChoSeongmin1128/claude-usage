import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    // MARK: - 인증 섹션

    var claudeOverviewSection: some View {
        authSection
    }

    var authSection: some View {
        ClaudeSetupSectionShell(presentation: appliedClaudeSetupPresentation) {
            settingsToggleRow(
                "Claude 모니터링 활성화",
                isOn: Binding(
                    get: { settings.isProviderEnabled(.claude) },
                    set: { settings.setProviderEnabled($0, for: .claude) }
                )
            )

            if settings.isProviderEnabled(.claude) {
                compactAuthStatusCard
                authPrimaryActionsCard
                runtimeStatusSummaryCard
                organizationSection
                if shouldOfferAdvancedAuthTeaser {
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedClaudeTab = .advanced
                                isAdvancedAuthExpanded = true
                            }
                        } label: {
                            HStack {
                                Text("문제 해결 및 수동 입력 보기")
                                    .font(.caption)
                                Spacer(minLength: 0)
                                if let subtitle = advancedAuthButtonSubtitle {
                                    Text(subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.borderless)

                        if let hint = advancedAuthCollapsedHint {
                            Text(hint)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("Claude 모니터링이 비활성화되어 있습니다. 활성화하면 메뉴바와 조회가 다시 동작합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
        }
    }

    var claudeAdvancedSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Claude 고급", systemImage: "wrench.and.screwdriver")
                .font(.headline)

            Text("수동 입력, 복구, 상세 진단은 필요할 때만 이 탭에서 확인합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            manualSessionKeySection

            if shouldSurfaceRecoveryAndDiagnostics {
                recoveryAndHelpSection
            }

            if !shouldSurfaceRecoveryAndDiagnostics {
                Text("현재는 추가 복구나 진단이 필요하지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
        }
    }

    private var recoveryAndHelpSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                detailedAuthStatusSection
                messagesFallbackSection
                if shouldRecommendCLIOAuth || !hasOAuthCredential {
                    claudeCLIOAuthGuideSection
                }
                if messagesFallbackStatus != nil || !hasSuccessfulClaudeFetch || shouldRecommendCLIOAuth {
                    authFAQSection
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text("복구 및 도움말")
                Spacer(minLength: 0)
                Text("복구 · OAuth 안내 · FAQ")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .font(.subheadline)
    }

    private var compactAuthStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionCardHeader(
                title: "현재 인증 상태",
                subtitle: appliedClaudeSetupPresentation.progress.stage == .complete
                    ? "지금 필요한 상태와 다음 행동만 보여줍니다"
                    : "처음 필요한 행동만 먼저 보여줍니다"
            )

            if let snapshot = usageHealthSnapshot {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        chip(
                            title: "활성 경로",
                            value: compactRuntimePathLabel(snapshot),
                            color: runtimePathColor(snapshot.runtime.activePath)
                        )
                        if let oauthChip = oauthStatusChip(snapshot) {
                            chip(title: "OAuth", value: oauthChip.value, color: oauthChip.color)
                        } else if snapshot.runtime.credentialAvailability.sessionCredentialAvailable {
                            chip(title: "세션", value: "준비됨", color: .green)
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
                        Button("Organization 보기") {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isOrganizationAdvancedExpanded = true
                            }
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
                        Label("Chrome에서 가져오기", systemImage: "globe")
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

                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedClaudeTab = .advanced
                                isAdvancedAuthExpanded = true
                            }
                        } label: {
                            Text("수동 입력")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }

                    Text("Chrome 가져오기를 먼저 시도해 주세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
        .cornerRadius(8)
    }

    private var shouldShowOrganizationAction: Bool {
        guard hasSuccessfulClaudeFetch else { return false }
        return appliedClaudeSetupPresentation.primaryActionKind == .openOrganizations
            || appliedClaudeSetupPresentation.progress.stage == .organization
    }

    private var detailedAuthStatusSection: some View {
        DisclosureGroup(isExpanded: $isAuthDetailsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                authChecklistCard
                profileMetadataCard
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text("상세 상태")
                Spacer(minLength: 0)
                Text("체크리스트 · 메타데이터")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .font(.subheadline)
    }

    private var manualSessionKeySection: some View {
        DisclosureGroup(isExpanded: $isAdvancedAuthExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("필요할 때만 직접 입력해 주세요.")
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

                Text("sessionKey 값만 입력하면 됩니다.")
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

    private var authChecklistCard: some View {
        let normalizedStoredSessionKey = normalizeSessionKey(storedSessionKey ?? "")
        let hasStoredSessionCredential = !normalizedStoredSessionKey.isEmpty
        let hasAppliedSessionCredential = usageHealthSnapshot?.runtime.credentialAvailability.sessionCredentialAvailable ?? false
        let hasOAuthCredential = self.hasOAuthCredential
        let hasAnySuccessfulFetch = hasSuccessfulClaudeFetch
        let progress = appliedClaudeSetupPresentation.progress

        return VStack(alignment: .leading, spacing: 8) {
            Text("인증 체크리스트")
                .font(.caption)
                .foregroundStyle(.secondary)

            checklistRow(
                title: "자격 준비",
                detail: hasOAuthCredential
                    ? "OAuth 자격 감지됨"
                    : (hasAppliedSessionCredential
                        ? "저장된 세션키 적용됨"
                        : (hasStoredSessionCredential ? "저장된 세션키 확인됨 · 적용 상태 확인 중" : "세션키 또는 OAuth 준비 필요")),
                state: hasReadyClaudeCredential ? .ok : .warning
            )
            checklistRow(
                title: "조회 검증",
                detail: hasAnySuccessfulFetch ? "최근 성공 조회 있음" : "연결 테스트 또는 상태 새로고침이 필요합니다",
                state: hasAnySuccessfulFetch ? .ok : .warning
            )
            checklistRow(
                title: "Organization 확인",
                detail: appliedOrganizationChecklistDetail,
                state: progress.isOrganizationReady ? .ok : .warning
            )

            if shouldRecommendCLIOAuth {
                checklistRow(
                    title: "Claude Code OAuth",
                    detail: hasOAuthCredential ? "Claude Code OAuth 자격이 준비되었습니다" : "세션키 단독 상태이거나 세션 경로가 불안정하면 `claude login`을 권장합니다",
                    state: hasOAuthCredential ? .ok : .warning
                )
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
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

    var pendingClaudeSetupPresentation: ClaudeSetupPresentation {
        SetupCompletionPolicy.resolvePresentation(
            hasReadyCredential: hasClaudeCredentialInput,
            hasSuccessfulFetch: hasSuccessfulClaudeFetch,
            preferredOrganizationID: normalizeOrganizationID(selectedOrganizationID),
            cachedMetadata: profileMetadata,
            hasChromeApp: hasChromeApp,
            credentialStepOverride: shouldShowAdvancedAuthSection ? .manualSessionKey : nil
        )
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

    private var shouldSurfaceRecoveryAndDiagnostics: Bool {
        guard let snapshot = usageHealthSnapshot else { return true }
        return !hasSuccessfulClaudeFetch
            || !hasReadyClaudeCredential
            || shouldRecommendCLIOAuth
            || settings.claudeMessagesFallbackPolicy != .off
            || snapshot.oauth.lastFailureAt != nil
            || snapshot.session.lastFailureAt != nil
            || messagesFallbackStatus != nil
    }

    private var hasPendingManualSessionKey: Bool {
        let normalized = normalizeSessionKey(sessionKey)
        guard !normalized.isEmpty else { return false }
        return normalized != normalizeSessionKey(storedSessionKey ?? "")
    }

    var shouldShowAdvancedAuthSection: Bool {
        selectedClaudeTab == .advanced || hasPendingManualSessionKey
    }

    private var shouldOfferAdvancedAuthTeaser: Bool {
        shouldShowAdvancedAuthSection
            || !hasSuccessfulClaudeFetch
            || !hasReadyClaudeCredential
            || shouldRecommendCLIOAuth
            || settings.claudeMessagesFallbackPolicy != .off
            || messagesFallbackStatus != nil
    }

    private var advancedAuthButtonSubtitle: String? {
        if hasPendingManualSessionKey {
            return "새 수동 입력"
        }
        if shouldRecommendCLIOAuth {
            return "CLI OAuth 권장"
        }
        if settings.claudeMessagesFallbackPolicy != .off {
            return "복구 설정 있음"
        }
        if !hasSuccessfulClaudeFetch {
            return "진단 필요"
        }
        return nil
    }

    private var advancedAuthCollapsedHint: String? {
        if hasPendingManualSessionKey {
            return "입력값을 저장 중이거나 현재 세션과 다릅니다."
        }
        if shouldRecommendCLIOAuth {
            return "CLI OAuth 확인이 필요할 수 있습니다."
        }
        if settings.claudeMessagesFallbackPolicy != .off {
            return "보조 복구 설정이 켜져 있습니다."
        }
        return nil
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

    private var shouldRecommendCLIOAuth: Bool {
        guard let snapshot = usageHealthSnapshot else { return false }
        return snapshot.session.isUnstable
            || (snapshot.runtime.credentialAvailability.sessionCredentialAvailable
                && !snapshot.runtime.credentialAvailability.oauthCredentialAvailable)
    }

    private var pendingOrganizationChecklistDetail: String {
        pendingClaudeSetupPresentation.organizationSummary
    }

    private var appliedOrganizationChecklistDetail: String {
        appliedClaudeSetupPresentation.organizationSummary
    }

    private func authSummaryLine(_ snapshot: ClaudeAPIService.UsageHealthSnapshot) -> String {
        if !hasSuccessfulClaudeFetch {
            return "아직 성공 조회가 없습니다. 먼저 가져오기 또는 로그인 후 상태 새로고침이 필요합니다."
        }

        if snapshot.runtime.credentialAvailability.oauthCredentialAvailable,
           snapshot.oauth.lastSuccessAt != nil {
            return "Claude Code OAuth가 최근에 실제로 검증됐고 조회도 성공했습니다."
        }

        if snapshot.runtime.credentialAvailability.oauthCredentialAvailable,
           snapshot.oauth.lastFailureAt != nil,
           snapshot.oauth.lastSuccessAt == nil {
            return "Claude Code OAuth 자격은 감지됐지만 아직 검증되지 않았습니다. 보조 복구 테스트나 `claude login` 재인증이 필요할 수 있습니다."
        }

        if shouldRecommendCLIOAuth {
            return "최근 조회는 성공했지만 세션 경로가 불안정할 수 있습니다."
        }

        if snapshot.runtime.credentialAvailability.oauthCredentialAvailable {
            return "Claude Code OAuth 자격이 감지됐습니다. 필요하면 복구 테스트로 실제 동작을 확인하시는 편이 맞습니다."
        }

        if snapshot.runtime.credentialAvailability.sessionCredentialAvailable {
            return "세션키 경로로 최근 조회가 성공했습니다."
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

    private var claudeCLIOAuthGuideSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                Text("1. 터미널에서 `brew install --cask claude-code`")
                Text("2. 설치 후 `claude login` 실행")
                Text("3. 브라우저 인증 완료")
                Text("4. 이 화면에서 `상태 새로고침`")
                Text("5. `OAuth 검증됨` 또는 활성 경로 `OAuth` 확인")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        } label: {
            HStack {
                Text("Claude Code CLI OAuth")
                Spacer(minLength: 0)
                Text("brew install → claude login")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .font(.subheadline)
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
                Picker("복구 모드:", selection: $settings.claudeMessagesFallbackPolicy) {
                    ForEach(ClaudeMessagesFallbackPolicy.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)

                Text(settingsViewModel.messagesFallbackModeSummary(
                    policy: settings.claudeMessagesFallbackPolicy,
                    thresholdPercent: settings.claudeMessagesFallbackAutoDisableBelowPercent
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                if settings.claudeMessagesFallbackPolicy == .automatic {
                    Label(
                        "OAuth 조회가 실패하고 현재 사용량이 \(settings.claudeMessagesFallbackAutoDisableBelowPercent)% 이상일 때만 자동으로 보조 복구를 시도합니다",
                        systemImage: "bolt.horizontal.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(alignment: .center, spacing: 8) {
                    Text("자동 중지 기준")
                        .font(.subheadline)
                    Spacer(minLength: 12)
                    Text("\(settings.claudeMessagesFallbackAutoDisableBelowPercent)% 미만")
                        .font(.subheadline)
                        .foregroundStyle(settings.claudeMessagesFallbackPolicy == .automatic ? .primary : .secondary)
                    Stepper(
                        value: Binding(
                            get: { settings.claudeMessagesFallbackAutoDisableBelowPercent },
                            set: { settings.claudeMessagesFallbackAutoDisableBelowPercent = settingsViewModel.clampFallbackThreshold($0) }
                        ),
                        in: 0...100,
                        step: 5
                    ) {
                        EmptyView()
                    }
                    .labelsHidden()
                    .disabled(settings.claudeMessagesFallbackPolicy != .automatic)
                }

                if settings.claudeMessagesFallbackPolicy == .automatic {
                    Text(settingsViewModel.messagesFallbackThresholdHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if settings.claudeMessagesFallbackPolicy == .manual {
                    Text("수동 보조 모드에서는 사용자가 직접 복구 테스트만 실행합니다. 자동 중지 기준은 저장되지만 자동 호출에는 사용되지 않습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("기능이 꺼져 있습니다. 자동 보조를 켜면 위 기준값을 사용해 저사용량 구간의 호출을 막습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(messagesFallbackRuntimeHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if settings.claudeMessagesFallbackPolicy != .off && !hasOAuthCredential {
                    Text(settingsViewModel.messagesFallbackOAuthHelpText)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if settings.claudeMessagesFallbackPolicy != .off,
                   let snapshot = usageHealthSnapshot,
                   snapshot.runtime.credentialAvailability.oauthCredentialAvailable,
                   snapshot.oauth.lastFailureAt != nil,
                   snapshot.oauth.lastSuccessAt == nil {
                    Text("OAuth 자격은 감지됐지만 아직 유효성 검증이 되지 않았습니다. 테스트가 실패하면 `claude login`으로 다시 로그인하는 편이 맞습니다.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if settings.claudeMessagesFallbackPolicy != .off {
                    HStack(spacing: 10) {
                        Button(isTestingMessagesFallback ? "복구 확인 중..." : "Messages 헤더 복구 테스트") {
                            runMessagesFallbackTest()
                        }
                        .disabled(isTestingMessagesFallback || !hasOAuthCredential)
                        .help(hasOAuthCredential ? "현재 OAuth 토큰으로 Messages 헤더 복구를 바로 확인합니다" : "Claude Code OAuth 토큰이 있어야 테스트할 수 있습니다")

                        if let messagesFallbackStatus {
                            Text(messagesFallbackStatus)
                                .font(.caption)
                                .foregroundStyle(messagesFallbackStatus.hasPrefix("실패:") ? .orange : .secondary)
                        }
                    }

                    Text(messagesFallbackTestHint)
                        .font(.caption2)
                        .foregroundStyle(hasOAuthCredential ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text("Messages 헤더 기반 보조 조회")
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

    private var messagesFallbackRuntimeHint: String {
        switch settings.claudeMessagesFallbackPolicy {
        case .off:
            return "지금은 기본 조회가 실패해도 Messages 헤더 보조 경로를 전혀 시도하지 않습니다."
        case .manual:
            return "자동 실행은 하지 않고, 아래 테스트 버튼으로만 보조 경로를 확인합니다."
        case .automatic:
            return "자동 실행 조건: Claude Code OAuth 준비 + 기본 조회 실패 + 현재 사용량 \(settings.claudeMessagesFallbackAutoDisableBelowPercent)% 이상"
        }
    }

    private var messagesFallbackTestHint: String {
        if !hasOAuthCredential {
            return "테스트 버튼이 비활성화된 이유: Claude Code OAuth 토큰이 아직 준비되지 않았습니다."
        }
        return "이 테스트는 현재 OAuth 토큰으로 보조 경로만 확인하며, 저장된 설정이나 세션키를 바꾸지 않습니다."
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
                    if let oauthChip = oauthStatusChip(snapshot) {
                        chip(title: "OAuth", value: oauthChip.value, color: oauthChip.color)
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

    private func compactRuntimePathLabel(_ snapshot: ClaudeAPIService.UsageHealthSnapshot) -> String {
        switch snapshot.runtime.activePath {
        case .unauthenticated:
            return "인증 없음"
        case .sessionPrimary:
            return "세션키"
        case .oauthPreferred, .oauthFallback:
            if snapshot.oauth.lastSuccessAt != nil {
                return "OAuth"
            }
            return "OAuth 후보"
        }
    }

    private func formatDuration(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)초" }
        let minutes = seconds / 60
        let remain = seconds % 60
        if remain == 0 { return "\(minutes)분" }
        return "\(minutes)분 \(remain)초"
    }

    var organizationSection: some View {
        ClaudeOrganizationStatusSectionShell(
            title: "Organization 선택",
            systemImage: "building.2",
            summary: "기본은 자동 선택입니다. 여러 organization을 직접 구분해서 볼 때만 여기서 고르면 됩니다."
        ) {
            organizationModeSummaryCard
            if shouldShowOrganizationAdvancedControls {
                organizationLoadActions
                organizationTargetPicker
                organizationHealthChips
                organizationPreviewList
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
                Text("현재 적용")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                chip(
                    title: "모드",
                    value: currentOrganizationModeLabel,
                    color: appliedPreferredOrganizationID.isEmpty ? .green : .blue
                )
                if !hasSuccessfulClaudeFetch || !appliedClaudeSetupPresentation.progress.isOrganizationReady {
                    chip(
                        title: "검증",
                        value: appliedOrganizationValidationChipValue,
                        color: appliedOrganizationValidationChipColor
                    )
                }
                Spacer(minLength: 0)
            }

            if appliedPreferredOrganizationID.isEmpty {
                Text("적용됨 · \(appliedOrganizationChecklistDetail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if hasSuccessfulClaudeFetch {
                    Text("지금은 자동 선택으로 동작합니다. 필요할 때만 아래 수동 선택을 여세요.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("저장된 organization 확인은 첫 조회 후 보강됩니다.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text(appliedPreferredOrganizationID)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text("적용됨 · \(appliedOrganizationChecklistDetail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if hasPendingOrganizationChange {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("편집 중")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    chip(
                        title: "모드",
                        value: pendingOrganizationModeLabel,
                        color: pendingOrganizationID.isEmpty ? .green : .orange
                    )
                    Spacer(minLength: 0)
                }

                Text("저장 예정 · \(pendingOrganizationChecklistDetail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("편집 중인 값은 저장하기 전까지 실제 조회와 완료 판정에 반영되지 않습니다.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                Button(shouldShowOrganizationAdvancedControls ? "수동 선택 닫기" : "수동 선택 열기") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isOrganizationAdvancedExpanded.toggle()
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

    var claudeDisplayConfigurationSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            claudeDisplaySection
            Divider()
            popoverItemsSection
        }
    }

    var claudeDisplaySection: some View {
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
                settingsToggleRow("Claude 아이콘", isOn: $settings.showClaudeIcon)
                Picker("퍼센트:", selection: Binding(
                    get: { settings.percentageDisplay },
                    set: { settings.percentageDisplay = $0 }
                )) {
                    ForEach(PercentageDisplay.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("리셋 시간:", selection: Binding(
                    get: { settings.resetTimeDisplay },
                    set: { settings.resetTimeDisplay = $0 }
                )) {
                    ForEach(ResetTimeDisplay.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if settings.resetTimeDisplay != .none {
                    Picker("시간 형식:", selection: Binding(
                        get: { settings.timeFormat },
                        set: { settings.timeFormat = $0 }
                    )) {
                        ForEach(TimeFormatStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                }

                Divider()

                Picker("아이콘:", selection: Binding(
                    get: { settings.menuBarStyle },
                    set: { newValue in
                        settings.menuBarStyle = newValue
                        if newValue.isBatteryStyle {
                            settings.circularDisplayMode = .remaining
                        } else if newValue == .none {
                            settings.circularDisplayMode = .usage
                        }
                    }
                )) {
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

                if let desc = styleDescription {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }

                if isBatteryWithPercent {
                    settingsToggleRow("배터리 내부 숫자", isOn: $settings.showBatteryPercent)
                        .padding(.leading, 20)
                }

                if isSingleMetricStyle {
                    settingsRadioGroup(
                        "아이콘 기준:",
                        options: IconMetric.allCases.map { ($0, $0.displayName) },
                        selection: settings.iconMetric,
                        onChange: { settings.iconMetric = $0 }
                    )
                    .padding(.leading, 20)
                }

                if isCircularStyle {
                    settingsRadioGroup(
                        "표시 기준:",
                        options: CircularDisplayMode.allCases.map { ($0, $0.displayName) },
                        selection: settings.circularDisplayMode,
                        onChange: { settings.circularDisplayMode = $0 }
                    )
                    .padding(.leading, 20)
                }

                Text(settingsViewModel.weeklyDisplayHelpText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
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
        settings.menuBarStyle != .none
    }

    private var isSingleMetricStyle: Bool {
        settings.menuBarStyle == .batteryBar || settings.menuBarStyle == .circular
    }

    private var isEditingCompact: Bool {
        settings.separateCompactConfig && compactConfigTab == 1
    }

    var popoverItemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("표시 항목", systemImage: "list.bullet")
                .font(.headline)

            Text("항목의 표시 여부와 순서를 설정합니다")
                .font(.caption)
                .foregroundStyle(.secondary)

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
