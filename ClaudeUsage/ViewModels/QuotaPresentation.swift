import Foundation

nonisolated extension QuotaIndicator {
    var glyph: String { self == .exhausted ? "!" : "?" }
}

nonisolated extension QuotaAvailability.Status {
    func detail(timeFormat: TimeFormatStyle, now: Date = Date()) -> String? {
        guard indicator != nil else { return nil }
        var lines = blockers.map { blocker in
            let exhaustion = blocker.limitID == nil ? blocker.title : "\(blocker.title) 소진"
            let reason = canUsePaidCredits ? exhaustion + " (추가 과금 가능)" : exhaustion
            guard let date = blocker.resetAt, date > now else { return reason }
            let reset = TimeFormatter.formatUsageResetDetail(
                resetAt: date, isWeekly: (blocker.periodSeconds ?? 0) >= 86_400,
                style: timeFormat, now: now, label: nil)
            return "\(reason) / 초기화 \(reset)"
        }
        if awaitingRefresh { lines.append("한도 초기화 확인 중") }
        return lines.joined(separator: "\n")
    }
}

nonisolated extension QuotaAvailability.Row {
    var titleSuffix: String {
        if isExhausted { return " 소진" }
        return status.indicator == .checking ? " 확인 중" : ""
    }
}

nonisolated extension QuotaAvailability {
    func detail(timeFormat: TimeFormatStyle, now: Date = Date()) -> String? {
        Self.detail(for: affectedStatuses, timeFormat: timeFormat, now: now) ?? accountRestriction
    }

    static func detail(for statuses: [Status], timeFormat: TimeFormatStyle, now: Date = Date()) -> String? {
        var seen: Set<String> = []
        let details = statuses.compactMap { $0.detail(timeFormat: timeFormat, now: now) }
            .flatMap { $0.components(separatedBy: "\n") }
            .filter { seen.insert($0).inserted }
        return details.isEmpty ? nil : details.joined(separator: "\n")
    }
}
