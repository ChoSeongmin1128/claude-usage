//
//  PopoverView.swift
//  ClaudeUsage
//
//  Phase 2: 메인 Popover UI
//

import SwiftUI

struct PopoverView: View {
    @ObservedObject var viewModel: PopoverViewModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var isDisplayEditorPresented = false
    @State private var displayEditorMode: PopoverDisplayEditorMode = .standard

    var body: some View {
        let layout = viewModel.layoutWithSections(for: selectedService, settings: settings)
        let layoutSpec = layout.spec

        VStack(alignment: .leading, spacing: 0) {
            // 상단 바: provider 선택과 조회 provenance/freshness를 한 영역에서 보여준다.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    headerServiceSelector
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    headerUtilityControls
                }
                .frame(height: PopoverLayoutMetrics.providerSelectorSize(compact: isCompact))

                providerStatusRail
                    .frame(height: isCompact ? 9 : 12)
            }
            .padding(.horizontal, isCompact ? 12 : 16)
            .padding(.top, isCompact ? 1 : 4)
            .padding(.bottom, isCompact ? 0 : 2)

            if isCompact {
                compactMainSection(layoutSpec: layoutSpec, sections: layout.sections)
            } else {
                standardMainContainer(layoutSpec: layoutSpec, sections: layout.sections)
            }

            Divider()

            // 하단 버튼
            HStack {
                if selectedService == .claude {
                    Button {
                        viewModel.openUsagePage()
                    } label: {
                        Image(systemName: "safari")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("claude.ai/settings/usage")

                    if !isCompact {
                        Button {
                            viewModel.openUsagePage()
                        } label: {
                            Text("claude.ai/settings/usage")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }

                Spacer()

                Button {
                    displayEditorMode = isCompact ? .compact : .standard
                    isDisplayEditorPresented.toggle()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "slider.horizontal.3")
                        if !isCompact { Text("표시") }
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("표시 항목 편집")
                .accessibilityLabel("표시 항목 편집")
                .popover(isPresented: $isDisplayEditorPresented, arrowEdge: .bottom) {
                    PopoverDisplayEditorView(
                        settings: settings,
                        service: selectedService,
                        selectedMode: $displayEditorMode
                    )
                }

                Button {
                    viewModel.openSettings()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "gearshape")
                        if !isCompact { Text("설정") }
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("설정 열기")
                .accessibilityLabel("설정 열기")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "power")
                        if !isCompact { Text("종료") }
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("ClaudeUsage 종료")
                .accessibilityLabel("ClaudeUsage 종료")
            }
            .padding(.horizontal, isCompact ? 12 : 16)
            .padding(.vertical, isCompact ? 4 : 8)

            if !isCompact {
                HStack(spacing: 8) {
                    Text("⌘R 새로고침")
                    Text("⌘, 설정")
                }
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 6)
            }
        }
        .frame(width: layoutSpec.size.width, height: layoutSpec.size.height, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            normalizeSelectedServiceIfNeeded()
            syncCompactForSelectedServiceIfNeeded()
            requestRefreshIfNeededForVisibleService()
        }
        .onChange(of: settings.providerStates) { _, _ in
            normalizeSelectedServiceIfNeeded()
        }
        .onChange(of: settings.additionalRuntimeProvidersEnabled) { _, _ in
            normalizeSelectedServiceIfNeeded()
        }
        .onChange(of: viewModel.selectedService) { _, _ in
            syncCompactForSelectedServiceIfNeeded()
            isDisplayEditorPresented = false
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private var headerUtilityControls: some View {
        HStack(spacing: 10) {
            if viewModel.shouldShowUpdateButton {
                Button(action: { viewModel.performUpdatePrimaryAction() }) {
                    Image(systemName: viewModel.updateButtonSymbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.blue)
                        .frame(width: 22, height: 14)
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .help(viewModel.updateButtonHelpText)
            }

            Button(action: { viewModel.refresh() }) {
                Group {
                    if currentServiceLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                    }
                }
                .frame(width: 14, height: 14)
            }
            .buttonStyle(.borderless)
            .disabled(currentServiceLoading)
            .help(currentServiceLoading ? "사용량 갱신 중" : "사용량 새로고침")
            .accessibilityLabel(currentServiceLoading ? "사용량 갱신 중" : "사용량 새로고침")

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isCompact.toggle()
                }
                displayEditorMode = isCompact ? .compact : .standard
                viewModel.requestLayoutRefresh(reason: .compactToggle)
            } label: {
                Image(systemName: isCompact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help(isCompact ? "일반 보기" : "간소화 보기")
            .accessibilityLabel(isCompact ? "일반 보기로 전환" : "간소화 보기로 전환")

            Button {
                isPinned.toggle()
                viewModel.onPinChanged?(selectedService, isPinned)
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .foregroundColor(isPinned ? .accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(isPinned ? "고정 해제" : "고정")
            .accessibilityLabel(isPinned ? "팝오버 고정 해제" : "팝오버 고정")
        }
        .fixedSize()
    }

    private func selectService(_ service: PopoverService) {
        guard service != selectedService else { return }
        viewModel.selectService(service)
        syncCompactForSelectedServiceIfNeeded()
        viewModel.requestLayoutRefresh(for: service, reason: .serviceSelection)
    }

    private func appProviderKind(for service: PopoverService) -> AppProviderKind {
        service.providerKind
    }

    @ViewBuilder
    private var headerServiceSelector: some View {
        if availableServices.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: isCompact ? 5 : 6) {
                    ForEach(availableServices, id: \.rawValue) { service in
                        headerSelectorButton(for: service)
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: PopoverLayoutMetrics.providerSelectorSize(compact: isCompact))
        } else {
            headerSelectorButton(for: selectedService)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func headerSelectorButton(for service: PopoverService) -> some View {
        Button {
            selectService(service)
        } label: {
            ProviderSelectorButtonLabel(
                provider: service.providerKind,
                isSelected: selectedService == service,
                showsWarning: shouldShowWarningDot(for: service),
                compact: isCompact
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(service.displayName)
        .accessibilityValue(providerSelectorAccessibilityValue(for: service))
        .accessibilityAddTraits(selectedService == service ? .isSelected : [])
    }

    private var providerStatusRail: some View {
        let state = viewModel.runtimeServiceState(for: selectedService, settings: settings)
        let label = providerStatusRailText(state: state)
        return HStack(spacing: 4) {
            providerStatusRailSegments(state: state)
            Spacer(minLength: 0)
        }
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(selectedService.displayName) 상태")
        .accessibilityValue(label)
    }

    private func providerStatusRailText(state: PopoverViewModel.RuntimeServiceState) -> String {
        let parts = providerStatusRailParts(state: state)
        return Self.providerStatusRailLabels(
            serviceName: selectedService.displayName,
            account: parts.account,
            source: parts.source,
            status: parts.status
        ).joined(separator: " · ")
    }

    static func providerStatusRailLabels(
        serviceName: String,
        account: String?,
        source: String?,
        status: String
    ) -> [String] {
        [serviceName, account, source, status].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
    }

    private func providerStatusRailParts(
        state: PopoverViewModel.RuntimeServiceState
    ) -> (account: String?, source: String?, status: String) {
        var accountLabel: String?
        if let accountID = state.accountID,
           let account = viewModel.usageHealthSnapshot?.accounts.first(where: { $0.id == accountID }) {
            accountLabel = account.identity.primaryLabel ?? account.displayName
        }
        let status: String
        if let meta = state.meta {
            status = meta
        } else if state.isLoading {
            status = "갱신 중"
        } else if state.isAuthRequired {
            status = "로그인 필요"
        } else {
            status = "아직 갱신되지 않음"
        }
        return (accountLabel, state.sourceLabel, status)
    }

    @ViewBuilder
    private func providerStatusRailSegments(state: PopoverViewModel.RuntimeServiceState) -> some View {
        let parts = providerStatusRailParts(state: state)
        let statusColor: Color = state.isAuthRequired || state.freshness == .stale ? .orange : .secondary
        let font = Font.system(size: isCompact ? 8 : 9, weight: .medium)
        Text(selectedService.displayName)
            .font(font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .layoutPriority(2)
        Text("·").font(font).foregroundStyle(.tertiary)
        if let account = parts.account {
            Text(account)
                .font(font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(0)
            Text("·").font(font).foregroundStyle(.tertiary)
        }
        if let source = parts.source {
            Text(source)
                .font(font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
            Text("·").font(font).foregroundStyle(.tertiary)
        }
        Text(parts.status)
            .font(font)
            .foregroundStyle(statusColor)
            .lineLimit(1)
            .fixedSize()
            .layoutPriority(2)
    }

    private func providerSelectorAccessibilityValue(for service: PopoverService) -> String {
        let state = viewModel.runtimeServiceState(for: service, settings: settings)
        var parts: [String] = []
        if selectedService == service { parts.append("선택됨") }
        if state.freshness == .stale { parts.append("이전 데이터") }
        if state.isAuthRequired { parts.append("로그인 필요") }
        return parts.isEmpty ? "사용 가능" : parts.joined(separator: ", ")
    }

    private var selectedService: PopoverService {
        viewModel.selectedService
    }

    private var currentServiceLoading: Bool {
        // 외부 runtime isLoading + 수동 새로고침 직후의 강제 spinner 윈도우.
        // 후자는 사용자가 새로고침 버튼 누른 즉시 ProgressView 가 돌도록 보장한다.
        serviceLoading(for: selectedService) || viewModel.isManualRefreshSpinnerActive
    }

    private var availableServices: [PopoverService] {
        let result = ServiceSelectionHelper.enabledServices(settings: settings)
        if result.isEmpty {
            let exposedServices = ServiceSelectionHelper.exposedServices(settings: settings)
            return exposedServices.isEmpty ? [.claude] : exposedServices
        }
        return result
    }

    private func shouldShowWarningDot(for service: PopoverService) -> Bool {
        viewModel.runtimeServiceState(for: service, settings: settings).shouldShowWarningDot
    }

    private func isAuthRequired(for service: PopoverService) -> Bool {
        viewModel.runtimeServiceState(for: service, settings: settings).isAuthRequired
    }

    private func normalizeSelectedServiceIfNeeded() {
        guard !availableServices.contains(selectedService),
              let fallback = availableServices.first else { return }
        viewModel.selectService(fallback)
    }

    private var serviceError: APIError? {
        error(for: selectedService)
    }

    private var isCompact: Bool {
        get {
            settings.popoverCompact
        }
        nonmutating set {
            settings.popoverCompact = newValue
        }
    }

    private func syncCompactForSelectedServiceIfNeeded() {
        // 전역 설정이므로 동기화 불필요
    }

    private var isPinned: Bool {
        get {
            settings.popoverPinned
        }
        nonmutating set {
            settings.popoverPinned = newValue
        }
    }

    private var currentLayoutSpec: PopoverLayoutSpec {
        viewModel.layoutSpec(for: selectedService, settings: settings)
    }

    static func preferredPopoverWidth(compact: Bool) -> CGFloat {
        PopoverLayoutMetrics.preferredPopoverWidth(compact: compact)
    }

    private func requestRefreshIfNeededForVisibleService() {
        guard ServiceSelectionHelper.isEnabled(selectedService, settings: settings) else { return }
        guard !serviceLoading(for: selectedService) else { return }
        guard !isAuthRequired(for: selectedService) else { return }

        let runtimeState = viewModel.runtimeServiceState(for: selectedService, settings: settings)
        if runtimeState.hasContent == false || runtimeState.error?.isTemporaryFailure == true {
            viewModel.refresh(service: selectedService)
        }
    }

    private func serviceLoading(for service: PopoverService) -> Bool {
        viewModel.runtimeServiceState(for: service, settings: settings).isLoading
    }

    private func error(for service: PopoverService) -> APIError? {
        viewModel.runtimeServiceState(for: service, settings: settings).error
    }

    private struct StatusPanelConfiguration {
        let icon: String?
        let iconColor: Color
        let showsProgress: Bool
        let title: String
        let message: String
        let actionTitle: String?
        let actionStyle: StatusPanelActionStyle
        let action: (() -> Void)?
    }

    @ViewBuilder
    private func bodyContent(layoutSpec: PopoverLayoutSpec, sections: [PopoverDisplaySection]) -> some View {
        switch layoutSpec.phase {
        case .authRequired:
            if selectedService == .claude {
                // Claude 는 첫 인상이 결정적인 Peak-End 구간. 사용자가 클릭 한 번에
                // wizard 로 가도록 "Claude 로그인 시작" 을 prominent action 으로 노출하고,
                // "설정 열기" 는 보조로 둔다. 메시지도 어떤 옵션이 있는지 짧게 안내.
                claudeUnauthenticatedPanel(density: layoutSpec.density)
            } else {
                statusPanel(
                    density: layoutSpec.density,
                    configuration: StatusPanelConfiguration(
                        icon: "lock.shield",
                        iconColor: .orange,
                        showsProgress: false,
                        title: "연결 필요",
                        message: "인증이 필요합니다. 설정에서 연결을 다시 확인해 주세요.",
                        actionTitle: "설정 열기",
                        actionStyle: .prominent,
                        action: { viewModel.openSettings(for: selectedService) }
                    )
                )
            }
        case .loading:
            statusPanel(
                density: layoutSpec.density,
                configuration: StatusPanelConfiguration(
                    icon: nil,
                    iconColor: .secondary,
                    showsProgress: true,
                    title: "데이터 로딩 중",
                    message: "현재 연결 상태를 확인하고 있습니다.",
                    actionTitle: nil,
                    actionStyle: .bordered,
                    action: nil
                )
            )
        case .error:
            if let error = serviceError {
                let presentation = errorPresentation(for: error, service: selectedService)
                statusPanel(
                    density: layoutSpec.density,
                    configuration: StatusPanelConfiguration(
                        icon: "exclamationmark.triangle",
                        iconColor: .orange,
                        showsProgress: false,
                        title: presentation.title,
                        message: presentation.message,
                        actionTitle: presentation.actionTitle,
                        actionStyle: presentation.actionStyle,
                        action: presentation.action
                    )
                )
            }
        case .content:
            displaySectionsContent(layoutSpec: layoutSpec, sections: sections)
        case .empty:
            statusPanel(
                density: layoutSpec.density,
                configuration: StatusPanelConfiguration(
                    icon: "tray",
                    iconColor: .secondary,
                    showsProgress: false,
                    title: "데이터 없음",
                    message: "아직 가져온 사용량이 없습니다.",
                    actionTitle: nil,
                    actionStyle: .bordered,
                    action: nil
                )
            )
        }
    }

    @ViewBuilder
    private func statusPanel(
        density: PopoverDensity,
        configuration: StatusPanelConfiguration
    ) -> some View {
        StatusPanelView(
            density: density,
            icon: configuration.icon,
            iconColor: configuration.iconColor,
            showsProgress: configuration.showsProgress,
            title: configuration.title,
            message: configuration.message,
            actionTitle: configuration.actionTitle,
            actionStyle: configuration.actionStyle,
            action: configuration.action
        )
    }

    /// Provider + 에러 종류에 따라 정확한 안내 + 적절한 action 을 결정.
    /// 이전 "인증 필요" / "연결을 다시 확인해 주세요" 같은 모호한 메시지를 대체.
    private struct ErrorPresentation {
        let title: String
        let message: String
        let actionTitle: String?
        let actionStyle: StatusPanelActionStyle
        let action: (() -> Void)?
    }

    private func errorPresentation(for error: APIError, service: PopoverService) -> ErrorPresentation {
        switch error {
        case .invalidSessionKey:
            return authReauthPresentation(service: service)

        case .claudeCodeCredentialUnavailable:
            return ErrorPresentation(
                title: "Claude Code 자격 증명 없음",
                message: "Claude Code 로그인 정보를 찾을 수 없습니다. 터미널에서 `claude auth login`을 실행한 뒤 다시 확인해 주세요.",
                actionTitle: "설정 열기",
                actionStyle: .prominent,
                action: { viewModel.openSettings(for: .claude) }
            )

        case .claudeCodeReauthenticationRequired:
            return ErrorPresentation(
                title: "Claude Code 인증 갱신 필요",
                message: "로그인 파일은 있지만 refresh token이 더 이상 유효하지 않습니다. 터미널에서 `claude auth login`을 한 번 다시 실행한 뒤 새로고침해 주세요.",
                actionTitle: "설정 열기",
                actionStyle: .prominent,
                action: { viewModel.openSettings(for: .claude) }
            )

        case .claudeCodeReconnectRequired:
            return ErrorPresentation(
                title: "Claude Code 연결 확인 필요",
                message: "Claude Code 로그인은 유지되고 있지만 ClaudeUsage가 현재 연결 정보를 사용할 수 없습니다. 설정에서 ‘Claude Code 다시 연결’을 눌러 최신 연결 정보를 다시 가져와 주세요.",
                actionTitle: "설정 열기",
                actionStyle: .prominent,
                action: { viewModel.openSettings(for: .claude) }
            )

        case .codexReauthRequired(let reason):
            // refresh_token 이 영구 무효화 — 일반 "토큰 만료" 와 달리 자동 회복 불가.
            // 사용자에게 명확히 "다시 로그인이 필요하다" 고 알리고, OAuth 응답 코드도 같이 노출(디버깅용).
            return ErrorPresentation(
                title: "Codex 재로그인 필요",
                message: "Codex 토큰이 영구 무효화되어 자동 갱신이 더 이상 동작하지 않습니다. 터미널에서 `codex login` 을 다시 실행한 뒤 새로고침해 주세요. (\(reason))",
                actionTitle: "설정 열기",
                actionStyle: .prominent,
                action: { viewModel.openSettings(for: .codex) }
            )

        case .codexTokenRefreshTemporary(let reason):
            return ErrorPresentation(
                title: "Codex 갱신 일시 실패",
                message: reason.isEmpty
                    ? "Codex 토큰 갱신 서버가 일시적으로 응답하지 않았습니다. 마지막 성공 데이터는 유지하고 잠시 후 자동 재시도합니다."
                    : "Codex 토큰 갱신 서버가 일시적으로 응답하지 않았습니다. 마지막 성공 데이터는 유지하고 잠시 후 자동 재시도합니다. (\(reason))",
                actionTitle: "지금 다시 시도",
                actionStyle: .bordered,
                action: { viewModel.refresh() }
            )

        case .cloudflareBlocked(let retryAfter):
            return ErrorPresentation(
                title: "일시 차단됨",
                message: "Cloudflare 가 잠시 호출을 차단했습니다. \(Self.formatRetryDuration(retryAfter)) 자동 재시도합니다.",
                actionTitle: "지금 다시 시도",
                actionStyle: .bordered,
                action: { viewModel.refresh() }
            )

        case .rateLimited(let retryAfter):
            // Anthropic / Cloudflare 가 보내는 HTTP 429 + Retry-After 헤더.
            // 사용자가 어떤 행동을 더 자주 했다기보다, 사용량/조회 빈도가 서버 정책에 닿은 경우.
            // 분/시간 단위로 변환해 "2400초" 같은 노이즈 대신 "40분 후" 로 보여준다.
            return ErrorPresentation(
                title: "조회 한도 도달",
                message: "\(service.displayName) 사용량 조회가 잠시 제한됐습니다. \(Self.formatRetryDuration(retryAfter)) 자동 재시도합니다.",
                actionTitle: "지금 다시 시도",
                actionStyle: .bordered,
                action: { viewModel.refresh() }
            )

        case .networkError(let detail):
            return ErrorPresentation(
                title: "네트워크 오류",
                message: "인터넷 연결을 확인해 주세요. (\(detail))",
                actionTitle: "다시 시도",
                actionStyle: .bordered,
                action: { viewModel.refresh() }
            )

        case .permissionDenied(let detail):
            return ErrorPresentation(
                title: "조회 권한 없음",
                message: detail.isEmpty ? "이 계정으로 해당 사용량 API를 호출할 권한이 없습니다." : detail,
                actionTitle: "설정 열기",
                actionStyle: .bordered,
                action: { viewModel.openSettings(for: service) }
            )

        case .parseError:
            return ErrorPresentation(
                title: "응답 형식 변경",
                message: "응답 형식이 우리 앱이 알고 있는 것과 달라 파싱하지 못했습니다. 앱 업데이트가 있는지 확인해 보세요.",
                actionTitle: "다시 시도",
                actionStyle: .bordered,
                action: { viewModel.refresh() }
            )

        case .serverError(let code):
            return ErrorPresentation(
                title: "서버 오류",
                message: "원격 서버가 HTTP \(code) 로 응답했습니다. 잠시 후 다시 시도해 주세요.",
                actionTitle: "다시 시도",
                actionStyle: .bordered,
                action: { viewModel.refresh() }
            )

        case .unknownError(let detail):
            return ErrorPresentation(
                title: "조회 실패",
                message: detail.isEmpty ? "원인을 파악하지 못했습니다." : detail,
                actionTitle: "다시 시도",
                actionStyle: .bordered,
                action: { viewModel.refresh() }
            )
        }
    }

    /// Retry-After 초 단위 값을 사용자 친화 시간 표현으로 변환.
    /// "2400초 후" 같은 노이즈 대신 "약 40분 후" 처럼 보여준다.
    /// retryAfter 가 nil 이면 그냥 "잠시 후" 라고 표시.
    private static func formatRetryDuration(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "잠시 후" }
        if seconds >= 3600 {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            if minutes > 0 {
                return "약 \(hours)시간 \(minutes)분 후"
            }
            return "약 \(hours)시간 후"
        }
        if seconds >= 60 {
            let minutes = (seconds + 30) / 60  // 반올림
            return "약 \(minutes)분 후"
        }
        return "\(seconds)초 후"
    }

    /// Provider 별 인증 만료/거부 안내. 사용자에게 정확한 행동(어떤 버튼을 누르면 되는지)을 알려준다.
    private func authReauthPresentation(service: PopoverService) -> ErrorPresentation {
        switch service {
        case .claude:
            let runtimeState = viewModel.runtimeServiceState(for: .claude, settings: settings)
            let activeAccount = viewModel.usageHealthSnapshot?.activeAccount
            let isClaudeCode = activeAccount?.kind == .claudeCodeExternal
                || runtimeState.sourceLabel?.hasPrefix("Claude Code") == true
            if isClaudeCode {
                return ErrorPresentation(
                    title: "Claude Code 로그인 만료",
                    message: "터미널에서 `claude auth login`을 다시 실행한 뒤 사용량 새로고침을 눌러 주세요.",
                    actionTitle: "설정 열기",
                    actionStyle: .prominent,
                    action: { viewModel.openSettings(for: .claude) }
                )
            }
            return ErrorPresentation(
                title: "Claude 로그인 만료",
                message: "Claude.ai 로그인이 만료됐습니다. 메뉴바의 'Claude 로그인 시작' 으로 다시 연결해 주세요.",
                actionTitle: "Claude 로그인 시작",
                actionStyle: .prominent,
                action: { viewModel.startClaudeLogin() }
            )
        case .codex:
            return ErrorPresentation(
                title: "Codex 로그인 만료",
                message: "터미널에서 `codex login` 을 다시 실행한 뒤 사용량 새로고침을 눌러 주세요.",
                actionTitle: "설정 열기",
                actionStyle: .prominent,
                action: { viewModel.openSettings(for: .codex) }
            )
        case .antigravity:
            return ErrorPresentation(
                title: "Antigravity 연결 필요",
                message: "Antigravity 연결 토큰이 만료됐거나 Google 계정 연결을 갱신할 수 없습니다. Antigravity 앱을 다시 열고, 계속 실패하면 설정에서 Google 계정을 다시 연결해 주세요.",
                actionTitle: "설정 열기",
                actionStyle: .prominent,
                action: { viewModel.openSettings(for: .antigravity) }
            )
        }
    }

    /// Claude 미인증 상태 전용 패널. 일반 statusPanel 은 단일 액션만 지원하므로
    /// "로그인 시작 (prominent) + 설정 열기 (보조)" 두 버튼을 같이 노출하려고 별도로 구성.
    /// 첫 사용자가 메뉴바에서 한 번의 클릭으로 로그인 wizard 에 도달하게 한다.
    @ViewBuilder
    private func claudeUnauthenticatedPanel(density: PopoverDensity) -> some View {
        if density == .compact {
            statusPanel(
                density: density,
                configuration: StatusPanelConfiguration(
                    icon: nil,
                    iconColor: .orange,
                    showsProgress: false,
                    title: "Claude 로그인 필요",
                    message: "Chrome 또는 Claude Code 로그인을 연결해 주세요.",
                    actionTitle: "로그인 시작",
                    actionStyle: .prominent,
                    action: { viewModel.startClaudeLogin() }
                )
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text("Claude 로그인이 필요합니다")
                    .font(.headline)
                Text("Chrome 프로필에 저장된 로그인이나 Claude Code 인증을 그대로 사용할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Claude 로그인 시작") {
                        viewModel.startClaudeLogin()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    Button("설정 열기") {
                        viewModel.openSettings(for: .claude)
                    }
                    .controlSize(.regular)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }

    @ViewBuilder
    private func displaySectionsContent(layoutSpec: PopoverLayoutSpec, sections: [PopoverDisplaySection]) -> some View {
        if sections.isEmpty {
            statusPanel(
                density: layoutSpec.density,
                configuration: StatusPanelConfiguration(
                    icon: "slider.horizontal.3",
                    iconColor: .secondary,
                    showsProgress: false,
                    title: "표시할 항목 없음",
                    message: "표시 편집에서 최소 한 항목을 선택해 주세요.",
                    actionTitle: "표시 편집",
                    actionStyle: .bordered,
                    action: { isDisplayEditorPresented = true }
                )
            )
        } else {
            VStack(spacing: layoutSpec.sectionSpacing) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    if index > 0 && !layoutSpec.isCompact {
                        Divider()
                    }
                    PopoverDisplaySectionView(section: section, density: layoutSpec.density)
                }
            }
        }
    }

    @ViewBuilder
    private func compactMainSection(layoutSpec: PopoverLayoutSpec, sections: [PopoverDisplaySection]) -> some View {
        PopoverStateContainer(layoutSpec: layoutSpec) {
            if layoutSpec.phase == .content {
                ScrollView(.vertical, showsIndicators: false) {
                    bodyContent(layoutSpec: layoutSpec, sections: sections)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.never)
                .overlay(alignment: .bottom) {
                    if sections.count > PopoverLayoutMetrics.compactMaximumVisibleRows {
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color(NSColor.windowBackgroundColor).opacity(0.72),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 14)
                        .allowsHitTesting(false)
                    }
                }
            } else {
                bodyContent(layoutSpec: layoutSpec, sections: sections)
            }
        }
        .padding(.bottom, 1)
    }

    @ViewBuilder
    private func standardMainContainer(layoutSpec: PopoverLayoutSpec, sections: [PopoverDisplaySection]) -> some View {
        if layoutSpec.phase == .content {
            ScrollView(.vertical, showsIndicators: true) {
                standardMainSection(layoutSpec: layoutSpec, sections: sections)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            standardMainSection(layoutSpec: layoutSpec, sections: sections)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func standardMainSection(layoutSpec: PopoverLayoutSpec, sections: [PopoverDisplaySection]) -> some View {
        PopoverStateContainer(layoutSpec: layoutSpec) {
            bodyContent(layoutSpec: layoutSpec, sections: sections)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.bottom, 2)
    }
}

struct ProviderSelectorButtonLabel: View {
    let provider: AppProviderKind
    let isSelected: Bool
    let showsWarning: Bool
    let compact: Bool

    var body: some View {
        let buttonSize = PopoverLayoutMetrics.providerSelectorSize(compact: compact)
        let iconSize = PopoverLayoutMetrics.providerIconSize(compact: compact)
        let warningDotSize = PopoverLayoutMetrics.providerWarningDotSize(compact: compact)
        let warningDotInset = PopoverLayoutMetrics.providerWarningDotInset(compact: compact)

        ProviderBrandIconView(provider: provider, kind: .popover, size: iconSize)
            .frame(width: buttonSize, height: buttonSize)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.18)
                    : Color(NSColor.controlBackgroundColor).opacity(0.45)
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: compact ? 6 : 8,
                    style: .continuous
                )
            )
            .overlay(alignment: .topTrailing) {
                if showsWarning {
                    Circle()
                        .fill(Color.orange)
                        .overlay {
                            Circle()
                                .stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1)
                        }
                        .frame(width: warningDotSize, height: warningDotSize)
                        .padding(warningDotInset)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
    }
}
