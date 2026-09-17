import SwiftUI

extension SettingsView {
    var welcomeSection: some View {
        let _ = runtimeEnvironmentRefreshTick
        return WelcomeView(
            settings: settings, selectedProvider: $welcomeProvider,
            statuses: welcomeStatuses?() ?? [:],
            connection: welcomeConnectionSection,
            display: providerMenuBarDisplaySection(for: welcomeProvider),
            onVerify: { service in
                if service == .codex { checkCodexAuth() }
                onVerifyService?(service)
            },
            onDefer: { selectedPanel = .common },
            onFinish: { selectedPanel = .display })
    }

    @ViewBuilder
    private var welcomeConnectionSection: some View {
        switch welcomeProvider {
        case .claude: claudeOverviewSection
        case .codex: codexOverviewSection
        case .antigravity: runtimeProviderPanel(for: .antigravity)
        }
    }
}
