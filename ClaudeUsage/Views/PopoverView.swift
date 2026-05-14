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
            // 상단 바
            HStack(spacing: 8) {
                headerServiceSelector
                    .layoutPriority(1)
                Spacer(minLength: 8)
                headerUtilityControls
            }
            .frame(height: isCompact ? 24 : 28)
            .padding(.horizontal, isCompact ? 12 : 16)
            .padding(.top, isCompact ? 3 : 10)
            .padding(.bottom, isCompact ? 3 : 6)

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
                HStack(spacing: 6) {
                    ForEach(availableServices, id: \.rawValue) { service in
                        headerSelectorButton(for: service)
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: 22)
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
            ZStack(alignment: .topTrailing) {
                ProviderBrandIconView(provider: service.providerKind, kind: .popover, size: 15)
                    .frame(width: 18, height: 18)

                if shouldShowWarningDot(for: service) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: isCompact ? 4 : 6, height: isCompact ? 4 : 6)
                        .offset(x: isCompact ? 2 : 3, y: isCompact ? -2 : -3)
                }
            }
            .frame(width: 22, height: 22)
            .background(selectedService == service ? Color.accentColor.opacity(0.18) : Color(NSColor.controlBackgroundColor).opacity(0.45))
            .foregroundStyle(selectedService == service ? Color.accentColor : .primary)
            .cornerRadius(7)
        }
        .buttonStyle(.plain)
    }

    private var selectedService: PopoverService {
        viewModel.selectedService
    }

    private var currentServiceLoading: Bool {
        serviceLoading(for: selectedService)
    }

    private var availableServices: [PopoverService] {
        let result = ServiceSelectionHelper.enabledServices(settings: settings)
        if result.isEmpty {
            return ServiceSelectionHelper.supportedPopoverServices.isEmpty ? [.claude] : ServiceSelectionHelper.supportedPopoverServices
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
                message: "Anthropic 이 잠시 사용량 조회를 제한했습니다. \(Self.formatRetryDuration(retryAfter)) 자동 재시도합니다.",
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

    /// Provider 별 인증 만료/거부 안내. 사용자에게 정확한 행동(어떤 명령 어디서 실행)을 알려준다.
    private func authReauthPresentation(service: PopoverService) -> ErrorPresentation {
        switch service {
        case .claude:
            // Claude 의 인증은 두 갈래 — 브라우저 sessionKey 또는 Claude Code OAuth.
            // 어느 쪽이 만료됐는지 viewModel 의 health snapshot 에서 추론할 수 있지만, 가장
            // 안전한 안내: wizard 진입(메뉴바 한 번 클릭) 또는 터미널 `claude /login` 양방향.
            return ErrorPresentation(
                title: "Claude 로그인 만료",
                message: "두 가지 방법 중 하나로 다시 연결해 주세요:\n1) 메뉴바에서 'Claude 로그인 시작'\n2) 터미널에서 `claude /login`",
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
        case .gemini:
            return ErrorPresentation(
                title: "Gemini 로그인 필요",
                message: "Gemini CLI 로그인 후 사용량 새로고침을 눌러 주세요.",
                actionTitle: "설정 열기",
                actionStyle: .prominent,
                action: { viewModel.openSettings(for: .gemini) }
            )
        case .antigravity:
            return ErrorPresentation(
                title: "Antigravity 연결 필요",
                message: "Antigravity 인증을 다시 확인해 주세요.",
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
        VStack(spacing: density == .compact ? 8 : 12) {
            Image(systemName: "person.badge.key")
                .font(.system(size: density == .compact ? 28 : 36))
                .foregroundStyle(.orange)
            Text("Claude 로그인이 필요합니다")
                .font(density == .compact ? .subheadline.weight(.semibold) : .headline)
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
                .controlSize(density == .compact ? .small : .regular)
                Button("설정 열기") {
                    viewModel.openSettings(for: .claude)
                }
                .controlSize(density == .compact ? .small : .regular)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, density == .compact ? 12 : 18)
    }

    @ViewBuilder
    private func displaySectionsContent(layoutSpec: PopoverLayoutSpec, sections: [PopoverDisplaySection]) -> some View {
        if sections.isEmpty {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 1)
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
            ScrollView(.vertical, showsIndicators: false) {
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
