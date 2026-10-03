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
        detectRevertedSwitch()
        self.claudeRuntimeAccountID = claudeRuntimeAccountID
        onChange?()
    }

    private(set) var claudeRuntimeAccountID: String?
    @Published private(set) var revertedSwitch: [PopoverService: String] = [:]

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

    // MARK: - 계정 전환

    /// 전환은 다른 폴더에 로그인이 있는 계정만 할 수 있다. 기본 로그인과 그 폴더의 로그인을 맞바꾼다.
    func canSwitch(to account: UsageAccount) -> Bool {
        !account.isInUse && account.sources.contains { $0.kind == .claudeCodeDirectory || $0.kind == .codexDirectory }
    }

    /// 성공하면 nil, 실패하면 보여줄 문구를 돌려준다.
    func switchDefault(to account: UsageAccount, terminating running: CodexAccountSwitcher.RunningCodex?) async
        -> String?
    {
        do {
            if account.service == .codex {
                guard let folder = account.sources.first(where: { $0.kind == .codexDirectory }),
                    let workspace = account.identity.organizationID
                else { return "이 계정은 전환할 수 없습니다." }
                if let running, !running.isEmpty {
                    guard await CodexAccountSwitcher.terminate(running) else {
                        return "실행 중인 Codex를 종료하지 못했습니다. 직접 종료한 뒤 다시 시도하세요."
                    }
                }
                try await CodexAccountSwitcher.switchDefault(
                    to: URL(fileURLWithPath: folder.reference), expectedWorkspaceID: workspace)
            } else {
                guard let folder = account.sources.first(where: { $0.kind == .claudeCodeDirectory }) else {
                    return "이 계정은 전환할 수 없습니다."
                }
                let work = workDirectory
                let email = account.identity.email
                try await Task.detached(priority: .userInitiated) {
                    try await ClaudeAccountSwitcher.switchDefault(
                        to: URL(fileURLWithPath: folder.reference), expectedEmail: email, workDirectory: work)
                }.value
            }
            preferences.expectedDefault[account.service.rawValue] = account.identity
            discover(claudeRuntimeAccountID: claudeRuntimeAccountID)
            return nil
        } catch AccountSwitchError.busy {
            return "Claude Code가 로그인을 갱신하는 중입니다. 잠시 뒤 다시 시도하세요."
        } catch AccountSwitchError.cancelled {
            return "전환을 취소했습니다."
        } catch AccountSwitchError.verificationFailed {
            return "바꾼 로그인을 확인하지 못해 원래대로 되돌렸습니다."
        } catch {
            return "전환하지 못했습니다. 로그인은 바뀌지 않았습니다."
        }
    }

    /// 앱이 바꾼 기본 로그인이 나중에 다른 계정으로 돌아가 있으면 한 번 알린다.
    private func detectRevertedSwitch() {
        for service in [PopoverService.claude, .codex] {
            guard let expected = preferences.expectedDefault[service.rawValue],
                let current = accounts[service]?.first(where: \.isInUse)?.identity
            else { continue }
            let same =
                expected.mergeKey.map { $0 == current.mergeKey }
                ?? (expected.email?.lowercased() == current.email?.lowercased())
            guard !same else { continue }
            preferences.expectedDefault[service.rawValue] = nil
            let message =
                "\(service.providerKind.displayName) 기본 로그인이 \(expected.email ?? "전환한 계정")에서 \(current.email ?? "다른 계정")으로 바뀌어 있습니다."
            revertedSwitch[service] = message
            NotificationManager.shared.deliverAccountNotice(title: "계정 전환이 되돌려졌습니다", body: message)
        }
    }

    func dismissRevertNotice(_ service: PopoverService) { revertedSwitch[service] = nil }
}
