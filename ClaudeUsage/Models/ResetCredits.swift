import Foundation

/// Claude 사용량 응답의 `cedar_ember`(한도 초기화권). 읽기만 하고 사용 요청은 보내지 않는다.
nonisolated struct ClaudeResetGrants: Decodable, Sendable, Equatable {
    struct Grant: Decodable, Sendable, Equatable {
        let id: String
        let label: String?
        let resetsLeft: Int?
        let startsAt: Date?
        let endsAt: Date?
        let clears: [String]
        let paused: Bool
        var givesBackWeekly = false

        private enum CodingKeys: String, CodingKey {
            case id, label, clears, paused
            case resetsLeft = "resets_left"
            case startsAt = "starts_at"
            case endsAt = "ends_at"
            case givesBackWeekly = "gives_back_weekly"
        }

        init(
            id: String, label: String?, resetsLeft: Int?, startsAt: Date?, endsAt: Date?, clears: [String], paused: Bool
        ) {
            self.id = id
            self.label = label
            self.resetsLeft = resetsLeft.flatMap { $0 >= 0 ? $0 : nil }
            self.startsAt = startsAt
            self.endsAt = endsAt
            self.clears = clears
            self.paused = paused
        }

        nonisolated func isActive(at now: Date) -> Bool {
            !paused && (startsAt.map { $0 <= now } ?? true) && (endsAt.map { $0 > now } ?? true)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            label = (try? container.decodeIfPresent(String.self, forKey: .label)).flatMap { $0 }
            resetsLeft = (try? container.decode(Int.self, forKey: .resetsLeft)).flatMap { $0 >= 0 ? $0 : nil }
            func date(_ key: CodingKeys) -> Date? {
                (try? container.decodeIfPresent(String.self, forKey: key)).flatMap { $0 }.flatMap(
                    TimeFormatter.parseISO8601)
            }
            startsAt = date(.startsAt)
            endsAt = date(.endsAt)
            clears = (try? container.decode([String].self, forKey: .clears)) ?? []
            paused = (try? container.decode(Bool.self, forKey: .paused)) ?? false
            givesBackWeekly = (try? container.decode(Bool.self, forKey: .givesBackWeekly)) == true
        }
    }

    let eligible: Bool
    let grants: [Grant]
    let exhaustedCount: Int

    private enum CodingKeys: String, CodingKey {
        case eligible, grants, exhausted
    }

    init(eligible: Bool, grants: [Grant], exhaustedCount: Int = 0) {
        self.eligible = eligible
        self.grants = grants
        self.exhaustedCount = exhaustedCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eligible = (try? container.decode(Bool.self, forKey: .eligible)) ?? false
        var grants: [Grant] = []
        if var array = try? container.nestedUnkeyedContainer(forKey: .grants) {
            while !array.isAtEnd {
                if let grant = try? array.decode(Grant.self) {
                    grants.append(grant)
                } else if (try? array.decode(ResetCreditDecodingSink.self)) == nil {
                    break
                }
            }
        }
        self.grants = grants
        var exhausted = 0
        if var array = try? container.nestedUnkeyedContainer(forKey: .exhausted) {
            while !array.isAtEnd, (try? array.decode(ResetCreditDecodingSink.self)) != nil { exhausted += 1 }
        }
        exhaustedCount = exhausted
    }

    func availableCount(at now: Date = Date()) -> Int? { inventory(at: now)?.count }

    func inventory(at now: Date) -> (grants: [Grant], count: Int)? {
        guard eligible, !grants.isEmpty || exhaustedCount > 0 else { return nil }
        var active: [Grant] = []
        var byID: [String: Grant] = [:]
        var total = 0
        for grant in grants where grant.isActive(at: now) {
            if let previous = byID[grant.id] {
                guard previous == grant else { return nil }
                continue
            }
            byID[grant.id] = grant
            guard let count = grant.resetsLeft else { return nil }
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow else { return nil }
            total = next
            if count > 0 { active.append(grant) }
        }
        return (active, total)
    }
}

private nonisolated struct ResetCreditDecodingSink: Decodable {
    init(from decoder: Decoder) throws {}
}

/// 서비스와 무관하게 팝오버와 메뉴바가 쓰는 초기화권 요약.
nonisolated struct ResetCreditSummary: Equatable, Sendable {
    enum Window: Hashable, Sendable {
        case fiveHour, weekly

        var periodSeconds: Int {
            switch self {
            case .fiveHour: UsageWindowLength.fiveHour
            case .weekly: UsageWindowLength.weekly
            }
        }
    }

    enum Effect: Hashable, Sendable {
        case refill(Window)
        case returnWeeklyModelUsage(String)
    }

    struct Scope: Hashable, Sendable {
        let effects: Set<Effect>
        var hasUnknownEffects = false

        static let fiveHourAndWeekly = Self(effects: [.refill(.fiveHour), .refill(.weekly)])
        static let unknown = Self(effects: [], hasUnknownEffects: true)

        static func claude(_ grant: ClaudeResetGrants.Grant, hasSessionWindow: Bool?) -> Self {
            let clears = Set(grant.clears)
            var effects: Set<Effect> = []
            if clears.contains("five_hour"), hasSessionWindow != false { effects.insert(.refill(.fiveHour)) }
            if clears.contains("seven_day"), !grant.givesBackWeekly { effects.insert(.refill(.weekly)) }

            // The observed Fable offer identifies the model in the label; a
            // weekly credit adjustment alone does not identify a model.
            let namesFable =
                grant.label?.range(of: #"\bfable\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            let returnsFableUsage = grant.givesBackWeekly && namesFable
            if returnsFableUsage {
                effects.insert(.returnWeeklyModelUsage("Fable"))
            }
            let knownKeys: Set<String> = ["five_hour", "seven_day", "seven_day_overage_included"]
            return Self(
                effects: effects,
                hasUnknownEffects: effects.isEmpty || !clears.isSubset(of: knownKeys)
                    || (grant.givesBackWeekly && !returnsFableUsage)
                    || (clears.contains("seven_day_overage_included") && !clears.contains("seven_day")
                        && !returnsFableUsage)
            )
        }

        static func codex(_ type: String?, hasSessionWindow: Bool) -> Self {
            guard type == "codexRateLimits" || type == "codex_rate_limits" else { return .unknown }
            return hasSessionWindow ? .fiveHourAndWeekly : Self(effects: [.refill(.weekly)])
        }
    }

    struct Item: Equatable, Sendable {
        let id: String?
        let serverTitle: String?
        let scope: Scope
        let expiresAt: Date?
        var doesNotExpire = false
        var count = 1
    }

    /// 만료가 빠른 순
    let items: [Item]
    let availableCount: Int
    var identityDetailsComplete = true
    var detailMetadata: CodexResetCreditMetadata? = nil

    static let expiringWindow: TimeInterval = 48 * 3600

    var nextExpiry: Date? { items.compactMap(\.expiresAt).min() }

    func isExpiringSoon(now: Date = Date()) -> Bool {
        guard detailMetadata?.isCurrent != false, availableCount > 0, let expiry = nextExpiry else { return false }
        return expiry.timeIntervalSince(now) <= Self.expiringWindow
    }

    /// "2일 3시간 뒤 만료"처럼 남은 시간을 일과 시간으로 쓴다.
    func expiryText(now: Date = Date()) -> String? {
        guard let expiry = nextExpiry else { return nil }
        let hours = max(1, Int((expiry.timeIntervalSince(now) / 3600).rounded(.up)))
        let text = hours < 24 ? "\(hours)시간" : hours % 24 == 0 ? "\(hours / 24)일" : "\(hours / 24)일 \(hours % 24)시간"
        return "\(text) 뒤 만료"
    }

    var hasCompleteExpirationDetails: Bool {
        items.reduce(0) { $0 + $1.count } >= availableCount
            && items.allSatisfy { $0.expiresAt != nil || $0.doesNotExpire }
    }

    func expirationDescription(now: Date = Date()) -> String {
        if let notice = detailMetadata?.notice {
            if let text = expiryText(now: now) { return notice + " / " + text }
            return notice
        }
        if let text = expiryText(now: now) { return text }
        if availableCount > 0, hasCompleteExpirationDetails, items.allSatisfy(\.doesNotExpire) {
            return "만료 없음"
        }
        return "만료 정보 없음"
    }

    static func claude(_ usage: ClaudeUsageResponse?, now: Date = Date()) -> ResetCreditSummary? {
        claude(
            usage?.resetGrants,
            hasSessionWindow: usage?.hasMalformedSessionWindow == true ? nil : usage?.hasSessionWindow, now: now)
    }

    static func claude(
        _ grants: ClaudeResetGrants?, hasSessionWindow: Bool? = nil, now: Date = Date()
    ) -> ResetCreditSummary? {
        guard let inventory = grants?.inventory(at: now) else { return nil }
        let items = inventory.grants.map { grant in
            Item(
                id: grant.id, serverTitle: grant.label?.isEmpty == false ? grant.label : nil,
                scope: .claude(grant, hasSessionWindow: hasSessionWindow),
                expiresAt: grant.endsAt, count: grant.resetsLeft ?? 0)
        }
        return ResetCreditSummary(
            items: sorted(items), availableCount: inventory.count)
    }

    static func codex(_ usage: CodexUsageResponse?, now: Date = Date()) -> ResetCreditSummary? {
        guard let usage, let credits = usage.resetCredits else { return nil }
        let count = credits.availableCount(at: now)
        guard count > 0 else { return nil }
        let items = credits.availableCredits(at: now).map { credit in
            Item(
                id: credit.id, serverTitle: credit.title,
                scope: .codex(credit.resetType, hasSessionWindow: usage.hasSessionWindow),
                expiresAt: credit.expiresDate, doesNotExpire: credit.doesNotExpire)
        }
        return ResetCreditSummary(
            items: sorted(items), availableCount: count,
            identityDetailsComplete: usage.resetCreditMetadata?.isCurrent != false
                && Set(items.compactMap(\.id)).count >= count,
            detailMetadata: usage.resetCreditMetadata)
    }

    private static func sorted(_ items: [Item]) -> [Item] {
        items.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }
}

nonisolated enum ResetCreditMenuBarMode: String, CaseIterable, Sendable {
    case always
    case newOrExpiring = "new_or_expiring"
    case off

    var title: String {
        switch self {
        case .always: return "항상"
        case .newOrExpiring: return "신규나 곧 만료일 때만"
        case .off: return "끔"
        }
    }
}

nonisolated struct MenuBarResetCreditBadge: Equatable, Sendable {
    enum Tone: String, Sendable { case normal, new, expiring }

    let count: Int
    let tone: Tone

    static let symbol = "↺"

    var text: String { "\(Self.symbol)\(count)" }
    var key: String { "\(text).\(tone.rawValue)" }

    /// 곧 만료(48시간)가 신규보다 우선이다. 0개면 그리지 않는다.
    static func resolve(
        summary: ResetCreditSummary?, isNew: Bool, mode: ResetCreditMenuBarMode, now: Date = Date()
    ) -> MenuBarResetCreditBadge? {
        guard mode != .off, let summary, summary.availableCount > 0 else { return nil }
        let tone: Tone =
            summary.isExpiringSoon(now: now) ? .expiring : isNew ? .new : .normal
        guard mode == .always || tone != .normal else { return nil }
        return MenuBarResetCreditBadge(count: summary.availableCount, tone: tone)
    }
}
