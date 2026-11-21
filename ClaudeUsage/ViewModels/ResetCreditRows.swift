import Foundation

/// Counts are reconciled before rendering. Details are optional and may arrive
/// after the authoritative count or describe the previous successful lookup.
nonisolated enum ResetCreditRows {
    struct Row: Equatable, Sendable {
        let title: String
        let count: Int
        let expiryText: String?
        let details: String?
        let isExpiring: Bool
        let helpsCurrentLimit: Bool
    }

    static func make(
        summary: ResetCreditSummary, availability: QuotaAvailability = .empty,
        now: Date = Date(), locale: Locale = Locale(identifier: "ko_KR"), timeZone: TimeZone = .current
    ) -> [Row] {
        var seenIDs: Set<String> = []
        let items = summary.items.filter { item in
            if let id = item.id { return seenIDs.insert(id).inserted }
            return true
        }
        let represented = items.reduce(0) { $0 + $1.count }
        guard summary.availableCount > 0, represented <= summary.availableCount else {
            return [unclassified(summary: summary, count: summary.availableCount)]
        }

        let groups = Dictionary(grouping: items, by: \.scope)
        var seenScopes: Set<ResetCreditSummary.Scope> = []
        let hasCurrentDetails = summary.detailMetadata?.isCurrent != false
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.timeZone = timeZone
        dateFormatter.setLocalizedDateFormatFromTemplate("MMMd")
        let rows = items.compactMap { item -> Row? in
            guard seenScopes.insert(item.scope).inserted, let group = groups[item.scope] else { return nil }
            let count = group.reduce(0) { $0 + $1.count }
            let expiry = group.compactMap(\.expiresAt).min()
            let expiryText =
                expiry.map { date in
                    let text = dateFormatter.string(from: date)
                    return count == 1 ? text + " 만료" : "다음 만료 " + text
                }
                ?? (group.allSatisfy(\.doesNotExpire) ? "만료 없음" : "만료 정보 없음")
            let helps =
                hasCurrentDetails
                && item.scope.effects.contains { effect in
                    guard case .refill(let window) = effect else { return false }
                    return availability.isExhausted(periodSeconds: window.periodSeconds)
                }
            let detail =
                [
                    item.scope.detail, summary.detailMetadata?.notice, hasCurrentDetails ? nil : expiryText,
                    helps ? "소진된 한도를 복구합니다" : nil,
                ].compactMap { $0 } + Array(Set(group.compactMap(\.serverTitle))).sorted()
            return Row(
                title: item.scope.title, count: count,
                expiryText: hasCurrentDetails ? expiryText : summary.detailMetadata?.notice,
                details: detail.isEmpty ? nil : detail.joined(separator: "\n"),
                isExpiring: hasCurrentDetails
                    && expiry.map { $0.timeIntervalSince(now) <= ResetCreditSummary.expiringWindow } == true,
                helpsCurrentLimit: helps)
        }
        let ordered = rows.filter(\.helpsCurrentLimit) + rows.filter { !$0.helpsCurrentLimit }
        let missing = summary.availableCount - represented
        return missing == 0 ? ordered : ordered + [unclassified(summary: summary, count: missing)]
    }

    private static func unclassified(summary: ResetCreditSummary, count: Int) -> Row {
        Row(
            title: count == 0 ? "초기화권" : "초기화권 상세 미확인", count: count,
            expiryText: summary.detailMetadata?.notice, details: nil,
            isExpiring: false, helpsCurrentLimit: false)
    }
}

nonisolated extension ResetCreditSummary.Scope {
    var title: String {
        if let model = returnedModel { return "\(model) 초기화권" }
        switch (effects.contains(.refill(.fiveHour)), effects.contains(.refill(.weekly))) {
        case (true, true): return "5시간 + 주간 초기화권"
        case (true, false): return "5시간 초기화권"
        case (false, true): return "주간 초기화권"
        case (false, false): return "범위 확인 안 됨"
        }
    }

    var detail: String? {
        var parts: [String] = []
        if let model = returnedModel {
            parts.append("\(model)에 쓴 주간 사용량 복구")
            if effects.contains(.refill(.fiveHour)) { parts.append("5시간 한도 전체 복구") }
        }
        if hasUnknownEffects, !effects.isEmpty { parts.append("일부 복구 범위 확인 안 됨") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var returnedModel: String? {
        effects.compactMap { effect in
            if case .returnWeeklyModelUsage(let model) = effect { return model }
            return nil
        }.sorted().first
    }
}
