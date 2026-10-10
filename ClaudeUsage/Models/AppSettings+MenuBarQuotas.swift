import Foundation

extension ProviderMenuBarDisplayConfig {
    func settingQuotaSelection(_ selection: MenuBarQuotaSelection?, gauges: MenuBarGaugeSelection? = nil) -> Self {
        Self(
            kind: kind, showIcon: showIcon, style: style, percentageDisplay: percentageDisplay,
            showBatteryPercent: showBatteryPercent, resetTimeDisplay: resetTimeDisplay, timeFormat: timeFormat,
            circularDisplayMode: circularDisplayMode, iconMetric: iconMetric, colorMode: colorMode, design: design,
            basisOverride: basisOverride, quotaSelection: selection, gaugeSelection: gauges ?? gaugeSelection)
    }

    func resolvedQuotaSelection(limits: [UsageLimit], codexUsage: CodexUsageResponse? = nil) -> MenuBarQuotaSelection {
        var selection =
            quotaSelection ?? MenuBarQuotaSelection.legacy(config: self, limits: limits, codexUsage: codexUsage)
        if selection.legacyPercentageDisplay != nil || selection.legacyResetTimeDisplay != nil {
            let legacyConfig = ProviderMenuBarDisplayConfig(
                kind: kind, showIcon: showIcon, style: .none,
                percentageDisplay: selection.legacyPercentageDisplay ?? .none,
                showBatteryPercent: showBatteryPercent, resetTimeDisplay: selection.legacyResetTimeDisplay ?? .none,
                timeFormat: timeFormat, circularDisplayMode: circularDisplayMode, iconMetric: iconMetric,
                colorMode: colorMode, design: design, basisOverride: basisOverride)
            let legacy = MenuBarQuotaSelection.legacy(config: legacyConfig, limits: limits, codexUsage: codexUsage)
            selection.percentageIDs = replacingLegacyBasicIDs(selection.percentageIDs, with: legacy.percentageIDs)
            selection.resetIDs = replacingLegacyBasicIDs(selection.resetIDs, with: legacy.resetIDs)
            selection.titles.merge(legacy.titles) { _, observed in observed }
        }
        if let ids = gaugeSelection?.ids {
            selection.gaugeIDs = ids
        } else {
            selection.gaugeIDs = Array(selection.gaugeIDs.prefix(style == .none ? 0 : style.isDualStyle ? 2 : 1))
        }
        if let titles = gaugeSelection?.titles { selection.titles.merge(titles) { _, gauge in gauge } }
        selection.arrangement = selection.arrangement?.resolved(selection: selection)
        if let layout = gaugeSelection?.layout {
            selection.arrangement = selection.arrangement?.settingLayout(layout, selection: selection)
        }
        return selection
    }

    private func replacingLegacyBasicIDs(_ previous: [String], with current: [String]) -> [String] {
        guard !current.isEmpty else { return previous }
        var replaced = false
        var candidates: [String] = []
        for id in previous {
            if UsageLimitCatalog.isBasicID(id, provider: kind) {
                if !replaced {
                    candidates += current
                    replaced = true
                }
            } else {
                candidates.append(id)
            }
        }
        if !replaced { candidates += current }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }
}

nonisolated extension MenuBarGaugeLayout {
    func adapted(to style: MenuBarStyle) -> Self {
        switch style {
        case .dualBattery: .stacked
        case .sideBySideBattery: .horizontal
        case .concentricRings: .concentric
        case .circular: self == .stacked ? .concentric : self
        case .batteryBar: self == .concentric ? .stacked : self
        case .none: self
        }
    }
}

nonisolated extension MenuBarQuotaSelection {
    func settingGaugeStyle(_ style: MenuBarStyle) -> Self {
        guard let arrangement else { return self }
        var selected = self
        if style == .none { selected.gaugeIDs = [] }
        selected.arrangement = arrangement.settingLayout(
            arrangement.gaugeLayout.adapted(to: style), selection: selected)
        return selected
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
        var updated = menuBarQuotaPreferences
        var selected = selection
        selected.arrangement = selection.arrangement.flatMap { $0.isValid ? $0.resolved(selection: selection) : nil }
        if let arrangement = selected.arrangement {
            selected.percentageIDs = arrangement.orderedIDs.filter { selection.percentageIDs.contains($0) }
            selected.resetIDs = arrangement.orderedIDs.filter { selection.resetIDs.contains($0) }
            selected.gaugeIDs = arrangement.orderedIDs.filter { selection.gaugeIDs.contains($0) }
        }
        let previousGauge = updated.gauges?[provider.rawValue]
        let gauge = MenuBarGaugeSelection(
            ids: selected.gaugeIDs,
            titles: selected.titles,
            layout: selected.arrangement?.gaugeLayout ?? previousGauge?.layout
                ?? MenuBarGaugeLayout.legacy(menuBarDisplayConfig(for: provider)?.style ?? .none),
            showsLabels: previousGauge?.showsLabels)
        updated.providers[provider.rawValue] = selected
        var gauges = updated.gauges ?? [:]
        gauges[provider.rawValue] = gauge
        updated.gauges = gauges
        if updated != menuBarQuotaPreferences { menuBarQuotaPreferences = updated }
    }

    func setMenuBarGaugeSelection(_ selection: MenuBarGaugeSelection, for provider: AppProviderKind) {
        guard provider != .antigravity else { return }
        var updated = menuBarQuotaPreferences
        var gauges = updated.gauges ?? [:]
        gauges[provider.rawValue] = selection
        updated.gauges = gauges
        if var quota = updated.providers[provider.rawValue], let ids = selection.ids {
            quota.gaugeIDs = ids
            quota.titles.merge(selection.titles) { _, gauge in gauge }
            quota.arrangement = quota.arrangement?.settingLayout(selection.layout, selection: quota)
            updated.providers[provider.rawValue] = quota
        }
        if updated != menuBarQuotaPreferences { menuBarQuotaPreferences = updated }
    }
}
