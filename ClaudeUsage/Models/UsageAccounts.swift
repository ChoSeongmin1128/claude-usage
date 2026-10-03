import Foundation

/// 여러 계정 화면의 한 계정. 같은 계정이 여러 출처(기본 로그인, 다른 CLI 폴더, 앱의 웹 로그인)로
/// 보이면 한 줄로 합치고 배지를 함께 단다.
nonisolated enum UsageAccountBadge: String, Codable, CaseIterable, Sendable, Comparable {
    case inUse, cli, web

    var title: String {
        switch self {
        case .inUse: return "사용 중"
        case .cli: return "CLI"
        case .web: return "웹"
        }
    }

    func help(for service: PopoverService) -> String? {
        switch self {
        case .inUse:
            return service == .codex
                ? "CLI와 ChatGPT 앱이 함께 쓰는 기본 로그인(~/.codex)" : "기본 Claude Code 로그인"
        case .cli: return "다른 폴더의 \(service == .codex ? "Codex" : "Claude Code") 로그인"
        case .web: return "앱에 저장된 웹 로그인"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// 계정 하나가 어디서 왔는지. 같은 계정 판별은 계정 uuid와 조직(워크스페이스) id로 한다.
nonisolated struct UsageAccountSource: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case claudeWeb, claudeCodeDefault, claudeCodeDirectory, codexDefault, codexDirectory
    }

    let kind: Kind
    /// 웹 계정 id 또는 폴더 경로
    let reference: String

    var badge: UsageAccountBadge {
        switch kind {
        case .claudeCodeDefault, .codexDefault: return .inUse
        case .claudeCodeDirectory, .codexDirectory: return .cli
        case .claudeWeb: return .web
        }
    }
}

nonisolated struct UsageAccountIdentity: Hashable, Codable, Sendable {
    var accountID: String?
    var organizationID: String?
    var email: String?
    var organizationName: String?

    /// 계정과 조직이 모두 있어야 같은 계정으로 합친다. 확인하지 못하면 따로 보인다.
    var mergeKey: String? {
        guard let accountID, !accountID.isEmpty, let organizationID, !organizationID.isEmpty else { return nil }
        return "\(accountID)|\(organizationID)"
    }
}

nonisolated struct UsageAccountCandidate: Equatable, Sendable {
    let source: UsageAccountSource
    let identity: UsageAccountIdentity
}

nonisolated struct UsageAccount: Identifiable, Equatable, Sendable {
    /// 합친 계정에서도 바뀌지 않도록 가장 앞선 출처를 id로 쓴다.
    let id: String
    let service: PopoverService
    var identity: UsageAccountIdentity
    var sources: [UsageAccountSource]

    var badges: [UsageAccountBadge] { Array(Set(sources.map(\.badge))).sorted() }
    var isInUse: Bool { badges.contains(.inUse) }

    static func merge(_ candidates: [UsageAccountCandidate], service: PopoverService) -> [UsageAccount] {
        var result: [UsageAccount] = []
        var indexByKey: [String: Int] = [:]
        for candidate in candidates {
            if let key = candidate.identity.mergeKey, let index = indexByKey[key] {
                result[index].sources.append(candidate.source)
                result[index].identity.email = result[index].identity.email ?? candidate.identity.email
                result[index].identity.organizationName =
                    result[index].identity.organizationName ?? candidate.identity.organizationName
                continue
            }
            if let key = candidate.identity.mergeKey { indexByKey[key] = result.count }
            result.append(
                UsageAccount(
                    id: "\(candidate.source.kind.rawValue):\(candidate.source.reference)", service: service,
                    identity: candidate.identity, sources: [candidate.source]))
        }
        return result
    }
}

/// 사용자가 정한 계정 표시 방식. 계정 자체(로그인)는 각 제품이 가진다.
nonisolated struct UsageAccountPreferences: Codable, Equatable, Sendable {
    enum PopoverMode: String, Codable, CaseIterable, Sendable {
        case pick, featuredList, summaryRows

        /// 모르는 값(빠진 보기)은 골라 보기로 읽는다. 실패하면 설정 전체를 기본값으로 되돌리게 된다.
        init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .pick
        }

        var title: String {
            switch self {
            case .pick: return "골라 보기"
            case .featuredList: return "대표 카드와 목록"
            case .summaryRows: return "요약과 행"
            }
        }
    }

    var aliases: [String: String] = [:]
    var hidden: Set<String> = []
    var archived: Set<String> = []
    /// 처음 본 순서. 직접 정렬하면 이 순서를 바꾼다.
    var order: [String] = []
    var pinnedTop: String?
    var selected: [String: [String]] = [:]
    var popoverMode: PopoverMode = .pick
    var codexDirectories: [String] = []
    var claudeDirectories: [String] = []
    /// 웹 계정의 계정 uuid와 조직. 같은 계정을 실행 사이에도 한 줄로 합치려고 남긴다.
    var knownIdentities: [String: UsageAccountIdentity] = [:]
    /// 앱이 전환한 기본 로그인. 나중에 다른 프로그램이 되돌리면 알린다.
    var expectedDefault: [String: UsageAccountIdentity] = [:]
    /// 사용자가 메뉴바 계정을 직접 골랐는지. 고르기 전에는 Claude 앱 로그인을 먼저 메뉴바에 둔다.
    /// 이전 저장 값에 없는 키라 선택값으로 둔다(없는 키가 있으면 전체 디코딩이 실패한다).
    var menuBarAccountChosen: Bool?
    /// 여러 계정 화면과 다른 계정 조회를 켰는지. 기본은 단일 계정이다.
    var multiAccountEnabled: Bool?

    var isMultiAccountEnabled: Bool { multiAccountEnabled == true }

    static let key = AppIdentifiers.defaultsKey("usageAccounts")

    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    /// 사용 중 계정을 먼저, 고정한 계정을 그다음, 나머지는 처음 본 순서.
    func ordered(_ accounts: [UsageAccount]) -> [UsageAccount] {
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return accounts.sorted { lhs, rhs in
            if lhs.isInUse != rhs.isInUse { return lhs.isInUse }
            if (lhs.id == pinnedTop) != (rhs.id == pinnedTop) { return lhs.id == pinnedTop }
            return (rank[lhs.id] ?? Int.max) < (rank[rhs.id] ?? Int.max)
        }
    }

    mutating func remember(_ accounts: [UsageAccount]) {
        for account in accounts where !order.contains(account.id) { order.append(account.id) }
    }

    /// 골라 보기는 처음에 사용 중 계정과 다음 계정 하나를 보여주고, 고른 조합을 기억한다.
    func selection(for service: PopoverService, visible: [UsageAccount]) -> [String] {
        let ids = Set(visible.map(\.id))
        if let stored = selected[service.rawValue]?.filter(ids.contains), !stored.isEmpty { return stored }
        return Array(visible.prefix(2).map(\.id))
    }

    func displayName(for account: UsageAccount, among accounts: [UsageAccount]) -> String {
        if let alias = aliases[account.id], !alias.isEmpty { return alias }
        let email = account.identity.email ?? "이름 없는 계정"
        // 같은 이메일이 여러 조직에 있을 때만 조직 이름을 붙인다.
        let siblings = accounts.filter { $0.identity.email == account.identity.email }
        if siblings.count > 1, let organization = account.identity.organizationName {
            return "\(email) · \(organization)"
        }
        return email
    }
}

/// 계정마다 마지막 조회 결과. 두 번 연속 실패해야 "오래된 값"으로 보이고, 로그인 만료는 바로 보인다.
nonisolated struct UsageAccountState: Sendable {
    enum Status: Equatable, Sendable {
        case checking, current, stale, loginExpired, needsPermission, archived
    }

    var claudeUsage: ClaudeUsageResponse?
    var codexUsage: CodexUsageResponse?
    var fetchedAt: Date?
    var consecutiveFailures = 0
    var loginExpired = false
    var needsPermission = false

    func status(isArchived: Bool) -> Status {
        if isArchived { return .archived }
        if loginExpired { return .loginExpired }
        if needsPermission { return .needsPermission }
        if fetchedAt == nil { return .checking }
        return consecutiveFailures >= 2 ? .stale : .current
    }

    var fiveHourPercentage: Double? { claudeUsage?.fiveHour?.utilization ?? codexUsage?.sessionWindow?.utilization }
    var weeklyPercentage: Double? { claudeUsage?.sevenDay?.utilization ?? codexUsage?.weeklyWindow?.utilization }
    var lowestRemaining: Double? {
        [fiveHourPercentage, weeklyPercentage].compactMap { $0 }.map { 100 - $0 }.min()
    }
}
