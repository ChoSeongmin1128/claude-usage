import AppKit
import SwiftUI

extension SettingsView {
    var commonServicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("앱 동작", systemImage: "gearshape")
                .font(.headline)

            settingsToggleRow(
                "사용량 자동 확인",
                subtitle: "주기적으로 사용량을 다시 확인합니다",
                isOn: $settings.autoRefresh
            )

            settingsToggleRow(
                "로그인 시 자동 시작",
                subtitle: settings.launchAtLoginRequiresApproval
                    ? "시스템 설정 → 일반 → 로그인 항목에서 승인이 필요합니다"
                    : "시스템 설정 → 일반 → 로그인 항목에서도 관리할 수 있습니다",
                isOn: $settings.launchAtLogin
            )

        }
    }

    var commonAlertSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("알림", systemImage: "bell")
                .font(.headline)

            settingsToggleRow(
                "전체 알림 사용",
                subtitle: "사용량이 정한 기준에 도달하면 알림을 표시합니다",
                isOn: Binding(
                    get: { settings.notificationsEnabled },
                    set: { isEnabled in
                        settings.notificationsEnabled = isEnabled
                        if isEnabled {
                            NotificationManager.shared.requestPermission()
                        }
                    }
                )
            )

            if !settings.notificationsEnabled {
                Label("전체 알림이 꺼져 있어 서비스별 알림도 함께 꺼집니다.", systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("이 화면에서 임계값과 서비스별 알림을 함께 조정합니다. 시스템 설정 → 알림 → ClaudeUsage에서도 허용이 필요합니다.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    var notificationThresholdSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("알림 기준", systemImage: "gauge.with.dots.needle.50percent")
                .font(.headline)

            settingsRadioGroup(
                "기준 표시",
                options: [
                    (value: false, label: "사용량"),
                    (value: true, label: "남은 양"),
                ],
                selection: settings.alertRemainingMode,
                onChange: { settings.alertRemainingMode = $0 }
            )

            settingsToggleRow(
                "5시간 한도",
                subtitle: "짧은 주기의 사용량 한도에 기준을 적용합니다",
                isOn: $settings.alertFiveHourEnabled
            )
            settingsToggleRow(
                "주간 한도",
                subtitle: "주간 사용량 한도에도 같은 기준을 적용합니다",
                isOn: $settings.alertWeeklyEnabled
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("임계값")
                    .font(.subheadline.weight(.semibold))
                ForEach(settings.sortedNotificationPresets) { preset in
                    notificationPresetRow(id: preset.id)
                }
            }
        }
        .disabled(!settings.notificationsEnabled)
        .opacity(settings.notificationsEnabled ? 1 : 0.6)
    }

    var updateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("업데이트", systemImage: "arrow.down.circle")
                .font(.headline)

            Label("30분마다 자동 확인", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 12) {
                Text("현재 버전 \(updateRuntimeState.currentVersionText)")
                    .font(.caption)
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

            Text(updateRuntimeState.statusSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    var commonDisplaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("공통 표시", systemImage: "menubar.rectangle")
                .font(.headline)

            settingsRadioGroup(
                "메뉴바 색상",
                options: MenuBarColorMode.allCases.map { (value: $0, label: $0.displayName) },
                selection: settings.menuBarColorMode,
                onChange: { settings.menuBarColorMode = $0 }
            )

            Text(settings.menuBarColorMode.detail)
                .font(.caption)
                .foregroundStyle(.tertiary)

            settingsToggleRow(
                "보조 텍스트 강조",
                subtitle: "갱신 시각과 구분자를 기본 텍스트 색상으로 표시합니다",
                isOn: $settings.menuBarTextHighContrast
            )
        }
    }

    private func notificationPresetRow(id: String) -> some View {
        HStack(spacing: 12) {
            Toggle(
                "",
                isOn: Binding(
                    get: {
                        settings.notificationPresets
                            .first(where: { $0.id == id })?
                            .isEnabled ?? false
                    },
                    set: { isEnabled in
                        guard let index = settings.notificationPresets
                            .firstIndex(where: { $0.id == id }) else { return }
                        settings.notificationPresets[index].isEnabled = isEnabled
                    }
                )
            )
            .labelsHidden()

            Stepper(
                value: Binding(
                    get: {
                        settings.notificationPresets
                            .first(where: { $0.id == id })?
                            .threshold ?? 75
                    },
                    set: { threshold in
                        guard let index = settings.notificationPresets
                            .firstIndex(where: { $0.id == id }) else { return }
                        settings.notificationPresets[index].threshold =
                            max(1, min(threshold, 99))
                    }
                ),
                in: 1...99,
                step: 5
            ) {
                let threshold = settings.notificationPresets
                    .first(where: { $0.id == id })?
                    .threshold ?? 0
                Text(
                    "\(settings.alertRemainingMode ? "남음" : "사용") \(threshold)%"
                )
                .monospacedDigit()
            }
        }
    }

}
