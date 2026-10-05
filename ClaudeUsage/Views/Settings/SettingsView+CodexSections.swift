import AppKit
import SwiftUI

extension SettingsView {
    var codexAuthSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            ProviderSettingsSectionHeader(provider: .codex, title: "Codex")

            settingsToggleRow(
                "Codex 사용",
                isOn: Binding(
                    get: { settings.isProviderEnabled(.codex) },
                    set: { settings.setProviderEnabled($0, for: .codex) }
                )
            )

            if settings.isProviderEnabled(.codex) {
                VStack(alignment: .leading, spacing: AppDesign.Space.row) {
                    HStack {
                        Text(codexStatusBadgeTitle)
                            .font(AppDesign.Typography.subheadline.weight(.semibold))
                            .foregroundStyle(codexStatusTone)
                        Spacer()
                        if codexAuthStatus == .checking { ProgressView().controlSize(.small) }
                        Button("다시 확인") { checkCodexAuth() }
                            .controlSize(.small).disabled(codexAuthStatus == .checking)
                    }
                    codexActionCard
                }
                .padding(AppDesign.Space.content)
                .appPanelStyle()
            }
        }
    }

    private var codexPresentation: CodexAuthPresentation {
        CodexAuthPresentation.resolve(for: codexAuthStatus)
    }

    private var codexStatusTone: Color {
        switch codexAuthStatus {
        case .checking:
            return .blue
        case .authenticated:
            return .green
        case .expired, .notLoggedIn:
            return .orange
        case .notInstalled:
            return .red
        }
    }

    private var codexStatusBadgeTitle: String {
        codexPresentation.statusBadgeTitle
    }

    @ViewBuilder
    private var codexActionCard: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.control) {
            if let detail = codexPresentation.actionDetail {
                Text(detail)
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            if let command = codexPresentation.command {
                HStack(spacing: AppDesign.Space.row) {
                    Text(command)
                        .font(AppDesign.Typography.compactValue)
                        .textSelection(.enabled)
                        .padding(.horizontal, AppDesign.Space.row)
                        .padding(.vertical, 5)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.65))
                        .cornerRadius(AppDesign.Radius.control)

                    Button("명령 복사") {
                        copyCodexCommand(command)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, AppDesign.Space.tight)
            }
        }

    }

    private func copyCodexCommand(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    func checkCodexAuth() {
        codexAuthCheckTask?.cancel()

        let isProviderEnabled = settings.isProviderEnabled(.codex)
        guard isProviderEnabled else {
            codexAuthStatus = .notLoggedIn
            return
        }

        codexAuthStatus = .checking
        let readStatus = codexAuthStatusReader
        codexAuthCheckTask = Task {
            let status = await readStatus(isProviderEnabled)

            guard !Task.isCancelled else { return }

            await MainActor.run {
                codexAuthStatus = status
            }
        }
    }

}
