import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

                    if shouldShowCodexTroubleshootingShortcut {
                        Button("문제 해결 보기") {
                            selectedCodexTab = .advanced
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    var codexAdvancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Codex 문제 해결", systemImage: "wrench.and.screwdriver")
                .font(.headline)

            Text("설치나 로그인이 안 될 때만 아래 안내를 따라 해 주세요.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if codexAuthStatus == .notInstalled {
                codexInstructionCard(
                    title: "설치",
                    message: "터미널에서 Codex를 설치한 뒤 다시 확인해 주세요.",
                    command: "brew install --cask codex"
                )
            }

            if codexAuthStatus == .notInstalled || codexAuthStatus == .notLoggedIn {
                codexInstructionCard(
                    title: "로그인",
                    message: "터미널에서 로그인만 마치면 바로 확인할 수 있습니다.",
                    command: "codex login"
                )
            }

            if codexAuthStatus == .expired {
                codexInstructionCard(
                    title: "다시 로그인",
                    message: "로그인이 만료되었습니다. 다시 로그인해 주세요.",
                    command: "codex login"
                )
            }

            if codexAuthStatus == .authenticated {
                Button("Codex 로그아웃") {
                    onCodexLogout?()
                    checkCodexAuth()
                }
                .foregroundStyle(.red)
            }

            if codexAuthStatus == .authenticated {
                Text("지금은 추가 조치가 필요하지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var codexDisplayConfigurationSection: some View {
        codexDisplaySection
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
        case .checking, .authenticated:
            return "필요하면 다시 확인하기"
        case .notInstalled:
            return "Codex 설치하기"
        case .notLoggedIn, .expired:
            return "Codex 로그인하기"
        }
    }

    private var codexActionDetail: String {
        switch codexAuthStatus {
        case .checking:
            return "잠시 뒤 상태가 바뀌는지 확인해 주세요."
        case .authenticated:
            return "지금은 추가 작업 없이 사용하시면 됩니다."
        case .notInstalled:
            return "문제 해결 탭에서 설치 명령 한 줄만 실행하시면 됩니다."
        case .notLoggedIn:
            return "문제 해결 탭에서 로그인 명령 한 줄만 실행하시면 됩니다."
        case .expired:
            return "문제 해결 탭에서 다시 로그인해 주세요."
        }
    }

    private var shouldShowCodexTroubleshootingShortcut: Bool {
        switch codexAuthStatus {
        case .checking, .authenticated:
            return false
        case .expired, .notInstalled, .notLoggedIn:
            return true
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
            Text("지금 할 일")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(codexActionTitle)
                .font(.subheadline.weight(.semibold))
            Text(codexActionDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
        .cornerRadius(8)
    }

    private func copyCodexCommand(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    private func codexInstructionCard(title: String, message: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("아래 한 줄만 실행해 주세요.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
                Button("복사") {
                    copyCodexCommand(command)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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

    var codexDisplaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Codex 표시", systemImage: "paintbrush")
                .font(.headline)

            settingsToggleRow("Codex 아이콘", isOn: $settings.showCodexIcon)
            Picker("퍼센트:", selection: Binding(
                get: { settings.codexPercentageDisplay },
                set: { settings.codexPercentageDisplay = $0 }
            )) {
                ForEach(PercentageDisplay.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Picker("리셋 시간:", selection: Binding(
                get: { settings.codexResetTimeDisplay },
                set: { settings.codexResetTimeDisplay = $0 }
            )) {
                ForEach(ResetTimeDisplay.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            if settings.codexResetTimeDisplay != .none {
                Picker("시간 형식:", selection: Binding(
                    get: { settings.codexTimeFormat },
                    set: { settings.codexTimeFormat = $0 }
                )) {
                    ForEach(TimeFormatStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            }

            Picker("표시 모양", selection: Binding(
                get: { SimplifiedMenuBarAppearance(style: settings.codexMenuBarStyle) },
                set: { settings.setMenuBarStyle($0.menuBarStyle, for: .codex) }
            )) {
                ForEach(SimplifiedMenuBarAppearance.allCases) { appearance in
                    Text(appearance.displayName).tag(appearance)
                }
            }
            .pickerStyle(.segmented)

            Text(SimplifiedMenuBarAppearance(style: settings.codexMenuBarStyle).summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("팝오버 항목 순서와 세부 구성은 기본 구성을 사용합니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
