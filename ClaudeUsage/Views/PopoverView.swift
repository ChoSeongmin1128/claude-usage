//
//  PopoverView.swift
//  ClaudeUsage
//
//  Phase 2: 메인 Popover UI
//

import SwiftUI

struct PopoverView: View {
    @ObservedObject var viewModel: PopoverViewModel
    @ObservedObject private var settings: AppSettings

    init(viewModel: PopoverViewModel, settings: AppSettings = .shared) {
        self.viewModel = viewModel
        self.settings = settings
    }
    @State private var isDisplayEditorPresented = false
    @State private var displayEditorMode: PopoverDisplayEditorMode = .standard

    var body: some View {
        let layout = viewModel.layoutWithSections(for: selectedService, settings: settings)
        let layoutSpec = layout.spec

        VStack(alignment: .leading, spacing: 0) {
            // Compact는 계정 혼동이나 조치가 필요한 상태만 한 줄에 남긴다.
            // Standard는 provenance/freshness를 별도 상태 레일로 제공한다.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: AppDesign.Space.row) {
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
                    providerStatusRail.frame(height: 12)
                }
            }
            .padding(.horizontal, isCompact ? 12 : 16)
            .frame(
                height: isCompact
                    ? PopoverLayoutMetrics.compactHeaderHeight : PopoverLayoutMetrics.standardHeaderContainerHeight)

            if isCompact {
                compactMainSection(layoutSpec: layoutSpec, sections: layout.sections)
            } else {
                standardMainContainer(layoutSpec: layoutSpec, sections: layout.sections)
            }

            Divider().padding(.horizontal, isCompact ? AppDesign.Space.content : AppDesign.Space.section)

            HStack(spacing: AppDesign.Space.compact) {
                ProviderExternalActionsView(provider: selectedService.providerKind, compact: isCompact) {
                    viewModel.openExternalAction($0)
                }
                Spacer(minLength: AppDesign.Space.compact)
                IconActionButton(symbol: "slider.horizontal.3", label: "표시 항목 편집", compact: isCompact) {
                    if selectedService == .antigravity {
                        viewModel.openSettings(panel: .display)
                    } else {
                        displayEditorMode = isCompact ? .compact : .standard
                        isDisplayEditorPresented.toggle()
                    }
                }
                .popover(isPresented: $isDisplayEditorPresented, arrowEdge: .bottom) {
                    PopoverDisplayEditorView(
                        settings: settings, service: selectedService, selectedMode: $displayEditorMode)
                }
                IconActionButton(symbol: "gearshape", label: "설정 열기", compact: isCompact) {
                    viewModel.openSettings()
                }
                IconActionButton(symbol: "power", label: "ClaudeUsage 종료", compact: isCompact) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, isCompact ? AppDesign.Space.content : AppDesign.Space.section)
            .frame(
                height: isCompact
                    ? PopoverLayoutMetrics.compactFooterHeight : PopoverLayoutMetrics.standardFooterContainerHeight)

            if !isCompact {
                HStack(spacing: AppDesign.Space.row) {
                    Text("⌘R 새로고침")
                    Text("⌘, 설정")
                }
                .font(AppDesign.Typography.metadata)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, AppDesign.Space.control)
            }
        }
        .frame(width: layoutSpec.size.width, height: layoutSpec.size.height, alignment: .topLeading)
        .onAppear {
            normalizeSelectedServiceIfNeeded()
            requestRefreshIfNeededForVisibleService()
        }
        .onChange(of: settings.providerStates) { _, _ in
            normalizeSelectedServiceIfNeeded()
        }
        .onChange(of: viewModel.selectedService) { _, _ in
            isDisplayEditorPresented = false
        }
    }

    // MARK: - Helpers

    private var headerUtilityControls: some View {
        HStack(spacing: AppDesign.Space.tight) {
            if viewModel.shouldShowUpdateButton {
                IconActionButton(
                    symbol: viewModel.updateButtonSymbolName, label: viewModel.updateButtonHelpText, isActive: true
                ) {
                    viewModel.performUpdatePrimaryAction()
                }
            }
            IconActionButton(
                symbol: "arrow.clockwise",
                label: viewModel.refreshHelp(for: selectedService, isLoading: currentServiceLoading),
                isLoading: currentServiceLoading,
                isEnabled: !currentServiceLoading && viewModel.manualRefreshAvailableAt(for: selectedService) == nil
            ) { viewModel.refresh() }
            IconActionButton(
                symbol: isCompact ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                label: isCompact ? "일반 보기로 전환" : "간소화 보기로 전환"
            ) {
                isCompact.toggle()
                displayEditorMode = isCompact ? .compact : .standard
                viewModel.requestLayoutRefresh(reason: .compactToggle)
            }
            IconActionButton(
                symbol: isPinned ? "pin.fill" : "pin", label: isPinned ? "팝오버 고정 해제" : "팝오버 고정", isActive: isPinned
            ) {
                isPinned.toggle()
                viewModel.onPinChanged?(selectedService, isPinned)
            }
        }
        .fixedSize()
    }

    private func selectService(_ service: PopoverService) {
        guard service != selectedService else { return }
        viewModel.selectService(service)
        viewModel.requestLayoutRefresh(for: service, reason: .serviceSelection)
    }

    private func appProviderKind(for service: PopoverService) -> AppProviderKind {
        service.providerKind
    }

    @ViewBuilder
    private var headerServiceSelector: some View {
        if isCompact {
            HStack(spacing: AppDesign.Space.heading) {
                ForEach(availableServices, id: \.rawValue) { service in
                    headerSelectorButton(for: service)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        } else if availableServices.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppDesign.Space.control) {
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
        HStack(spacing: AppDesign.Space.micro) {
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
                Text(context.lastSuccessLabel ?? status.label)
                    .foregroundStyle(status == .authenticationRequired || status == .refreshFailed ? .orange : .secondary)
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
        .font(AppDesign.Typography.compactIdentity)
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
            HStack(spacing: AppDesign.Space.compact) {
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
        serviceLoading(for: selectedService)
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

            } else {
                bodyContent(layoutSpec: layoutSpec, sections: sections)
            }
        }
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
        .padding(.bottom, AppDesign.Space.tight)
    }
}
