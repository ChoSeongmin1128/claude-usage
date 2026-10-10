import Foundation

nonisolated struct MenuBarQuotaSelection: Codable, Equatable, Sendable {
    var percentageIDs: [String] = []
    var resetIDs: [String] = []
    var gaugeIDs: [String] = []
    var titles: [String: String] = [:]
    var arrangement: MenuBarQuotaArrangement? = nil
    var legacyPercentageDisplay: PercentageDisplay? = nil
    var legacyResetTimeDisplay: ResetTimeDisplay? = nil

    private enum CodingKeys: String, CodingKey {
        case percentageIDs, resetIDs, gaugeIDs, titles, arrangement
        case legacyPercentageDisplay, legacyResetTimeDisplay
    }

    enum Surface: Equatable, Sendable { case percentage, reset, gauge }

    mutating func setSelected(_ selected: Bool, id: String, surface: Surface, title: String? = nil) {
        guard !id.isEmpty else { return }
        if selected, let title { titles[id] = title }
        var values = ids(for: surface)
        if selected {
            if !values.contains(id) { values.append(id) }
        } else {
            values.removeAll { $0 == id }
        }
        switch surface {
        case .percentage: percentageIDs = values
        case .reset: resetIDs = values
        case .gauge: gaugeIDs = values
        }
    }

    func ids(for surface: Surface) -> [String] {
        switch surface {
        case .percentage: percentageIDs
        case .reset: resetIDs
        case .gauge: gaugeIDs
        }
    }

    var selectedIDs: Set<String> { Set(percentageIDs + resetIDs + gaugeIDs) }
    var hasPercentageIntent: Bool {
        !percentageIDs.isEmpty || (legacyPercentageDisplay.map { $0 != .none } ?? false)
    }
    var hasResetIntent: Bool {
        !resetIDs.isEmpty || (legacyResetTimeDisplay.map { $0 != .none } ?? false)
    }

    static func legacy(
        config: ProviderMenuBarDisplayConfig, limits: [UsageLimit], codexUsage: CodexUsageResponse? = nil
    ) -> Self {
        let primary: UsageLimit?
        let weekly: UsageLimit?
        if config.kind == .codex {
            if let codexUsage {
                primary = codexUsage.sessionWindowWithSourceSlot.flatMap { selected in
                    limits.first { $0.scope == "general" && $0.windowSlot == selected.slot }
                }
                weekly = codexUsage.weeklyWindowWithSourceSlot.flatMap { selected in
                    limits.first { $0.scope == "general" && $0.windowSlot == selected.slot }
                }
            } else {
                primary = limits.first { $0.scope == "general" && $0.windowSlot == "primary" }
                weekly = limits.first { $0.scope == "general" && $0.windowSlot == "secondary" }
            }
        } else {
            primary = limits.first { $0.scope == "five_hour" }
            weekly = limits.first { $0.scope == "seven_day" }
        }
        let displayPrimary = primary ?? weekly
        var result = Self(
            titles: Dictionary(uniqueKeysWithValues: limits.map { ($0.id, $0.title) }),
            legacyPercentageDisplay: config.percentageDisplay == .none ? nil : config.percentageDisplay,
            legacyResetTimeDisplay: config.resetTimeDisplay == .none ? nil : config.resetTimeDisplay)
        let percentage =
            config.kind == .codex
            ? config.percentageDisplay.effectiveCodexSelection(usage: codexUsage) : config.percentageDisplay
        switch percentage {
        case .none: break
        case .fiveHour: result.percentageIDs = displayPrimary.map { [$0.id] } ?? []
        case .weekly: result.percentageIDs = weekly.map { [$0.id] } ?? []
        case .dual: result.percentageIDs = [primary, weekly].compactMap { $0?.id }
        }
        switch config.resetTimeDisplay {
        case .none: break
        case .fiveHour:
            var resetPrimary = config.kind == .codex ? displayPrimary : primary
            if config.kind == .codex, primary?.resetAt == nil, weekly?.resetAt != nil { resetPrimary = weekly }
            result.resetIDs = resetPrimary.map { [$0.id] } ?? []
        case .weekly: result.resetIDs = weekly.map { [$0.id] } ?? []
        case .dual: result.resetIDs = [primary, weekly].compactMap { $0?.id }
        }
        let gauge = config.iconMetric == .weekly ? weekly : displayPrimary
        if config.style == .none {
            result.gaugeIDs = []
        } else if config.style == .dualBattery || config.style == .sideBySideBattery || config.style == .concentricRings
        {
            result.gaugeIDs = [primary, weekly].compactMap { $0?.id }
        } else {
            result.gaugeIDs = gauge.map { [$0.id] } ?? []
        }
        return result
    }
}

nonisolated extension MenuBarQuotaSelection {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        percentageIDs = try container.decode([String].self, forKey: .percentageIDs)
        resetIDs = try container.decode([String].self, forKey: .resetIDs)
        gaugeIDs = try container.decode([String].self, forKey: .gaugeIDs)
        titles = try container.decode([String: String].self, forKey: .titles)
        let decoded = try? container.decode(MenuBarQuotaArrangement.self, forKey: .arrangement)
        arrangement = decoded.flatMap { $0.isValid ? $0 : nil }
        legacyPercentageDisplay = try? container.decode(PercentageDisplay.self, forKey: .legacyPercentageDisplay)
        legacyResetTimeDisplay = try? container.decode(ResetTimeDisplay.self, forKey: .legacyResetTimeDisplay)
    }
}

nonisolated struct MenuBarQuotaPreferences: Codable, Equatable, Sendable {
    static let key = AppIdentifiers.defaultsKey("menuBarQuotaSelection.v1")
    var version = 1
    var providers: [String: MenuBarQuotaSelection] = [:]
    var gauges: [String: MenuBarGaugeSelection]? = nil

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: key),
            let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1
        else { return Self() }
        return value
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

nonisolated struct MenuBarGaugeSelection: Codable, Equatable, Sendable {
    var ids: [String]? = nil
    var titles: [String: String] = [:]
    var layout: MenuBarGaugeLayout = .horizontal
    var showsLabels: Bool? = nil


}

nonisolated enum MenuBarGaugeLayout: String, Codable, Equatable, Sendable {
    case horizontal, stacked, concentric

    static func legacy(_ style: MenuBarStyle) -> Self {
        switch style {
        case .dualBattery: .stacked
        case .concentricRings: .concentric
        default: .horizontal
        }
    }
}

nonisolated struct MenuBarGaugeValue: Equatable, Sendable {
    let id: String
    let title: String
    let usedPercentage: Double?
    let basis: UsageValueBasis

    var percentage: Double? { basis.percentage(fromUsed: usedPercentage) }
}
