import XCTest
@testable import ClaudeUsage

final class UsageAccountsTests: XCTestCase {
    private func candidate(
        _ role: UsageAccountSource.Role, _ ref: String, account: String?, org: String?, email: String?
    ) -> UsageAccountCandidate {
        UsageAccountCandidate(
            source: .init(role: role, reference: ref),
            identity: .init(accountID: account, organizationID: org, email: email))
    }

    private func account(_ id: String, service: PopoverService = .claude, role: UsageAccountSource.Role = .web)
        -> UsageAccount
    {
        UsageAccount(id: id, service: service, identity: .init(), sources: [.init(role: role, reference: id)])
    }

    func testSameAccountAndOrganizationMergeIntoOneRowKeyedByAccount() {
        let accounts = UsageAccount.merge(
            [
                candidate(.defaultLogin, "/home/.claude", account: "a", org: "team", email: "work@example.com"),
                candidate(.web, "web-1", account: "a", org: "team", email: nil),
                candidate(.web, "web-2", account: "a", org: "personal", email: "work@example.com"),
                candidate(.web, "web-3", account: nil, org: nil, email: "work@example.com"),
            ], service: .claude)

        XCTAssertEqual(accounts.count, 3)
        XCTAssertEqual(accounts[0].roles, [.defaultLogin, .web])
        XCTAssertEqual(accounts[0].id, "claude:a|team", "계정이 확인되면 기본 로그인을 전환해도 id가 계정을 따라갑니다")
        XCTAssertEqual(accounts[2].id, "claude:web:web-3", "확인하지 못한 계정만 출처 기준입니다")
    }

    func testPinnedAccountIsPerServiceAndComesFirst() {
        let a = account("a"), b = account("b"), c = account("c", service: .codex)
        var preferences = UsageAccountPreferences()
        preferences.remember([a, b, c])
        XCTAssertEqual(preferences.ordered([a, b], service: .claude).map(\.id), ["a", "b"])
        preferences[.claude].pinnedTop = "b"
        preferences[.codex].pinnedTop = "c"
        XCTAssertEqual(preferences.ordered([a, b], service: .claude).map(\.id), ["b", "a"])
        XCTAssertEqual(preferences[.claude].pinnedTop, "b", "다른 서비스 고정이 Claude 고정을 풀지 않습니다")
    }

    func testRememberIgnoresDuplicatesAndOrderingSurvivesDuplicateSavedIDs() throws {
        let saved = #"{"order":["a","a","b"]}"#
        var preferences = try JSONDecoder().decode(UsageAccountPreferences.self, from: Data(saved.utf8))
        preferences.remember([account("b"), account("c")])
        XCTAssertEqual(preferences.order, ["a", "a", "b", "c"])
        XCTAssertEqual(preferences.ordered([account("c"), account("a")], service: .claude).map(\.id), ["a", "c"])
    }

    func testPickSelectionDefaultsToFirstTwoAndRemembersChoicePerService() {
        let accounts = ["live", "a", "b"].map { account($0, service: .codex, role: .directory) }
        var preferences = UsageAccountPreferences()
        XCTAssertEqual(preferences.selection(for: .codex, visible: accounts), ["live", "a"])
        preferences[.codex].selected = ["b", "gone"]
        XCTAssertEqual(preferences.selection(for: .codex, visible: accounts), ["b"])
    }

    func testDisplayNameAddsOrganizationOnlyForSharedEmail() {
        let team = UsageAccount(
            id: "1", service: .claude,
            identity: .init(accountID: "a", organizationID: "t", email: "me@example.com", organizationName: "Acme"),
            sources: [])
        let personal = UsageAccount(
            id: "2", service: .claude,
            identity: .init(accountID: "a", organizationID: "p", email: "me@example.com", organizationName: "개인"),
            sources: [])
        let other = UsageAccount(
            id: "3", service: .claude, identity: .init(email: "you@example.com", organizationName: "Acme"), sources: [])
        var preferences = UsageAccountPreferences()
        let all = [team, personal, other]

        XCTAssertEqual(preferences.displayName(for: team, among: all), "me@example.com (Acme)")
        XCTAssertEqual(preferences.displayName(for: other, among: all), "you@example.com")
        preferences.aliases["3"] = "회사"
        XCTAssertEqual(preferences.displayName(for: other, among: all), "회사")
    }

    func testStatusSeparatesFirstFailureFromStaleValues() {
        var state = UsageAccountState()
        XCTAssertEqual(state.status(isArchived: false), .checking)
        state.consecutiveFailures = 1
        XCTAssertEqual(state.status(isArchived: false), .failed, "값을 한 번도 못 읽은 실패는 방금 확인한 것으로 보이면 안 됩니다")
        state.usage = UsageAccountUsage(fiveHour: .init(usedPercent: 20, resetsAt: nil))
        XCTAssertEqual(state.status(isArchived: false), .current)
        state.consecutiveFailures = UsageAccountState.staleAfterFailures
        XCTAssertEqual(state.status(isArchived: false), .stale)
        state.issue = .loginExpired
        XCTAssertEqual(state.status(isArchived: false), .loginExpired)
        XCTAssertEqual(state.status(isArchived: true), .archived)
    }

    func testOlderSavedPreferencesAndBrokenFieldsFallBackPerField() throws {
        let saved =
            #"{"aliases":{"a":"업무"},"hidden":["b"],"order":["a","b"],"popoverMode":"pick","multiAccountEnabled":true,"services":{"claude":{"popoverMode":"single","isMultiAccountEnabled":"yes","directories":["/x"]}}}"#
        let decoded = try JSONDecoder().decode(UsageAccountPreferences.self, from: Data(saved.utf8))

        XCTAssertEqual(decoded.aliases["a"], "업무")
        XCTAssertEqual(decoded.hidden, ["b"])
        XCTAssertEqual(decoded[.claude].popoverMode, .pick, "모르는 보기 값은 골라 보기로 읽습니다")
        XCTAssertFalse(decoded[.claude].isMultiAccountEnabled, "모양이 다른 값은 기본값입니다")
        XCTAssertEqual(decoded[.claude].directories, ["/x"])
        XCTAssertFalse(decoded[.codex].isMultiAccountEnabled, "기본은 단일 계정입니다")
    }

    func testIdentityMatchesByAccountOrEmail() {
        let a = UsageAccountIdentity(accountID: "1", organizationID: "o", email: "A@example.com")
        XCTAssertTrue(a.isSameAccount(as: .init(accountID: "1", organizationID: "o")))
        XCTAssertFalse(a.isSameAccount(as: .init(accountID: "1", organizationID: "other", email: "a@example.com")))
        XCTAssertTrue(UsageAccountIdentity(email: "A@example.com").isSameAccount(as: .init(email: "a@example.com")))
    }

    func testUsageNormalizesClaudeAndCodexWindows() throws {
        let claude = try JSONDecoder().decode(
            ClaudeUsageResponse.self,
            from: Data(
                #"{"five_hour":{"utilization":40,"resets_at":"2026-10-04T10:00:00Z"},"seven_day":{"utilization":90,"resets_at":null}}"#
                    .utf8))
        let usage = UsageAccountUsage(claude: claude)
        XCTAssertEqual(usage.fiveHour?.usedPercent, 40)
        XCTAssertEqual(usage.fiveHour?.resetsAt, ISO8601DateFormatter().date(from: "2026-10-04T10:00:00Z"))
        XCTAssertEqual(usage.lowestRemainingPercent, 10)

        let codex = try CodexHomeAccount.usageResponse(fromAppServer: [
            "rateLimits": ["primary": ["usedPercent": 30, "windowDurationMins": 300, "resetsAt": 1_790_000_000]]
        ])
        XCTAssertEqual(UsageAccountUsage(codex: codex).fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_790_000_000))
    }
}

@MainActor
final class MultiAccountPresentationTests: XCTestCase {
    private func row(
        _ id: String, runtime: Bool = false, five: Double = 20, status: UsageAccountState.Status = .current
    ) -> PopoverAccountRowData {
        PopoverAccountRowData(
            id: id, service: .claude, name: id, badges: [], status: status,
            usage: UsageAccountUsage(
                fiveHour: .init(usedPercent: five, resetsAt: nil), weekly: .init(usedPercent: 30, resetsAt: nil)),
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), isRuntime: runtime, basis: .used)
    }

    private let catalog = [
        PopoverDisplaySection(
            id: "currentSession", kind: .status, importance: .primary,
            payload: .status(PopoverStatusSectionData(title: "5시간 한도", error: nil)))
    ]

    func testExhaustedAccountRowShowsDurationOnlyForAUsedLimitWithResetTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = UsageAccountUsage.Window(
            usedPercent: 100, resetsAt: now.addingTimeInterval(3 * 86400 + 14 * 3600 + 22 * 60))
        let account = OtherAccountRow(data: row("a"), density: .compact)
        XCTAssertEqual(account.exhaustedQuotaText(for: window, isWeekly: true, now: now), "3d 14h")
        XCTAssertNil(
            account.exhaustedQuotaText(for: .init(usedPercent: 99, resetsAt: window.resetsAt), isWeekly: true, now: now)
        )
        XCTAssertNil(account.exhaustedQuotaText(for: .init(usedPercent: 100, resetsAt: nil), isWeekly: true, now: now))
    }

    func testPickShowsPickerCatalogOnlyWhenRuntimeSelectedAndSelectedOthers() {
        let rows = [row("live", runtime: true), row("a"), row("b")]
        let picked = MultiAccountPresentation(service: .claude, mode: .pick, rows: rows, selectedIDs: ["live", "b"])
        XCTAssertEqual(
            picked.sections(catalog: catalog).map(\.id),
            ["account-picker", "currentSession", "account-b"])
        let withoutRuntime = MultiAccountPresentation(service: .claude, mode: .pick, rows: rows, selectedIDs: ["a"])
        XCTAssertEqual(
            withoutRuntime.sections(catalog: catalog).map(\.id),
            ["account-picker", "account-a"])
    }

    func testFeaturedListAndSummaryRowsUseTheLowRemainingThreshold() {
        let rows = [row("live", runtime: true), row("a", five: 95), row("b", status: .loginExpired)]
        let featured = MultiAccountPresentation(service: .claude, mode: .featuredList, rows: rows, selectedIDs: [])
        XCTAssertEqual(
            featured.sections(catalog: catalog).map(\.id),
            ["currentSession", "account-a", "account-b"])
        let summary = MultiAccountPresentation(service: .claude, mode: .summaryRows, rows: rows, selectedIDs: [])
        XCTAssertEqual(
            summary.sections(catalog: catalog).map(\.id),
            ["account-summary", "account-live", "account-a", "account-b"])
        let threshold = PercentageText.string(AdaptiveRefreshPolicy.lowRemainingPercent)
        XCTAssertEqual(summary.summary, .init(text: "남은 한도 \(threshold) 이하 1개, 로그인 만료 1개", isWarning: true))
        let calm = MultiAccountPresentation(
            service: .claude, mode: .summaryRows, rows: [row("x"), row("y")], selectedIDs: [])
        XCTAssertEqual(calm.summary.text, "모든 계정 여유 있음")
    }
}

/// 서비스 종류와 관계없는 컨트롤러 규칙을 가짜 서비스로 확인한다.
@MainActor
final class UsageAccountsControllerTests: XCTestCase {
    private func controller(_ providers: [FakeAccountProvider], enabled: Set<PopoverService> = [.claude, .codex])
        -> UsageAccountsController
    {
        let suiteName = "UsageAccountsControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        return UsageAccountsController(
            providers: providers, defaults: defaults, isServiceEnabled: { enabled.contains($0) })
    }

    func testDisabledServiceIsNotDiscoveredOrFetched() async {
        let codex = FakeAccountProvider(service: .codex, accounts: [("live", .defaultLogin), ("other", .directory)])
        let sut = controller([codex], enabled: [])
        sut.setMultiAccountEnabled(true, for: .codex)
        await sut.discoverAndWait()
        sut.refreshIfNeeded(force: true)
        await Task.yield()

        XCTAssertTrue(sut.orderedAccounts(for: .codex).isEmpty)
        XCTAssertEqual(codex.fetches, [])
    }

    func testMultiAccountSettingIsPerServiceAndOnlyEnabledServiceFetches() async throws {
        let claude = FakeAccountProvider(
            service: .claude, accounts: [("c-live", .defaultLogin), ("c-other", .directory)])
        let codex = FakeAccountProvider(
            service: .codex, accounts: [("x-live", .defaultLogin), ("x-other", .directory)])
        let sut = controller([claude, codex])
        await sut.discoverAndWait()
        sut.setMultiAccountEnabled(true, for: .codex)
        try await waitUntil { codex.fetches.count == 1 }

        XCTAssertTrue(sut.isMultiAccount(.codex))
        XCTAssertFalse(sut.isMultiAccount(.claude))
        XCTAssertEqual(codex.fetches, ["x-other"], "메뉴바 계정은 따로 조회하지 않습니다")
        XCTAssertEqual(claude.fetches, [])
    }

    func testRefreshSkipsAccountsAlreadyQueuedAndRecentlyAttempted() async throws {
        let codex = FakeAccountProvider(service: .codex, accounts: [("live", .defaultLogin), ("other", .directory)])
        codex.fetchDelay = .milliseconds(100)
        let sut = controller([codex])
        await sut.discoverAndWait()
        sut.setMultiAccountEnabled(true, for: .codex)
        sut.refreshIfNeeded(force: true)
        sut.refreshIfNeeded()
        try await waitUntil { sut.states.values.contains { $0.fetchedAt != nil } }
        sut.refreshIfNeeded()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(codex.fetches.count, 1)
    }

    func testMissingExecutableKeepsOtherAccountNumbersAndReportsItsCause() async throws {
        let claude = FakeAccountProvider(service: .claude, accounts: [("live", .defaultLogin), ("other", .directory)])
        let sut = controller([claude])
        await sut.discoverAndWait()
        sut.setMultiAccountEnabled(true, for: .claude)
        try await waitUntil { sut.states.values.contains { $0.fetchedAt != nil } }
        let previousDate = try XCTUnwrap(sut.states.values.first?.fetchedAt)
        claude.failure = UsageAccountFetchError.executableNotFound

        sut.refreshIfNeeded(force: true)
        try await waitUntil { sut.states.values.contains { $0.issue == .executableNotFound } }

        let state = try XCTUnwrap(sut.states.values.first)
        XCTAssertEqual(state.status(isArchived: false), .executableNotFound)
        XCTAssertEqual(state.usage?.fiveHour?.usedPercent, 10)
        XCTAssertEqual(state.fetchedAt, previousDate)
    }

    func testFirstFailureWithoutDataIsReportedAsFailed() async throws {
        let codex = FakeAccountProvider(service: .codex, accounts: [("live", .defaultLogin), ("other", .directory)])
        codex.failure = UsageAccountFetchError.unavailable
        let sut = controller([codex])
        await sut.discoverAndWait()
        sut.setMultiAccountEnabled(true, for: .codex)
        try await waitUntil { !sut.states.isEmpty }

        let state = try XCTUnwrap(sut.states.values.first)
        XCTAssertEqual(state.status(isArchived: false), .failed)
        XCTAssertNil(state.fetchedAt)
    }

    func testHidingMenuBarAccountMovesMenuBarToReplacement() async throws {
        let claude = FakeAccountProvider(
            service: .claude, accounts: [("cli", .defaultLogin), ("app", .web)], menuBarTarget: "cli")
        let sut = controller([claude])
        await sut.discoverAndWait()
        let cli = try XCTUnwrap(sut.orderedAccounts(for: .claude).first { $0.id.hasSuffix("cli") })

        XCTAssertTrue(sut.canHide(cli))
        sut.setHidden(true, cli)
        try await waitUntil { claude.menuBarTarget == "app" }
        XCTAssertTrue(sut.isHidden(cli))
    }

    func testMenuBarDefaultAppliesUntilUserChoosesAnotherAccountElsewhere() async throws {
        let claude = FakeAccountProvider(
            service: .claude, accounts: [("cli", .defaultLogin), ("app", .web)], menuBarTarget: "cli")
        claude.preferredDefault = "app"
        let sut = controller([claude])
        await sut.discoverAndWait()
        try await waitUntil { claude.menuBarTarget == "app" }
        // 저장소가 바뀌면 다시 찾기가 불린다. 앱이 바꾼 것이라 사용자 선택으로 보지 않는다.
        await sut.discoverAndWait()

        // 다른 경로(예: Claude Code 다시 연결)로 메뉴바 계정을 바꾸면 그 선택을 지킨다.
        claude.menuBarTarget = "cli"
        await sut.discoverAndWait()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(claude.menuBarTarget, "cli")
    }

    func testLearnedIdentityCarriesNameAndStateToAccountKeyedID() async throws {
        let claude = FakeAccountProvider(service: .claude, accounts: [("cli", .defaultLogin), ("web", .web)])
        let sut = controller([claude])
        await sut.discoverAndWait()
        let web = try XCTUnwrap(sut.orderedAccounts(for: .claude).first { $0.source(.web) != nil })
        sut.rename(web, to: "업무")

        claude.identities["web"] = UsageAccountIdentity(accountID: "u", organizationID: "o", email: "w@example.com")
        await sut.discoverAndWait()

        let renamed = try XCTUnwrap(sut.orderedAccounts(for: .claude).first { $0.source(.web) != nil })
        XCTAssertEqual(renamed.id, "claude:u|o")
        XCTAssertEqual(sut.displayName(for: renamed), "업무")
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("시간 안에 조건을 만족하지 못했습니다") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class FakeAccountProvider: UsageAccountProvider, UsageAccountMenuBarPolicy {
    let service: PopoverService
    let cliName = "Fake"
    let configDirectoryVariable = "FAKE_HOME"
    let addMethods: [UsageAccountAddMethod] = [.folder]
    let managedDirectoryRoot: URL? = nil
    var menuBar: (any UsageAccountMenuBarPolicy)? { hasMenuBar ? self : nil }

    private let hasMenuBar: Bool
    private let accountRoles: [(String, UsageAccountSource.Role)]
    var identities: [String: UsageAccountIdentity] = [:]
    var menuBarTarget: String?
    var preferredDefault: String?
    var fetches: [String] = []
    var fetchDelay: Duration?
    var beforeFetch: (@MainActor (String) async -> Void)?
    var failure: Error?

    init(service: PopoverService, accounts: [(String, UsageAccountSource.Role)], menuBarTarget: String? = nil) {
        self.service = service
        self.accountRoles = accounts
        self.menuBarTarget = menuBarTarget
        self.hasMenuBar = menuBarTarget != nil
    }

    func discoveryInput(directories: [String], knownIdentities: [String: UsageAccountIdentity])
        -> UsageAccountDiscoveryInput
    {
        UsageAccountDiscoveryInput(
            directories: directories,
            webLogins: accountRoles.map { UsageAccountWebLogin(id: $0.0, identity: identities[$0.0] ?? .init()) })
    }

    nonisolated func candidates(_ input: UsageAccountDiscoveryInput) -> [UsageAccountCandidate] {
        let roles: [String: UsageAccountSource.Role] = [
            "cli": .defaultLogin, "live": .defaultLogin, "c-live": .defaultLogin, "x-live": .defaultLogin,
        ]
        return input.webLogins.map { login in
            UsageAccountCandidate(
                source: .init(
                    role: roles[login.id] ?? (login.id == "app" || login.id == "web" ? .web : .directory),
                    reference: login.id),
                identity: login.identity)
        }
    }

    func badgeHelp(for role: UsageAccountSource.Role) -> String { "" }

    func isRuntime(_ account: UsageAccount) -> Bool {
        if hasMenuBar { return account.sources.contains { $0.reference == menuBarTarget } }
        return account.isDefaultLogin
    }

    func runtimeUsage(from snapshot: RuntimeProviderSnapshot) -> UsageAccountUsage? { nil }

    func fetchUsage(for account: UsageAccount, interactive: Bool) async throws -> UsageAccountFetchResult {
        fetches.append(account.sources[0].reference)
        await beforeFetch?(account.sources[0].reference)
        if let fetchDelay { try await Task.sleep(for: fetchDelay) }
        if let failure { throw failure }
        return UsageAccountFetchResult(usage: UsageAccountUsage(fiveHour: .init(usedPercent: 10, resetsAt: nil)))
    }

    func canSwitch(to account: UsageAccount) -> Bool { false }
    func switchPlan(for account: UsageAccount, name: String) -> UsageAccountSwitchPlan {
        UsageAccountSwitchPlan(message: "", confirmTitle: "", terminatesRunningApps: false)
    }
    func switchDefault(to account: UsageAccount, plan: UsageAccountSwitchPlan) async throws {}

    var currentTarget: String? { menuBarTarget }
    func target(for account: UsageAccount) -> String? { account.sources.first?.reference }
    func show(_ target: String) { menuBarTarget = target }

    func defaultChoice(among visible: [UsageAccount]) -> UsageAccountMenuBarDefault? {
        guard let preferredDefault, let account = visible.first(where: { target(for: $0) == preferredDefault }) else {
            return nil
        }
        return UsageAccountMenuBarDefault(preferred: .init(account: account, origin: "앱"), alternative: nil)
    }

    func replacement(among visible: [UsageAccount]) -> UsageAccount? { visible.first { !isRuntime($0) } }
}

final class UsageAccountSourceTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("accounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func write(_ object: Any, to path: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    func testClaudeSiblingFoldersExposeIdentityFromTheirOwnProfile() throws {
        try write(
            ["oauthAccount": ["accountUuid": "acc", "organizationUuid": "org", "emailAddress": "lab@example.com"]],
            to: ".claude-lab/.claude.json")
        try write(["projects": [:]], to: ".claude-empty/.claude.json")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claudebar"), withIntermediateDirectories: true)

        let found = ClaudeUsageAccountProvider.siblingConfigDirectories(home: home)
        XCTAssertEqual(found.map(\.lastPathComponent), [".claude-empty", ".claude-lab"])
        XCTAssertNil(ClaudeCodeLoginSlot.folderSlot(found[0], home: home).identity())
        let identity = try XCTUnwrap(ClaudeCodeLoginSlot.folderSlot(found[1], home: home).identity())
        XCTAssertEqual(identity.mergeKey, "acc|org")
        XCTAssertEqual(identity.email, "lab@example.com")
    }

    func testDefaultSlotReadsHomeProfileAndUnscopedKeychainName() throws {
        try write(["oauthAccount": ["accountUuid": "a", "organizationUuid": "o"]], to: ".claude.json")
        let slot = ClaudeCodeLoginSlot.defaultSlot(home: home)

        XCTAssertEqual(slot.identity()?.mergeKey, "a|o")
        XCTAssertEqual(slot.keychainService, ClaudeCodeCredentialReader.defaultKeychainService)
        XCTAssertNil(slot.cliConfigDirectory, "기본 로그인에 CLAUDE_CONFIG_DIR을 주면 Keychain 이름이 달라집니다")
        XCTAssertNotEqual(
            ClaudeCodeLoginSlot.folderSlot(home.appendingPathComponent(".claude-x"), home: home).keychainService,
            ClaudeCodeCredentialReader.defaultKeychainService)
    }

    func testCurrentCredentialPrefersFresherKeychainOverStaleFile() async throws {
        let slot = ClaudeCodeLoginSlot.folderSlot(home.appendingPathComponent(".claude-x"), home: home)
        try write(
            ["claudeAiOauth": ["accessToken": "file-token", "expiresAt": 1_000_000_000_000]],
            to: ".claude-x/.credentials.json")
        let fresh = #"{"claudeAiOauth":{"accessToken":"keychain-token","expiresAt":4102444800000}}"#
        var keychain = ClaudeCodeKeychain.none
        keychain.read = { _ in .payload(fresh) }

        guard case .credential(let credential) = await slot.currentCredential(interactive: false, keychain: keychain)
        else { return XCTFail("로그인을 읽지 못했습니다") }
        XCTAssertEqual(credential.accessToken, "keychain-token")
    }

    func testCurrentCredentialNeverPromptsWhenNotInteractive() async {
        let slot = ClaudeCodeLoginSlot.folderSlot(home.appendingPathComponent(".claude-y"), home: home)
        var keychain = ClaudeCodeKeychain.none
        keychain.read = { _ in .failed }
        keychain.readInteractively = { _, _ in
            XCTFail("자동 조회에서 확인 창을 띄우면 안 됩니다")
            return .cancelled
        }

        let read = await slot.currentCredential(interactive: false, keychain: keychain)
        XCTAssertEqual(read, .needsPermission)
    }

    func testCredentialParsingConvertsMillisecondExpiry() {
        let credential = ClaudeCodeCredentialReader.parseCredential(
            from: #"{"claudeAiOauth":{"accessToken":"token-value","expiresAt":1790000000000}}"#,
            source: .file(URL(fileURLWithPath: "/tmp/x")))
        XCTAssertEqual(credential?.accessToken, "token-value")
        XCTAssertEqual(credential?.expiresAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertNil(ClaudeCodeCredentialReader.parseCredential(from: "{}", source: .refreshed))
    }

    func testClaudeCLIEnvironmentCarriesUserSoClaudeCodeFindsItsKeychainLogin() {
        let folder = URL(fileURLWithPath: "/tmp/.claude-work")
        let scoped = ClaudeCodeCLI.environment(configDirectory: folder, home: home)
        let main = ClaudeCodeCLI.environment(configDirectory: nil, home: home)

        XCTAssertEqual(scoped["USER"], NSUserName())
        XCTAssertEqual(scoped["CLAUDE_CONFIG_DIR"], folder.path)
        XCTAssertEqual(main["USER"], NSUserName())
        XCTAssertNil(main["CLAUDE_CONFIG_DIR"])
        XCTAssertTrue(main["PATH"]?.contains("/opt/homebrew/bin") == true, "npm으로 설치한 CLI가 node를 찾아야 합니다")
    }

    func testCodexHomesNeedAuthFileAndSkipLookalikeFolders() throws {
        let claims = Data(#"{"email":"me@example.com"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        try write(["tokens": ["account_id": "ws-1", "id_token": "x.\(claims).y"]], to: ".codex-work/auth.json")
        try write(["tokens": [:]], to: ".codexbar/auth.json")
        let managed = home.appendingPathComponent("managed")

        let homes = CodexHomeAccount.discoverHomes(home: home, managedRoot: managed)
        XCTAssertEqual(homes.map(\.lastPathComponent), [".codex-work"])
        let identity = try XCTUnwrap(CodexHomeAccount.identity(home: homes[0]))
        XCTAssertEqual(identity.email, "me@example.com")
        XCTAssertEqual(identity.organizationID, "ws-1")
    }

    func testAppServerSnapshotMapsToUsageResponse() throws {
        let usage = try CodexHomeAccount.usageResponse(fromAppServer: [
            "accountId": "ws-1",
            "rateLimits": [
                "primary": ["usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1_790_000_000],
                "secondary": ["usedPercent": 10, "windowDurationMins": 10080, "resetsAt": 1_790_500_000],
                "planType": "plus",
            ],
            "rateLimitResetCredits": ["availableCount": 1, "credits": NSNull()],
        ])
        XCTAssertEqual(usage.sessionWindow?.utilization, 42)
        XCTAssertEqual(usage.weeklyWindow?.utilization, 10)
        XCTAssertEqual(usage.planType, "plus")
        XCTAssertEqual(usage.resetCredits?.availableCount(), 1)
    }
}


extension UsageAccountsControllerTests {
    func testVerifiedRuntimeIdentityStaysWithItsPayloadAcrossDiscovery() async throws {
        let provider = FakeAccountProvider(service: .codex, accounts: [("live", .defaultLogin), ("other", .directory)])
        let original = UsageAccountIdentity(accountID: "a", organizationID: "team", email: "a@example.com")
        provider.identities["live"] = original
        let sut = controller([provider])
        await sut.discoverAndWait()
        let previous = try XCTUnwrap(sut.accounts[.codex]?.first(where: \.isDefaultLogin))
        sut.rename(previous, to: "원래 계정")
        let confirmed = UsageAccountCandidate(
            source: .init(role: .defaultLogin, reference: "live"),
            identity: .init(accountID: "b", organizationID: "team", email: "b@example.com"))

        sut.bindRuntimeAccount(confirmed, for: .codex)
        await sut.discoverAndWait()  // discovery is still reporting A from its earlier credential view

        let runtime = try XCTUnwrap(sut.orderedAccounts(for: .codex).first(where: sut.isRuntime))
        XCTAssertEqual(runtime.id, "codex:b|team")
        XCTAssertEqual(runtime.identity.email, "b@example.com")
        XCTAssertEqual(sut.preferences.aliases[previous.id], "원래 계정")
        XCTAssertNotEqual(sut.alias(for: runtime), "원래 계정")
    }

    func testQueuedArchivedAccountIsSkippedUntilUnarchived() async throws {
        let provider = FakeAccountProvider(
            service: .codex, accounts: [("live", .defaultLogin), ("first", .directory), ("second", .directory)])
        let gate = UsageAccountFetchGate()
        provider.beforeFetch = { reference in if reference == "first" { await gate.wait() } }
        let sut = controller([provider])
        await sut.discoverAndWait()
        let second = try XCTUnwrap(sut.accounts[.codex]?.first { $0.sources.first?.reference == "second" })
        sut.setMultiAccountEnabled(true, for: .codex)
        try await waitUntil { provider.fetches == ["first"] }
        sut.setArchived(true, second)
        await gate.resume()
        try await waitUntil { sut.states.values.contains { $0.fetchedAt != nil } }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(provider.fetches, ["first"])
        XCTAssertNil(sut.states[second.id])
        sut.setArchived(false, second)
        try await waitUntil { provider.fetches.contains("second") }
        XCTAssertEqual(provider.fetches, ["first", "second"])
    }
}

private actor UsageAccountFetchGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false
    func wait() async {
        guard !resumed else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() {
        resumed = true
        continuation?.resume()
        continuation = nil
    }
}

extension MultiAccountPresentationTests {
    func testSummaryDoesNotCallUnknownOrStaleAccountsHealthy() {
        let unknown = PopoverAccountRowData(
            id: "unknown", service: .claude, name: "unknown", badges: [], status: .checking,
            usage: nil, fetchedAt: nil, isRuntime: false, basis: .used)
        let pending = MultiAccountPresentation(service: .claude, mode: .summaryRows, rows: [unknown], selectedIDs: [])
        XCTAssertEqual(pending.summary, .init(text: "사용량 확인 전", isWarning: false))
        let mixed = MultiAccountPresentation(
            service: .claude, mode: .summaryRows, rows: [row("ready"), unknown], selectedIDs: [])
        XCTAssertEqual(mixed.summary, .init(text: "확인한 계정은 여유 있음, 1개 미확인", isWarning: false))
        let stale = MultiAccountPresentation(
            service: .claude, mode: .summaryRows, rows: [row("old", status: .stale)], selectedIDs: [])
        XCTAssertNotEqual(stale.summary.text, "모든 계정 여유 있음")
    }
}

extension UsageAccountsControllerTests {
    func testSwitchDetectionUsesPhysicalLoginWhileDisplayedPayloadStillBelongsToPreviousAccount() async throws {
        let suite = "UsageAccountsControllerTests.physical.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = FakeAccountProvider(service: .codex, accounts: [("live", .defaultLogin), ("other", .directory)])
        let previous = UsageAccountIdentity(accountID: "a", organizationID: "team", email: "a@example.com")
        let next = UsageAccountIdentity(accountID: "b", organizationID: "team", email: "b@example.com")
        provider.identities["live"] = previous
        provider.identities["other"] = next
        var notices: [String] = []
        let sut = UsageAccountsController(
            providers: [provider], defaults: defaults, notifyAccountChange: { _, body in notices.append(body) },
            isServiceEnabled: { _ in true })
        await sut.discoverAndWait()
        sut.bindRuntimeAccount(
            .init(source: .init(role: .defaultLogin, reference: "live"), identity: previous), for: .codex)
        let destination = try XCTUnwrap(sut.accounts[.codex]?.first { $0.identity == next })
        provider.identities["live"] = next
        let switchError = await sut.switchDefault(
            to: destination, plan: .init(message: "fixture", confirmTitle: "fixture", terminatesRunningApps: false))
        XCTAssertNil(switchError)
        XCTAssertEqual(sut.preferences[.codex].expectedDefault, next)
        XCTAssertNil(sut.revertedSwitch[.codex])
        XCTAssertEqual(notices, [])
        XCTAssertEqual(sut.orderedAccounts(for: .codex).first(where: sut.isRuntime)?.identity, previous)
        // 실제 로그인이 다시 A로 바뀐 뒤에만 되돌림을 알린다.
        provider.identities["live"] = previous
        await sut.discoverAndWait()
        XCTAssertNil(sut.preferences[.codex].expectedDefault)
        XCTAssertNotNil(sut.revertedSwitch[.codex])
        XCTAssertEqual(notices.count, 1)
    }
}

extension UsageAccountsControllerTests {
    func testMergedWebAndCLILabelsCannotDetachVerifiedRuntimeQuota() async throws {
        let provider = FakeAccountProvider(
            service: .claude, accounts: [("live", .defaultLogin), ("app", .web), ("other", .directory)])
        let identity = UsageAccountIdentity(accountID: "user", organizationID: "team")
        provider.identities["live"] = identity
        provider.identities["app"] = .init(
            accountID: "user", organizationID: "team", email: "a@example.com", organizationName: "Team")
        let sut = controller([provider])
        await sut.discoverAndWait()
        let candidate = UsageAccountCandidate(source: .init(role: .defaultLogin, reference: "live"), identity: identity)
        sut.bindRuntimeAccount(candidate, for: .claude)
        await sut.discoverAndWait()
        let merged = try XCTUnwrap(sut.accounts[.claude]?.first { $0.id == "claude:user|team" })
        XCTAssertEqual(merged.identity.email, "a@example.com")
        XCTAssertEqual(merged.identity.organizationName, "Team")
        XCTAssertEqual(merged.roles, [.defaultLogin, .web])
        XCTAssertTrue(sut.isRuntime(merged))
        XCTAssertTrue(merged.matches(candidate))
        XCTAssertFalse(merged.matches(.init(source: candidate.source, identity: .init())))
        XCTAssertFalse(
            merged.matches(
                .init(
                    source: candidate.source,
                    identity: .init(accountID: "user", organizationID: "other", email: "a@example.com"))))
    }
}
