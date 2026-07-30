import SwiftUI

extension SettingsView {
    @ViewBuilder
    func providerMenuBarDisplaySection(for provider: AppProviderKind) -> some View {
        if provider == .antigravity {
            antigravityMenuBarDisplaySection()
        } else if let displayConfig = settings.menuBarDisplayConfig(for: provider) {
            let showsDisplayControls = provider == .claude
                || provider == .codex
                || settings.isProviderVisibleInMenuBar(provider)

            VStack(alignment: .leading, spacing: 12) {
                Text("메뉴바 표시")
                    .font(.subheadline.weight(.semibold))

                if showsDisplayControls {
                    Picker("표시 방식", selection: menuBarPresetBinding(for: provider)) {
                        ForEach(ProviderMenuBarDisplayPreset.allCases) { preset in
                            Text(menuBarPresetDisplayName(preset, for: provider)).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(menuBarPresetDetail(currentMenuBarPreset(for: provider), for: provider))
                        .font(.caption)
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
    private func menuBarCustomControls(
        for provider: AppProviderKind,
        displayConfig: ProviderMenuBarDisplayConfig
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsToggleRow(
                "아이콘 표시",
                isOn: Binding(
                    get: { settings.menuBarDisplayConfig(for: provider)?.showIcon ?? true },
                    set: { settings.setProviderShowIcon($0, for: provider) }
                )
            )

            Picker("퍼센트", selection: Binding(
                get: { settings.menuBarDisplayConfig(for: provider)?.percentageDisplay ?? .fiveHour },
                set: { settings.setProviderPercentageDisplay($0, for: provider) }
            )) {
                ForEach(PercentageDisplay.allCases, id: \.self) { mode in
                    Text(percentageDisplayName(mode, for: provider)).tag(mode)
                }
            }

            Picker("갱신 시간", selection: Binding(
                get: { settings.menuBarDisplayConfig(for: provider)?.resetTimeDisplay ?? .none },
                set: { settings.setProviderResetTimeDisplay($0, for: provider) }
            )) {
                ForEach(ResetTimeDisplay.allCases, id: \.self) { mode in
                    Text(resetTimeDisplayName(mode, for: provider)).tag(mode)
                }
            }

            if displayConfig.resetTimeDisplay != .none {
                Picker("시간 형식", selection: Binding(
                    get: { settings.menuBarDisplayConfig(for: provider)?.timeFormat ?? .h24 },
                    set: { settings.setProviderTimeFormat($0, for: provider) }
                )) {
                    ForEach(TimeFormatStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            }

            Picker("아이콘 스타일", selection: Binding(
                get: { settings.menuBarDisplayConfig(for: provider)?.style ?? .none },
                set: { settings.setMenuBarStyle($0, for: provider) }
            )) {
                Text("없음").tag(MenuBarStyle.none)
                Section("개별 표시") {
                    Text("배터리바").tag(MenuBarStyle.batteryBar)
                    Text("원형").tag(MenuBarStyle.circular)
                }
                Section("동시 표시") {
                    Text("동심원").tag(MenuBarStyle.concentricRings)
                    Text("이중 배터리").tag(MenuBarStyle.dualBattery)
                    Text("좌우 배터리").tag(MenuBarStyle.sideBySideBattery)
                }
            }

            if displayConfig.style == .batteryBar || displayConfig.style == .sideBySideBattery {
                settingsToggleRow(
                    "배터리 내부 숫자",
                    isOn: Binding(
                        get: { settings.menuBarDisplayConfig(for: provider)?.showBatteryPercent ?? true },
                        set: { settings.setProviderShowBatteryPercent($0, for: provider) }
                    )
                )
            }

            if displayConfig.style == .batteryBar || displayConfig.style == .circular {
                settingsRadioGroup(
                    "아이콘 기준",
                    options: IconMetric.allCases.map { ($0, iconMetricDisplayName($0, for: provider)) },
                    selection: settings.menuBarDisplayConfig(for: provider)?.iconMetric ?? .fiveHour,
                    onChange: { settings.setProviderIconMetric($0, for: provider) }
                )
            }

            if displayConfig.style != .none {
                settingsRadioGroup(
                    "표시 기준",
                    options: CircularDisplayMode.allCases.map { ($0, $0.displayName) },
                    selection: settings.menuBarDisplayConfig(for: provider)?.circularDisplayMode ?? .usage,
                    onChange: { settings.setProviderCircularDisplayMode($0, for: provider) }
                )
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.35))
        .cornerRadius(8)
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
    private func antigravityMenuBarDisplaySection()
        -> some View
    {
        VStack(
            alignment: .leading,
            spacing: 12
        ) {
            Text("메뉴바 표시")
                .font(.subheadline.weight(.semibold))

            if let display =
                antigravitySettings.state.display
            {
                settingsToggleRow(
                    "메뉴바에 표시",
                    isOn:
                        antigravityMenuBarBinding(
                            display,
                            keyPath: \.isVisible
                        )
                )

                settingsToggleRow(
                    "Antigravity 아이콘 표시",
                    isOn:
                        antigravityMenuBarBinding(
                            display,
                            keyPath:
                                \.showsProviderIcon
                        )
                )

                Picker(
                    "대표 한도",
                    selection:
                        antigravityMenuBarLaneSelection(
                            display
                        )
                ) {
                    Text("가장 제한적인 한도 자동 선택")
                        .tag("")
                    ForEach(
                        antigravityObservedLanes,
                        id: \.id
                    ) { lane in
                        Text(
                            "\(lane.scopeTitle) · \(lane.cadenceTitle)"
                        )
                        .tag(lane.id.rawValue)
                    }
                }

                if !antigravityObservedLanes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("함께 표시할 한도")
                            .font(.subheadline)
                        ForEach(
                            antigravityObservedLanes,
                            id: \.id
                        ) { lane in
                            Toggle(
                                "\(lane.scopeTitle) · \(lane.cadenceTitle)",
                                isOn:
                                    antigravityAdditionalMenuBarLaneBinding(
                                        display,
                                        laneID: lane.id
                                    )
                            )
                            .toggleStyle(.checkbox)
                        }
                        Text("대표 한도는 게이지와 상태 색상에 사용하고, 선택한 한도는 메뉴바 텍스트에 나란히 표시합니다.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Picker(
                    "아이콘 스타일",
                    selection:
                        antigravityMenuBarStyleBinding(
                            display
                        )
                ) {
                    Text("없음")
                        .tag(
                            AntigravityDisplaySettings
                                .MenuBarPresentationIntent
                                .Style.none
                        )
                    Text("배터리바")
                        .tag(
                            AntigravityDisplaySettings
                                .MenuBarPresentationIntent
                                .Style.batteryBar
                        )
                    Text("원형")
                        .tag(
                            AntigravityDisplaySettings
                                .MenuBarPresentationIntent
                                .Style.circular
                        )
                }

                settingsToggleRow(
                    "사용률 표시",
                    isOn:
                        antigravityMenuBarBinding(
                            display,
                            keyPath:
                                \.showsSelectedLanePercentage
                        )
                )
                settingsToggleRow(
                    "갱신 시각 표시",
                    isOn:
                        antigravityMenuBarBinding(
                            display,
                            keyPath:
                                \.showsSelectedLaneResetTime
                        )
                )
                settingsToggleRow(
                    "게이지 내부 숫자",
                    isOn:
                        antigravityMenuBarBinding(
                            display,
                            keyPath:
                                \.showsGaugePercentage
                        )
                )

                if display.menuBar
                    .showsSelectedLaneResetTime
                {
                    Picker(
                        "시간 형식",
                        selection:
                            antigravityMenuBarTimeBinding(
                                display
                            )
                    ) {
                        Text("24시간")
                            .tag(
                                AntigravityDisplaySettings
                                    .MenuBarPresentationIntent
                                    .TimeFormat.h24
                            )
                        Text("12시간")
                            .tag(
                                AntigravityDisplaySettings
                                    .MenuBarPresentationIntent
                                    .TimeFormat.h12
                            )
                        Text("남은 시간")
                            .tag(
                                AntigravityDisplaySettings
                                    .MenuBarPresentationIntent
                                    .TimeFormat.remaining
                            )
                    }
                }

                if display.menuBar.style
                    == .circular
                {
                    Picker(
                        "원형 게이지 기준",
                        selection:
                            antigravityCircularValueBinding(
                                display
                            )
                    ) {
                        Text("사용량")
                            .tag(
                                AntigravityDisplaySettings
                                    .MenuBarPresentationIntent
                                    .CircularValue.usage
                            )
                        Text("남은 양")
                            .tag(
                                AntigravityDisplaySettings
                                    .MenuBarPresentationIntent
                                    .CircularValue.remaining
                            )
                    }
                }
            } else {
                Text(
                    "Antigravity 설정을 준비하고 있습니다."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
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

    private func antigravityMenuBarTimeBinding(
        _ display: AntigravityDisplaySettings
    ) -> Binding<
        AntigravityDisplaySettings
            .MenuBarPresentationIntent.TimeFormat
    > {
        Binding(
            get: { display.menuBar.timeFormat },
            set: { format in
                updateAntigravityDisplay {
                    $0.menuBar.timeFormat = format
                }
            }
        )
    }

    private func antigravityCircularValueBinding(
        _ display: AntigravityDisplaySettings
    ) -> Binding<
        AntigravityDisplaySettings
            .MenuBarPresentationIntent
            .CircularValue
    > {
        Binding(
            get: {
                display.menuBar.circularValue
            },
            set: { value in
                updateAntigravityDisplay {
                    $0.menuBar.circularValue =
                        value
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

    @ViewBuilder
    func providerAlertSection(for provider: AppProviderKind) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if provider == .antigravity,
                   let display =
                        antigravitySettings.state
                            .display
                {
                    settingsToggleRow(
                        "사용량 알림",
                        subtitle:
                            settings.notificationsEnabled
                                ? "한 refresh에서 임계값을 넘은 사용 한도를 알림 하나로 묶습니다"
                                : "공통 알림이 꺼져 있어 이 설정도 적용되지 않습니다",
                        isOn: Binding(
                            get: {
                                display.notifications
                                    .isEnabled
                            },
                            set: { isEnabled in
                                updateAntigravityDisplay {
                                    $0.notifications
                                        .isEnabled =
                                        isEnabled
                                }
                            }
                        )
                    )
                } else {
                    settingsToggleRow(
                        "사용량 알림",
                        subtitle: settings.notificationsEnabled
                            ? "이 서비스의 사용량 기준 알림을 표시합니다"
                            : "공통 알림이 꺼져 있어 이 설정도 적용되지 않습니다",
                        isOn: Binding(
                            get: { settings.isProviderAlertEnabled(provider) },
                            set: { settings.setProviderAlertEnabled($0, for: provider) }
                        )
                    )
                }
            }
            .disabled(!settings.notificationsEnabled)
            .opacity(settings.notificationsEnabled ? 1.0 : 0.6)

            if !settings.notificationsEnabled {
                Label("공통 설정에서 전체 알림을 먼저 켜야 합니다.", systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    func segmentedTabButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor.opacity(0.18) : Color(NSColor.controlBackgroundColor).opacity(0.45))
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    func settingsToggleRow(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .padding(.vertical, 2)
    }

    /// macOS SwiftUI Picker(.radioGroup)의 Binding set 미호출 버그 우회용 수동 라디오 그룹
    func settingsRadioGroup<T: Hashable>(
        _ title: String,
        options: [(value: T, label: String)],
        selection: T,
        onChange: @escaping (T) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
            ForEach(options.indices, id: \.self) { i in
                Button {
                    onChange(options[i].value)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: selection == options[i].value ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selection == options[i].value ? Color.accentColor : Color.secondary)
                            .font(.system(size: 12))
                        Text(options[i].label)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(options[i].label)
                .accessibilityValue(selection == options[i].value ? "선택됨" : "선택 안 됨")
                .accessibilityAddTraits(selection == options[i].value ? .isSelected : [])
            }
        }
    }

    func chip(title: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.caption2)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.16))
        .foregroundStyle(color)
        .cornerRadius(6)
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
                .font(.caption)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("미리보기")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(mode.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            popoverFrame
        }
    }

    @ViewBuilder
    private var popoverFrame: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewHeader
                .frame(height: mode.isCompact ? 28 : 34)
                .padding(.horizontal, mode.isCompact ? 12 : 16)
                .padding(.top, mode.isCompact ? 3 : 10)
                .padding(.bottom, mode.isCompact ? 3 : 6)

            previewBody
                .padding(.horizontal, mode.isCompact ? 14 : 18)
                .padding(.vertical, mode.isCompact ? 10 : 14)

            Divider()

            previewFooter
                .padding(.horizontal, mode.isCompact ? 12 : 16)
                .padding(.vertical, mode.isCompact ? 5 : 8)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var previewHeader: some View {
        HStack(spacing: 8) {
            ForEach(availableServices, id: \.rawValue) { candidate in
                ProviderBrandIconView(provider: candidate.providerKind, kind: .popover, size: 15)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(candidate == service
                                ? Color.accentColor.opacity(0.18)
                                : Color(NSColor.controlBackgroundColor).opacity(0.45))
                    )
            }

            Spacer(minLength: 8)

            Image(systemName: "arrow.clockwise")
            Image(systemName: mode.isCompact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
            Image(systemName: settings.popoverPinned ? "pin.fill" : "pin")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
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
            VStack(spacing: mode.isCompact ? 5 : 0) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    if index > 0 && !mode.isCompact {
                        Divider()
                            .padding(.vertical, 8)
                    }
                    PopoverDisplaySectionView(section: section, density: density)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var previewFooter: some View {
        HStack(spacing: 12) {
            if service == .claude {
                Image(systemName: "safari")
                    .foregroundStyle(Color.accentColor)
                if !mode.isCompact {
                    Text("claude.ai/settings/usage")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }

            Spacer()

            Image(systemName: "slider.horizontal.3")
            Image(systemName: "gearshape")
            Image(systemName: "power")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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
