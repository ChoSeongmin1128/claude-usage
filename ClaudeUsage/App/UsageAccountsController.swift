import Combine
import Foundation

/// 여러 계정 화면의 계정 목록과 조회 결과. 메뉴바와 기존 팝오버 본문은 지금처럼 활성 계정 하나를 쓰고,
/// 이 컨트롤러는 그 밖의 계정을 5분마다 조회해 팝오버 아래쪽 줄과 설정의 계정 목록에 준다.
@MainActor
final class UsageAccountsController: ObservableObject {
    static let refreshInterval: TimeInterval = 300

    @Published private(set) var accounts: [PopoverService: [UsageAccount]] = [:]
    @Published private(set) var states: [String: UsageAccountState] = [:]
    @Published var preferences: UsageAccountPreferences {
        didSet { if preferences != oldValue { preferences.save(to: defaults) } }
    }

    private let defaults: UserDefaults
    private var refreshTask: Task<Void, Never>?
    private var permissionGranted: Set<String> = []
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = UsageAccountPreferences.load(from: defaults)
    }

    var workDirectory: URL {
        CodexHomeAccount.managedRoot.deletingLastPathComponent().appendingPathComponent(
            "claude-cli-work", isDirectory: true)
    }

    // MARK: - 목록

    func visibleAccounts(for service: PopoverService) -> [UsageAccount] {
        preferences.ordered((accounts[service] ?? []).filter { !preferences.hidden.contains($0.id) })
    }

    /// 계정이 2개 이상 보일 때만 여러 계정 화면을 쓴다. 1개면 지금 화면 그대로다.
    func isMultiAccount(_ service: PopoverService) -> Bool {
        visibleAccounts(for: service).count >= 2
    }

    func discover(claudeRuntimeAccountID: String?) {
        let claude = UsageAccount.merge(claudeCandidates(), service: .claude)
        let codex = UsageAccount.merge(codexCandidates(), service: .codex)
        accounts = [.claude: claude, .codex: codex]
        var updated = preferences
        updated.remember(claude + codex)
        preferences = updated
        self.claudeRuntimeAccountID = claudeRuntimeAccountID
        onChange?()
    }

    private(set) var claudeRuntimeAccountID: String?

    /// 지금 메뉴바와 팝오버 본문이 보여주는 계정. 이 계정은 따로 조회하지 않는다.
    func isRuntimeAccount(_ account: UsageAccount) -> Bool {
        account.sources.contains { source in
            switch source.kind {
            case .claudeCodeDefault: return claudeRuntimeAccountID == ClaudeAccountStore.claudeCodeExternalAccountID
            case .claudeWeb: return claudeRuntimeAccountID == source.reference
            case .codexDefault: return true
            case .claudeCodeDirectory, .codexDirectory: return false
            }
        }
    }

    private func claudeCandidates() -> [UsageAccountCandidate] {
        var result: [UsageAccountCandidate] = []
        let stored = ClaudeAccountStore.shared.accounts()
        if stored.contains(where: { $0.kind == .claudeCodeExternal }) || ClaudeCodeLoginDetector.hasLogin(),
            let identity = ClaudeCodeDirectoryAccount.identity(configDirectory: nil)
        {
            result.append(.init(source: .init(kind: .claudeCodeDefault, reference: "~/.claude"), identity: identity))
        }
        for account in stored where account.kind == .webSession {
            let known = preferences.knownIdentities[account.id]
            result.append(
                .init(
                    source: .init(kind: .claudeWeb, reference: account.id),
                    identity: known
                        ?? .init(email: account.identity.email, organizationName: account.identity.organizationName)))
        }
        let directories = ClaudeCodeDirectoryAccount.discoverDirectories().map(\.path) + preferences.claudeDirectories
        for path in Array(NSOrderedSet(array: directories)) as? [String] ?? [] {
            let url = URL(fileURLWithPath: path)
            guard let identity = ClaudeCodeDirectoryAccount.identity(configDirectory: url) else { continue }
            result.append(.init(source: .init(kind: .claudeCodeDirectory, reference: path), identity: identity))
        }
        return result
    }

    private func codexCandidates() -> [UsageAccountCandidate] {
        var result: [UsageAccountCandidate] = []
        let defaultHome = URL(fileURLWithPath: CodexAuthManager.defaultAuthJsonPath()).deletingLastPathComponent()
        if let identity = CodexHomeAccount.identity(home: defaultHome) {
            result.append(.init(source: .init(kind: .codexDefault, reference: defaultHome.path), identity: identity))
        }
        let homes =
            CodexHomeAccount.discoverHomes(managedRoot: CodexHomeAccount.managedRoot).map(\.path)
            + preferences.codexDirectories
        for path in Array(NSOrderedSet(array: homes)) as? [String] ?? [] where path != defaultHome.path {
            guard let identity = CodexHomeAccount.identity(home: URL(fileURLWithPath: path)) else { continue }
            result.append(.init(source: .init(kind: .codexDirectory, reference: path), identity: identity))
        }
        return result
    }

    // MARK: - 조회

    func refreshIfNeeded(force: Bool = false) {
        guard refreshTask == nil else { return }
        let targets = (accounts[.claude] ?? []) + (accounts[.codex] ?? [])
        let now = Date()
        let due = targets.filter { account in
            guard !preferences.hidden.contains(account.id), !preferences.archived.contains(account.id),
                !isRuntimeAccount(account)
            else { return false }
            guard !force, let fetched = states[account.id]?.fetchedAt else { return true }
            return now.timeIntervalSince(fetched) >= Self.refreshInterval
        }
        guard !due.isEmpty else { return }
        refreshTask = Task { [weak self] in
            for account in due {
                guard let self, !Task.isCancelled else { break }
                await self.refresh(account)
            }
            self?.refreshTask = nil
        }
    }

    func grantPermission(for account: UsageAccount) {
        permissionGranted.insert(account.id)
        Task { await refresh(account) }
    }

    private func refresh(_ account: UsageAccount) async {
        var state = states[account.id] ?? UsageAccountState()
        let interactive = permissionGranted.remove(account.id) != nil
        do {
            if account.service == .codex {
                guard let source = account.sources.first(where: { $0.kind == .codexDirectory }) else { return }
                state.codexUsage = try await CodexHomeAccount.fetchUsage(home: URL(fileURLWithPath: source.reference))
            } else if let web = account.sources.first(where: { $0.kind == .claudeWeb }),
                let key = KeychainManager.shared.load(for: web.reference)
            {
                let preferred = ClaudeAccountStore.shared.accounts().first { $0.id == web.reference }?
                    .userSelectedPreferredOrganizationID
                let result = try await ClaudeWebAccountFetcher.fetch(
                    sessionKey: key, preferredOrganizationID: preferred)
                state.claudeUsage = result.usage
                if preferences.knownIdentities[web.reference] != result.identity {
                    preferences.knownIdentities[web.reference] = result.identity
                    discover(claudeRuntimeAccountID: claudeRuntimeAccountID)
                }
            } else if let directory = account.sources.first(where: { $0.kind == .claudeCodeDirectory }) {
                state.claudeUsage = try await fetchClaudeDirectory(
                    URL(fileURLWithPath: directory.reference), interactive: interactive)
            } else {
                return
            }
            state.fetchedAt = Date()
            state.consecutiveFailures = 0
            state.loginExpired = false
            state.needsPermission = false
        } catch UsageAccountFetchError.loginExpired {
            state.loginExpired = true
        } catch UsageAccountFetchError.needsPermission {
            state.needsPermission = true
        } catch is CancellationError {
            return
        } catch {
            state.consecutiveFailures += 1
            if state.fetchedAt == nil { state.fetchedAt = Date() }
        }
        states[account.id] = state
        onChange?()
    }

    private func fetchClaudeDirectory(_ directory: URL, interactive: Bool) async throws -> ClaudeUsageResponse {
        var read = ClaudeCodeDirectoryAccount.readToken(configDirectory: directory, interactive: interactive)
        if case .token(_, let expiresAt?) = read, expiresAt.timeIntervalSinceNow < 300 {
            guard
                await ClaudeCodeDirectoryAccount.refreshViaCLI(configDirectory: directory, workDirectory: workDirectory)
            else { throw UsageAccountFetchError.loginExpired }
            read = ClaudeCodeDirectoryAccount.readToken(configDirectory: directory, interactive: false)
        }
        switch read {
        case .token(let token, _): return try await ClaudeCodeDirectoryAccount.fetchUsage(accessToken: token)
        case .needsPermission: throw UsageAccountFetchError.needsPermission
        case .missing: throw UsageAccountFetchError.loginExpired
        }
    }

    // MARK: - 사용자 동작

    func toggleSelection(_ id: String, service: PopoverService) {
        var current = preferences.selection(for: service, visible: visibleAccounts(for: service))
        if let index = current.firstIndex(of: id) {
            guard current.count > 1 else { return }
            current.remove(at: index)
        } else {
            current.append(id)
        }
        preferences.selected[service.rawValue] = current
        onChange?()
    }

    func setHidden(_ hidden: Bool, _ id: String) {
        if hidden { preferences.hidden.insert(id) } else { preferences.hidden.remove(id) }
        onChange?()
    }

    func setArchived(_ archived: Bool, _ account: UsageAccount) {
        if archived { preferences.archived.insert(account.id) } else { preferences.archived.remove(account.id) }
        if !archived { Task { await refresh(account) } }
        onChange?()
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.aliases[id] = trimmed.isEmpty ? nil : trimmed
        onChange?()
    }

    func addDirectory(_ url: URL, service: PopoverService) {
        switch service {
        case .claude where !preferences.claudeDirectories.contains(url.path):
            preferences.claudeDirectories.append(url.path)
        case .codex where !preferences.codexDirectories.contains(url.path):
            preferences.codexDirectories.append(url.path)
        default: break
        }
        discover(claudeRuntimeAccountID: claudeRuntimeAccountID)
        refreshIfNeeded(force: true)
    }

    /// 사용자가 추가한 폴더만 목록에서 뺀다. 폴더와 그 안의 로그인은 지우지 않는다.
    func removeDirectory(_ account: UsageAccount) {
        let paths = Set(account.sources.map(\.reference))
        preferences.claudeDirectories.removeAll { paths.contains($0) }
        preferences.codexDirectories.removeAll { paths.contains($0) }
        preferences.hidden.insert(account.id)
        discover(claudeRuntimeAccountID: claudeRuntimeAccountID)
    }
}
