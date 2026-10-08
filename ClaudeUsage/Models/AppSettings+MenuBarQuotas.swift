import Foundation

extension ProviderMenuBarDisplayConfig {
    func resolvedQuotaSelection(limits: [UsageLimit], codexUsage: CodexUsageResponse? = nil) -> MenuBarQuotaSelection {
        var selection =
            quotaSelection ?? MenuBarQuotaSelection.legacy(config: self, limits: limits, codexUsage: codexUsage)
        if let ids = gaugeSelection?.ids {
            selection.gaugeIDs = ids
        } else {
            selection.gaugeIDs = Array(selection.gaugeIDs.prefix(style == .none ? 0 : style.isDualStyle ? 2 : 1))
        }
        if let titles = gaugeSelection?.titles { selection.titles.merge(titles) { _, gauge in gauge } }
        return selection
    }
}

extension AppSettings {
    func menuBarQuotaSelection(
        for provider: AppProviderKind, limits: [UsageLimit], codexUsage: CodexUsageResponse? = nil
    ) -> MenuBarQuotaSelection? {
        menuBarDisplayConfig(for: provider)?.resolvedQuotaSelection(limits: limits, codexUsage: codexUsage)
    }

    func setMenuBarQuotaSelection(_ selection: MenuBarQuotaSelection, for provider: AppProviderKind) {
        guard provider != .antigravity else { return }
        menuBarQuotaPreferences.providers[provider.rawValue] = selection
    }

    func setMenuBarGaugeSelection(_ selection: MenuBarGaugeSelection, for provider: AppProviderKind) {
        guard provider != .antigravity else { return }
        var gauges = menuBarQuotaPreferences.gauges ?? [:]
        gauges[provider.rawValue] = selection
        menuBarQuotaPreferences.gauges = gauges
    }
}
