import Foundation

/// Claude 사용량 응답의 `cedar_ember`(한도 초기화권). 읽기만 하고 사용 요청은 보내지 않는다.
nonisolated struct ClaudeResetGrants: Decodable, Sendable, Equatable {
    struct Grant: Decodable, Sendable, Equatable {
        let id: String
        let label: String?
        let resetsLeft: Int
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
            id: String, label: String?, resetsLeft: Int, startsAt: Date?, endsAt: Date?, clears: [String], paused: Bool
        ) {
            self.id = id
            self.label = label
            self.resetsLeft = resetsLeft
            self.startsAt = startsAt
            self.endsAt = endsAt
            self.clears = clears
            self.paused = paused
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            label = (try? container.decodeIfPresent(String.self, forKey: .label)).flatMap { $0 }
            resetsLeft = max(0, (try? container.decode(Int.self, forKey: .resetsLeft)) ?? 0)
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
        let id: String
        let serverTitle: String?
        let scope: Scope
        let expiresAt: Date?
    }

    /// 만료가 빠른 순
    let items: [Item]
    let availableCount: Int
    let atLimit: Bool

    static let expiringWindow: TimeInterval = 48 * 3600

    var nextExpiry: Date? { items.compactMap(\.expiresAt).min() }

    func isExpiringSoon(now: Date = Date()) -> Bool {
        guard availableCount > 0, let expiry = nextExpiry else { return false }
        return expiry.timeIntervalSince(now) <= Self.expiringWindow
    }

    /// "2일 3시간 뒤 만료"처럼 남은 시간을 일과 시간으로 쓴다.
    func expiryText(now: Date = Date()) -> String? {
        guard let expiry = nextExpiry else { return nil }
        let hours = max(1, Int((expiry.timeIntervalSince(now) / 3600).rounded(.up)))
        let text = hours < 24 ? "\(hours)시간" : hours % 24 == 0 ? "\(hours / 24)일" : "\(hours / 24)일 \(hours % 24)시간"
        return "\(text) 뒤 만료"
    }

    var scopeText: String {
        let scope = items.first?.scope.title ?? Scope.all.title
        return availableCount > 1 ? "\(scope) 외 \(availableCount - 1)개" : scope
    }

    func hasNewItems(seen: Set<String>) -> Bool {
        availableCount > 0 && items.contains { !seen.contains($0.id) }
    }

    static func claude(_ grants: ClaudeResetGrants?, now: Date = Date()) -> ResetCreditSummary? {
        guard let grants, grants.eligible else { return nil }
        let usable = grants.grants.filter { grant in
            !grant.paused && grant.resetsLeft > 0 && (grant.startsAt.map { $0 <= now } ?? true)
                && (grant.endsAt.map { $0 > now } ?? true)
        }
        guard !usable.isEmpty || !grants.grants.isEmpty || grants.exhaustedCount > 0 else { return nil }
        let items = usable.map { grant in
            Item(
                id: grant.id, serverTitle: grant.label?.isEmpty == false ? grant.label : nil,
                scope: grant.clears.contains(where: { $0.hasPrefix("seven_day") }) ? .all : .fiveHourOnly,
                expiresAt: grant.endsAt)
        }
        return ResetCreditSummary(
            items: sorted(items), availableCount: usable.reduce(0) { $0 + $1.resetsLeft }, atLimit: grants.atLimit)
    }

    static func codex(_ usage: CodexUsageResponse?, now: Date = Date()) -> ResetCreditSummary? {
        guard let usage, let credits = usage.resetCredits else { return nil }
        let count = credits.availableCount(at: now)
        guard count > 0 else { return nil }
        var items = credits.availableCredits(at: now).enumerated().map { index, credit in
            Item(
                id: credit.id ?? "codex-credit-\(index)", serverTitle: credit.title, scope: .all,
                expiresAt: credit.expiresDate)
        }
        if items.isEmpty {
            // 개수만 알 때는 개수로 신규 여부를 판단한다.
            items = [Item(id: "codex-count-\(count)", serverTitle: nil, scope: .all, expiresAt: nil)]
        }
        let atLimit = [usage.primaryPercentage, usage.secondaryPercentage].contains { $0 >= 100 }
        return ResetCreditSummary(items: sorted(items), availableCount: count, atLimit: atLimit)
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
        summary: ResetCreditSummary?, seen: Set<String>, mode: ResetCreditMenuBarMode, now: Date = Date()
    ) -> MenuBarResetCreditBadge? {
        guard mode != .off, let summary, summary.availableCount > 0 else { return nil }
        let tone: Tone =
            summary.isExpiringSoon(now: now) ? .expiring : summary.hasNewItems(seen: seen) ? .new : .normal
        guard mode == .always || tone != .normal else { return nil }
        return MenuBarResetCreditBadge(count: summary.availableCount, tone: tone)
    }
}

/// 팝오버에서 한 번 본 초기화권은 신규 표시를 끈다.
nonisolated enum ResetCreditSeenStore {
    static let key = AppIdentifiers.defaultsKey("seenResetCredits")

    static func seen(_ service: PopoverService, defaults: UserDefaults = .standard) -> Set<String> {
        Set((defaults.dictionary(forKey: key)?[service.rawValue] as? [String]) ?? [])
    }

    static func markSeen(_ summary: ResetCreditSummary?, service: PopoverService, defaults: UserDefaults = .standard) {
        guard let summary else { return }
        var all = defaults.dictionary(forKey: key) ?? [:]
        let ids = summary.items.map(\.id)
        guard Set(ids) != seen(service, defaults: defaults) else { return }
        all[service.rawValue] = ids
        defaults.set(all, forKey: key)
    }
}
