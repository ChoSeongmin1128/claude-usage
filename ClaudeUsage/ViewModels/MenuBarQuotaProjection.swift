import Foundation

nonisolated struct MenuBarQuotaProjection {
    let selection: MenuBarQuotaSelection
    let limits: [UsageLimit]
    let basis: UsageValueBasis
    let timeFormat: TimeFormatStyle
    var weeklyResetIDs: Set<String> = []

    static func legacyPercentageText(
        session: Double?, weekly: Double?, hasSession: Bool,
        display: PercentageDisplay, basis: UsageValueBasis
    ) -> String {
        let primary = basis.text(fromUsed: hasSession ? session : weekly)
        let weeklyText = basis.text(fromUsed: weekly)
        switch display {
        case .none: return ""
        case .fiveHour: return primary
        case .weekly: return weeklyText
        case .dual:
            guard hasSession, weekly != nil else { return hasSession ? primary : weeklyText }
            return "\(primary)·\(weeklyText)"
        }
    }

    static func legacyTooltip(session: Double?, weekly: Double?, basis: UsageValueBasis) -> String {
        let parts = [
            session.map { "5시간 \(basis.text(fromUsed: $0))" },
            weekly.map { "주간 \(basis.text(fromUsed: $0))" },
        ].compactMap { $0 }
        return parts.isEmpty ? "데이터 없음" : parts.joined(separator: " · ") + " \(basis.label)"
    }

    func limit(_ id: String?) -> UsageLimit? {
        id.flatMap { id in limits.first { $0.id == id && $0.isIdentifiable } }
    }

    var primary: UsageLimit? { limit(selection.gaugeIDs.first) }
    var secondary: UsageLimit? { limit(selection.gaugeIDs.dropFirst().first) }

    var gauges: [MenuBarGaugeValue] {
        selection.gaugeIDs.map { id in
            let item = limit(id)
            return MenuBarGaugeValue(
                id: id, title: item?.shortTitle ?? selection.titles[id] ?? "한도",
                usedPercentage: item?.usedPercentage, basis: basis)
        }
    }

    func percentageText(for id: String) -> String {
        guard let limit = limit(id), let used = limit.usedPercentage else {
            return "\(selection.titles[id] ?? "한도") 데이터 없음"
        }
        return basis.text(fromUsed: used)
    }

    func resetText(for id: String) -> String? {
        guard let limit = limit(id), let date = limit.resetAt else { return nil }
        return TimeFormatter.formatResetTime(
            from: date, isWeekly: (limit.periodSeconds ?? 0) >= 86_400 || weeklyResetIDs.contains(id),
            style: timeFormat, includeDateIfNotToday: false)
    }

    var percentageText: String {
        selection.percentageIDs.map { percentageText(for: $0) }.joined(separator: "·")
    }

    var resetText: String? {
        let text = selection.resetIDs.compactMap { resetText(for: $0) }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    var tooltip: String {
        let observed = Set(limits.map(\.id))
        let ids = limits.map(\.id) + selection.selectedIDs.subtracting(observed).sorted()
        return ids.map { id in
            guard let limit = limit(id), let used = limit.usedPercentage else {
                return "\(selection.titles[id] ?? "한도"): 데이터 없음"
            }
            return "\(limit.title): \(basis.text(fromUsed: used)) \(basis.label)"
        }.joined(separator: "\n")
    }

    var visualValues: [Double] {
        selection.selectedIDs.sorted().map { limit($0)?.usedPercentage ?? -1 }
    }
}

extension MenuBarQuotaProjection {
    init(config: ProviderMenuBarDisplayConfig, limits: [UsageLimit], codexUsage: CodexUsageResponse? = nil) {
        self.init(
            selection: config.resolvedQuotaSelection(limits: limits, codexUsage: codexUsage),
            limits: limits, basis: config.usageValueBasis, timeFormat: config.timeFormat)
        if let slot = codexUsage?.weeklyWindowWithSourceSlot?.slot {
            weeklyResetIDs = Set(limits.filter { $0.scope == "general" && $0.windowSlot == slot }.map(\.id))
        }
    }
}
