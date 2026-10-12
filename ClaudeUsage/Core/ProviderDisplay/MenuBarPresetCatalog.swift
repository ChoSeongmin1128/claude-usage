import Foundation

@MainActor
enum MenuBarPresetCatalog {
    static func presets(for provider: AppProviderKind) -> [MenuBarBuiltinPreset] {
        MenuBarBuiltinPreset.allCases.filter { $0.supports(provider) }
    }

    static func catalogDisplay(_ preset: MenuBarBuiltinPreset, provider: AppProviderKind) -> CatalogMenuBarPresetDisplay
    {
        let style: MenuBarStyle =
            switch preset {
            case .number: .none
            case .battery: .batteryBar
            case .circle: .circular
            case .twoLimits: .sideBySideBattery
            case .concentric: .concentricRings
            }
        let config = ProviderMenuBarDisplayConfig(
            kind: provider, showIcon: true, style: style,
            percentageDisplay: preset == .number || preset == .circle ? .fiveHour : .none,
            showBatteryPercent: preset == .battery || preset == .twoLimits,
            resetTimeDisplay: .none, timeFormat: .h24, circularDisplayMode: .remaining, iconMetric: .fiveHour)
        return CatalogMenuBarPresetDisplay(config: config, resetCredits: preset == .number ? .always : .off)
    }

    static func antigravityDisplay(
        _ preset: MenuBarBuiltinPreset, quotaIDs: [String] = []
    ) -> AntigravityMenuBarPresetDisplay? {
        guard preset.supports(.antigravity) else { return nil }
        var menuBar = AntigravityDisplaySettings.default.menuBar
        menuBar.showsSelectedLaneResetTime = false
        menuBar.resetLaneIDs = []
        menuBar.additionalLaneIDs = []
        menuBar.showsGaugeLabels = false
        switch preset {
        case .number:
            menuBar.style = .none
            menuBar.gaugeLaneIDs = []
        case .battery:
            menuBar.style = .batteryBar
            menuBar.showsSelectedLanePercentage = false
            menuBar.percentageLaneIDs = []
        case .concentric:
            guard quotaIDs.count == 2, Set(quotaIDs).count == 2 else { return nil }
            let ids = quotaIDs.map { AntigravityQuotaLaneID(rawValue: $0) }
            guard ids.allSatisfy(\.hasStableDisplayIdentifierShape) else { return nil }
            menuBar.style = .circular
            menuBar.laneSelection = .fixed(ids[0])
            menuBar.showsSelectedLanePercentage = false
            menuBar.showsGaugePercentage = false
            menuBar.percentageLaneIDs = []
            menuBar.gaugeLaneIDs = ids
            menuBar.arrangement = MenuBarQuotaArrangement(
                orderedIDs: quotaIDs, gaugeGroups: [quotaIDs], gaugeLayout: .concentric)
        case .circle, .twoLimits: return nil
        }
        return AntigravityMenuBarPresetDisplay(menuBar)
    }

    static func matches(
        _ lhs: CatalogMenuBarPresetDisplay, _ rhs: CatalogMenuBarPresetDisplay,
        config: ProviderMenuBarDisplayConfig, limits: [UsageLimit], codexUsage: CodexUsageResponse?
    ) -> Bool {
        comparable(lhs, config: config, limits: limits, codexUsage: codexUsage)
            == comparable(rhs, config: config, limits: limits, codexUsage: codexUsage)
    }

    static func matches(_ lhs: AntigravityMenuBarPresetDisplay, _ rhs: AntigravityMenuBarPresetDisplay) -> Bool {
        var left = lhs
        var right = rhs
        left.gaugeTitles = nil
        right.gaugeTitles = nil
        return left == right
    }

    private static func comparable(
        _ value: CatalogMenuBarPresetDisplay, config: ProviderMenuBarDisplayConfig,
        limits: [UsageLimit], codexUsage: CodexUsageResponse?
    ) -> CatalogMenuBarPresetDisplay {
        let resolvedConfig = value.config(preserving: config)
        var selection = resolvedConfig.resolvedQuotaSelection(limits: limits, codexUsage: codexUsage)
        selection.titles = [:]
        if !selection.percentageIDs.isEmpty { selection.legacyPercentageDisplay = nil }
        if !selection.resetIDs.isEmpty { selection.legacyResetTimeDisplay = nil }
        selection.arrangement =
            (selection.arrangement
            ?? .baseline(
                selection: selection, layout: value.gauges?.layout ?? .legacy(value.style))).resolved(
                selection: selection)
        var result = value
        result.style = value.style.gaugeShape
        result.percentage = .none
        result.resetTime = .none
        result.iconMetric = .fiveHour
        result.gaugeNumber = value.style.isBatteryStyle && value.gaugeNumber
        result.selection = selection
        result.gauges = MenuBarGaugeSelection(showsLabels: value.gauges?.showsLabels == true)
        return result
    }
}
