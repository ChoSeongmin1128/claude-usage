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

    private var codexStatusTitle: String {
        switch codexAuthStatus {
        case .checking:
            return "상태를 확인하는 중입니다"
        case .authenticated:
            return "로그인되어 바로 사용할 수 있습니다"
        case .notInstalled:
            return "Codex를 먼저 설치해야 합니다"
        case .notLoggedIn:
            return "Codex 로그인이 필요합니다"
        case .expired:
            return "로그인이 만료되어 다시 확인이 필요합니다"
        }
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
        switch codexAuthStatus {
        case .checking:
            return "확인 중"
        case .authenticated:
            return "로그인됨"
        case .expired:
            return "다시 로그인"
        case .notInstalled:
            return "설치 필요"
        case .notLoggedIn:
            return "로그인 필요"
        }
    }

    private var codexActionTitle: String {
        switch codexAuthStatus {
        case .checking:
            return "확인 중"
        case .authenticated:
            return "로그인 완료"
        case .notInstalled:
            return "Codex 설치"
        case .notLoggedIn, .expired:
            return "Codex 로그인"
        }
    }

    private var codexActionDetail: String? {
        switch codexAuthStatus {
        case .checking:
            return nil
        case .authenticated:
            return nil
        case .notInstalled:
            return "설치 후 다시 확인"
        case .notLoggedIn:
            return "로그인 후 다시 확인"
        case .expired:
            return "다시 로그인 후 확인"
        }
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
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
        .cornerRadius(8)
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
