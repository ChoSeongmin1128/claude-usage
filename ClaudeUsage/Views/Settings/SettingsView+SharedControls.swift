import SwiftUI

extension SettingsView {
    @ViewBuilder
    func providerTimeFormatSection(for provider: AppProviderKind) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            Text("시간 표시")
                .font(AppDesign.Typography.subheadline.weight(.semibold))

            Grid(
                alignment: .leading,
                horizontalSpacing: AppDesign.Space.row,
                verticalSpacing: AppDesign.Space.row
            ) {
                GridRow {
                    Text("시간 형식")
                    Picker(
                        "시간 형식 — 메뉴바·팝오버 공통",
                        selection: providerTimeFormatBinding(for: provider)
                    ) {
                        ForEach(TimeFormatStyle.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .labelsHidden()
                }
            }
            .font(AppDesign.Typography.subheadline)

            Text("메뉴바와 팝오버의 한도 초기화 시간에 함께 적용됩니다.")
                .font(AppDesign.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }

    private func providerTimeFormatBinding(for provider: AppProviderKind) -> Binding<TimeFormatStyle> {
        Binding(
            get: {
                if provider == .antigravity {
                    guard let raw = antigravitySettings.state.display?.menuBar.timeFormat.rawValue else {
                        return .h24
                    }
                    return TimeFormatStyle(rawValue: raw) ?? .h24
                }
                return settings.menuBarDisplayConfig(for: provider)?.timeFormat ?? .h24
            },
            set: { format in
                if provider == .antigravity {
                    guard
                        let agyFormat =
                            AntigravityDisplaySettings.MenuBarPresentationIntent.TimeFormat(rawValue: format.rawValue)
                    else {
                        return
                    }
                    updateAntigravityDisplay {
                        $0.menuBar.timeFormat = agyFormat
                    }
                } else {
                    settings.setProviderTimeFormat(format, for: provider)
                }
            }
        )
    }

    @ViewBuilder
    func providerMenuBarDisplaySection(for provider: AppProviderKind) -> some View {
        if provider == .antigravity {
            antigravityMenuBarDisplaySection()
        } else if let displayConfig = settings.menuBarDisplayConfig(for: provider) {
            let showsDisplayControls = provider == .claude
                || provider == .codex
                || settings.isProviderVisibleInMenuBar(provider)

            VStack(alignment: .leading, spacing: AppDesign.Space.content) {
                Text("메뉴바 표시")
                    .font(AppDesign.Typography.subheadline.weight(.semibold))

                if showsDisplayControls {
                    Picker("표시 방식", selection: menuBarPresetBinding(for: provider)) {
                        ForEach(ProviderMenuBarDisplayPreset.allCases) { preset in
                            Text(menuBarPresetDisplayName(preset, for: provider)).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(menuBarPresetDetail(currentMenuBarPreset(for: provider), for: provider))
                        .font(AppDesign.Typography.caption)
                        .foregroundStyle(.secondary)
                }

                if showsDisplayControls {
                    if currentMenuBarPreset(for: provider) == .custom {
                        menuBarCustomControls(for: provider, displayConfig: displayConfig)
                    }
                }
            }
        }
    }

    private func currentMenuBarPreset(for provider: AppProviderKind) -> ProviderMenuBarDisplayPreset {
        if expandedCustomMenuBarProviders.contains(provider) {
            return .custom
        }
        return settings.menuBarDisplayPreset(for: provider)
    }

    private func menuBarPresetBinding(for provider: AppProviderKind) -> Binding<ProviderMenuBarDisplayPreset> {
        Binding(
            get: { currentMenuBarPreset(for: provider) },
            set: { preset in
                if preset == .custom {
                    expandedCustomMenuBarProviders.insert(provider)
                    return
                }
                expandedCustomMenuBarProviders.remove(provider)
                settings.applyMenuBarDisplayPreset(preset, for: provider)
            }
        )
    }

    @ViewBuilder
    private func menuBarCustomControls(for provider: AppProviderKind, displayConfig: ProviderMenuBarDisplayConfig)
        -> some View
    {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            menuBarSettingsPreview(for: provider, config: displayConfig)
            Toggle(
                "서비스 로고",
                isOn: Binding(
                    get: { settings.menuBarDisplayConfig(for: provider)?.showIcon ?? true },
                    set: { settings.setProviderShowIcon($0, for: provider) })
            )
            .toggleStyle(.checkbox)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppDesign.Space.section) {
                    menuBarGaugeControls(for: provider, config: displayConfig).fixedSize(
                        horizontal: true, vertical: false)
                    menuBarTextControls(for: provider, config: displayConfig).fixedSize(
                        horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: AppDesign.Space.content) {
                    menuBarGaugeControls(for: provider, config: displayConfig)
                    menuBarTextControls(for: provider, config: displayConfig)
                }
            }
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
                    selection: Binding(
                        get: { settings.menuBarDisplayConfig(for: provider)?.style ?? .none },
                        set: { settings.setMenuBarStyle($0, for: provider) })
                ) {
                    ForEach(MenuBarStyle.allCases, id: \.rawValue) { Text($0.displayName).tag($0) }
                }.labelsHidden()
            }
            if config.style == .batteryBar || config.style == .circular {
                GridRow {
                    Text("표시할 한도")
                    Picker(
                        "게이지에 표시할 한도",
                        selection: Binding(
                            get: { settings.menuBarDisplayConfig(for: provider)?.iconMetric ?? .fiveHour },
                            set: { settings.setProviderIconMetric($0, for: provider) })
                    ) {
                        ForEach(IconMetric.allCases, id: \.self) {
                            Text(iconMetricDisplayName($0, for: provider)).tag($0)
                        }
                    }.labelsHidden()
                }
            }
            if config.style == .batteryBar || config.style == .sideBySideBattery {
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

    private func menuBarTextControls(for provider: AppProviderKind, config: ProviderMenuBarDisplayConfig) -> some View {
        Grid(alignment: .leading, horizontalSpacing: AppDesign.Space.row, verticalSpacing: AppDesign.Space.row) {
            GridRow {
                Text("게이지 밖 숫자")
                Picker(
                    "게이지 밖 숫자",
                    selection: Binding(
                        get: { settings.menuBarDisplayConfig(for: provider)?.percentageDisplay ?? .none },
                        set: { settings.setProviderPercentageDisplay($0, for: provider) })
                ) {
                    ForEach(PercentageDisplay.allCases, id: \.self) {
                        Text(percentageDisplayName($0, for: provider)).tag($0)
                    }
                }.labelsHidden()
            }
            GridRow {
                Text("한도 초기화 시간")
                Picker(
                    "한도 초기화 시간",
                    selection: Binding(
                        get: { settings.menuBarDisplayConfig(for: provider)?.resetTimeDisplay ?? .none },
                        set: { settings.setProviderResetTimeDisplay($0, for: provider) })
                ) {
                    ForEach(ResetTimeDisplay.allCases, id: \.self) {
                        Text(resetTimeDisplayName($0, for: provider)).tag($0)
                    }
                }.labelsHidden()
            }
        }
        .font(AppDesign.Typography.subheadline)
    }

    private func menuBarSettingsPreview(for provider: AppProviderKind, config: ProviderMenuBarDisplayConfig)
        -> some View
    {
        let appearance = NSApp.effectiveAppearance
        let icon = ProviderBrandIconResolver.image(for: provider, kind: .menuBar, appearance: appearance)
        let snapshot: MenuBarProviderSnapshot
        if provider == .claude {
            snapshot = MenuBarStatusComposer.claudeSnapshot(
                config: config, usage: claudeLastUsage?(), error: nil,
                hasAuthError: false, hasCredential: hasReadyClaudeCredential, secondaryColor: .secondaryLabelColor,
                icon: icon, appearance: appearance)
        } else {
            snapshot = MenuBarStatusComposer.codexSnapshot(
                config: config, usage: codexLastUsage?(), error: codexLastError?(),
                hasAuthError: false, isAuthenticated: codexAuthStatus == .authenticated,
                secondaryColor: .secondaryLabelColor, icon: icon, appearance: appearance)
        }
        return MenuBarSettingsPreview(snapshot: snapshot)
    }

    private func menuBarPresetDisplayName(_ preset: ProviderMenuBarDisplayPreset, for provider: AppProviderKind) -> String {
        return preset.displayName
    }

    private func menuBarPresetDetail(_ preset: ProviderMenuBarDisplayPreset, for provider: AppProviderKind) -> String {
        preset.detail
    }

    private func percentageDisplayName(_ mode: PercentageDisplay, for provider: AppProviderKind) -> String {
        switch mode {
        case .none:
            return "없음"
        case .fiveHour:
            return primaryMenuBarMetricName(for: provider)
        case .weekly:
            return secondaryMenuBarMetricName(for: provider)
        case .dual:
            return "동시 표시"
        }
    }

    private func resetTimeDisplayName(_ mode: ResetTimeDisplay, for provider: AppProviderKind) -> String {
        switch mode {
        case .none:
            return "없음"
        case .fiveHour:
            return primaryMenuBarMetricName(for: provider)
        case .weekly:
            return secondaryMenuBarMetricName(for: provider)
        case .dual:
            return "동시 표시"
        }
    }

    private func iconMetricDisplayName(_ metric: IconMetric, for provider: AppProviderKind) -> String {
        switch metric {
        case .fiveHour:
            return primaryMenuBarMetricName(for: provider)
        case .weekly:
            return secondaryMenuBarMetricName(for: provider)
        }
    }

    private func primaryMenuBarMetricName(for provider: AppProviderKind) -> String {
        "현재 세션"
    }

    private func secondaryMenuBarMetricName(for provider: AppProviderKind) -> String {
        "주간"
    }

    @ViewBuilder
    private func antigravityMenuBarDisplaySection() -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            Text("메뉴바 표시").font(AppDesign.Typography.subheadline.weight(.semibold))
            if let display = antigravitySettings.state.display {
                if case .content(let presentation) = antigravitySettings.state.quotaPresentation,
                    let snapshot = MenuBarStatusComposer.antigravitySnapshot(
                        presentation: presentation.menuBar,
                        icon: ProviderBrandIconResolver.image(
                            for: .antigravity, kind: .menuBar, appearance: NSApp.effectiveAppearance),
                        appearance: NSApp.effectiveAppearance, design: settings.menuBarDesign,
                        colorMode: settings.menuBarColorMode)
                {
                    MenuBarSettingsPreview(snapshot: snapshot)
                }
                HStack(spacing: AppDesign.Space.section) {
                    Toggle("메뉴바에 표시", isOn: antigravityMenuBarBinding(display, keyPath: \.isVisible))
                    Toggle("서비스 로고", isOn: antigravityMenuBarBinding(display, keyPath: \.showsProviderIcon))
                }.toggleStyle(.checkbox)
                Grid(alignment: .leading, horizontalSpacing: AppDesign.Space.row, verticalSpacing: AppDesign.Space.row)
                {
                    GridRow {
                        Text("대표 한도")
                        Picker("게이지에 표시할 한도", selection: antigravityMenuBarLaneSelection(display)) {
                            Text("가장 제한적인 한도 자동 선택").tag("")
                            ForEach(antigravityObservedLanes, id: \.id) { lane in
                                Text("\(lane.scopeTitle) · \(lane.cadenceTitle)").tag(lane.id.rawValue)
                            }
                        }.labelsHidden()
                    }
                    GridRow {
                        Text("게이지 모양")
                        Picker("게이지 모양", selection: antigravityMenuBarStyleBinding(display)) {
                            Text("없음").tag(AntigravityDisplaySettings.MenuBarPresentationIntent.Style.none)
                            Text("배터리바").tag(AntigravityDisplaySettings.MenuBarPresentationIntent.Style.batteryBar)
                            Text("원형").tag(AntigravityDisplaySettings.MenuBarPresentationIntent.Style.circular)
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
                    GridRow {
                        Text("텍스트")
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: AppDesign.Space.row) { antigravityTextToggles(display) }
                            VStack(alignment: .leading, spacing: AppDesign.Space.row) {
                                antigravityTextToggles(display)
                            }
                        }.toggleStyle(.checkbox)
                    }
                }
                if !antigravityObservedLanes.isEmpty {
                    Text("함께 표시할 한도").font(AppDesign.Typography.subheadline.weight(.medium))
                    ForEach(antigravityObservedLanes, id: \.id) { lane in
                        Toggle(
                            "\(lane.scopeTitle) · \(lane.cadenceTitle)",
                            isOn: antigravityAdditionalMenuBarLaneBinding(display, laneID: lane.id)
                        )
                        .toggleStyle(.checkbox)
                    }
                    Text("대표 한도는 게이지에, 추가 한도는 텍스트에 표시합니다.")
                        .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Antigravity 설정을 준비하고 있습니다.").foregroundStyle(.secondary)
            }
        }
        .font(AppDesign.Typography.subheadline)
        .controlSize(.small)
    }

    @ViewBuilder
    private func antigravityTextToggles(_ display: AntigravityDisplaySettings) -> some View {
        Toggle("게이지 밖 숫자", isOn: antigravityMenuBarBinding(display, keyPath: \.showsSelectedLanePercentage))
        Toggle("한도 초기화 시간", isOn: antigravityMenuBarBinding(display, keyPath: \.showsSelectedLaneResetTime))
    }

    private var antigravityObservedLanes:
        [AntigravityQuotaLanePresentation]
    {
        guard case .content(let presentation) =
                antigravitySettings.state
                    .quotaPresentation
        else {
            return []
        }
        return presentation.groups
            .flatMap(\.lanes)
    }

    private func updateAntigravityDisplay(
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

    private func antigravityMenuBarStyleBinding(
        _ display: AntigravityDisplaySettings
    ) -> Binding<
        AntigravityDisplaySettings
            .MenuBarPresentationIntent.Style
    > {
        Binding(
            get: { display.menuBar.style },
            set: { style in
                updateAntigravityDisplay {
                    $0.menuBar.style = style
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

    private func antigravityAdditionalMenuBarLaneBinding(
        _ display: AntigravityDisplaySettings,
        laneID: AntigravityQuotaLaneID
    ) -> Binding<Bool> {
        Binding(
            get: {
                display.menuBar.effectiveAdditionalLaneIDs
                    .contains(laneID)
            },
            set: { isSelected in
                updateAntigravityDisplay {
                    var ids =
                        $0.menuBar.effectiveAdditionalLaneIDs
                    if isSelected {
                        if !ids.contains(laneID) {
                            ids.append(laneID)
                        }
                    } else {
                        ids.removeAll { $0 == laneID }
                    }
                    $0.menuBar.additionalLaneIDs = ids
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
                provider: provider,
                service: service,
                claudeUsage: provider == .claude ? claudeLastUsage?() : nil,
                claudeOverage: provider == .claude ? claudeLastOverage?() : nil,
                claudeAccounts: claudeAccounts,
                activeClaudeAccountID: activeClaudeAccountID,
                codexUsage: provider == .codex ? codexLastUsage?() : nil,
                codexError: provider == .codex ? codexLastError?() : nil
            )
        }
    }

    func providerAlertSection(for provider: AppProviderKind) -> some View {
        NotificationProviderRow(
            settings: settings, provider: provider,
            limits: notificationManager.inventories[provider.runtimeService ?? .claude] ?? [],
            isEnabled: Binding(
                get: {
                    provider == .antigravity
                        ? antigravitySettings.state.display?.notifications.isEnabled ?? false
                        : settings.isProviderAlertEnabled(provider)
                },
                set: { enabled in
                    if provider == .antigravity {
                        updateAntigravityDisplay { $0.notifications.isEnabled = enabled }
                    } else {
                        settings.setProviderAlertEnabled(enabled, for: provider)
                    }
                })
        )
        .disabled(
            !settings.notificationsEnabled || (provider == .antigravity && antigravitySettings.state.display == nil))
    }

    func segmentedTabButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppDesign.Typography.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, AppDesign.Space.label)
                .padding(.vertical, AppDesign.Space.control)
                .background(isSelected ? Color.accentColor.opacity(0.18) : AppDesign.Surface.group)
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                .cornerRadius(AppDesign.Radius.group)
        }
        .buttonStyle(.plain)
    }

    func settingsToggleRow(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(AppDesign.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .padding(.vertical, AppDesign.Space.tight)
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
    let provider: AppProviderKind
    let service: PopoverService
    let claudeUsage: ClaudeUsageResponse?
    let claudeOverage: OverageSpendLimitResponse?
    let claudeAccounts: [ClaudeAccount]
    let activeClaudeAccountID: String?
    let codexUsage: CodexUsageResponse?
    let codexError: APIError?
    @State private var selectedMode: PopoverDisplayEditorMode = .standard

    var body: some View {
        ProviderDisplayEditorShell(
            title: "팝오버 표시 항목",
            description:
                "\(provider.displayName) 팝오버에서 일반/간소화 보기별 항목과 순서를 정합니다.",
            selectedMode: modeSelection
        ) {
            ProviderPopoverPreviewView(
                settings: settings,
                service: service,
                mode: selectedMode,
                claudeUsage: claudeUsage,
                claudeOverage: claudeOverage,
                claudeAccounts: claudeAccounts,
                activeClaudeAccountID: activeClaudeAccountID,
                codexUsage: codexUsage,
                codexError: codexError
            )
        } controls: {
            PopoverDisplayItemsListView(
                settings: settings,
                service: service,
                isCompact: selectedMode.isCompact,
                unavailableItemIDs: unavailableItemIDs
            )
            .frame(maxWidth: 420, alignment: .leading)

            Text("눈 아이콘으로 표시 여부를 바꾸고, 항목을 드래그해 순서를 조정합니다.")
                .font(AppDesign.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modeSelection: Binding<PopoverDisplayEditorMode> {
        Binding(
            get: { selectedMode },
            set: { newMode in
                if newMode.isCompact && !settings.separateCompactConfig {
                    settings.separateCompactConfig = true
                }
                selectedMode = newMode
            }
        )
    }

    /// 응답은 정상인데 표시할 데이터가 없는 항목 ID — 목록에 "지금 데이터 없음" 안내를 붙인다.
    /// (예: 주간 전용 Codex 플랜에서는 "Codex 현재"가 해당)
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
            claudeAccounts: claudeAccounts,
            activeClaudeAccountID: activeClaudeAccountID,
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
    let claudeAccounts: [ClaudeAccount]
    let activeClaudeAccountID: String?
    let codexUsage: CodexUsageResponse?
    let codexError: APIError?

    var body: some View { popoverFrame }

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
        }.allowsHitTesting(false)
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
            IconActionButton(symbol: "power", label: "ClaudeUsage 종료", compact: mode.isCompact) {}
        }
        .font(AppDesign.Typography.caption)
        .foregroundStyle(.secondary)
        .allowsHitTesting(false)
    }

    private var sections: [PopoverDisplaySection] {
        guard let catalog =
                UsageItemCatalogRegistry.catalog(
                    for: service
                )
        else {
            return []
        }
        let items = mode.isCompact
            ? settings.compactPopoverItems(for: service)
            : settings.popoverItems(for: service)
        return catalog.sections(from: items, context: context)
    }

    private var context: UsageItemContext {
        UsageItemContext(
            density: density,
            settings: settings,
            claudeUsage: claudeUsage,
            claudeOverage: claudeOverage,
            claudeAccounts: claudeAccounts,
            activeClaudeAccountID: activeClaudeAccountID,
            codexUsage: codexUsage,
            codexError: codexError
        )
    }

    private var emptyMessage: String {
        switch service {
        case .claude:
            return claudeUsage == nil
                ? "사용량을 한 번 조회하면 팝오버 미리보기가 표시됩니다."
                : "현재 설정으로 표시할 Claude 항목이 없습니다."
        case .codex:
            return codexUsage == nil
                ? "사용량을 한 번 조회하면 팝오버 미리보기가 표시됩니다."
                : "현재 설정으로 표시할 Codex 항목이 없습니다."
        case .antigravity:
            return "Antigravity 사용량 한도는 팝오버에서 quota lane으로 표시됩니다."
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
