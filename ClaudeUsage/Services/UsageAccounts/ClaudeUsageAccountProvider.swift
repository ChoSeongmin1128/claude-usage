import Foundation

/// Claude 계정: 기본 Claude Code 로그인, 다른 폴더(CLAUDE_CONFIG_DIR)의 Claude Code 로그인, 앱에 저장된 웹 로그인.
/// 메뉴바에는 기본 Claude Code 로그인이나 웹 로그인을 올릴 수 있다.
@MainActor
final class ClaudeUsageAccountProvider: UsageAccountProvider, UsageAccountMenuBarPolicy {
    let service = PopoverService.claude
    let cliName = "Claude Code"
    let configDirectoryVariable = "CLAUDE_CONFIG_DIR"
    let addMethods: [UsageAccountAddMethod] = [.browserImport, .inAppLogin, .sessionKey, .folder]
    let managedDirectoryRoot: URL? = nil
    var menuBar: (any UsageAccountMenuBarPolicy)? { self }

    private let store: ClaudeAccountStore

    init(store: ClaudeAccountStore = .shared) {
        self.store = store
    }

    func discoveryInput(directories: [String], knownIdentities: [String: UsageAccountIdentity])
        -> UsageAccountDiscoveryInput
    {
        let stored = store.accounts()
        let webLogins = stored.filter { $0.kind == .webSession }.map { account in
            UsageAccountWebLogin(
                id: account.id,
                identity: knownIdentities[account.id]
                    ?? UsageAccountIdentity(
                        email: account.identity.email, organizationName: account.identity.organizationName))
        }
        return UsageAccountDiscoveryInput(
            directories: directories, webLogins: webLogins,
            hasRegisteredDefaultLogin: stored.contains { $0.kind == .claudeCodeExternal })
    }

    nonisolated func candidates(_ input: UsageAccountDiscoveryInput) async -> [UsageAccountCandidate] {
        var result: [UsageAccountCandidate] = []
        let defaultSlot = ClaudeCodeLoginSlot.defaultSlot()
        if let identity = defaultSlot.identity() {
            var isLoggedIn = input.hasRegisteredDefaultLogin
            if !isLoggedIn { isLoggedIn = await ClaudeCodeLoginDetector.hasLogin() }
            if isLoggedIn {
                result.append(
                    .init(
                        source: .init(role: .defaultLogin, reference: defaultSlot.configDirectory.path),
                        identity: identity))
            }
        }
        for login in input.webLogins {
            result.append(.init(source: .init(role: .web, reference: login.id), identity: login.identity))
        }
        let folders = Self.siblingConfigDirectories().map(\.path) + input.directories
        var seen: Set<String> = []
        for path in folders where seen.insert(path).inserted {
            guard let identity = ClaudeCodeLoginSlot.folderSlot(URL(fileURLWithPath: path)).identity() else { continue }
            result.append(.init(source: .init(role: .directory, reference: path), identity: identity))
        }
        return result
    }

    /// `~/.claude-이름`처럼 기본 폴더 옆에 둔 CLAUDE_CONFIG_DIR 폴더
    nonisolated static func siblingConfigDirectories(home: URL = FileManager.default.realHomeDirectory) -> [URL] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: home, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        return entries.filter { url in
            let name = url.lastPathComponent
            return (name.hasPrefix(".claude-") || name.hasPrefix(".claude_"))
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        .sorted { $0.path < $1.path }
    }

    func badgeHelp(for role: UsageAccountSource.Role) -> String {
        switch role {
        case .defaultLogin: return "기본 Claude Code 로그인"
        case .directory: return "다른 폴더의 Claude Code 로그인"
        case .web: return "앱에 저장된 웹 로그인"
        }
    }

    func isRuntime(_ account: UsageAccount) -> Bool {
        guard let current = currentTarget else { return false }
        return targets(of: account).contains(current)
    }

    nonisolated static func runtimeAccount(
        provenance: ClaudeFetchProvenance, validatedIdentity: UsageAccountIdentity?,
        resolvedOrganizationID: String?, knownIdentities: [String: UsageAccountIdentity]
    ) -> UsageAccountCandidate? {
        switch provenance.source {
        case .oauth, .messagesHeaderFallback:
            return UsageAccountCandidate(
                source: .init(role: .defaultLogin, reference: ClaudeCodeLoginSlot.defaultSlot().configDirectory.path),
                identity: validatedIdentity ?? UsageAccountIdentity())
        case .webSession:
            guard let reference = provenance.accountID else { return nil }
            let identity: UsageAccountIdentity
            if let known = knownIdentities[reference], let organization = resolvedOrganizationID,
                known.organizationID == organization
            {
                identity = known
            } else {
                identity = UsageAccountIdentity(
                    organizationID: resolvedOrganizationID, organizationName: validatedIdentity?.organizationName)
            }
            return UsageAccountCandidate(source: .init(role: .web, reference: reference), identity: identity)
        }
    }

    func runtimeUsage(from snapshot: RuntimeProviderSnapshot) -> UsageAccountUsage? {
        snapshot.claudeUsage.map(UsageAccountUsage.init(claude:))
    }

    func fetchUsage(for account: UsageAccount, interactive: Bool) async throws -> UsageAccountFetchResult {
        if let web = account.source(.web) {
            guard let sessionKey = KeychainManager.shared.load(for: web.reference) else {
                throw UsageAccountFetchError.loginExpired
            }
            let stored = store.accounts().first { $0.id == web.reference }
            // 메뉴바 계정일 때 고른 조직(직접 고르지 않았으면 마지막으로 쓴 조직)을 그대로 쓴다.
            let organization = stored?.userSelectedPreferredOrganizationID ?? stored?.identity.organizationID
            let result = try await ClaudeWebUsageFetcher.fetch(sessionKey: sessionKey, organizationID: organization)
            return UsageAccountFetchResult(
                usage: UsageAccountUsage(claude: result.usage), learnedIdentity: (web.reference, result.identity))
        }
        let slot: ClaudeCodeLoginSlot
        if let directory = account.source(.directory) {
            slot = .folderSlot(URL(fileURLWithPath: directory.reference))
        } else if account.isDefaultLogin {
            slot = .defaultSlot()
        } else {
            throw UsageAccountFetchError.unavailable
        }
        // macOS 확인 창을 기다리는 동안 main을 막지 않는다.
        let usage = try await Task.detached(priority: .utility) {
            try await Self.fetchClaudeCodeUsage(slot: slot, interactive: interactive)
        }.value
        return UsageAccountFetchResult(usage: UsageAccountUsage(claude: usage))
    }

    /// 토큰이 곧 끝나면 그 로그인의 Claude Code가 갱신하게 한 뒤 다시 읽는다.
    nonisolated static func fetchClaudeCodeUsage(slot: ClaudeCodeLoginSlot, interactive: Bool) async throws
        -> ClaudeUsageResponse
    {
        var read = await slot.currentCredential(interactive: interactive)
        if case .credential(let credential) = read, credential.isExpired {
            switch await ClaudeCodeCLI.refreshLogin(configDirectory: slot.cliConfigDirectory) {
            case .refreshed: read = await slot.currentCredential(interactive: false)
            case .notLoggedIn: throw UsageAccountFetchError.loginExpired
            case .executableNotFound: throw UsageAccountFetchError.executableNotFound
            case .unavailable: throw UsageAccountFetchError.unavailable
            }
        }
        switch read {
        case .credential(let credential):
            guard !credential.isExpired else { throw UsageAccountFetchError.unavailable }
            return try await ClaudeWebUsageFetcher.fetchOAuthUsage(accessToken: credential.accessToken)
        case .needsPermission: throw UsageAccountFetchError.needsPermission
        case .missing: throw UsageAccountFetchError.loginExpired
        }
    }

    /// 바꾼 뒤 Claude Code로 이메일을 확인하므로 이메일과 Claude Code가 모두 있어야 한다.
    func canSwitch(to account: UsageAccount) -> Bool {
        !account.isDefaultLogin && account.source(.directory) != nil && account.identity.email != nil
            && ClaudeCodeCLI.executable() != nil
    }

    func switchPlan(for account: UsageAccount, name: String) -> UsageAccountSwitchPlan {
        UsageAccountSwitchPlan(
            message: "\(name) 계정으로 기본 Claude Code 로그인을 전환합니다. 지금 로그인은 그 계정이 있던 폴더로 옮깁니다.",
            confirmTitle: "전환", terminatesRunningApps: false)
    }

    func switchDefault(to account: UsageAccount, plan: UsageAccountSwitchPlan) async throws {
        guard let directory = account.source(.directory) else { throw AccountSwitchError.unavailable }
        let folder = URL(fileURLWithPath: directory.reference)
        let email = account.identity.email
        // 잠금을 기다리는 동안 main을 막지 않는다.
        try await Task.detached(priority: .userInitiated) {
            try await ClaudeAccountSwitcher.switchDefault(to: folder, expectedEmail: email)
        }.value
    }

    // MARK: - 메뉴바

    var currentTarget: String? { store.state().activeAccountID }

    func target(for account: UsageAccount) -> String? {
        let ids = targets(of: account)
        if let current = currentTarget, ids.contains(current) { return current }
        return ids.first(where: isClaudeAppLogin) ?? ids.first
    }

    func show(_ target: String) {
        store.setActiveAccountID(target)
    }

    /// Claude 앱 로그인을 먼저 메뉴바에 두고, 기본 Claude Code 로그인이 다른 계정이면 한 번 묻는다.
    func defaultChoice(among visible: [UsageAccount]) -> UsageAccountMenuBarDefault? {
        guard let claudeApp = visible.first(where: { targets(of: $0).contains(where: isClaudeAppLogin) }) else {
            return nil
        }
        let claudeCode = visible.first { $0.id != claudeApp.id && $0.isDefaultLogin }
        return UsageAccountMenuBarDefault(
            preferred: .init(account: claudeApp, origin: "Claude 앱"),
            alternative: claudeCode.map { .init(account: $0, origin: "Claude Code") })
    }

    /// Claude 앱 로그인, 기본 Claude Code 로그인, 나머지 웹 로그인 순
    func replacement(among visible: [UsageAccount]) -> UsageAccount? {
        let eligible = visible.filter { !isRuntime($0) && target(for: $0) != nil }
        return eligible.first { targets(of: $0).contains(where: isClaudeAppLogin) }
            ?? eligible.first(where: \.isDefaultLogin)
            ?? eligible.first
    }

    private func targets(of account: UsageAccount) -> [String] {
        account.sources.compactMap { source in
            switch source.role {
            case .defaultLogin: return ClaudeAccountStore.claudeCodeExternalAccountID
            case .web: return source.reference
            case .directory: return nil
            }
        }
    }

    private func isClaudeAppLogin(_ target: String) -> Bool {
        store.accounts().contains {
            $0.id == target && $0.kind == .webSession
                && ClaudeBrowserFamily.family(fromSourceDetail: $0.sourceDetail) == .claudeApp
        }
    }
}
