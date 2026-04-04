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
        let layoutSpec = currentLayoutSpec

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
                compactMainSection(layoutSpec: layoutSpec)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    standardMainSection(layoutSpec: layoutSpec)
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
        .frame(width: layoutSpec.size.width, alignment: .topLeading)
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
                viewModel.requestLayoutRefresh(reason: .compactToggle)
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
        viewModel.requestLayoutRefresh(for: service, reason: .serviceSelection)
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

    private var currentServiceLastUpdated: Date? {
        serviceLastUpdated(for: selectedService)
    }

    private var currentServiceRuntimeState: PopoverViewModel.RuntimeServiceState {
        viewModel.runtimeServiceState(for: selectedService, settings: settings)
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
            return settings.isPopoverCompact(for: appProviderKind(for: selectedService))
        }
        nonmutating set {
            setCompactForAllServices(newValue)
        }
    }

    private func setCompactForAllServices(_ compact: Bool) {
        settings.setPopoverCompact(compact, for: appProviderKind(for: selectedService))
    }

    private func syncCompactAcrossServicesIfNeeded() {
        settings.setPopoverCompact(isCompact, for: appProviderKind(for: selectedService))
    }

    private var isPinned: Bool {
        get {
            settings.isPopoverPinned(for: appProviderKind(for: selectedService))
        }
        nonmutating set {
            settings.setPopoverPinned(newValue, for: appProviderKind(for: selectedService))
        }
    }

    private var currentLayoutSpec: PopoverLayoutSpec {
        viewModel.layoutSpec(for: selectedService, settings: settings)
    }

    static func preferredPopoverWidth(compact: Bool) -> CGFloat {
        PopoverLayoutMetrics.preferredPopoverWidth(compact: compact)
    }

    static func resolvedPopoverWidth(for service: PopoverService, compact: Bool) -> CGFloat {
        self.preferredPopoverWidth(compact: compact)
    }

    static func minimumPopoverHeight(compact: Bool) -> CGFloat {
        if !compact { return 292 }
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

    private typealias StatusActionStyle = StatusPanelActionStyle

    private struct StatusPanelConfiguration {
        let icon: String?
        let iconColor: Color
        let showsProgress: Bool
        let title: String
        let message: String
        let actionTitle: String?
        let actionStyle: StatusActionStyle
        let action: (() -> Void)?
    }

    @ViewBuilder
    private func bodyContent(layoutSpec: PopoverLayoutSpec) -> some View {
        switch layoutSpec.phase {
        case .authRequired:
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
                statusPanel(
                    density: layoutSpec.density,
                    configuration: StatusPanelConfiguration(
                        icon: "exclamationmark.triangle",
                        iconColor: .orange,
                        showsProgress: false,
                        title: error.isDefinitiveAuthFailure ? "인증 필요" : "조회 실패",
                        message: error.isDefinitiveAuthFailure ? "연결을 다시 확인해 주세요." : "잠시 후 다시 시도해 주세요.",
                        actionTitle: error.isDefinitiveAuthFailure ? "설정 열기" : "다시 시도",
                        actionStyle: error.isDefinitiveAuthFailure ? .prominent : .bordered,
                        action: {
                            if error.isDefinitiveAuthFailure {
                                viewModel.openSettings(for: selectedService)
                            } else {
                                viewModel.refresh()
                            }
                        }
                    )
                )
            }
        case .content:
            displaySectionsContent(layoutSpec: layoutSpec)
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

    @ViewBuilder
    private func displaySectionsContent(layoutSpec: PopoverLayoutSpec) -> some View {
        let sections = viewModel.displaySections(for: selectedService, density: layoutSpec.density, settings: settings)
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
    private func compactMainSection(layoutSpec: PopoverLayoutSpec) -> some View {
        PopoverStateContainer(layoutSpec: layoutSpec) {
            bodyContent(layoutSpec: layoutSpec)
        }
        .padding(.bottom, 1)
    }

    @ViewBuilder
    private func standardMainSection(layoutSpec: PopoverLayoutSpec) -> some View {
        PopoverStateContainer(layoutSpec: layoutSpec) {
            bodyContent(layoutSpec: layoutSpec)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.bottom, 2)
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
    static let compactPopoverWidth: CGFloat = 296
    static let compactHeaderHeight: CGFloat = 30
    static let compactFooterHeight: CGFloat = 31
    static let dividerHeight: CGFloat = 1
    static let compactBodyInsets = EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10)
    static let standardBodyInsets = EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
    static let compactSectionSpacing: CGFloat = 3
    static let standardSectionSpacing: CGFloat = 12
    static let compactRowLabelWidth: CGFloat = 100
    static let compactRowMeterWidth: CGFloat = 150
    static let compactRowSpacing: CGFloat = 6
    static let compactUsageRowHeight: CGFloat = 18
    static let compactCreditsRowHeight: CGFloat = 18
    static let compactStatusRowHeight: CGFloat = 18
    static let compactOverageRowHeight: CGFloat = 22
    static let compactProgressBarHeight: CGFloat = 8
    static let compactStatusPanelHeight: CGFloat = 40
    static let compactInteractiveStatusPanelHeight: CGFloat = 48
    static let compactMinimumPopoverHeight: CGFloat = 96

    static func preferredPopoverWidth(compact: Bool) -> CGFloat {
        compact ? compactPopoverWidth : standardPopoverWidth
    }

    static func layoutSpec(
        density: PopoverDensity,
        phase: PopoverContentPhase,
        sections: [PopoverDisplaySection],
        rowCount: Int
    ) -> PopoverLayoutSpec {
        let bodyInsets = density.isCompact ? compactBodyInsets : standardBodyInsets
        let sectionSpacing = density.isCompact ? compactSectionSpacing : standardSectionSpacing

        if density.isCompact {
            let bodyContentHeight = compactBodyContentHeight(phase: phase, sections: sections)
            let totalHeight = max(
                compactMinimumPopoverHeight,
                compactHeaderHeight
                    + bodyInsets.top
                    + bodyContentHeight
                    + bodyInsets.bottom
                    + dividerHeight
                    + compactFooterHeight
            )
            return PopoverLayoutSpec(
                density: density,
                phase: phase,
                size: CGSize(width: compactPopoverWidth, height: totalHeight),
                bodyContentHeight: bodyContentHeight,
                bodyInsets: bodyInsets,
                sectionSpacing: sectionSpacing
            )
        }

        let bodyContentHeight = minimumBodyHeight(compact: false, phase: phase)
        return PopoverLayoutSpec(
            density: density,
            phase: phase,
            size: CGSize(
                width: standardPopoverWidth,
                height: preferredPopoverHeight(compact: false, phase: phase, rowCount: rowCount)
            ),
            bodyContentHeight: bodyContentHeight,
            bodyInsets: bodyInsets,
            sectionSpacing: sectionSpacing
        )
    }

    static func preferredPopoverHeight(
        compact: Bool,
        phase: PopoverContentPhase,
        rowCount: Int
    ) -> CGFloat {
        if compact {
            if phase == .content {
                let contentHeight = compactUsageRowHeight * CGFloat(max(rowCount, 1))
                    + compactSectionSpacing * CGFloat(max(0, rowCount - 1))
                return max(
                    compactMinimumPopoverHeight,
                    compactHeaderHeight
                        + compactBodyInsets.top
                        + contentHeight
                        + compactBodyInsets.bottom
                        + dividerHeight
                        + compactFooterHeight
                )
            }
            let statusHeight = phase == .authRequired || phase == .error
                ? compactInteractiveStatusPanelHeight
                : compactStatusPanelHeight
            return compactHeaderHeight
                + compactBodyInsets.top
                + statusHeight
                + compactBodyInsets.bottom
                + dividerHeight
                + compactFooterHeight
        }

        switch phase {
        case .authRequired, .loading, .error, .empty:
            return 216
        case .content:
            switch rowCount {
            case ...2:
                return 256
            case 3:
                return 300
            default:
                return 336
            }
        }
    }

    static func minimumBodyHeight(
        compact: Bool,
        phase: PopoverContentPhase
    ) -> CGFloat {
        if compact {
            switch phase {
            case .content:
                return 44
            case .authRequired, .loading, .error, .empty:
                return 36
            }
        }

        switch phase {
        case .content:
            return 108
        case .authRequired, .loading, .error, .empty:
            return 72
        }
    }

    static func compactSectionHeight(for kind: PopoverDisplaySectionKind) -> CGFloat {
        switch kind {
        case .usage:
            return compactUsageRowHeight
        case .credits:
            return compactCreditsRowHeight
        case .overage:
            return compactOverageRowHeight
        case .account:
            return compactOverageRowHeight
        case .status:
            return compactStatusRowHeight
        }
    }

    static func compactBodyContentHeight(
        phase: PopoverContentPhase,
        sections: [PopoverDisplaySection]
    ) -> CGFloat {
        guard phase == .content else {
            return phase == .authRequired || phase == .error
                ? compactInteractiveStatusPanelHeight
                : compactStatusPanelHeight
        }

        let sectionHeights = sections.map { compactSectionHeight(for: $0.kind) }
        guard !sectionHeights.isEmpty else { return 1 }
        return sectionHeights.reduce(0, +)
            + compactSectionSpacing * CGFloat(max(0, sectionHeights.count - 1))
    }
}

struct PopoverStateContainer<Content: View>: View {
    let layoutSpec: PopoverLayoutSpec
    private let content: Content

    init(layoutSpec: PopoverLayoutSpec, @ViewBuilder content: () -> Content) {
        self.layoutSpec = layoutSpec
        self.content = content()
    }

    var body: some View {
        content
            .frame(
                maxWidth: .infinity,
                minHeight: layoutSpec.bodyContentHeight,
                maxHeight: layoutSpec.isCompact ? layoutSpec.bodyContentHeight : nil,
                alignment: .topLeading
            )
            .padding(layoutSpec.bodyInsets)
    }
}

enum StatusPanelActionStyle: Equatable {
    case bordered
    case prominent
}

struct StatusPanelView: View {
    let density: PopoverDensity
    let icon: String?
    let iconColor: Color
    let showsProgress: Bool
    let title: String
    let message: String
    let actionTitle: String?
    let actionStyle: StatusPanelActionStyle
    let action: (() -> Void)?

    private var compactPanelHeight: CGFloat {
        if actionTitle != nil, action != nil {
            return PopoverLayoutMetrics.compactInteractiveStatusPanelHeight
        }
        return PopoverLayoutMetrics.compactStatusPanelHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.isCompact ? 6 : 10) {
            HStack(alignment: .center, spacing: density.isCompact ? 8 : 10) {
                leadingIndicator

                Text(title)
                    .font(density.isCompact ? .caption.weight(.semibold) : .title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(density.isCompact ? 0.85 : 1.0)

                Spacer(minLength: density.isCompact ? 8 : 12)

                if let actionTitle, let action {
                    actionButton(title: actionTitle, action: action)
                }
            }

            Text(message)
                .font(density.isCompact ? .system(size: 10, weight: .medium) : .subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(
            minHeight: density.isCompact ? compactPanelHeight : nil,
            maxHeight: density.isCompact ? compactPanelHeight : nil,
            alignment: .topLeading
        )
        .padding(.vertical, density.isCompact ? 0 : 4)
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        if showsProgress {
            ProgressView()
                .controlSize(density.isCompact ? .small : .regular)
                .frame(width: density.isCompact ? 14 : 18, height: density.isCompact ? 14 : 18, alignment: .center)
        } else if let icon {
            Image(systemName: icon)
                .font(.system(size: density.isCompact ? 12 : 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: density.isCompact ? 14 : 18, height: density.isCompact ? 14 : 18, alignment: .center)
        }
    }

    @ViewBuilder
    private func actionButton(title: String, action: @escaping () -> Void) -> some View {
        if actionStyle == .prominent {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(density.isCompact ? .small : .regular)
        } else {
            Button(title, action: action)
                .buttonStyle(.bordered)
                .controlSize(density.isCompact ? .small : .regular)
        }
    }
}

struct PopoverDisplaySectionView: View {
    let section: PopoverDisplaySection
    let density: PopoverDensity

    var body: some View {
        switch section.payload {
        case .usage(let usage):
            if density.isCompact {
                CompactUsageRow(
                    label: usage.compactLabel,
                    percentage: usage.percentage,
                    resetAt: usage.resetAt,
                    isWeekly: usage.isWeekly,
                    timeFormatStyle: usage.timeFormatStyle
                )
            } else {
                UsageSectionView(
                    systemIcon: usage.systemIcon,
                    title: usage.title,
                    percentage: usage.percentage,
                    resetAt: usage.resetAt,
                    isWeekly: usage.isWeekly,
                    timeFormatStyle: usage.timeFormatStyle
                )
            }
        case .credits(let credits):
            if density.isCompact {
                CompactCodexCreditsRow(credits: credits.credits)
            } else {
                CodexCreditsView(credits: credits.credits)
            }
        case .overage(let overage):
            if density.isCompact {
                CompactOverageRow(overage: overage.overage)
            } else {
                OverageUsageView(overage: overage.overage)
            }
        case .account(let account):
            AccountSectionView(account: account, density: density)
        case .status(let status):
            ProviderStatusSectionView(status: status, density: density)
        }
    }
}

struct AccountSectionView: View {
    let account: PopoverAccountSectionData
    let density: PopoverDensity

    var body: some View {
        VStack(alignment: .leading, spacing: density.isCompact ? 4 : 6) {
            Label(account.title, systemImage: account.systemIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let email = account.email {
                Text(email)
                    .font(density.isCompact ? .caption : .subheadline)
                    .lineLimit(1)
            }
            if let plan = account.plan {
                Text("플랜: \(plan)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProviderStatusSectionView: View {
    let status: PopoverStatusSectionData
    let density: PopoverDensity

    var body: some View {
        if density.isCompact {
            HStack(spacing: 6) {
                Text(status.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: PopoverLayoutMetrics.compactStatusRowHeight,
                maxHeight: PopoverLayoutMetrics.compactStatusRowHeight,
                alignment: .center
            )
        } else {
            ProviderStatusRow(title: status.title, error: status.error)
        }
    }

    private var statusText: String {
        if let error = status.error {
            return error.isDefinitiveAuthFailure ? "인증 필요" : "조회 실패"
        }
        return "데이터 없음"
    }

    private var statusColor: Color {
        if let error = status.error {
            return error.isDefinitiveAuthFailure ? .orange : .secondary
        }
        return .secondary
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
            compactLabelLine
            .frame(width: PopoverLayoutMetrics.compactRowLabelWidth, alignment: .leading)

            HStack(spacing: 6) {
                ProgressBarView(
                    percentage: percentage,
                    height: PopoverLayoutMetrics.compactProgressBarHeight
                )
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
        .frame(
            maxWidth: .infinity,
            minHeight: PopoverLayoutMetrics.compactUsageRowHeight,
            maxHeight: PopoverLayoutMetrics.compactUsageRowHeight,
            alignment: .center
        )
    }

    private var compactLabelLine: some View {
        (
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            +
            Text(" · ")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            +
            Text(compactResetText ?? "--")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        )
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .truncationMode(.tail)
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
        .frame(
            maxWidth: .infinity,
            minHeight: PopoverLayoutMetrics.compactCreditsRowHeight,
            maxHeight: PopoverLayoutMetrics.compactCreditsRowHeight,
            alignment: .center
        )
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
                ProgressBarView(
                    percentage: overage.usagePercentage,
                    height: PopoverLayoutMetrics.compactProgressBarHeight,
                    color: .purple
                )
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
        .frame(
            maxWidth: .infinity,
            minHeight: PopoverLayoutMetrics.compactOverageRowHeight,
            maxHeight: PopoverLayoutMetrics.compactOverageRowHeight,
            alignment: .center
        )
    }
}
