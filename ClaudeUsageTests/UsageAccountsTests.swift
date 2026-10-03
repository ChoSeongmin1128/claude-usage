import XCTest
@testable import ClaudeUsage

final class UsageAccountsTests: XCTestCase {
    private func candidate(
        _ kind: UsageAccountSource.Kind, _ ref: String, account: String?, org: String?, email: String?
    )
        -> UsageAccountCandidate
    {
        UsageAccountCandidate(
            source: .init(kind: kind, reference: ref),
            identity: .init(accountID: account, organizationID: org, email: email))
    }

    func testSameAccountAndOrganizationMergeIntoOneRowWithBothBadges() {
        let accounts = UsageAccount.merge(
            [
                candidate(.claudeCodeDefault, "~/.claude", account: "a", org: "team", email: "work@example.com"),
                candidate(.claudeWeb, "web-1", account: "a", org: "team", email: nil),
                candidate(.claudeWeb, "web-2", account: "a", org: "personal", email: "work@example.com"),
                candidate(.claudeWeb, "web-3", account: nil, org: nil, email: "work@example.com"),
            ], service: .claude)

        XCTAssertEqual(accounts.count, 3)
        XCTAssertEqual(accounts[0].badges, [.inUse, .web])
        XCTAssertEqual(accounts[0].id, "claudeCodeDefault:~/.claude")
        XCTAssertEqual(accounts[1].badges, [.web])
    }

    func testOrderPutsPinnedFirstThenFirstSeen() {
        let a = UsageAccount(
            id: "a", service: .claude, identity: .init(), sources: [.init(kind: .claudeWeb, reference: "a")])
        let b = UsageAccount(
            id: "b", service: .claude, identity: .init(), sources: [.init(kind: .claudeWeb, reference: "b")])
        let live = UsageAccount(
            id: "live", service: .claude, identity: .init(), sources: [.init(kind: .claudeCodeDefault, reference: "x")])
        var preferences = UsageAccountPreferences()
        preferences.remember([a, b, live])
        XCTAssertEqual(preferences.ordered([a, b, live]).map(\.id), ["a", "b", "live"])
        preferences.pinnedTop = "b"
        XCTAssertEqual(preferences.ordered([a, b, live]).map(\.id), ["b", "a", "live"])
    }

    func testPickSelectionDefaultsToFirstTwoAndRemembersChoice() {
        let ids = ["live", "a", "b"]
        let accounts = ids.map {
            UsageAccount(
                id: $0, service: .codex, identity: .init(), sources: [.init(kind: .codexDirectory, reference: $0)])
        }
        var preferences = UsageAccountPreferences()
        XCTAssertEqual(preferences.selection(for: .codex, visible: accounts), ["live", "a"])
        preferences.selected["codex"] = ["b", "gone"]
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

        XCTAssertEqual(preferences.displayName(for: team, among: all), "me@example.com · Acme")
        XCTAssertEqual(preferences.displayName(for: other, among: all), "you@example.com")
        preferences.aliases["3"] = "회사"
        XCTAssertEqual(preferences.displayName(for: other, among: all), "회사")
    }

    func testStaleOnlyAfterTwoFailuresButExpiredImmediately() {
        var state = UsageAccountState(fetchedAt: Date())
        state.consecutiveFailures = 1
        XCTAssertEqual(state.status(isArchived: false), .current)
        state.consecutiveFailures = 2
        XCTAssertEqual(state.status(isArchived: false), .stale)
        state.loginExpired = true
        XCTAssertEqual(state.status(isArchived: false), .loginExpired)
        XCTAssertEqual(state.status(isArchived: true), .archived)
    }
}

@MainActor
final class MultiAccountPresentationTests: XCTestCase {
    private func row(
        _ id: String, runtime: Bool = false, five: Double? = 20, status: UsageAccountState.Status = .current
    )
        -> PopoverAccountRowData
    {
        PopoverAccountRowData(
            id: id, service: .claude, name: id, badges: runtime ? [.inUse] : [.web], status: status, fiveHour: five,
            weekly: 30, fiveHourResetAt: nil, weeklyResetAt: nil, fetchedAt: Date(), isRuntime: runtime, basis: .used)
    }

    private let catalog = [
        PopoverDisplaySection(
            id: "currentSession", kind: .status, importance: .primary,
            payload: .status(PopoverStatusSectionData(title: "5시간 한도", error: nil)))
    ]

    func testPickShowsPickerCatalogOnlyWhenRuntimeSelectedAndSelectedOthers() {
        let rows = [row("live", runtime: true), row("a"), row("b")]
        let picked = MultiAccountPresentation(service: .claude, mode: .pick, rows: rows, selectedIDs: ["live", "b"])
        XCTAssertEqual(picked.sections(catalog: catalog).map(\.id), ["account-picker", "currentSession", "account-b"])
        let withoutRuntime = MultiAccountPresentation(service: .claude, mode: .pick, rows: rows, selectedIDs: ["a"])
        XCTAssertEqual(withoutRuntime.sections(catalog: catalog).map(\.id), ["account-picker", "account-a"])
    }

    func testMenuBarDefaultPrefersClaudeAppThenClaudeCodeThenOtherWebLogins() {
        func account(_ id: String, _ kind: UsageAccountSource.Kind, _ reference: String) -> UsageAccount {
            UsageAccount(
                id: id, service: .claude, identity: .init(), sources: [.init(kind: kind, reference: reference)])
        }
        let chrome = account("chrome", .claudeWeb, "web-chrome")
        let cli = account("cli", .claudeCodeDefault, "~/.claude")
        let app = account("app", .claudeWeb, "web-app")

        XCTAssertEqual(
            UsageAccountsController.preferredMenuBarAccount(among: [chrome, cli, app], claudeAppWebIDs: ["web-app"])?
                .id,
            "app")
        XCTAssertEqual(
            UsageAccountsController.preferredMenuBarAccount(among: [chrome, cli], claudeAppWebIDs: ["web-app"])?.id,
            "cli")
        XCTAssertEqual(
            UsageAccountsController.preferredMenuBarAccount(among: [chrome], claudeAppWebIDs: [])?.id, "chrome")
    }

    func testPreferencesSavedBeforeMenuBarChoiceStillDecode() throws {
        let saved =
            #"{"aliases":{"a":"업무"},"hidden":["b"],"archived":[],"order":["a","b"],"selected":{},"popoverMode":"pick","codexDirectories":[],"claudeDirectories":[],"knownIdentities":{},"expectedDefault":{}}"#
        let decoded = try JSONDecoder().decode(UsageAccountPreferences.self, from: Data(saved.utf8))

        XCTAssertEqual(decoded.aliases["a"], "업무")
        XCTAssertEqual(decoded.hidden, ["b"])
        XCTAssertNil(decoded.menuBarAccountChosen)
        XCTAssertFalse(decoded.isMultiAccountEnabled, "기본은 단일 계정이어야 합니다")
    }

    func testRemovedPopoverModeFallsBackToPickWithoutLosingOtherPreferences() throws {
        let saved =
            #"{"aliases":{"a":"업무"},"hidden":[],"archived":[],"order":[],"selected":{},"popoverMode":"single","codexDirectories":[],"claudeDirectories":[],"knownIdentities":{},"expectedDefault":{},"multiAccountEnabled":true}"#
        let decoded = try JSONDecoder().decode(UsageAccountPreferences.self, from: Data(saved.utf8))

        XCTAssertEqual(decoded.popoverMode, .pick)
        XCTAssertEqual(decoded.aliases["a"], "업무")
        XCTAssertTrue(decoded.isMultiAccountEnabled)
    }

    func testFeaturedListAndSummaryRows() {
        let rows = [row("live", runtime: true), row("a", five: 95), row("b", status: .loginExpired)]
        let featured = MultiAccountPresentation(service: .claude, mode: .featuredList, rows: rows, selectedIDs: [])
        XCTAssertEqual(featured.sections(catalog: catalog).map(\.id), ["currentSession", "account-a", "account-b"])
        let summary = MultiAccountPresentation(service: .claude, mode: .summaryRows, rows: rows, selectedIDs: [])
        XCTAssertEqual(
            summary.sections(catalog: catalog).map(\.id), ["account-summary", "account-live", "account-a", "account-b"])
        XCTAssertEqual(summary.summary, .init(text: "1개 계정 한도 10% 이하 · 로그인 만료 1개", isWarning: true))
        let calm = MultiAccountPresentation(
            service: .claude, mode: .summaryRows, rows: [row("x"), row("y")], selectedIDs: [])
        XCTAssertEqual(calm.summary.text, "모든 계정 여유 있음")
    }
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

    func testClaudeDirectoriesNeedOAuthAccountAndExposeIdentity() throws {
        try write(
            ["oauthAccount": ["accountUuid": "acc", "organizationUuid": "org", "emailAddress": "lab@example.com"]],
            to: ".claude-lab/.claude.json")
        try write(["projects": [:]], to: ".claude-empty/.claude.json")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claudebar"), withIntermediateDirectories: true)

        let found = ClaudeCodeDirectoryAccount.discoverDirectories(home: home)
        XCTAssertEqual(found.map(\.lastPathComponent), [".claude-lab"])
        let identity = try XCTUnwrap(ClaudeCodeDirectoryAccount.identity(configDirectory: found[0]))
        XCTAssertEqual(identity.mergeKey, "acc|org")
        XCTAssertEqual(identity.email, "lab@example.com")
    }

    func testClaudeCredentialFileParsesTokenAndExpiry() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "token-value", "expiresAt": 1_790_000_000_000]
        ])
        XCTAssertEqual(
            ClaudeCodeDirectoryAccount.parse(data),
            .token("token-value", expiresAt: Date(timeIntervalSince1970: 1_790_000_000)))
        XCTAssertNil(ClaudeCodeDirectoryAccount.parse(Data("{}".utf8)))
    }

    func testClaudeCLIEnvironmentCarriesUserSoClaudeCodeFindsItsKeychainLogin() {
        let folder = URL(fileURLWithPath: "/tmp/.claude-work")
        let scoped = ClaudeCodeDirectoryAccount.cliEnvironment(configDirectory: folder)
        let main = ClaudeCodeDirectoryAccount.cliEnvironment(configDirectory: nil)

        XCTAssertEqual(scoped["USER"], NSUserName())
        XCTAssertEqual(scoped["CLAUDE_CONFIG_DIR"], folder.path)
        XCTAssertEqual(main["USER"], NSUserName())
        XCTAssertNil(main["CLAUDE_CONFIG_DIR"])
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
