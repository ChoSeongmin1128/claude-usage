import AppKit
import SwiftUI

extension SettingsView {
    var codexOverviewSection: some View {
        codexAuthSection
    }

    var codexAuthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Codex 사용", systemImage: "bubble.left.and.bubble.right")
                .font(.headline)

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

                    if codexAuthStatus == .authenticated {
                        Button("로그아웃") {
                            onCodexLogout?()
                            checkCodexAuth()
                        }
                        .buttonStyle(.bordered)
                    }
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
        if !settings.isProviderEnabled(.codex) {
            codexAuthStatus = .notLoggedIn
            return
        }

        if CodexAuthManager.shared.authJsonExists {
            if let token = CodexAuthManager.shared.getToken() {
                codexAuthStatus = token.isExpired ? .expired : .authenticated
            } else {
                codexAuthStatus = .notLoggedIn
            }
            return
        }

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

        codexAuthStatus = codexInstalled ? .notLoggedIn : .notInstalled
    }
}
