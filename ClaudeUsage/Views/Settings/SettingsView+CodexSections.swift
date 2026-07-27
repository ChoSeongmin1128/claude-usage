import AppKit
import SwiftUI

extension SettingsView {
    var codexOverviewSection: some View {
        codexAuthSection
    }

    var codexAuthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProviderSettingsSectionHeader(provider: .codex, title: "Codex 사용")

            settingsToggleRow(
                "Codex 사용",
                isOn: Binding(
                    get: { settings.isProviderEnabled(.codex) },
                    set: { settings.setProviderEnabled($0, for: .codex) }
                )
            )

            if settings.isProviderEnabled(.codex) {
                codexStatusCard
                codexActionCard

                HStack(spacing: 8) {
                    Button("다시 확인") {
                        checkCodexAuth()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var codexPresentation: CodexAuthPresentation {
        CodexAuthPresentation.resolve(for: codexAuthStatus)
    }

    private var codexStatusTitle: String {
        codexPresentation.statusTitle
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

    private var codexActionTitle: String {
        codexPresentation.actionTitle
    }

    private var codexActionDetail: String? {
        codexPresentation.actionDetail
    }

    private var codexStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(codexStatusBadgeTitle)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(codexStatusTone.opacity(0.16))
                    .foregroundStyle(codexStatusTone)
                    .cornerRadius(6)
                Spacer(minLength: 0)
                if codexAuthStatus == .checking {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(codexStatusTitle)
                .font(.subheadline.weight(.semibold))
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private var codexActionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(codexActionTitle)
                .font(.subheadline.weight(.semibold))
            if let codexActionDetail {
                Text(codexActionDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let command = codexPresentation.command {
                HStack(spacing: 8) {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.65))
                        .cornerRadius(6)

                    Button("명령 복사") {
                        copyCodexCommand(command)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
        .cornerRadius(8)
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
        codexAuthCheckTask = Task {
            let authJsonExists = CodexAuthManager.shared.authJsonExists
            let token = CodexAuthManager.shared.getToken()
            // [C] status 조회는 read-only — refresh 시도하지 않는다.
            // 사용자가 설정 UI 진입한 것만으로 RT 가 소비되어 다음 부팅 시 reused 에러로 이어지는
            // 회귀를 막는다. 만료된 경우 사용자에게 `codex login` 안내 (.expired).
            let status = CodexAuthStatusResolver.resolve(
                isProviderEnabled: isProviderEnabled,
                authJsonExists: authJsonExists,
                token: token,
                isCodexInstalled: Self.isCodexInstalled
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                codexAuthStatus = status
            }
        }
    }

    private static func isCodexInstalled() -> Bool {
        let codexInstalled = FileManager.default.isExecutableFile(atPath: "/usr/local/bin/codex")
            || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/codex")
            || FileManager.default.isExecutableFile(atPath: "\(NSHomeDirectory())/.npm-global/bin/codex")
            || {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                process.arguments = ["codex"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                try? process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            }()

        return codexInstalled
    }
}
