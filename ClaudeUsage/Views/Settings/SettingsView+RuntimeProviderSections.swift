import AppKit
import SwiftUI

extension SettingsView {
    @ViewBuilder
    func runtimeProviderPanel(for provider: AppProviderKind, tab: ProviderSettingsTab) -> some View {
        switch tab {
        case .overview:
            runtimeProviderOverviewSection(for: provider)
        case .display:
            runtimeProviderDisplaySection(for: provider)
        case .alerts:
            runtimeProviderOverviewSection(for: provider)
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
                Text("이 provider의 개요 화면은 아직 별도 presentation을 쓰지 않습니다.")
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
            summary: "메뉴바 표시 방식과 팝오버 동작을 함께 정합니다."
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

                        Picker("아이콘:", selection: Binding(
                            get: { settings.menuBarDisplayConfig(for: provider)?.style ?? .none },
                            set: { settings.setMenuBarStyle($0, for: provider) }
                        )) {
                            Text("없음").tag(MenuBarStyle.none)
                            Section("개별 기준") {
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
                                "아이콘 기준:",
                                options: IconMetric.allCases.map { ($0, $0.displayName) },
                                selection: settings.menuBarDisplayConfig(for: provider)?.iconMetric ?? .fiveHour,
                                onChange: { settings.setProviderIconMetric($0, for: provider) }
                            )
                        }

                        if displayConfig.style != .none {
                            settingsRadioGroup(
                                "표시 기준:",
                                options: CircularDisplayMode.allCases.map { ($0, $0.displayName) },
                                selection: settings.menuBarDisplayConfig(for: provider)?.circularDisplayMode ?? .usage,
                                onChange: { settings.setProviderCircularDisplayMode($0, for: provider) }
                            )
                        }
                    } else {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "eye.slash")
                                .foregroundStyle(.secondary)
                                .padding(.top, 1)
                            Text("이 provider는 활성화되어 있어도 popover와 새로고침에만 참여하고, 메뉴바에는 표시하지 않습니다.")
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
                footnote: shellSectionFootnote(for: provider, selectionState: settings.providerSelectionState),
                onRefreshEnvironment: { runtimeEnvironmentRefreshTick += 1 }
            )
        }
    }

    private func runtimeProviderOverviewHint(for presentation: RuntimeProviderAuthPresentation) -> String? {
        guard let firstPath = presentation.pathHints.first else { return nil }
        switch presentation.stage {
        case .installRequired, .unsupportedConfiguration, .authRequired, .waitingForApp:
            return "확인 경로: \(firstPath)"
        case .disabled, .refreshingCredential, .probingRuntime:
            return nil
        }
    }
}
