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
            return settings.isPopoverCompact(for: appProviderKind(for: selectedService))
        }
        nonmutating set {
            setCompactForSelectedService(newValue)
        }
    }

    private func setCompactForSelectedService(_ compact: Bool) {
        settings.setPopoverCompact(compact, for: appProviderKind(for: selectedService))
    }

    private func syncCompactForSelectedServiceIfNeeded() {
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
