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
            // Compact는 계정 혼동이나 조치가 필요한 상태만 한 줄에 남긴다.
            // Standard는 provenance/freshness를 별도 상태 레일로 제공한다.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    headerServiceSelector
                        .layoutPriority(1)
                    if let context = compactHeaderContext {
                        compactHeaderContextView(context)
                            .layoutPriority(0)
                    }
                    Spacer(minLength: isCompact ? 4 : 8)
                    headerUtilityControls
                }
                .frame(height: PopoverLayoutMetrics.providerSelectorSize(compact: isCompact))

                if !isCompact {
                    providerStatusRail
                        .frame(height: 12)
                }
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
                ProviderExternalActionsView(
                    provider: selectedService.providerKind,
                    compact: isCompact
                ) { action in
                    viewModel.openExternalAction(action)
                }

                Spacer()

                if selectedService == .antigravity {
                    Button {
                        viewModel.openSettings(panel: .display)
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "slider.horizontal.3")
                            if !isCompact { Text("표시") }
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Antigravity 표시 설정")
                    .accessibilityLabel("Antigravity 표시 설정")
                } else {
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
        if isCompact {
            HStack(spacing: 5) {
                ForEach(availableServices, id: \.rawValue) { service in
                    headerSelectorButton(for: service)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        } else if availableServices.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
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

    private var compactHeaderContext: CompactPopoverHeaderContext? {
        guard isCompact else { return nil }
        return viewModel.compactHeaderContext(
            for: selectedService,
            settings: settings
        )
    }

    private func compactHeaderContextView(_ context: CompactPopoverHeaderContext) -> some View {
        HStack(spacing: 3) {
            if let accountLabel = context.accountLabel {
                Text(accountLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if context.accountLabel != nil, context.status != nil {
                Text("·")
                    .foregroundStyle(.tertiary)
            }
            if let status = context.status {
                Text(status.label)
                    .foregroundStyle(status == .authenticationRequired || status == .refreshFailed ? .orange : .secondary)
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
        .font(.system(size: 9, weight: .medium))
        .help(context.labels.joined(separator: " · "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("선택한 서비스 상태")
        .accessibilityValue(context.labels.joined(separator: ", "))
    }

    @ViewBuilder
    private var providerStatusRail: some View {
        let state = viewModel.runtimeServiceState(for: selectedService, settings: settings)
        if let identityRail =
            viewModel.identityRailProjection(
                for: selectedService
            )
        {
            // Standard AGY의 계정·출처·freshness는 스크롤 밖에 고정한다.
            // quota group이 길어져도 현재 숫자의 provenance를 잃지 않는다.
            ProviderIdentityRail(
                projection: identityRail
            )
        } else {
            let label = providerStatusRailText(state: state)
            HStack(spacing: 4) {
                providerStatusRailSegments(state: state)
                Spacer(minLength: 0)
            }
            .help(label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(selectedService.displayName) 상태")
            .accessibilityValue(label)
        }
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
        return state.providerSelectorAccessibilityValue(
            isSelected: selectedService == service
        )
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

        if viewModel.shouldRequestRefreshWhenVisible(
            for: selectedService,
            settings: settings
        ) {
            viewModel.refresh(service: selectedService)
        }
    }

    private func serviceLoading(for service: PopoverService) -> Bool {
        viewModel.runtimeServiceState(for: service, settings: settings).isLoading
    }

    @ViewBuilder
    private func bodyContent(layoutSpec: PopoverLayoutSpec, sections: [PopoverDisplaySection]) -> some View {
        ProviderPopoverContentHost(
            viewModel: viewModel,
            settings: settings,
            service: selectedService,
            layoutSpec: layoutSpec,
            sections: sections,
            isDisplayEditorPresented:
                $isDisplayEditorPresented
        )
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
                    if viewModel
                        .compactContentRowCount(
                            for: selectedService,
                            catalogSections:
                                sections
                        )
                        > PopoverLayoutMetrics
                        .compactMaximumVisibleRows
                    {
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
            .frame(
                maxWidth: .infinity,
                minHeight:
                    layoutSpec.bodyContentHeight
                    + layoutSpec.bodyInsets.top
                    + layoutSpec.bodyInsets.bottom
                    + PopoverLayoutMetrics.standardMainSectionBottomSpacing,
                maxHeight:
                    layoutSpec.bodyContentHeight
                    + layoutSpec.bodyInsets.top
                    + layoutSpec.bodyInsets.bottom
                    + PopoverLayoutMetrics.standardMainSectionBottomSpacing,
                alignment: .top
            )
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
