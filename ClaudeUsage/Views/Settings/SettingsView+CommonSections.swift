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

            settingsToggleRow(
                "Codex/Antigravity도 사용",
                subtitle: "끄면 설정, 팝오버, 메뉴에는 Claude만 표시합니다",
                isOn: Binding(
                    get: { settings.additionalRuntimeProvidersEnabled },
                    set: { settings.additionalRuntimeProvidersEnabled = $0 }
                )
            )

            settingsRadioGroup(
                "메뉴바 색상",
                options: MenuBarColorMode.allCases.map { (value: $0, label: $0.displayName) },
                selection: settings.menuBarColorMode,
                onChange: { settings.menuBarColorMode = $0 }
            )

            Text(settings.menuBarColorMode.detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
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

            Text("서비스별 알림은 각 서비스 화면에서 조정합니다. 시스템 설정 → 알림 → ClaudeUsage에서도 알림 허용이 필요합니다.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
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
            Label("고급 표시", systemImage: "menubar.rectangle")
                .font(.headline)

            settingsToggleRow(
                "보조 텍스트 강조",
                subtitle: "갱신 시각과 구분자를 기본 텍스트 색상으로 표시합니다",
                isOn: $settings.menuBarTextHighContrast
            )
        }
    }

}
