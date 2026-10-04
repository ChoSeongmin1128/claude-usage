import AppKit
import SwiftUI

extension SettingsView {
    var commonServicesSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            Label("앱 동작", systemImage: "gearshape")
                .font(AppDesign.Typography.headline)

            settingsToggleRow("사용량 자동 확인", isOn: $settings.autoRefresh)

            settingsToggleRow(
                "로그인 시 자동 시작",
                subtitle: settings.launchAtLoginRequiresApproval
                    ? "시스템 설정 > 일반 > 로그인 항목에서 허용하세요" : nil,
                isOn: $settings.launchAtLogin
            )
        }
    }

    var appDataResetSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            Text("데이터 초기화").font(AppDesign.Typography.headline)
            Button("모든 데이터 초기화", role: .destructive) {
                Task { pendingDestructiveAction = .resetAllData(await AppDataResetPlan.prepare()) }
            }
            .buttonStyle(.bordered)
        }
    }

    var commonAlertSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            settingsToggleRow(
                "사용량 알림",
                isOn: Binding(
                    get: { settings.notificationsEnabled },
                    set: { enabled in
                        settings.notificationsEnabled = enabled
                        if enabled { NotificationManager.shared.requestPermission() }
                    }))
        }
    }

    var notificationThresholdSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            HStack {
                Text("알릴 시점").font(AppDesign.Typography.headline)
                Spacer()
                Button("표시 기준: \(settings.notificationValueBasis.title)") { selectedPanel = .display }
                    .buttonStyle(.link).controlSize(.small)
                    .help("모양에서 메뉴바, 팝오버, 알림의 기준을 함께 바꿉니다")
            }
            NotificationThresholdEditor(settings: settings)
        }
        .disabled(!settings.notificationsEnabled)
    }

    var commonUsageDisplaySection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.compact) {
            Picker("표시 기준", selection: $settings.usageDisplayMode) {
                if settings.usageDisplayMode == .legacy {
                    Text(UsageDisplayMode.legacy.title).tag(UsageDisplayMode.legacy)
                }
                Text(UsageDisplayMode.used.title).tag(UsageDisplayMode.used)
                Text(UsageDisplayMode.remaining.title).tag(UsageDisplayMode.remaining)
            }
            .pickerStyle(.segmented)
            Text(
                settings.usageDisplayMode == .legacy
                    ? "서비스별로 정했던 기준을 그대로 씁니다."
                    : "메뉴바, 팝오버, 알림에 함께 적용합니다. 알림 시점과 경고 색상은 바뀌지 않습니다."
            )
            .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
        }
    }

    var updateSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            Label("업데이트", systemImage: "arrow.down.circle")
                .font(AppDesign.Typography.headline)

            HStack(alignment: .center, spacing: AppDesign.Space.content) {
                Text("현재 버전 \(updateRuntimeState.currentVersionText)")
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if updateRuntimeState.isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("지금 확인") {
                        updateRuntimeState.checkNow()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!updateRuntimeState.canCheckNow)

                    if updateRuntimeState.showsPrimaryAction {
                        Button(updateRuntimeState.primaryActionTitle) {
                            updateRuntimeState.performPrimaryAction()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!updateRuntimeState.isPrimaryActionEnabled)
                    }
                }
            }

            if let summary = updateRuntimeState.statusSummary {
                Text(summary)
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            UpdateHistoryActions(onShowWhatsNew: onShowWhatsNew)

            if let update = updateRuntimeState.latestKnownUpdate,
               !update.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DisclosureGroup("v\(update.version) 변경 사항") {
                    Text(verbatim: update.releaseNotes)
                        .font(AppDesign.Typography.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, AppDesign.Space.control)
                }
                .font(AppDesign.Typography.caption)
            }
        }
    }

    var commonDisplaySection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            Label("공통 표시", systemImage: "menubar.rectangle")
                .font(AppDesign.Typography.headline)

            commonUsageDisplaySection
            MenuBarDesignPicker(
                settings: settings, style: selectedDesignPreviewStyle, basis: selectedDesignPreviewBasis)

            settingsRadioGroup(
                "메뉴바 색상",
                options: MenuBarColorMode.allCases.map { (value: $0, label: $0.displayName) },
                selection: settings.menuBarColorMode,
                onChange: { settings.menuBarColorMode = $0 }
            )

            Text(settings.menuBarColorMode.detail)
                .font(AppDesign.Typography.caption)
                .foregroundStyle(.tertiary)

            settingsToggleRow(
                "보조 텍스트 강조",
                subtitle: "갱신 시각과 구분자를 기본 텍스트 색상으로 표시합니다",
                isOn: $settings.menuBarTextHighContrast
            )
        }
    }

    private var selectedDesignPreviewBasis: UsageValueBasis {
        if let basis = settings.usageDisplayMode.basis { return basis }
        if selectedDisplayProvider == .antigravity, let display = antigravitySettings.state.display {
            return .antigravity(display.menuBar)
        }
        return settings.usageValueBasis(for: selectedDisplayProvider.runtimeService ?? .claude)
    }

    private var selectedDesignPreviewStyle: MenuBarStyle {
        if selectedDisplayProvider == .antigravity {
            switch antigravitySettings.state.display?.menuBar.style {
            case .batteryBar: return .batteryBar
            case .circular: return .circular
            default: return .none
            }
        }
        return settings.menuBarDisplayConfig(for: selectedDisplayProvider)?.style ?? .none
    }
}
