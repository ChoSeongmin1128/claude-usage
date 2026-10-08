import Foundation

nonisolated struct MenuBarQuotaSelection: Codable, Equatable, Sendable {
    var percentageIDs: [String] = []
    var resetIDs: [String] = []
    var gaugeIDs: [String] = []
    var titles: [String: String] = [:]

    enum Surface { case percentage, reset, gauge }

    mutating func setSelected(_ selected: Bool, id: String, surface: Surface, limits: [UsageLimit]) {
        if selected {
            guard let limit = limits.first(where: { $0.id == id }), limit.isIdentifiable,
                limit.usedPercentage != nil
            else { return }
            titles[id] = limit.title
        }
        switch surface {
        case .percentage:
            percentageIDs.removeAll { $0 == id }
            if selected { percentageIDs.append(id) }
        case .reset:
            resetIDs.removeAll { $0 == id }
            if selected { resetIDs.append(id) }
        case .gauge:
            gaugeIDs.removeAll { $0 == id }
            if selected { gaugeIDs.append(id) }
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
        var result = Self(titles: Dictionary(uniqueKeysWithValues: limits.map { ($0.id, $0.title) }))
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

    mutating func move(_ id: String, by offset: Int) {
        guard var ids, let source = ids.firstIndex(of: id), ids.indices.contains(source + offset) else { return }
        ids.swapAt(source, source + offset)
        self.ids = ids
    }
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
