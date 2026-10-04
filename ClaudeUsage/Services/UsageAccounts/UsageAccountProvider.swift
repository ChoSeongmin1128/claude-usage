import Foundation

/// 여러 계정을 지원하는 서비스 하나. 컨트롤러와 설정 화면은 서비스 종류 대신 이 규약만 쓴다.
/// 서비스를 더할 때는 이 규약을 구현해 `UsageAccountsController`에 넘기면 된다.
@MainActor
protocol UsageAccountProvider: AnyObject, Sendable {
    var service: PopoverService { get }
    /// 이 서비스의 공식 CLI 이름
    var cliName: String { get }
    /// 다른 로그인 폴더를 가리키는 환경 변수 이름
    var configDirectoryVariable: String { get }
    var addMethods: [UsageAccountAddMethod] { get }
    /// 앱이 만든 계정 폴더 위치. 그 아래 폴더는 사용자가 추가한 것으로 본다.
    var managedDirectoryRoot: URL? { get }
    /// 메뉴바에 기본 로그인이 아닌 계정도 올릴 수 있는 서비스만 준다.
    var menuBar: (any UsageAccountMenuBarPolicy)? { get }

    /// 계정 찾기에 필요한 앱 상태를 main에서 모은다.
    func discoveryInput(directories: [String], knownIdentities: [String: UsageAccountIdentity])
        -> UsageAccountDiscoveryInput
    /// 이 서비스의 로그인을 찾는다. 파일을 읽으므로 호출하는 쪽이 main 밖에서 부른다.
    nonisolated func candidates(_ input: UsageAccountDiscoveryInput) async -> [UsageAccountCandidate]
    func badgeHelp(for role: UsageAccountSource.Role) -> String
    /// 지금 메뉴바와 팝오버 큰 카드가 보여주는 계정인지. 이 계정은 따로 조회하지 않는다.
    func isRuntime(_ account: UsageAccount) -> Bool
    func runtimeUsage(from snapshot: RuntimeProviderSnapshot) -> UsageAccountUsage?
    func fetchUsage(for account: UsageAccount, interactive: Bool) async throws -> UsageAccountFetchResult

    func canSwitch(to account: UsageAccount) -> Bool
    func switchPlan(for account: UsageAccount, name: String) -> UsageAccountSwitchPlan
    func switchDefault(to account: UsageAccount, plan: UsageAccountSwitchPlan) async throws
}

nonisolated struct UsageAccountDiscoveryInput: Equatable, Sendable {
    /// 사용자가 추가한 CLI 폴더
    var directories: [String]
    var webLogins: [UsageAccountWebLogin] = []
    /// 앱이 기본 로그인을 연결해 둔 적이 있는지
    var hasRegisteredDefaultLogin = false
}

/// 앱에 저장된 웹 로그인 하나
nonisolated struct UsageAccountWebLogin: Equatable, Sendable {
    let id: String
    let identity: UsageAccountIdentity
}

nonisolated struct UsageAccountFetchResult: Sendable {
    let usage: UsageAccountUsage
    /// 조회하면서 확인한 웹 로그인의 계정. 다음 발견 때 같은 계정끼리 합치는 데 쓴다.
    var learnedIdentity: (reference: String, identity: UsageAccountIdentity)?
}

nonisolated enum UsageAccountFetchError: Error, Equatable {
    case loginExpired
    case needsPermission
    case executableNotFound
    case unavailable
    case server(Int)
}

nonisolated struct UsageAccountSwitchPlan: Equatable, Sendable {
    let message: String
    let confirmTitle: String
    /// 전환 전에 기본 로그인을 쓰는 프로그램을 종료한다
    let terminatesRunningApps: Bool
}

nonisolated enum UsageAccountAddMethod: Hashable, Sendable {
    case browserImport, inAppLogin, sessionKey, deviceLogin, folder
}

/// 메뉴바에 다른 계정을 올릴 수 있는 서비스의 규칙
@MainActor
protocol UsageAccountMenuBarPolicy: AnyObject, Sendable {
    /// 메뉴바에 올릴 수 있으면 그 계정의 저장소 id
    func target(for account: UsageAccount) -> String?
    /// 지금 메뉴바 계정의 저장소 id
    var currentTarget: String? { get }
    func show(_ target: String)
    /// 사용자가 정하기 전 메뉴바 계정. 다른 후보가 있으면 한 번 묻는다.
    func defaultChoice(among visible: [UsageAccount]) -> UsageAccountMenuBarDefault?
    /// 숨긴 메뉴바 계정을 대신할 계정
    func replacement(among visible: [UsageAccount]) -> UsageAccount?
}

nonisolated struct UsageAccountMenuBarDefault: Equatable, Sendable {
    struct Option: Equatable, Sendable {
        let account: UsageAccount
        /// 어디서 로그인했는지(예: "Claude 앱")
        let origin: String
    }

    let preferred: Option
    let alternative: Option?
}

nonisolated extension UsageAccountUsage {
    init(claude usage: ClaudeUsageResponse) {
        func window(_ value: UsageWindow?) -> Window? {
            value.map { Window(usedPercent: $0.utilization, resetsAt: $0.resetsAt.flatMap(TimeFormatter.parseISO8601)) }
        }
        self.init(fiveHour: window(usage.fiveHour), weekly: window(usage.sevenDay))
    }

    init(codex usage: CodexUsageResponse) {
        func window(_ value: CodexUsageWindow?) -> Window? {
            value.map {
                Window(usedPercent: $0.utilization, resetsAt: $0.resetAt.map(Date.init(timeIntervalSince1970:)))
            }
        }
        self.init(fiveHour: window(usage.sessionWindow), weekly: window(usage.weeklyWindow))
    }
}
