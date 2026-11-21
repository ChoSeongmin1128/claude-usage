import Foundation

nonisolated struct MenuBarQuotaProjection {
    let selection: MenuBarQuotaSelection
    let limits: [UsageLimit]
    let basis: UsageValueBasis
    let timeFormat: TimeFormatStyle
    var weeklyResetIDs: Set<String> = []
    var availability: QuotaAvailability = .empty
    var showsGauges = true

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

    var gauges: [MenuBarGaugeValue] { selection.gaugeIDs.map { gaugeValue(for: $0) } }

    func gaugeValue(for id: String) -> MenuBarGaugeValue {
        let item = limit(id)
        return MenuBarGaugeValue(
            id: id, title: item?.shortTitle ?? selection.titles[id] ?? "한도",
            usedPercentage: item?.usedPercentage, basis: basis, indicator: availability[id]?.indicator)
    }

    var hasSelectedIndicators: Bool { selection.selectedIDs.contains { availability[$0]?.indicator != nil } }

    func displayedPercentage(for id: String) -> String? {
        guard let indicator = availability[id]?.indicator else { return percentageText(for: id) }
        return drawsGauge(for: id) ? nil : indicator.glyph
    }

    func percentageText(for id: String) -> String {
        guard let limit = limit(id), let used = limit.usedPercentage else {
            return "\(selection.titles[id] ?? "한도") 데이터 없음"
        }
        return basis.text(fromUsed: used)
    }

    private func drawsGauge(for id: String) -> Bool { showsGauges && selection.gaugeIDs.contains(id) }

    func resetText(for id: String) -> String? {
        if let status = availability[id] {
            if let recovery = status.automaticRecovery, let date = recovery.resetAt {
                return TimeFormatter.formatResetTime(
                    from: date, isWeekly: (recovery.periodSeconds ?? 0) >= 86_400, style: timeFormat,
                    includeDateIfNotToday: false)
            }
            return drawsGauge(for: id) || selection.percentageIDs.contains(id) ? nil : status.indicator?.glyph
        }
        guard let limit = limit(id), let date = limit.resetAt else { return nil }
        return TimeFormatter.formatResetTime(
            from: date, isWeekly: (limit.periodSeconds ?? 0) >= 86_400 || weeklyResetIDs.contains(id),
            style: timeFormat, includeDateIfNotToday: false)
    }

    var percentageText: String {
        selection.percentageIDs.compactMap { displayedPercentage(for: $0) }.joined(separator: "·")
    }

    var resetText: String? {
        let text = selection.resetIDs.compactMap { resetText(for: $0) }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    var tooltip: String {
        let observed = Set(limits.map(\.id))
        let ids = limits.map(\.id) + selection.selectedIDs.subtracting(observed).sorted()
        let readings = ids.map { id in
            guard let limit = limit(id), let used = limit.usedPercentage else {
                return "\(selection.titles[id] ?? "한도"): 데이터 없음"
            }
            return "\(limit.title): \(basis.text(fromUsed: used)) \(basis.label)"
        }
        return (readings + [availability.detail(timeFormat: timeFormat)].compactMap { $0 }).joined(separator: "\n")
    }

    var visualValues: [Double] {
        selection.selectedIDs.sorted().map { limit($0)?.usedPercentage ?? -1 }
    }
}

extension MenuBarQuotaProjection {
    init(
        config: ProviderMenuBarDisplayConfig, limits: [UsageLimit], codexUsage: CodexUsageResponse? = nil,
        availability: QuotaAvailability = .empty
    ) {
        self.init(
            selection: config.resolvedQuotaSelection(limits: limits, codexUsage: codexUsage),
            limits: limits, basis: config.usageValueBasis, timeFormat: config.timeFormat,
            availability: availability, showsGauges: config.style != .none)
        if let slot = codexUsage?.weeklyWindowWithSourceSlot?.slot {
            weeklyResetIDs = Set(limits.filter { $0.scope == "general" && $0.windowSlot == slot }.map(\.id))
        }
    }
}
