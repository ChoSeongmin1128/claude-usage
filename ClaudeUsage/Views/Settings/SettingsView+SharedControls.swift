import SwiftUI

extension SettingsView {
    @ViewBuilder
    func providerMenuBarDisplaySection(for provider: AppProviderKind) -> some View {
        if let displayConfig = settings.menuBarDisplayConfig(for: provider) {
            VStack(alignment: .leading, spacing: 12) {
                Label("메뉴바 표시", systemImage: "slider.horizontal.3")
                    .font(.headline)

                if provider == .gemini || provider == .antigravity {
                    settingsToggleRow(
                        "메뉴바에 표시",
                        isOn: Binding(
                            get: { settings.isProviderVisibleInMenuBar(provider) },
                            set: { settings.setProviderMenuBarVisible($0, for: provider) }
                        )
                    )
                }

                if provider == .claude || provider == .codex || settings.isProviderVisibleInMenuBar(provider) {
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
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Picker("갱신 시간", selection: Binding(
                        get: { settings.menuBarDisplayConfig(for: provider)?.resetTimeDisplay ?? .none },
                        set: { settings.setProviderResetTimeDisplay($0, for: provider) }
                    )) {
                        ForEach(ResetTimeDisplay.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
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
                            options: IconMetric.allCases.map { ($0, $0.displayName) },
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

            }
        }
    }

    @ViewBuilder
    func providerPopoverDisplaySection(for provider: AppProviderKind) -> some View {
        if let service = provider.runtimeService {
            ProviderPopoverDisplaySection(
                settings: settings,
                provider: provider,
                service: service
            )
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
        HStack(spacing: 12) {
            Button {
                isOn.wrappedValue.toggle()
            } label: {
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
            .buttonStyle(.plain)

            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
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
    @State private var selectedMode: PopoverDisplayEditorMode = .standard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("팝오버 표시 항목", systemImage: "list.bullet.rectangle")
                .font(.headline)

            Text("\(provider.displayName) 팝오버에서 일반/간소화 보기별 항목과 순서를 정합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("", selection: modeSelection) {
                ForEach(PopoverDisplayEditorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360, alignment: .leading)

            PopoverDisplayItemsListView(
                settings: settings,
                service: service,
                isCompact: selectedMode.isCompact
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
}
