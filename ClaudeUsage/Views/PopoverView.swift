//
//  PopoverView.swift
//  ClaudeUsage
//
//  Phase 2: 메인 Popover UI
//

import SwiftUI
import Combine

struct PopoverView: View {
    @ObservedObject var viewModel: PopoverViewModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 상단 바
            HStack(spacing: 8) {
                headerServiceSelector
                    .layoutPriority(1)
                Spacer(minLength: 8)
                headerUtilityControls
            }
            .frame(height: isCompact ? 26 : 30)
            .padding(.horizontal, isCompact ? 12 : 16)
            .padding(.top, isCompact ? 4 : 12)
            .padding(.bottom, isCompact ? 4 : 8)

            if isCompact {
                compactMainSection
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    standardMainSection
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            .padding(.vertical, isCompact ? 6 : 8)

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
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            normalizeSelectedServiceIfNeeded()
            syncCompactAcrossServicesIfNeeded()
            requestRefreshIfNeededForVisibleService()
        }
        .onChange(of: settings.providerStates) { _, _ in
            normalizeSelectedServiceIfNeeded()
        }
        .onChange(of: viewModel.selectedService) { _, _ in
            syncCompactAcrossServicesIfNeeded()
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private var headerUtilityControls: some View {
        HStack(spacing: 10) {
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
                DispatchQueue.main.async {
                    viewModel.requestLayoutRefresh(reason: .compactToggle)
                }
            } label: {
                Image(systemName: isCompact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help(isCompact ? "기본 보기" : "간소화")

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
        syncCompactAcrossServicesIfNeeded()
        DispatchQueue.main.async {
            viewModel.requestLayoutRefresh(for: service, reason: .serviceSelection)
        }
    }

    private func sectionHeader(title: String, subtitle: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
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

                if shouldShowWarningDot(for: service) && !isCompact {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .offset(x: 3, y: -3)
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

    private var currentServiceLastUpdated: Date? {
        serviceLastUpdated(for: selectedService)
    }

    private var currentServiceRuntimeState: PopoverViewModel.RuntimeServiceState {
        viewModel.runtimeServiceState(for: selectedService, settings: settings)
    }

    private var currentServiceSummary: String {
        currentServiceRuntimeState.summary
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
            let runtimeKinds = settings.providerSelectionState.runtimeEnabledKinds
            if runtimeKinds.isEmpty {
                return settings.isPopoverCompact(for: appProviderKind(for: selectedService))
            }

            let compactValues = Set(runtimeKinds.map(settings.isPopoverCompact(for:)))
            if compactValues.count == 1 {
                return compactValues.first ?? settings.isPopoverCompact(for: appProviderKind(for: selectedService))
            }

            return settings.isPopoverCompact(for: appProviderKind(for: selectedService))
        }
        nonmutating set {
            setCompactForAllServices(newValue)
        }
    }

    private func setCompactForAllServices(_ compact: Bool) {
        let runtimeKinds = settings.providerSelectionState.runtimeEnabledKinds
        let targets = runtimeKinds.isEmpty ? ServiceSelectionHelper.supportedProviderKinds : runtimeKinds
        for kind in targets where settings.isPopoverCompact(for: kind) != compact {
            settings.setPopoverCompact(compact, for: kind)
        }
    }

    private func syncCompactAcrossServicesIfNeeded() {
        let compact = isCompact
        setCompactForAllServices(compact)
    }

    private var isPinned: Bool {
        get {
            settings.isPopoverPinned(for: appProviderKind(for: selectedService))
        }
        nonmutating set {
            settings.setPopoverPinned(newValue, for: appProviderKind(for: selectedService))
        }
    }

    static func preferredPopoverWidth(compact: Bool) -> CGFloat {
        if compact {
            return 296
        }
        return PopoverLayoutMetrics.standardPopoverWidth
    }

    static func resolvedPopoverWidth(for service: PopoverService, compact: Bool) -> CGFloat {
        self.preferredPopoverWidth(compact: compact)
    }

    static func minimumPopoverHeight(compact: Bool) -> CGFloat {
        if !compact { return 260 }
        return 116
    }

    static func preferredPopoverHeight(compact: Bool) -> CGFloat {
        if !compact { return 336 }
        return 144
    }

    static func maximumPopoverHeight(compact: Bool) -> CGFloat {
        if !compact { return 420 }
        return 176
    }

    static func resolvedPopoverSize(compact: Bool) -> CGSize {
        CGSize(
            width: preferredPopoverWidth(compact: compact),
            height: preferredPopoverHeight(compact: compact)
        )
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

    private var hasServiceData: Bool {
        let runtimeState = viewModel.runtimeServiceState(for: selectedService, settings: settings)
        return runtimeState.hasContent || runtimeState.error != nil
    }

    private func serviceLastUpdated(for service: PopoverService) -> Date? {
        viewModel.runtimeServiceState(for: service, settings: settings).lastUpdated
    }

    private func serviceLoading(for service: PopoverService) -> Bool {
        viewModel.runtimeServiceState(for: service, settings: settings).isLoading
    }

    private func error(for service: PopoverService) -> APIError? {
        viewModel.runtimeServiceState(for: service, settings: settings).error
    }

    private func hasLoadedContent(for service: PopoverService) -> Bool {
        viewModel.runtimeServiceState(for: service, settings: settings).hasContent
    }

    private var claudeUsage: ClaudeUsageResponse? {
        viewModel.claudeUsage
    }

    private var codexUsage: CodexUsageResponse? {
        viewModel.codexUsage
    }

    private var geminiUsage: GeminiUsageResponse? {
        viewModel.geminiUsage
    }

    private var antigravityUsage: AntigravityUsageResponse? {
        viewModel.antigravityUsage
    }

    private func needsInitialLoad(for service: PopoverService) -> Bool {
        serviceLoading(for: service) && !hasLoadedContent(for: service)
    }

    private func contentPhase(for service: PopoverService) -> PopoverContentPhase {
        if isAuthRequired(for: service) {
            return .authRequired
        }
        if needsInitialLoad(for: service) {
            return .loading
        }
        if error(for: service) != nil && !hasLoadedContent(for: service) {
            return .error
        }
        switch service {
        case .claude:
            if claudeUsage != nil { return .content }
        case .codex:
            if codexUsage != nil { return .content }
        case .gemini:
            if geminiUsage != nil { return .content }
        case .antigravity:
            if antigravityUsage != nil { return .content }
        }
        return .empty
    }

    private enum StatusActionStyle {
        case bordered
        case prominent
    }

    private var standardTitleArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ProviderBrandIconView(provider: selectedService.providerKind, kind: .popover, size: 18)
                    .frame(width: 20, height: 20, alignment: .center)

                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedService.displayName)
                        .font(.headline)
                        .lineLimit(1)

                    Text(currentServiceSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if let lastUpdated = currentServiceLastUpdated {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("마지막 업데이트")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(lastUpdated, style: .time)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var compactBodyContent: some View {
        switch contentPhase(for: selectedService) {
        case .authRequired:
            compactStatusCard(
                icon: "lock.shield",
                iconColor: .orange,
                title: "\(selectedService.displayName) 연결 필요",
                message: "인증이 필요합니다. 설정에서 연결을 다시 확인해 주세요.",
                actionTitle: "설정 열기",
                actionStyle: .prominent
            ) {
                viewModel.openSettings(for: selectedService)
            }
        case .loading:
            compactStatusCard(
                showsProgress: true,
                title: "불러오는 중",
                message: "현재 연결 상태를 확인하고 있습니다."
            )
        case .error:
            if let error = serviceError {
                compactStatusCard(
                    icon: "exclamationmark.triangle",
                    iconColor: .orange,
                    title: error.isDefinitiveAuthFailure ? "인증 필요" : "조회 실패",
                    message: error.isDefinitiveAuthFailure ? "연결을 다시 확인해 주세요." : "잠시 후 다시 시도해 주세요.",
                    actionTitle: error.isDefinitiveAuthFailure ? "설정 열기" : "다시 시도",
                    actionStyle: error.isDefinitiveAuthFailure ? .prominent : .bordered
                ) {
                    if error.isDefinitiveAuthFailure {
                        viewModel.openSettings(for: selectedService)
                    } else {
                        viewModel.refresh()
                    }
                }
            }
        case .content:
            switch selectedService {
            case .claude:
                compactClaudeContent(usage: claudeUsage)
            case .codex:
                compactCodexContent()
            case .gemini:
                compactGeminiContent()
            case .antigravity:
                compactAntigravityContent()
            }
        case .empty:
            compactStatusCard(
                icon: "tray",
                iconColor: .secondary,
                title: "데이터 없음",
                message: "아직 가져온 사용량이 없습니다."
            )
        }
    }

    @ViewBuilder
    private var standardBodyContent: some View {
        switch contentPhase(for: selectedService) {
        case .authRequired:
            standardStatusCard(
                icon: "lock.shield",
                iconColor: .orange,
                title: "\(selectedService.displayName) 연결 필요",
                message: "인증이 필요합니다. 설정에서 연결을 다시 확인해 주세요.",
                actionTitle: "설정 열기",
                actionStyle: .prominent
            ) {
                viewModel.openSettings(for: selectedService)
            }
        case .loading:
            standardStatusCard(
                showsProgress: true,
                title: "데이터 로딩 중...",
                message: "현재 연결 상태를 확인하고 있습니다."
            )
        case .error:
            if let error = serviceError {
                standardStatusCard(
                    icon: "exclamationmark.triangle",
                    iconColor: .orange,
                    title: error.isDefinitiveAuthFailure ? "인증 필요" : "조회 실패",
                    message: error.isDefinitiveAuthFailure ? "연결을 다시 확인해 주세요." : "잠시 후 다시 시도해 주세요.",
                    actionTitle: error.isDefinitiveAuthFailure ? "설정 열기" : "다시 시도",
                    actionStyle: error.isDefinitiveAuthFailure ? .prominent : .bordered
                ) {
                    if error.isDefinitiveAuthFailure {
                        viewModel.openSettings(for: selectedService)
                    } else {
                        viewModel.refresh()
                    }
                }
            }
        case .content:
            switch selectedService {
            case .claude:
                standardClaudeContent(usage: claudeUsage)
            case .codex:
                standardCodexContent()
            case .gemini:
                standardGeminiContent()
            case .antigravity:
                standardAntigravityContent()
            }
        case .empty:
            standardStatusCard(
                icon: "tray",
                iconColor: .secondary,
                title: "데이터 없음",
                message: "아직 가져온 사용량이 없습니다."
            )
        }
    }

    @ViewBuilder
    private func standardStatusCard(
        icon: String? = nil,
        iconColor: Color = .secondary,
        showsProgress: Bool = false,
        title: String,
        message: String,
        actionTitle: String? = nil,
        actionStyle: StatusActionStyle = .bordered,
        action: (() -> Void)? = nil
    ) -> some View {
        centeredStatusCard(
            compact: false,
            icon: icon,
            iconColor: iconColor,
            showsProgress: showsProgress,
            title: title,
            message: message,
            actionTitle: actionTitle,
            actionStyle: actionStyle,
            action: action
        )
    }

    @ViewBuilder
    private func compactStatusCard(
        icon: String? = nil,
        iconColor: Color = .secondary,
        showsProgress: Bool = false,
        title: String,
        message: String,
        actionTitle: String? = nil,
        actionStyle: StatusActionStyle = .bordered,
        action: (() -> Void)? = nil
    ) -> some View {
        centeredStatusCard(
            compact: true,
            icon: icon,
            iconColor: iconColor,
            showsProgress: showsProgress,
            title: title,
            message: message,
            actionTitle: actionTitle,
            actionStyle: actionStyle,
            action: action
        )
    }

    @ViewBuilder
    private func centeredStatusCard(
        compact: Bool,
        icon: String?,
        iconColor: Color,
        showsProgress: Bool,
        title: String,
        message: String,
        actionTitle: String?,
        actionStyle: StatusActionStyle,
        action: (() -> Void)?
    ) -> some View {
        VStack(spacing: compact ? 6 : 8) {
            if showsProgress {
                ProgressView()
                    .controlSize(compact ? .small : .regular)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: compact ? 24 : 34))
                    .foregroundStyle(iconColor)
            }

            Text(title)
                .font(compact ? .subheadline.weight(.semibold) : .headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(message)
                .font(compact ? .caption2 : .caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .lineLimit(compact ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                if actionStyle == .prominent {
                    Button(actionTitle) {
                        action()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(compact ? .small : .regular)
                } else {
                    Button(actionTitle) {
                        action()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(compact ? .small : .regular)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Standard Content

    @ViewBuilder
    private func standardContent(usage: ClaudeUsageResponse?) -> some View {
        let visibleClaudeItems = settings.popoverItems.filter { $0.visible }
        let visibleCodexItems = ServiceSelectionHelper.isEnabled(.codex, settings: settings) ? settings.codexPopoverItems.filter { $0.visible } : []
        let orderedIDs = visibleClaudeItems.map(\.id) + visibleCodexItems.map(\.id)
        VStack(spacing: 12) {
            ForEach(Array(orderedIDs.enumerated()), id: \.offset) { index, itemID in
                if index > 0 { Divider() }
                switch itemID {
                case "currentSession":
                    if let usage {
                        UsageSectionView(
                            systemIcon: "gauge.medium",
                            title: "현재 세션",
                            percentage: usage.fiveHour.utilization,
                            resetAt: usage.fiveHour.resetsAt,
                            timeFormatStyle: settings.timeFormat
                        )
                    }
                case "weeklyLimit":
                    if let sevenDay = usage?.sevenDay {
                        UsageSectionView(
                            systemIcon: "calendar",
                            title: "주간 한도",
                            percentage: sevenDay.utilization,
                            resetAt: sevenDay.resetsAt,
                            isWeekly: true,
                            timeFormatStyle: settings.timeFormat
                        )
                    }
                case "modelUsage":
                    if let sonnet = usage?.sevenDaySonnet {
                        UsageSectionView(
                            systemIcon: "bolt.fill",
                            title: "Sonnet (주간)",
                            percentage: sonnet.utilization,
                            resetAt: sonnet.resetsAt,
                            isWeekly: true,
                            timeFormatStyle: settings.timeFormat
                        )
                    }
                    if let opus = usage?.sevenDayOpus {
                        if usage?.sevenDaySonnet != nil { Divider() }
                        UsageSectionView(
                            systemIcon: "diamond.fill",
                            title: "Opus (주간)",
                            percentage: opus.utilization,
                            resetAt: opus.resetsAt,
                            isWeekly: true,
                            timeFormatStyle: settings.timeFormat
                        )
                    }
                case "overageUsage":
                    if let overage = viewModel.overage, overage.isEnabled {
                        OverageUsageView(overage: overage)
                    }
                case "codexPrimary":
                    if let codex = codexUsage, let window = codex.rateLimit?.primaryWindow {
                        UsageSectionView(
                            systemIcon: "bubble.left.and.bubble.right",
                            title: "현재 세션",
                            percentage: window.utilization,
                            resetAt: window.resetAtISO,
                            timeFormatStyle: settings.codexTimeFormat
                        )
                    } else {
                        ProviderStatusRow(title: "현재 세션", error: viewModel.snapshot(for: .codex)?.error)
                    }
                case "codexSecondary":
                    if let codex = codexUsage, let window = codex.rateLimit?.secondaryWindow {
                        UsageSectionView(
                            systemIcon: "calendar.badge.clock",
                            title: "주간 한도",
                            percentage: window.utilization,
                            resetAt: window.resetAtISO,
                            isWeekly: true,
                            timeFormatStyle: settings.codexTimeFormat
                        )
                    } else {
                        ProviderStatusRow(title: "주간 한도", error: viewModel.snapshot(for: .codex)?.error)
                    }
                case "codexCredits":
                    if let codex = codexUsage, let credits = codex.credits {
                        CodexCreditsView(credits: credits)
                    } else {
                        ProviderStatusRow(title: "Codex 크레딧", error: viewModel.snapshot(for: .codex)?.error)
                    }
                default:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private func standardClaudeContent(usage: ClaudeUsageResponse?) -> some View {
        let visibleClaudeItems = settings.popoverItems.filter { $0.visible }
        VStack(spacing: 12) {
            ForEach(Array(visibleClaudeItems.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider() }
                switch item.id {
                case "currentSession":
                    if let usage {
                        UsageSectionView(
                            systemIcon: "gauge.medium",
                            title: "현재 세션",
                            percentage: usage.fiveHour.utilization,
                            resetAt: usage.fiveHour.resetsAt,
                            timeFormatStyle: settings.timeFormat
                        )
                    }
                case "weeklyLimit":
                    if let sevenDay = usage?.sevenDay {
                        UsageSectionView(
                            systemIcon: "calendar",
                            title: "주간 한도",
                            percentage: sevenDay.utilization,
                            resetAt: sevenDay.resetsAt,
                            isWeekly: true,
                            timeFormatStyle: settings.timeFormat
                        )
                    }
                case "modelUsage":
                    if let sonnet = usage?.sevenDaySonnet {
                        UsageSectionView(
                            systemIcon: "bolt.fill",
                            title: "Sonnet (주간)",
                            percentage: sonnet.utilization,
                            resetAt: sonnet.resetsAt,
                            isWeekly: true,
                            timeFormatStyle: settings.timeFormat
                        )
                    }
                    if let opus = usage?.sevenDayOpus {
                        if usage?.sevenDaySonnet != nil { Divider() }
                        UsageSectionView(
                            systemIcon: "diamond.fill",
                            title: "Opus (주간)",
                            percentage: opus.utilization,
                            resetAt: opus.resetsAt,
                            isWeekly: true,
                            timeFormatStyle: settings.timeFormat
                        )
                    }
                case "overageUsage":
                    if let overage = viewModel.overage, overage.isEnabled {
                        OverageUsageView(overage: overage)
                    }
                default:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private func standardCodexContent() -> some View {
        let visibleCodexItems = ServiceSelectionHelper.isEnabled(.codex, settings: settings) ? settings.codexPopoverItems.filter { $0.visible } : []
        VStack(spacing: 12) {
            ForEach(Array(visibleCodexItems.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider() }
                switch item.id {
                case "codexPrimary":
                    if let codex = codexUsage, let window = codex.rateLimit?.primaryWindow {
                        UsageSectionView(
                            systemIcon: "bubble.left.and.bubble.right",
                            title: "현재 세션",
                            percentage: window.utilization,
                            resetAt: window.resetAtISO,
                            timeFormatStyle: settings.codexTimeFormat
                        )
                    } else {
                        ProviderStatusRow(title: "현재 세션", error: viewModel.snapshot(for: .codex)?.error)
                    }
                case "codexSecondary":
                    if let codex = codexUsage, let window = codex.rateLimit?.secondaryWindow {
                        UsageSectionView(
                            systemIcon: "calendar.badge.clock",
                            title: "주간 한도",
                            percentage: window.utilization,
                            resetAt: window.resetAtISO,
                            isWeekly: true,
                            timeFormatStyle: settings.codexTimeFormat
                        )
                    } else {
                        ProviderStatusRow(title: "주간 한도", error: viewModel.snapshot(for: .codex)?.error)
                    }
                case "codexCredits":
                    if let codex = codexUsage, let credits = codex.credits {
                        CodexCreditsView(credits: credits)
                    } else {
                        ProviderStatusRow(title: "Codex 크레딧", error: viewModel.snapshot(for: .codex)?.error)
                    }
                default:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private var compactMainSection: some View {
        PopoverStateContainer(compact: true) {
            compactBodyContent
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var standardMainSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            standardTitleArea

            PopoverStateContainer(compact: false) {
                standardBodyContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.bottom, 4)
    }

    // MARK: - Compact Content

    @ViewBuilder
    private func compactClaudeContent(usage: ClaudeUsageResponse?) -> some View {
        let visibleClaudeItems = settings.effectiveCompactItems.filter { $0.visible }
        VStack(spacing: 4) {
            ForEach(visibleClaudeItems.map(\.id), id: \.self) { itemID in
                switch itemID {
                case "currentSession":
                    if let usage {
                        CompactUsageRow(label: "현재", percentage: usage.fiveHour.utilization, resetAt: usage.fiveHour.resetsAt, timeFormatStyle: settings.timeFormat)
                    }
                case "weeklyLimit":
                    if let sevenDay = usage?.sevenDay {
                        CompactUsageRow(label: "주간", percentage: sevenDay.utilization, resetAt: sevenDay.resetsAt, isWeekly: true, timeFormatStyle: settings.timeFormat)
                    }
                case "modelUsage":
                    if let sonnet = usage?.sevenDaySonnet {
                        CompactUsageRow(label: "Sonnet", percentage: sonnet.utilization, resetAt: sonnet.resetsAt, isWeekly: true, timeFormatStyle: settings.timeFormat)
                    }
                    if let opus = usage?.sevenDayOpus {
                        CompactUsageRow(label: "Opus", percentage: opus.utilization, resetAt: opus.resetsAt, isWeekly: true, timeFormatStyle: settings.timeFormat)
                    }
                case "overageUsage":
                    if let overage = viewModel.overage, overage.isEnabled {
                        CompactOverageRow(overage: overage)
                    }
                default:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private func compactCodexContent() -> some View {
        let visibleCodexItems = settings.effectiveCompactCodexItems.filter { $0.visible }
        VStack(spacing: 4) {
            ForEach(visibleCodexItems.map(\.id), id: \.self) { itemID in
                switch itemID {
                case "codexPrimary":
                    if let codex = codexUsage, let window = codex.rateLimit?.primaryWindow {
                        CompactUsageRow(label: "현재", percentage: window.utilization, resetAt: window.resetAtISO, timeFormatStyle: settings.codexTimeFormat)
                    }
                case "codexSecondary":
                    if let codex = codexUsage, let window = codex.rateLimit?.secondaryWindow {
                        CompactUsageRow(label: "주간", percentage: window.utilization, resetAt: window.resetAtISO, isWeekly: true, timeFormatStyle: settings.codexTimeFormat)
                    }
                case "codexCredits":
                    if let codex = codexUsage, let credits = codex.credits {
                        CompactCodexCreditsRow(credits: credits)
                    }
                default:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private func standardGeminiContent() -> some View {
        VStack(spacing: 12) {
            if let primary = geminiUsage?.primaryWindow {
                UsageSectionView(
                    systemIcon: "sparkles",
                    title: primary.label,
                    percentage: primary.usedPercent,
                    resetAt: primary.resetAtISO,
                    timeFormatStyle: settings.timeFormat
                )
            }

            if let secondary = geminiUsage?.secondaryWindow {
                Divider()
                UsageSectionView(
                    systemIcon: "bolt.horizontal.circle",
                    title: secondary.label,
                    percentage: secondary.usedPercent,
                    resetAt: secondary.resetAtISO,
                    isWeekly: true,
                    timeFormatStyle: settings.timeFormat
                )
            }

            if let tertiary = geminiUsage?.tertiaryWindow {
                Divider()
                UsageSectionView(
                    systemIcon: "circle.hexagongrid",
                    title: tertiary.label,
                    percentage: tertiary.usedPercent,
                    resetAt: tertiary.resetAtISO,
                    isWeekly: true,
                    timeFormatStyle: settings.timeFormat
                )
            }

            if let usage = geminiUsage,
               usage.accountEmail != nil || usage.accountPlan != nil {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("계정 정보", systemImage: "person.crop.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let email = usage.accountEmail {
                        Text(email)
                            .font(.subheadline)
                    }
                    if let plan = usage.accountPlan {
                        Text("플랜: \(plan)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func compactGeminiContent() -> some View {
        VStack(spacing: 4) {
            if let primary = geminiUsage?.primaryWindow {
                CompactUsageRow(label: primary.label, percentage: primary.usedPercent, resetAt: primary.resetAtISO, timeFormatStyle: settings.timeFormat)
            }
            if let secondary = geminiUsage?.secondaryWindow {
                CompactUsageRow(label: secondary.label, percentage: secondary.usedPercent, resetAt: secondary.resetAtISO, isWeekly: true, timeFormatStyle: settings.timeFormat)
            }
            if let tertiary = geminiUsage?.tertiaryWindow {
                CompactUsageRow(label: "Lite", percentage: tertiary.usedPercent, resetAt: tertiary.resetAtISO, isWeekly: true, timeFormatStyle: settings.timeFormat)
            }
        }
    }

    @ViewBuilder
    private func standardAntigravityContent() -> some View {
        VStack(spacing: 12) {
            if let primary = antigravityUsage?.primaryWindow {
                UsageSectionView(
                    systemIcon: "brain",
                    title: primary.label,
                    percentage: primary.usedPercent,
                    resetAt: primary.resetAtISO,
                    timeFormatStyle: settings.timeFormat
                )
            }

            if let secondary = antigravityUsage?.secondaryWindow {
                Divider()
                UsageSectionView(
                    systemIcon: "sparkles",
                    title: secondary.label,
                    percentage: secondary.usedPercent,
                    resetAt: secondary.resetAtISO,
                    isWeekly: true,
                    timeFormatStyle: settings.timeFormat
                )
            }

            if let tertiary = antigravityUsage?.tertiaryWindow {
                Divider()
                UsageSectionView(
                    systemIcon: "bolt.horizontal.circle",
                    title: tertiary.label,
                    percentage: tertiary.usedPercent,
                    resetAt: tertiary.resetAtISO,
                    isWeekly: true,
                    timeFormatStyle: settings.timeFormat
                )
            }

            if let usage = antigravityUsage,
               usage.accountEmail != nil || usage.accountPlan != nil {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("계정 정보", systemImage: "person.crop.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let email = usage.accountEmail {
                        Text(email)
                            .font(.subheadline)
                    }
                    if let plan = usage.accountPlan {
                        Text("플랜: \(plan)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func compactAntigravityContent() -> some View {
        VStack(spacing: 4) {
            if let primary = antigravityUsage?.primaryWindow {
                CompactUsageRow(label: primary.label, percentage: primary.usedPercent, resetAt: primary.resetAtISO, timeFormatStyle: settings.timeFormat)
            }
            if let secondary = antigravityUsage?.secondaryWindow {
                CompactUsageRow(label: secondary.label, percentage: secondary.usedPercent, resetAt: secondary.resetAtISO, isWeekly: true, timeFormatStyle: settings.timeFormat)
            }
            if let tertiary = antigravityUsage?.tertiaryWindow {
                CompactUsageRow(label: tertiary.label, percentage: tertiary.usedPercent, resetAt: tertiary.resetAtISO, isWeekly: true, timeFormatStyle: settings.timeFormat)
            }
        }
    }
}

enum PopoverContentPhase {
    case authRequired
    case loading
    case error
    case empty
    case content
}

enum PopoverLayoutMetrics {
    static let standardPopoverWidth: CGFloat = 368
    static let compactRowLabelWidth: CGFloat = 108
    static let compactRowMeterWidth: CGFloat = 140
    static let compactRowSpacing: CGFloat = 8
}

struct PopoverStateContainer<Content: View>: View {
    let compact: Bool
    private let content: Content

    init(compact: Bool, @ViewBuilder content: () -> Content) {
        self.compact = compact
        self.content = content()
    }

    private var minHeight: CGFloat {
        compact ? 72 : 184
    }

    private var paddingInsets: EdgeInsets {
        if compact {
            return EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        }
        return EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .padding(paddingInsets)
    }
}

// MARK: - Compact Usage Row

struct CompactUsageRow: View {
    let label: String
    let percentage: Double
    var resetAt: String? = nil
    var isWeekly: Bool = false
    var timeFormatStyle: TimeFormatStyle = .h24

    var body: some View {
        HStack(alignment: .center, spacing: PopoverLayoutMetrics.compactRowSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(compactResetText ?? "--")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
            }
            .frame(width: PopoverLayoutMetrics.compactRowLabelWidth, alignment: .leading)

            HStack(spacing: 6) {
                ProgressBarView(percentage: percentage, height: 6)
                    .frame(maxWidth: .infinity)

                Text(String(format: "%.0f%%", percentage))
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundStyle(ColorProvider.statusColor(for: percentage))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(width: PopoverLayoutMetrics.compactRowMeterWidth, alignment: .trailing)
        }
        .padding(.vertical, 1)
    }

    private var compactResetText: String? {
        guard let resetAt = resetAt else { return "--" }
        if isWeekly {
            return TimeFormatter.formatResetTimeWeekly(from: resetAt, style: timeFormatStyle) ?? "--"
        }
        // 현재 세션(5시간)은 날짜 없이 시간만 표시
        return TimeFormatter.formatResetTime(from: resetAt, style: timeFormatStyle, includeDateIfNotToday: false) ?? "--"
    }
}

// MARK: - Error Section

struct AuthRequiredSectionView: View {
    let service: PopoverService
    let openSettingsAction: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 30))
                .foregroundStyle(.orange)

            Text(authTitle)
                .font(.headline)

            Text(authMessage)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("인증 설정 열기") {
                openSettingsAction()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
    }

    private var authTitle: String {
        switch service {
        case .claude:
            return "Claude 인증이 필요합니다"
        case .codex:
            return "Codex 인증이 필요합니다"
        case .gemini:
            return "Gemini 연결이 필요합니다"
        case .antigravity:
            return "Antigravity 연결이 필요합니다"
        }
    }

    private var authMessage: String {
        switch service {
        case .claude:
            return "로그인 후 세션키를 저장하면 조회가 시작됩니다."
        case .codex:
            return "Codex CLI 로그인 후 토큰이 준비되면 조회가 시작됩니다."
        case .gemini:
            return "Gemini CLI OAuth 자격이 준비되면 조회가 시작됩니다."
        case .antigravity:
            return "Antigravity language server가 실행 중이면 로컬 quota 조회가 시작됩니다."
        }
    }
}

struct ErrorSectionView: View {
    let error: APIError
    let retryAction: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            Text("데이터를 가져올 수 없습니다")
                .font(.headline)

            Text(error.errorDescription ?? "알 수 없는 오류")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if error.isTemporaryFailure {
                Text("현재 세션키 경로가 일시적으로 불안정합니다. 설정 > 인증에서 Claude CLI OAuth 인증을 권장합니다.")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(6)
            }

            HStack(spacing: 12) {
                Button("다시 시도") {
                    retryAction()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct ProviderStatusRow: View {
    let title: String
    let error: APIError?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        if let error {
            return error.isDefinitiveAuthFailure ? "인증 필요" : "조회 실패"
        }
        return "데이터 없음"
    }

    private var statusColor: Color {
        if let error {
            return error.isDefinitiveAuthFailure ? .orange : .secondary
        }
        return .secondary
    }
}

// MARK: - Codex Credits

struct CodexCreditsView: View {
    let credits: CodexCredits

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "creditcard")
                    .foregroundStyle(.secondary)
                Text("Codex 크레딧")
                    .font(.headline)
                Spacer()
                Text(credits.formattedBalance)
                    .font(.title3)
                    .fontWeight(.semibold)
            }
            HStack {
                Text(credits.unlimited ? "무제한 플랜" : "사용 가능한 크레딧")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
}

struct CompactCodexCreditsRow: View {
    let credits: CodexCredits

    var body: some View {
        HStack(spacing: 4) {
            Text("크레딧")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, idealWidth: 42, maxWidth: 56, alignment: .leading)

            Text(credits.formattedBalance)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 48, alignment: .trailing)
                .layoutPriority(1)
        }
    }
}

// MARK: - Overage Usage View (Standard)

struct OverageUsageView: View {
    let overage: OverageSpendLimitResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "creditcard")
                    .foregroundStyle(.secondary)
                Text("추가 사용량")
                    .font(.headline)
                Spacer(minLength: 0)
                Text(String(format: "%.0f%%", overage.usagePercentage))
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.purple)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Text("\(overage.formattedUsedCredits) 사용 / \(overage.formattedCreditLimit) 한도 (잔액 \(overage.formattedRemainingCredits))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Compact Overage Row

struct CompactOverageRow: View {
    let overage: OverageSpendLimitResponse

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("추가")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text("잔액 \(overage.formattedRemainingCredits)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)

            HStack(spacing: 6) {
                ProgressBarView(percentage: overage.usagePercentage, height: 6, color: .purple)
                    .frame(maxWidth: .infinity)

                Text(String(format: "%.0f%%", overage.usagePercentage))
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundStyle(.purple)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(minWidth: 88, idealWidth: 110, maxWidth: 140)
        }
        .padding(.vertical, 1)
    }
}
