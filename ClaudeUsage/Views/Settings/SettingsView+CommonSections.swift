import AppKit
import SwiftUI

extension SettingsView {
    var commonServicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("서비스", systemImage: "square.stack.3d.up")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("서비스 사용")
                    .font(.subheadline.weight(.semibold))

                ForEach(AppProviderKind.allCases, id: \.self) { provider in
                    settingsToggleRow(
                        "\(provider.displayName) 사용",
                        subtitle: providerToggleSubtitle(for: provider),
                        isOn: Binding(
                            get: { settings.isProviderEnabled(provider) },
                            set: { settings.setProviderEnabled($0, for: provider) }
                        )
                    )
                }
            }
        }
    }

    var refreshSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("사용량 확인", systemImage: "arrow.clockwise")
                .font(.headline)

            settingsToggleRow(
                "자동 새로고침",
                subtitle: "주기적으로 사용량을 다시 확인합니다",
                isOn: $settings.autoRefresh
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
                isOn: $settings.notificationsEnabled
            )

            if !settings.notificationsEnabled {
                Label("전체 알림이 꺼져 있어 서비스별 알림도 함께 꺼집니다.", systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("서비스별 알림")
                    .font(.subheadline.weight(.semibold))

                ForEach(AppProviderKind.allCases, id: \.self) { provider in
                    settingsToggleRow(
                        "\(provider.displayName) 알림 사용",
                        isOn: Binding(
                            get: { settings.isProviderAlertEnabled(provider) },
                            set: { settings.setProviderAlertEnabled($0, for: provider) }
                        )
                    )
                }

            }
            .disabled(!settings.notificationsEnabled)
            .opacity(settings.notificationsEnabled ? 1.0 : 0.6)

            Divider()

            Text("시스템 설정 → 알림 → ClaudeUsage에서 알림을 허용해야 합니다.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    var updateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("업데이트", systemImage: "arrow.down.circle")
                .font(.headline)

            Picker("자동 확인", selection: $settings.updateCheckInterval) {
                ForEach(UpdateCheckInterval.allCases, id: \.self) { interval in
                    Text(interval.displayName).tag(interval)
                }
            }
            .pickerStyle(.segmented)

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

    var appPreferencesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("앱", systemImage: "gearshape.2")
                .font(.headline)

            settingsToggleRow("로그인 시 자동 시작", isOn: $settings.launchAtLogin)

            Text("시스템 설정 → 일반 → 로그인 항목에서도 관리할 수 있습니다")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func providerToggleSubtitle(for provider: AppProviderKind) -> String {
        switch provider {
        case .claude:
            return "Claude 사용량을 표시합니다"
        case .codex:
            return "Codex 사용량을 표시합니다"
        case .gemini:
            return "Gemini 사용량을 표시합니다"
        case .antigravity:
            return "Antigravity 사용량을 표시합니다"
        }
    }

}
