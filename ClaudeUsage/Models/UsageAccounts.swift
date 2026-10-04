import Foundation

/// 계정 하나가 어디서 왔는지. 같은 계정이 여러 출처(기본 로그인, 다른 CLI 폴더, 앱의 웹 로그인)로 보이면
/// 한 줄로 합치고 배지를 함께 단다.
nonisolated struct UsageAccountSource: Hashable, Sendable {
    enum Role: String, CaseIterable, Comparable, Sendable {
        case defaultLogin, directory, web

        var badgeTitle: String {
            switch self {
            case .defaultLogin: return "기본 로그인"
            case .directory: return "CLI"
            case .web: return "웹"
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    let role: Role
    /// 웹 로그인 id 또는 폴더 경로
    let reference: String
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

    func isSameAccount(as other: Self) -> Bool {
        if let key = mergeKey, let otherKey = other.mergeKey { return key == otherKey }
        guard let email, let otherEmail = other.email else { return false }
        return email.caseInsensitiveCompare(otherEmail) == .orderedSame
    }
}

nonisolated struct UsageAccountCandidate: Equatable, Sendable {
    let source: UsageAccountSource
    let identity: UsageAccountIdentity
}

nonisolated struct UsageAccount: Identifiable, Equatable, Sendable {
    /// 계정이 확인되면 계정 기준이라 기본 로그인을 전환해도 이름, 숨김, 조회 결과가 계정을 따라간다.
    /// 확인하지 못한 계정만 출처 기준이다.
    let id: String
    let service: PopoverService
    var identity: UsageAccountIdentity
    var sources: [UsageAccountSource]

    var roles: [UsageAccountSource.Role] { Array(Set(sources.map(\.role))).sorted() }
    var isDefaultLogin: Bool { sources.contains { $0.role == .defaultLogin } }

    func source(_ role: UsageAccountSource.Role) -> UsageAccountSource? {
        sources.first { $0.role == role }
    }

    static func id(service: PopoverService, identity: UsageAccountIdentity, source: UsageAccountSource) -> String {
        if let key = identity.mergeKey { return "\(service.rawValue):\(key)" }
        return "\(service.rawValue):\(source.role.rawValue):\(source.reference)"
    }

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
                    id: id(service: service, identity: candidate.identity, source: candidate.source),
                    service: service, identity: candidate.identity, sources: [candidate.source]))
        }
        return result
    }
}

/// 사용자가 정한 계정 표시 방식. 계정 자체(로그인)는 각 제품이 가진다.
/// 키가 빠진 이전 저장값도 읽히도록 항목마다 기본값으로 읽는다.
nonisolated struct UsageAccountPreferences: Codable, Equatable, Sendable {
    enum PopoverMode: String, Codable, CaseIterable, Sendable {
        case pick, featuredList, summaryRows

        var title: String {
            switch self {
            case .pick: return "골라 보기"
            case .featuredList: return "대표 카드와 목록"
            case .summaryRows: return "요약과 목록"
            }
        }
    }

    /// 서비스마다 따로 정하는 값
    struct ServiceSettings: Codable, Equatable, Sendable {
        var isMultiAccountEnabled = false
        var popoverMode: PopoverMode = .pick
        /// 골라 보기에서 고른 계정
        var selected: [String] = []
        var pinnedTop: String?
        /// 사용자가 추가한 CLI 폴더
        var directories: [String] = []
        /// 앱이 전환한 기본 로그인. 나중에 다른 프로그램이 되돌리면 알린다.
        var expectedDefault: UsageAccountIdentity?
        /// 메뉴바 계정을 사용자가 정했는지. 정하기 전에는 서비스가 정한 기본 계정을 메뉴바에 둔다.
        var isMenuBarAccountChosen = false

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Self()
            isMultiAccountEnabled = container.value(.isMultiAccountEnabled, default: defaults.isMultiAccountEnabled)
            popoverMode = container.value(.popoverMode, default: defaults.popoverMode)
            selected = container.value(.selected, default: defaults.selected)
            pinnedTop = container.value(.pinnedTop, default: defaults.pinnedTop)
            directories = container.value(.directories, default: defaults.directories)
            expectedDefault = container.value(.expectedDefault, default: defaults.expectedDefault)
            isMenuBarAccountChosen = container.value(.isMenuBarAccountChosen, default: defaults.isMenuBarAccountChosen)
        }
    }

    private var services: [String: ServiceSettings] = [:]
    var aliases: [String: String] = [:]
    var hidden: Set<String> = []
    var archived: Set<String> = []
    /// 처음 본 순서
    var order: [String] = []
    /// 웹 로그인의 계정 uuid와 조직. 같은 계정을 실행 사이에도 한 줄로 합치려고 남긴다.
    var knownIdentities: [String: UsageAccountIdentity] = [:]

    static let key = AppIdentifiers.defaultsKey("usageAccounts")

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        services = container.value(.services, default: [:])
        aliases = container.value(.aliases, default: [:])
        hidden = container.value(.hidden, default: [])
        archived = container.value(.archived, default: [])
        order = container.value(.order, default: [])
        knownIdentities = container.value(.knownIdentities, default: [:])
    }

    subscript(service: PopoverService) -> ServiceSettings {
        get { services[service.rawValue] ?? ServiceSettings() }
        set { services[service.rawValue] = newValue }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    /// 고정한 계정을 먼저, 나머지는 처음 본 순서
    func ordered(_ accounts: [UsageAccount], service: PopoverService) -> [UsageAccount] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let pinned = self[service].pinnedTop
        return accounts.sorted { lhs, rhs in
            if (lhs.id == pinned) != (rhs.id == pinned) { return lhs.id == pinned }
            return (rank[lhs.id] ?? Int.max) < (rank[rhs.id] ?? Int.max)
        }
    }

    mutating func remember(_ accounts: [UsageAccount]) {
        var known = Set(order)
        for account in accounts where known.insert(account.id).inserted { order.append(account.id) }
    }

    /// 골라 보기는 처음에 메뉴바 계정과 다음 계정 하나를 보여주고, 고른 조합을 기억한다.
    func selection(for service: PopoverService, visible: [UsageAccount]) -> [String] {
        let ids = Set(visible.map(\.id))
        let stored = self[service].selected.filter(ids.contains)
        return stored.isEmpty ? Array(visible.prefix(2).map(\.id)) : stored
    }

    func displayName(for account: UsageAccount, among accounts: [UsageAccount]) -> String {
        if let alias = aliases[account.id], !alias.isEmpty { return alias }
        let email = account.identity.email ?? "이름 없는 계정"
        // 같은 이메일이 여러 조직에 있을 때만 조직 이름을 붙인다.
        let siblings = accounts.filter { $0.identity.email == account.identity.email }
        if siblings.count > 1, let organization = account.identity.organizationName {
            return "\(email) (\(organization))"
        }
        return email
    }
}

nonisolated private extension KeyedDecodingContainer {
    /// 키가 없거나 모양이 다르면 기본값으로 읽는다. 한 항목 때문에 설정 전체가 초기화되지 않게 한다.
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

/// 한도 두 가지(5시간, 주간)만 서비스와 관계없이 같은 모양으로 담는다.
nonisolated struct UsageAccountUsage: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        let usedPercent: Double
        let resetsAt: Date?
    }

    var fiveHour: Window?
    var weekly: Window?

    var lowestRemainingPercent: Double? {
        [fiveHour, weekly].compactMap { $0.map { 100 - $0.usedPercent } }.min()
    }
}

/// 계정마다 마지막 조회 결과.
nonisolated struct UsageAccountState: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case checking, current, stale, failed, loginExpired, needsPermission, executableNotFound, archived
    }

    enum Issue: Equatable, Sendable {
        case loginExpired, needsPermission, executableNotFound
    }

    /// 실패가 이만큼 이어져야 이전 값으로 표시한다. 로그인 만료는 바로 표시한다.
    static let staleAfterFailures = 2

    var usage: UsageAccountUsage?
    /// 마지막으로 성공한 시각
    var fetchedAt: Date?
    /// 마지막으로 조회를 시작한 시각
    var attemptedAt: Date?
    var consecutiveFailures = 0
    var issue: Issue?

    func status(isArchived: Bool) -> Status {
        if isArchived { return .archived }
        switch issue {
        case .loginExpired: return .loginExpired
        case .needsPermission: return .needsPermission
        case .executableNotFound: return .executableNotFound
        case nil: break
        }
        guard usage != nil else { return consecutiveFailures > 0 ? .failed : .checking }
        return consecutiveFailures >= Self.staleAfterFailures ? .stale : .current
    }
}
