import SwiftUI

extension SettingsView {
    @ViewBuilder
    var timeFormatSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            Grid(
                alignment: .leading,
                horizontalSpacing: AppDesign.Space.row,
                verticalSpacing: AppDesign.Space.row
            ) {
                GridRow {
                    Text("시간 형식")
                    TimeFormatPicker(
                        selection: $settings.timeFormat)
                }
            }
            .font(AppDesign.Typography.subheadline)

            Text("메뉴바와 팝오버에 함께 적용합니다.")
                .font(AppDesign.Typography.caption)
                .foregroundStyle(AppDesign.Text.secondary)
        }
        .controlSize(.small)
    }

    @ViewBuilder
    func providerMenuBarDisplaySection(for provider: AppProviderKind) -> some View {
        if provider == .antigravity {
            antigravityMenuBarDisplaySection()
        } else if let displayConfig = settings.menuBarDisplayConfig(for: provider) {
            VStack(alignment: .leading, spacing: AppDesign.Space.content) {
                Text("메뉴바 표시").font(AppDesign.Typography.headline)
                menuBarPresetsSection(for: provider)
                providerMenuBarQuotaEditor(for: provider)
                menuBarAppearanceControls(for: provider, displayConfig: displayConfig)
                menuBarResetCreditControls(for: provider)
            }
        }
    }

    private func menuBarPresetsSection(for provider: AppProviderKind) -> some View {
        MenuBarPresetsSection(
            provider: provider, settings: settings, antigravity: antigravitySettings,
            limits: providerUsageLimits(provider), codexUsage: provider == .codex ? codexLastUsage?() : nil,
            preview: { display in
                let appearance =
                    NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance
                return MenuBarPresetPreviewRenderer.render(
                    display, provider: provider, settings: settings,
                    claudeUsage: provider == .claude ? claudeLastUsage?() : nil,
                    codexUsage: provider == .codex ? codexLastUsage?() : nil,
                    antigravityState: antigravitySettings.state, appearance: appearance,
                    resetCreditsAreNew: provider.runtimeService.map(resetCreditsAreNew) ?? false)
            }
        ).id(provider)
    }

    private func menuBarAppearanceControls(for provider: AppProviderKind, displayConfig: ProviderMenuBarDisplayConfig)
        -> some View
    {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            Toggle(
                "서비스 로고",
                isOn: Binding(
                    get: { settings.menuBarDisplayConfig(for: provider)?.showIcon ?? true },
                    set: { settings.setProviderShowIcon($0, for: provider) })
            )
            .toggleStyle(.checkbox)
            menuBarGaugeControls(for: provider, config: displayConfig)
            menuBarGaugeArrangementControls(for: provider)
        }
        .controlSize(.small)
    }

    private func menuBarGaugeControls(for provider: AppProviderKind, config: ProviderMenuBarDisplayConfig) -> some View
    {
        Grid(alignment: .leading, horizontalSpacing: AppDesign.Space.row, verticalSpacing: AppDesign.Space.row) {
            GridRow {
                Text("게이지 모양")
                Picker(
                    "게이지 모양",
                    selection: gaugeShapeBinding(provider)
                ) {
                    ForEach([MenuBarStyle.none, .batteryBar, .circular], id: \.rawValue) {
                        Text($0.displayName).tag($0)
                    }
                }.labelsHidden()
            }
            if config.style.gaugeShape == .batteryBar {
                GridRow {
                    Text("숫자")
                    Toggle(
                        "게이지 안 숫자",
                        isOn: Binding(
                        get: { settings.menuBarDisplayConfig(for: provider)?.showBatteryPercent ?? true },
                            set: { settings.setProviderShowBatteryPercent($0, for: provider) })
                    )
                    .toggleStyle(.checkbox)
                }
            }
        }
        .font(AppDesign.Typography.subheadline)
    }

    @ViewBuilder
    private func antigravityMenuBarDisplaySection() -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            Text("메뉴바 표시").font(AppDesign.Typography.headline)
            if let display = antigravitySettings.state.display {
                menuBarPresetsSection(for: .antigravity)
                providerMenuBarQuotaEditor(for: .antigravity)
                HStack(spacing: AppDesign.Space.section) {
                    Toggle("메뉴바에 표시", isOn: antigravityMenuBarBinding(display, keyPath: \.isVisible))
                    Toggle("서비스 로고", isOn: antigravityMenuBarBinding(display, keyPath: \.showsProviderIcon))
                }.toggleStyle(.checkbox)
                Grid(alignment: .leading, horizontalSpacing: AppDesign.Space.row, verticalSpacing: AppDesign.Space.row)
                {
                    if display.menuBar.gaugeLaneIDs == nil
                        || (display.menuBar.percentageLaneIDs == nil && display.menuBar.showsSelectedLanePercentage)
                        || (display.menuBar.resetLaneIDs == nil && display.menuBar.showsSelectedLaneResetTime)
                    {
                        GridRow {
                        Text("대표 한도")
                        Picker("게이지에 표시할 한도", selection: antigravityMenuBarLaneSelection(display)) {
                            Text("자동 (가장 많이 쓴 한도)").tag("")
                            ForEach(antigravityObservedLanes, id: \.id) { lane in
                                Text("\(lane.scopeTitle) · \(lane.cadenceTitle)").tag(lane.id.rawValue)
                            }
                        }.labelsHidden()
                        }
                    }
                    GridRow {
                        Text("게이지 모양")
                        Picker("게이지 모양", selection: gaugeShapeBinding(.antigravity)) {
                            ForEach([MenuBarStyle.none, .batteryBar, .circular], id: \.rawValue) {
                                Text($0.displayName).tag($0)
                            }
                        }.labelsHidden()
                    }
                    if display.menuBar.style == .batteryBar {
                        GridRow {
                            Text("숫자")
                            Toggle(
                                "게이지 안 숫자", isOn: antigravityMenuBarBinding(display, keyPath: \.showsGaugePercentage)
                            )
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                menuBarGaugeArrangementControls(for: .antigravity)
            } else {
                Text("불러오는 중").foregroundStyle(AppDesign.Text.secondary)
            }
        }
        .font(AppDesign.Typography.subheadline)
        .controlSize(.small)
        .disabled(antigravitySettings.state.activity.isBusy)
    }

    var antigravityObservedLanes:
        [AntigravityQuotaLanePresentation]
    {
        guard case .content(let presentation) =
                antigravitySettings.state
                    .quotaPresentation
        else {
            return []
        }
        return presentation.allGroups
            .flatMap(\.lanes)
    }

    func updateAntigravityDisplay(
        _ update:
            (inout AntigravityDisplaySettings)
                -> Void
    ) {
        guard let currentDisplay =
                antigravitySettings.state.display
        else {
            return
        }
        var display = currentDisplay
        update(&display)
        Task {
            _ = await antigravitySettings
                .updateDisplay(
                    display,
                    replacing: currentDisplay
                )
        }
    }

    private func antigravityMenuBarBinding(
        _ display: AntigravityDisplaySettings,
        keyPath:
            WritableKeyPath<
                AntigravityDisplaySettings
                    .MenuBarPresentationIntent,
                Bool
            >
    ) -> Binding<Bool> {
        Binding(
            get: {
                display.menuBar[
                    keyPath: keyPath
                ]
            },
            set: { value in
                updateAntigravityDisplay {
                    $0.menuBar[
                        keyPath: keyPath
                    ] = value
                }
            }
        )
    }

    private func antigravityMenuBarLaneSelection(
        _ display: AntigravityDisplaySettings
    ) -> Binding<String> {
        Binding(
            get: {
                switch display.menuBar
                    .laneSelection
                {
                case .automaticMostConstrained:
                    return ""
                case .fixed(let laneID):
                    return laneID.rawValue
                }
            },
            set: { rawValue in
                updateAntigravityDisplay {
                    $0.menuBar.laneSelection =
                        rawValue.isEmpty
                            ? .automaticMostConstrained
                            : .fixed(
                                AntigravityQuotaLaneID(
                                    rawValue:
                                        rawValue
                                )
                            )
                }
            }
        )
    }

    @ViewBuilder
    func providerPopoverDisplaySection(for provider: AppProviderKind) -> some View {
        let _ = runtimeEnvironmentRefreshTick
        if provider == .antigravity {
            AntigravityPopoverDisplaySettingsSection(
                viewModel: antigravitySettings
            )
        } else if let service = provider.runtimeService {
            ProviderPopoverDisplaySection(
                settings: settings,
                service: service,
                claudeUsage: provider == .claude ? claudeLastUsage?() : nil,
                claudeOverage: provider == .claude ? claudeLastOverage?() : nil,

                codexUsage: provider == .codex ? codexLastUsage?() : nil,
                codexError: provider == .codex ? codexLastError?() : nil
            )
        }
    }

    func settingsToggleRow(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        AppSettingRow(title, detail: subtitle) {
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }

    /// macOS SwiftUI Picker(.radioGroup)의 Binding set 미호출 버그 우회용 수동 라디오 그룹
    func settingsRadioGroup<T: Hashable>(
        _ title: String,
        options: [(value: T, label: String)],
        selection: T,
        onChange: @escaping (T) -> Void
    ) -> some View {
        SettingsChoiceGroup(title: title, options: options, selection: selection, onChange: onChange)
    }

    func chip(title: String, value: String, color: Color) -> some View {
        HStack(spacing: AppDesign.Space.compact) {
            Text(title)
            Text(value)
                .fontWeight(.semibold)
        }
        .font(AppDesign.Typography.caption2)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.16))
        .foregroundStyle(color)
        .cornerRadius(AppDesign.Radius.control)
    }
}

private struct ProviderPopoverDisplaySection: View {
    @ObservedObject var settings: AppSettings
    let service: PopoverService
    let claudeUsage: ClaudeUsageResponse?
    let claudeOverage: OverageSpendLimitResponse?
    let codexUsage: CodexUsageResponse?
    let codexError: APIError?
    @State private var selectedMode: PopoverDisplayEditorMode = .standard

    var body: some View {
        ProviderDisplayEditorShell(
            title: "표시 항목",
            selectedMode: $selectedMode
        ) {
            ProviderPopoverPreviewView(
                settings: settings,
                service: service,
                mode: selectedMode,
                claudeUsage: claudeUsage,
                claudeOverage: claudeOverage,

                codexUsage: codexUsage,
                codexError: codexError
            )
        } controls: {
            PopoverDisplayItemsListView(
                settings: settings,
                service: service,
                surface: selectedMode,
                unavailableItemIDs: unavailableItemIDs,
                codexUsage: codexUsage
            )
            .frame(maxWidth: 420, alignment: .leading)

            Text("드래그해 순서를 바꿉니다.")
                .font(AppDesign.Typography.caption)
                .foregroundStyle(AppDesign.Text.secondary)
        }
    }

    /// 응답은 정상인데 표시할 데이터가 없는 항목 ID. 목록에 "데이터 없음"을 붙인다(예: 주간 전용 Codex 플랜의 5시간 한도).
    private var unavailableItemIDs: Set<String> {
        guard let catalog =
                UsageItemCatalogRegistry.catalog(
                    for: service
                )
        else {
            return []
        }
        let context = UsageItemContext(
            density: selectedMode.isCompact ? .compact : .standard,
            settings: settings,
            claudeUsage: claudeUsage,
            claudeOverage: claudeOverage,

            codexUsage: codexUsage,
            codexError: codexError
        )
        return catalog.unavailableItemIDs(context: context)
    }
}

private struct ProviderPopoverPreviewView: View {
    @ObservedObject var settings: AppSettings
    let service: PopoverService
    let mode: PopoverDisplayEditorMode
    let claudeUsage: ClaudeUsageResponse?
    let claudeOverage: OverageSpendLimitResponse?
    let codexUsage: CodexUsageResponse?
    let codexError: APIError?

    @ViewBuilder
    var body: some View {
        if mode == .hover {
            let payload: RuntimeProviderPayload? =
                service == .claude
                ? claudeUsage.map(RuntimeProviderPayload.claude) : codexUsage.map(RuntimeProviderPayload.codex)
            let snapshot = RuntimeProviderSnapshot(
                service: service, payload: payload, error: codexError,
                credentialState: .usable, isDetected: true, canAttemptRefresh: true,
                hasAuthError: codexError?.isDefinitiveAuthFailure == true, claudeOverage: claudeOverage)
            let provider = MenuBarHoverUsageContent.catalogProvider(snapshot: snapshot, settings: settings)
            MenuBarHoverUsageView(content: MenuBarHoverUsageContent(providers: provider.map { [$0] } ?? []))
                .padding(AppDesign.Hover.inset).frame(width: AppDesign.Hover.width)
                .background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.panel))
        } else {
            popoverFrame
        }
    }

    @ViewBuilder
    private var popoverFrame: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewHeader
                .padding(.horizontal, mode.isCompact ? AppDesign.Space.content : AppDesign.Space.section)
                .frame(
                    height: mode.isCompact
                        ? PopoverLayoutMetrics.compactHeaderHeight : PopoverLayoutMetrics.standardHeaderContainerHeight)

            previewBody
                .padding(
                    mode.isCompact ? PopoverLayoutMetrics.compactBodyInsets : PopoverLayoutMetrics.standardBodyInsets)

            Divider()

            previewFooter
                .padding(.horizontal, mode.isCompact ? AppDesign.Space.content : AppDesign.Space.section)
                .frame(
                    height: mode.isCompact
                        ? PopoverLayoutMetrics.compactFooterHeight : PopoverLayoutMetrics.standardFooterContainerHeight)
        }
        .frame(width: PopoverLayoutMetrics.preferredPopoverWidth(compact: mode.isCompact), alignment: .topLeading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppDesign.Radius.panel, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var previewHeader: some View {
        HStack(spacing: AppDesign.Space.compact) {
            ForEach(availableServices, id: \.rawValue) { candidate in
                ProviderSelectorButtonLabel(
                    provider: candidate.providerKind, isSelected: candidate == service,
                    showsWarning: false, compact: mode.isCompact)
            }
            Spacer(minLength: AppDesign.Space.compact)
            IconActionButton(symbol: "arrow.clockwise", label: "사용량 새로고침") {}
            IconActionButton(
                symbol: mode.isCompact ? "rectangle.expand.vertical" : "rectangle.compress.vertical", label: "보기 전환"
            ) {}
            IconActionButton(
                symbol: settings.popoverPinned ? "pin.fill" : "pin", label: "고정", isActive: settings.popoverPinned
            ) {}
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var previewBody: some View {
        if sections.isEmpty {
            StatusPanelView(
                density: density,
                icon: "tray",
                iconColor: .secondary,
                showsProgress: false,
                title: "데이터 없음",
                message: emptyMessage,
                actionTitle: nil,
                actionStyle: .bordered,
                action: nil
            )
        } else {
            PopoverCatalogSectionList(sections: sections, density: density)
        }
    }

    private var previewFooter: some View {
        HStack(spacing: AppDesign.Space.compact) {
            ProviderExternalActionsView(
                provider: service.providerKind,
                compact: mode.isCompact,
                isInteractive: false
            ) { _ in }

            Spacer()

            IconActionButton(symbol: "slider.horizontal.3", label: "표시 항목 편집", compact: mode.isCompact) {}
            IconActionButton(symbol: "gearshape", label: "설정 열기", compact: mode.isCompact) {}
            IconActionButton(symbol: "power", label: "\(AppDistribution.current.appName) 종료", compact: mode.isCompact) {
            }
        }
        .font(AppDesign.Typography.caption)
        .foregroundStyle(AppDesign.Text.secondary)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var sections: [PopoverDisplaySection] {
        guard let catalog =
                UsageItemCatalogRegistry.catalog(
                    for: service
                )
        else {
            return []
        }
        let items = settings.displayItems(for: service, surface: mode)
        return catalog.sections(from: items, context: context)
    }

    private var context: UsageItemContext {
        UsageItemContext(
            density: density,
            settings: settings,
            claudeUsage: claudeUsage,
            claudeOverage: claudeOverage,

            codexUsage: codexUsage,
            codexError: codexError
        )
    }

    private var emptyMessage: String {
        switch service {
        case .claude:
            return claudeUsage == nil
                ? "사용량을 조회하면 미리보기가 나옵니다."
                : "현재 설정으로 표시할 Claude 항목이 없습니다."
        case .codex:
            return codexUsage == nil
                ? "사용량을 조회하면 미리보기가 나옵니다."
                : "현재 설정으로 표시할 Codex 항목이 없습니다."
        case .antigravity:
            return "Antigravity 한도는 아래 표시 항목에서 고릅니다."
        }
    }

    private var density: PopoverDensity {
        mode.isCompact ? .compact : .standard
    }

    private var availableServices: [PopoverService] {
        let enabled = ServiceSelectionHelper.enabledServices(settings: settings)
        if enabled.isEmpty {
            return [service]
        }
        return enabled
    }
}

struct TimeFormatPicker: View {
    @Binding var selection: TimeFormatStyle

    var body: some View {
        Picker("시간 형식", selection: $selection) {
            ForEach(TimeFormatStyle.allCases, id: \.self) { style in
                Text("\(style.displayName) (\(style.exampleText()))").tag(style)
            }
        }
        .labelsHidden()
    }
}
