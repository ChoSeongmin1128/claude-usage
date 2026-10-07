import Foundation

extension AppSettings {
    func menuBarQuotaSelection(
        for provider: AppProviderKind, limits: [UsageLimit], codexUsage: CodexUsageResponse? = nil
    ) -> MenuBarQuotaSelection? {
        guard let config = menuBarDisplayConfig(for: provider) else { return nil }
        return config.quotaSelection
            ?? MenuBarQuotaSelection.legacy(config: config, limits: limits, codexUsage: codexUsage)
    }

    func setMenuBarQuotaSelection(_ selection: MenuBarQuotaSelection, for provider: AppProviderKind) {
        guard provider != .antigravity else { return }
        menuBarQuotaPreferences.providers[provider.rawValue] = selection
    }
}
