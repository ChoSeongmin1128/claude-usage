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

        private enum CodingKeys: String, CodingKey {
            case id, label, clears, paused
            case resetsLeft = "resets_left"
            case startsAt = "starts_at"
            case endsAt = "ends_at"
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
        }
    }

    let eligible: Bool
    let atLimit: Bool
    let grants: [Grant]
    let exhaustedCount: Int

    private enum CodingKeys: String, CodingKey {
        case eligible, grants, exhausted
        case atLimit = "at_limit"
    }

    init(eligible: Bool, atLimit: Bool, grants: [Grant], exhaustedCount: Int = 0) {
        self.eligible = eligible
        self.atLimit = atLimit
        self.grants = grants
        self.exhaustedCount = exhaustedCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eligible = (try? container.decode(Bool.self, forKey: .eligible)) ?? false
        atLimit = (try? container.decode(Bool.self, forKey: .atLimit)) ?? false
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

    func availableCount(at now: Date = Date()) -> Int? {
        guard eligible, !grants.isEmpty || exhaustedCount > 0 else { return nil }
        var total = 0
        for grant in grants {
            guard grant.isActive(at: now) else { continue }
            guard let count = grant.resetsLeft else { return nil }
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }
}

private nonisolated struct ResetCreditDecodingSink: Decodable {
    init(from decoder: Decoder) throws {}
}

/// 서비스와 무관하게 팝오버와 메뉴바가 쓰는 초기화권 요약.
nonisolated struct ResetCreditSummary: Equatable, Sendable {
    enum Scope: Sendable, Equatable {
        case all, fiveHourOnly

        var title: String { self == .all ? "전체 한도" : "5시간 한도만" }
    }

    struct Item: Equatable, Sendable {
        let id: String?
        let serverTitle: String?
        let scope: Scope
        let expiresAt: Date?
        var doesNotExpire = false
    }

    /// 만료가 빠른 순
    let items: [Item]
    let availableCount: Int
    let atLimit: Bool
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
        items.count >= availableCount && items.allSatisfy { $0.expiresAt != nil || $0.doesNotExpire }
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

    var scopeText: String {
        let scope = items.first?.scope.title ?? Scope.all.title
        return availableCount > 1 ? "\(scope) 외 \(availableCount - 1)개" : scope
    }

    static func claude(_ grants: ClaudeResetGrants?, now: Date = Date()) -> ResetCreditSummary? {
        guard let grants, let count = grants.availableCount(at: now) else { return nil }
        let usable = grants.grants.filter { grant in
            grant.isActive(at: now) && grant.resetsLeft.map({ $0 > 0 }) == true
        }
        let items = usable.map { grant in
            Item(
                id: grant.id, serverTitle: grant.label?.isEmpty == false ? grant.label : nil,
                scope: grant.clears.contains(where: { $0.hasPrefix("seven_day") }) ? .all : .fiveHourOnly,
                expiresAt: grant.endsAt)
        }
        return ResetCreditSummary(
            items: sorted(items), availableCount: count, atLimit: grants.atLimit)
    }

    static func codex(_ usage: CodexUsageResponse?, now: Date = Date()) -> ResetCreditSummary? {
        guard let usage, let credits = usage.resetCredits else { return nil }
        let count = credits.availableCount(at: now)
        guard count > 0 else { return nil }
        let items = credits.availableCredits(at: now).map { credit in
            Item(
                id: credit.id, serverTitle: credit.title, scope: .all,
                expiresAt: credit.expiresDate, doesNotExpire: credit.doesNotExpire)
        }
        let atLimit = [usage.primaryPercentage, usage.secondaryPercentage].contains { $0 >= 100 }
        return ResetCreditSummary(
            items: sorted(items), availableCount: count, atLimit: atLimit,
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
