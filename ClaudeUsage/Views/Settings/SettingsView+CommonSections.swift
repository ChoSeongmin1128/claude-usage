import AppKit
import SwiftUI

extension SettingsView {
    var commonServicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("서비스", systemImage: "square.stack.3d.up")
                .font(.headline)

            Text("필요한 서비스만 켜 두시면 됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

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

    var commonDisplaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("표시", systemImage: "paintbrush")
                .font(.headline)

            settingsToggleRow(
                "리셋 시간 선명하게 보기",
                subtitle: "리셋 시간과 구분자를 더 또렷하게 표시합니다",
                isOn: $settings.menuBarTextHighContrast
            )

            Divider()

            settingsToggleRow(
                "간소화 보기",
                subtitle: "팝오버를 더 간단한 레이아웃으로 보여줍니다",
                isOn: $settings.popoverCompact
            )

            Text("표시 항목 순서와 세부 구성은 기본 구성을 사용합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

            if settings.autoRefresh {
                Picker("확인 간격", selection: refreshIntervalSelection) {
                    ForEach(refreshIntervalOptions, id: \.self) { interval in
                        Text("\(Int(interval))초").tag(interval)
                    }
                }

                Text("필요할 때는 수동으로 다시 확인할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

                Text("필요한 서비스만 알림을 켜 두시면 됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.notificationsEnabled)
            .opacity(settings.notificationsEnabled ? 1.0 : 0.6)

            Divider()

            Text("시스템 설정 → 알림 → ClaudeUsage에서 알림을 허용해야 합니다.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    var powerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("배터리 사용 중", systemImage: "battery.75percent")
                .font(.headline)

            settingsToggleRow(
                "배터리 사용 시 새로고침 감소",
                subtitle: "배터리로 사용할 때 새로고침 간격을 최소 60초로 유지합니다",
                isOn: $settings.reducedRefreshOnBattery
            )
        }
    }

    func refreshUpdateEnginePresentation() {
        updateRuntimeState.refreshEngineStatus()
    }

    var updateSection: some View {
        UpdateDiagnosticsSectionShell(updateModeSummary: updateRuntimeState.modeSummary) {
            Picker("자동 확인", selection: $settings.updateCheckInterval) {
                ForEach(UpdateCheckInterval.allCases, id: \.self) { interval in
                    Text(interval.displayName).tag(interval)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("현재 버전: \(updateRuntimeState.currentVersionText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let lastCheckedAt = updateRuntimeState.lastCheckedAt {
                    Text("마지막 확인 \(shortRelativeTimestamp(lastCheckedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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

            updateStatusCard
        }
    }

    private var updateStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(updateRuntimeState.statusTitle)
                .font(.subheadline.weight(.semibold))
            Text(updateRuntimeState.statusSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(updateStatusColor.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(updateStatusColor.opacity(0.22), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    private var updateStatusColor: Color {
        switch updateRuntimeState.tone {
        case .accent:
            return .blue
        case .positive:
            return .green
        case .caution:
            return .orange
        case .destructive:
            return .red
        case .secondary:
            return .secondary
        }
    }

    var appPreferencesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("앱 시작", systemImage: "gearshape.2")
                .font(.headline)

            settingsToggleRow("로그인 시 자동 시작", isOn: $settings.launchAtLogin)

            Text("시스템 설정 → 일반 → 로그인 항목에서도 관리할 수 있습니다")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var refreshIntervalOptions: [TimeInterval] {
        let defaults: [TimeInterval] = [15, 30, 60, 120]
        let current = max(5, min(120, Double(Int(settings.refreshInterval.rounded()))))
        if defaults.contains(current) {
            return defaults
        }
        return (defaults + [current]).sorted()
    }

    private var refreshIntervalSelection: Binding<TimeInterval> {
        Binding(
            get: {
                let current = max(5, min(120, Double(Int(settings.refreshInterval.rounded()))))
                if refreshIntervalOptions.contains(current) {
                    return current
                }
                return 30
            },
            set: { newValue in
                settings.refreshInterval = newValue
                refreshIntervalText = String(Int(newValue))
            }
        )
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
