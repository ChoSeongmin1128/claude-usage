import AppKit
import SwiftUI

enum SimplifiedMenuBarAppearance: String, CaseIterable, Identifiable {
    case textOnly
    case simple
    case detailed

    var id: Self { self }

    init(style: MenuBarStyle) {
        switch style {
        case .none:
            self = .textOnly
        case .batteryBar, .circular:
            self = .simple
        case .concentricRings, .dualBattery, .sideBySideBattery:
            self = .detailed
        }
    }

    var displayName: String {
        switch self {
        case .textOnly:
            return "텍스트만"
        case .simple:
            return "간단히"
        case .detailed:
            return "자세히"
        }
    }

    var summary: String {
        switch self {
        case .textOnly:
            return "아이콘 없이 텍스트만 보여줍니다."
        case .simple:
            return "현재 상태를 한눈에 보는 단순한 아이콘을 함께 보여줍니다."
        case .detailed:
            return "현재 세션과 주간 정보를 함께 보여줍니다."
        }
    }

    var menuBarStyle: MenuBarStyle {
        switch self {
        case .textOnly:
            return .none
        case .simple:
            return .batteryBar
        case .detailed:
            return .concentricRings
        }
    }
}

extension SettingsView {
    @ViewBuilder
    func runtimeProviderPanel(for provider: AppProviderKind, tab: ProviderSettingsTab) -> some View {
        switch tab {
        case .overview:
            runtimeProviderOverviewSection(for: provider)
        case .display:
            runtimeProviderDisplaySection(for: provider)
        case .advanced:
            runtimeProviderAdvancedSection(for: provider)
        }
    }

    @ViewBuilder
    private func runtimeProviderOverviewSection(for provider: AppProviderKind) -> some View {
        let _ = runtimeEnvironmentRefreshTick
        let descriptor = SettingsProviderRegistry.providerShellDescriptor(for: provider)
        if let presentation = RuntimeProviderSettingsPresentation.authPresentation(
            for: provider,
            isEnabled: settings.isProviderEnabled(provider)
        ) {
            RuntimeProviderOverviewSectionView(
                settings: settings,
                provider: provider,
                descriptor: descriptor,
                presentation: presentation,
                hint: runtimeProviderOverviewHint(for: presentation)
            )
        } else {
            RuntimeProviderPanelShell(
                descriptor: descriptor,
                title: descriptor.title,
                summary: descriptor.summary,
                detail: descriptor.detail
            ) {
                Text("이 서비스의 안내 화면은 아직 준비 중입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func runtimeProviderDisplaySection(for provider: AppProviderKind) -> some View {
        let descriptor = SettingsProviderRegistry.providerShellDescriptor(for: provider)
        let displayConfig = settings.menuBarDisplayConfig(for: provider)
        RuntimeProviderPanelShell(
            descriptor: descriptor,
            title: "\(descriptor.title) 표시",
            summary: "메뉴바에 무엇을 보여줄지만 간단히 정합니다."
        ) {
            if let displayConfig {
                VStack(alignment: .leading, spacing: 10) {
                    settingsToggleRow(
                        "\(descriptor.title) 메뉴바에 표시",
                        isOn: Binding(
                            get: { settings.isProviderVisibleInMenuBar(provider) },
                            set: { settings.setProviderMenuBarVisible($0, for: provider) }
                        )
                    )

                    if settings.isProviderVisibleInMenuBar(provider) {
                        settingsToggleRow(
                            "\(descriptor.title) 아이콘",
                            isOn: Binding(
                                get: { settings.menuBarDisplayConfig(for: provider)?.showIcon ?? true },
                                set: { settings.setProviderShowIcon($0, for: provider) }
                            )
                        )

                        Picker("퍼센트:", selection: Binding(
                            get: { settings.menuBarDisplayConfig(for: provider)?.percentageDisplay ?? .fiveHour },
                            set: { settings.setProviderPercentageDisplay($0, for: provider) }
                        )) {
                            ForEach(PercentageDisplay.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }

                        Picker("리셋 시간:", selection: Binding(
                            get: { settings.menuBarDisplayConfig(for: provider)?.resetTimeDisplay ?? .none },
                            set: { settings.setProviderResetTimeDisplay($0, for: provider) }
                        )) {
                            ForEach(ResetTimeDisplay.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }

                        if displayConfig.resetTimeDisplay != .none {
                            Picker("시간 형식:", selection: Binding(
                                get: { settings.menuBarDisplayConfig(for: provider)?.timeFormat ?? .h24 },
                                set: { settings.setProviderTimeFormat($0, for: provider) }
                            )) {
                                ForEach(TimeFormatStyle.allCases, id: \.self) { style in
                                    Text(style.displayName).tag(style)
                                }
                            }
                        }

                        Picker("표시 모양", selection: Binding(
                            get: {
                                SimplifiedMenuBarAppearance(
                                    style: settings.menuBarDisplayConfig(for: provider)?.style ?? .none
                                )
                            },
                            set: { settings.setMenuBarStyle($0.menuBarStyle, for: provider) }
                        )) {
                            ForEach(SimplifiedMenuBarAppearance.allCases) { appearance in
                                Text(appearance.displayName).tag(appearance)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(SimplifiedMenuBarAppearance(style: displayConfig.style).summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "eye.slash")
                                .foregroundStyle(.secondary)
                                .padding(.top, 1)
                            Text("메뉴바에는 표시하지 않고, 팝오버에서만 보여줍니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
                        .cornerRadius(8)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func runtimeProviderAdvancedSection(for provider: AppProviderKind) -> some View {
        let _ = runtimeEnvironmentRefreshTick
        let descriptor = SettingsProviderRegistry.providerShellDescriptor(for: provider)
        if let presentation = RuntimeProviderSettingsPresentation.authPresentation(
            for: provider,
            isEnabled: settings.isProviderEnabled(provider)
        ) {
            RuntimeProviderAdvancedSectionView(
                descriptor: descriptor,
                presentation: presentation,
                onRefreshEnvironment: { runtimeEnvironmentRefreshTick += 1 }
            )
        }
    }

    private func runtimeProviderOverviewHint(for presentation: RuntimeProviderAuthPresentation) -> String? {
        nil
    }
}
