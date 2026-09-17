import Foundation

/// Verified quota data before any surface's visibility/order filters. Credit
/// balances and reset-credit counts intentionally have no adapter here.
nonisolated struct UsageLimit: Identifiable, Equatable, Sendable {
    let id: String
    let provider: PopoverService
    let title: String
    let shortTitle: String
    let scope: String
    let periodSeconds: Int?
    let usedPercentage: Double?
    let resetAt: Date?
    let isIdentifiable: Bool
    let legacyKey: String?

    var canNotify: Bool { isIdentifiable && usedPercentage != nil }

    func unavailable() -> Self {
        Self(
            id: id, provider: provider, title: title, shortTitle: shortTitle, scope: scope,
            periodSeconds: periodSeconds,
            usedPercentage: nil, resetAt: resetAt, isIdentifiable: isIdentifiable, legacyKey: legacyKey)
    }
}

nonisolated enum UsageLimitCatalog {
    static func claude(_ usage: ClaudeUsageResponse) -> [UsageLimit] {
        var result = [
            make(
                provider: .claude, scope: "five_hour", period: 18_000,
                title: "5시간", used: usage.fiveHour.utilization,
                reset: date(usage.fiveHour.resetsAt), legacy: "fiveHour")
        ]
        if let weekly = usage.sevenDay {
            result.append(
                make(
                    provider: .claude, scope: "seven_day", period: 604_800,
                    title: "주간", used: weekly.utilization, reset: date(weekly.resetsAt), legacy: "weekly"))
        }
        let models = usage.modelWeeklyWindows
        result += models.map { window in
            make(
                provider: .claude, scope: "model:\(window.sourceID ?? window.slug)", period: 604_800,
                title: "\(window.modelName) · 주간", shortTitle: window.modelName, used: window.utilization,
                reset: date(window.resetsAt),
                identifiable: window.sourceID != nil)
        }
        return checked(result)
    }

    static func codex(_ usage: CodexUsageResponse) -> [UsageLimit] {
        var result = codexWindows(usage.rateLimit, scope: "general", title: nil, identifiable: true, legacy: "base")
        for limit in usage.additionalRateLimits {
            let sourceID = nonempty(limit.meteredFeature)
            let name = nonempty(limit.limitName) ?? sourceID ?? "추가 한도"
            result += codexWindows(
                limit.rateLimit, scope: "model:\(sourceID ?? name)", title: name,
                identifiable: sourceID != nil, legacy: nil)
        }
        return checked(result)
    }

    static func antigravity(_ snapshot: AntigravityQuotaSnapshot) -> [UsageLimit] {
        checked(
            snapshot.lanes.map { lane in
                let scope: String
                switch lane.scope {
                case .gemini: scope = "Gemini"
                case .thirdPartyModels: scope = "Claude·GPT"
                case .unknown(let id, let label): scope = label ?? id
                }
                let period: Int?
                let cadence: String
                switch lane.cadence {
                case .fiveHour: period = 18_000; cadence = "5시간"
                case .weekly: period = 604_800; cadence = "주간"
                case .unknown(let raw): period = nil; cadence = raw
                }
                let used: Double? =
                    lane.availability == .available
                    ? lane.remainingFraction.flatMap { $0.isFinite && (0...1).contains($0) ? (1 - $0) * 100 : nil }
                    : nil
                return make(
                    provider: .antigravity, scope: lane.id.rawValue, period: period,
                    title: "\(scope) · \(cadence)", used: used, reset: lane.resetAt,
                    identifiable: lane.id.hasStableDisplayIdentifierShape, legacy: lane.id.rawValue)
            })
    }

    private static func codexWindows(
        _ limit: CodexRateLimit?, scope: String, title: String?,
        identifiable: Bool, legacy: String?
    ) -> [UsageLimit] {
        [("primary", limit?.primaryWindow), ("secondary", limit?.secondaryWindow)].compactMap { slot, window in
            guard let window else { return nil }
            let duration = window.limitWindowSeconds.flatMap { $0 > 0 ? $0 : nil }
            let period = duration.map(periodTitle) ?? (slot == "primary" ? "기본 한도 · 주기 미제공" : "보조 한도 · 주기 미제공")
            return make(
                provider: .codex, scope: scope, period: duration,
                unknownPeriodKey: slot,
                title: [title, period].compactMap { $0 }.joined(separator: " · "),
                used: window.usedPercent, reset: window.resetAt.map(Date.init(timeIntervalSince1970:)),
                identifiable: identifiable && (window.limitWindowSeconds == nil || duration != nil), legacy: legacy)
        }
    }

    static func periodTitle(_ seconds: Int) -> String {
        if seconds == 604_800 { return "주간" }
        if seconds % 86_400 == 0 { return "\(seconds / 86_400)일" }
        if seconds % 3_600 == 0 { return "\(seconds / 3_600)시간" }
        if seconds % 60 == 0 { return "\(seconds / 60)분" }
        return "\(seconds)초"
    }

    private static func make(
        provider: PopoverService, scope: String, period: Int?, unknownPeriodKey: String = "unknown",
        title: String, shortTitle: String? = nil, used: Double?, reset: Date?, identifiable: Bool = true,
        legacy: String? = nil
    ) -> UsageLimit {
        let id = ["quota-v1", provider.rawValue, scope, period.map(String.init) ?? unknownPeriodKey]
            .map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }.joined(separator: "/")
        return UsageLimit(
            id: id, provider: provider, title: title, shortTitle: shortTitle ?? title, scope: scope,
            periodSeconds: period,
            usedPercentage: used.flatMap { $0.isFinite && $0 >= 0 ? min(100, $0) : nil },
            resetAt: reset.flatMap { $0.timeIntervalSince1970.isFinite ? $0 : nil },
            isIdentifiable: identifiable, legacyKey: legacy)
    }

    /// Conflicting upstream IDs cannot share a persisted selection or alert history.
    private static func checked(_ limits: [UsageLimit]) -> [UsageLimit] {
        var result: [UsageLimit] = []
        let grouped = Dictionary(grouping: limits, by: \.id)
        var seen: Set<String> = []
        for limit in limits where seen.insert(limit.id).inserted {
            let matches = grouped[limit.id] ?? []
            guard let first = matches.first else { continue }
            if matches.count == 1 {
                result.append(first)
            } else {
                result.append(
                    UsageLimit(
                        id: first.id, provider: first.provider, title: first.title + " · 식별 충돌",
                        shortTitle: first.shortTitle, scope: first.scope, periodSeconds: first.periodSeconds,
                        usedPercentage: nil,
                        resetAt: nil, isIdentifiable: false, legacyKey: nil))
            }
        }
        return result
    }

    private static func nonempty(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
    private static func date(_ value: String?) -> Date? { value.flatMap(TimeFormatter.parseISO8601) }
}
