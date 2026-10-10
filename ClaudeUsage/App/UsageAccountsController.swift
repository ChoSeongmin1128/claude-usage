import Combine
import Foundation

/// 여러 계정 목록과 조회 결과. 메뉴바와 팝오버 큰 카드는 메뉴바 계정 하나를 쓰고, 이 컨트롤러는
/// 나머지 계정을 주기적으로 조회해 팝오버의 계정 줄과 설정의 계정 목록에 준다.
/// 서비스마다 다른 일은 `UsageAccountProvider`가 하고, 여기에는 서비스 분기가 없다.
@MainActor
final class UsageAccountsController: ObservableObject {
    /// 다른 계정 조회 주기. 앱의 주기 타이머도 이 값으로 돈다.
    static let refreshInterval: TimeInterval = 300
    /// 한 주기 안에서 계정을 차례로 조회하므로 뒤 계정은 늦게 시작한다. 그만큼 일찍 다음 차례로 본다.
    static let refreshTolerance: TimeInterval = 30

    let providers: [any UsageAccountProvider]
    @Published private(set) var accounts: [PopoverService: [UsageAccount]] = [:]
    @Published private(set) var states: [String: UsageAccountState] = [:]
    @Published private(set) var preferences: UsageAccountPreferences {
        didSet { if preferences != oldValue { preferences.save(to: defaults) } }
    }
    @Published private(set) var revertedSwitch: [PopoverService: String] = [:]

    var onChange: (() -> Void)?
    /// 메뉴바 계정 후보가 둘이면 한 번 묻는다. 고른 계정을 넘기면 메뉴바에 둔다.
    var onMenuBarChoiceNeeded: ((UsageAccountMenuBarDefault, @escaping (UsageAccount) -> Void) -> Void)?
    /// 기본 로그인을 전환한 뒤 메뉴바 계정 조회가 새 로그인을 읽게 한다.
    var onDefaultLoginSwitched: ((PopoverService) -> Void)?

    private let defaults: UserDefaults
    private let isServiceEnabled: (PopoverService) -> Bool
    private let notifyAccountChange: @MainActor (String, String) -> Void
    private var refreshTask: Task<Void, Never>?
    /// 조회를 기다리거나 조회 중인 계정. 같은 계정을 겹쳐 조회하지 않는다.
    private var queued: Set<String> = []
    /// 사용자가 "허용"을 누른 계정. 다음 조회 한 번만 macOS 확인 창을 띄운다.
    private var interactiveOnce: Set<String> = []
    private var discoveryTask: Task<Void, Never>?
    private var needsAnotherDiscovery = false
    private var runtimeAccounts: [PopoverService: UsageAccountCandidate] = [:]
    private var successfulBindings: [String: UsageAccountFetchBinding] = [:]
    private var askingMenuBarChoice: Set<PopoverService> = []
    /// 마지막으로 본 메뉴바 계정과 앱이 바꾼 메뉴바 계정. 다른 경로로 바뀌면 사용자가 고른 것으로 본다.
    private var lastMenuBarTarget: [PopoverService: String] = [:]
    private var scheduledMenuBarTarget: [PopoverService: String] = [:]

    /// adoptsCurrentMenuBarAccount: 이전 버전에서 고른 메뉴바 계정이 있으면 사용자가 고른 것으로 본다.
    /// 업데이트한 사용자의 메뉴바 계정이 기본 규칙(Claude 앱 로그인 먼저)으로 바뀌지 않게 한다.
    init(
        providers: [any UsageAccountProvider], defaults: UserDefaults = .standard,
        adoptsCurrentMenuBarAccount: Bool = false,
        notifyAccountChange: @escaping @MainActor (String, String) -> Void = { title, body in
            NotificationManager.shared.deliverAccountNotice(title: title, body: body)
        },
        isServiceEnabled: @escaping (PopoverService) -> Bool
    ) {
        self.providers = providers
        self.defaults = defaults
        self.isServiceEnabled = isServiceEnabled
        self.notifyAccountChange = notifyAccountChange
        self.adoptsCurrentMenuBarAccount = adoptsCurrentMenuBarAccount
        preferences = UsageAccountPreferences.load(from: defaults)
    }

    private var adoptsCurrentMenuBarAccount: Bool

    func provider(for service: PopoverService) -> (any UsageAccountProvider)? {
        providers.first { $0.service == service }
    }

    func supportsMultipleAccounts(_ service: PopoverService) -> Bool { provider(for: service) != nil }

    private var activeProviders: [any UsageAccountProvider] { providers.filter { isServiceEnabled($0.service) } }

    // MARK: - 목록

    /// 메뉴바 계정을 맨 위에 두고 나머지는 저장한 순서를 따른다.
    func orderedAccounts(for service: PopoverService) -> [UsageAccount] {
        let ordered = preferences.ordered(accounts[service] ?? [], service: service)
        return ordered.filter(isRuntime) + ordered.filter { !isRuntime($0) }
    }

    func visibleAccounts(for service: PopoverService) -> [UsageAccount] {
        orderedAccounts(for: service).filter { !preferences.hidden.contains($0.id) }
    }

    func isRuntime(_ account: UsageAccount) -> Bool {
        if let candidate = runtimeAccounts[account.service] {
            return account.matches(candidate)
        }
        return provider(for: account.service)?.isRuntime(account) ?? false
    }

    /// 검증한 payload와 같은 출처의 identity만 쓴다. 호출자가 같은 main actor 실행 안에서
    /// payload를 공개하므로 여기서 onChange를 먼저 부르지 않는다.
    func bindRuntimeAccount(_ candidate: UsageAccountCandidate?, for service: PopoverService) {
        runtimeAccounts[service] = candidate
        guard let candidate else { return }
        let candidates = (accounts[service] ?? []).flatMap { account in
            account.sources.filter { $0 != candidate.source }.map {
                UsageAccountCandidate(source: $0, identity: account.identity)
            }
        }
        let merged = UsageAccount.merge(candidates + [candidate], service: service)
        discardConflictingCachedUsage(in: [service: merged])
        carryOverRenamedAccounts(from: accounts, to: [service: merged])
        accounts[service] = merged
        preferences.remember(merged)
    }

    private func candidatesWithRuntimeAccount(
        _ candidates: [UsageAccountCandidate], service: PopoverService
    ) -> [UsageAccountCandidate] {
        guard let runtime = runtimeAccounts[service] else { return candidates }
        return candidates.filter { $0.source != runtime.source } + [runtime]
    }

    func isMultiAccountEnabled(_ service: PopoverService) -> Bool { preferences[service].isMultiAccountEnabled }

    /// 여러 계정을 켰고 계정이 2개 이상 보일 때만 여러 계정 화면을 쓴다. 아니면 메뉴바 계정 하나만 보인다.
    func isMultiAccount(_ service: PopoverService) -> Bool {
        isMultiAccountEnabled(service) && visibleAccounts(for: service).count >= 2
    }

    func setMultiAccountEnabled(_ enabled: Bool, for service: PopoverService) {
        preferences[service].isMultiAccountEnabled = enabled
        if enabled { refreshIfNeeded(force: true) }
        onChange?()
    }

    func popoverMode(for service: PopoverService) -> UsageAccountPreferences.PopoverMode {
        preferences[service].popoverMode
    }

    func setPopoverMode(_ mode: UsageAccountPreferences.PopoverMode, for service: PopoverService) {
        preferences[service].popoverMode = mode
        onChange?()
    }

    func isPinned(_ account: UsageAccount) -> Bool { preferences[account.service].pinnedTop == account.id }

    func togglePinned(_ account: UsageAccount) {
        preferences[account.service].pinnedTop = isPinned(account) ? nil : account.id
        onChange?()
    }

    func displayName(for account: UsageAccount) -> String {
        preferences.displayName(for: account, among: accounts[account.service] ?? [])
    }

    func badges(for account: UsageAccount) -> [AccountBadge] {
        account.roles.map { role in
            AccountBadge(title: role.badgeTitle, help: provider(for: account.service)?.badgeHelp(for: role) ?? "")
        }
    }

    func alias(for account: UsageAccount) -> String { preferences.aliases[account.id] ?? "" }
    func isHidden(_ account: UsageAccount) -> Bool { preferences.hidden.contains(account.id) }
    func isArchived(_ account: UsageAccount) -> Bool { preferences.archived.contains(account.id) }

    func selection(for service: PopoverService) -> [String] {
        preferences.selection(for: service, visible: visibleAccounts(for: service))
    }

    /// 사용자가 직접 추가한 폴더라 목록에서 뺄 수 있는지
    func isUserAdded(_ account: UsageAccount) -> Bool {
        let added = preferences[account.service].directories
        return account.sources.contains { $0.role == .directory && added.contains($0.reference) }
    }

    /// 앱이 만든 로그인 폴더. 앱이 늘 찾으므로 목록에서 빼는 대신 폴더를 지운다.
    func managedFolders(of account: UsageAccount) -> [URL] {
        guard let root = provider(for: account.service)?.managedDirectoryRoot?.standardizedFileURL.path else {
            return []
        }
        return account.sources.filter { $0.role == .directory && $0.reference.hasPrefix(root + "/") }
            .map { URL(fileURLWithPath: $0.reference, isDirectory: true) }
    }

    // MARK: - 찾기

    /// 계정 찾기를 예약한다. 이미 찾는 중이면 끝난 뒤 한 번 더 찾는다. 찾기는 한 번에 하나만 돌아
    /// 늦게 끝난 결과가 새 결과를 덮지 않는다.
    @discardableResult
    func rediscover() -> Task<Void, Never> {
        if let discoveryTask {
            needsAnotherDiscovery = true
            return discoveryTask
        }
        let task = Task { [weak self] in
            repeat {
                self?.needsAnotherDiscovery = false
                await self?.discover()
            } while self?.needsAnotherDiscovery == true
            self?.discoveryTask = nil
        }
        discoveryTask = task
        return task
    }

    /// 지금 상태로 찾기를 마칠 때까지 기다린다.
    func discoverAndWait() async {
        await rediscover().value
    }

    private func discover() async {
        var found: [PopoverService: [UsageAccount]] = [:]
        var discovered: [PopoverService: [UsageAccount]] = [:]
        for provider in activeProviders {
            let service = provider.service
            let input = provider.discoveryInput(
                directories: preferences[service].directories, knownIdentities: preferences.knownIdentities)
            let candidates = await Task.detached(priority: .utility) { await provider.candidates(input) }.value
            discovered[service] = UsageAccount.merge(candidates, service: service)
            found[service] = UsageAccount.merge(
                candidatesWithRuntimeAccount(
                    candidatesWithObservedOwners(candidates, service: service), service: service),
                service: service)
        }
        discardConflictingCachedUsage(in: found)
        carryOverRenamedAccounts(from: accounts, to: found)
        accounts = found
        preferences.remember(found.values.flatMap { $0 })
        detectRevertedSwitch(in: discovered)
        for provider in activeProviders { applyMenuBarDefault(provider) }
        onChange?()
    }

    private func candidatesWithObservedOwners(
        _ candidates: [UsageAccountCandidate], service: PopoverService
    ) -> [UsageAccountCandidate] {
        candidates.map { candidate in
            guard candidate.identity.mergeKey == nil,
                let previous = accounts[service]?.first(where: { $0.sources.contains(candidate.source) }),
                let binding = successfulBindings[previous.id], binding.account.source == candidate.source,
                binding.account.identity.mergeKey != nil, binding.matchesOwner(of: candidate.identity)
            else { return candidate }
            // Incomplete discovery labels do not erase the last verified payload owner.
            return binding.account
        }
    }

    /// 웹 로그인의 계정을 확인하면 id가 출처 기준에서 계정 기준으로 바뀐다. 이름, 숨김, 조회 결과를 옮긴다.
    private func carryOverRenamedAccounts(
        from previous: [PopoverService: [UsageAccount]], to current: [PopoverService: [UsageAccount]]
    ) {
        var updated = preferences
        for (service, accounts) in current {
            for account in accounts {
                // 이전 id가 출처 기준이었던 계정만 옮긴다. 계정 기준 id끼리는 기본 로그인을 전환해 출처가
                // 맞바뀌어도 서로 다른 계정이다.
                guard account.identity.mergeKey != nil,
                    let old = previous[service]?.first(where: { candidate in
                        candidate.identity.mergeKey == nil && candidate.id != account.id
                            && candidate.sources.contains(where: account.sources.contains)
                    }), updated.aliases[account.id] == nil, states[account.id] == nil
                else { continue }
                guard
                    successfulBindings[old.id]?.matchesOwner(of: account.identity)
                        ?? UsageAccountFetchBinding.matches(expected: old.identity, observed: account.identity)
                else { continue }
                updated.aliases[account.id] = updated.aliases.removeValue(forKey: old.id)
                if updated.hidden.remove(old.id) != nil { updated.hidden.insert(account.id) }
                if updated.archived.remove(old.id) != nil { updated.archived.insert(account.id) }
                if updated[service].pinnedTop == old.id { updated[service].pinnedTop = account.id }
                updated[service].selected = updated[service].selected.map { $0 == old.id ? account.id : $0 }
                states[account.id] = states.removeValue(forKey: old.id)
                successfulBindings[account.id] = successfulBindings.removeValue(forKey: old.id)
            }
        }
        preferences = updated
    }

    private func discardConflictingCachedUsage(in found: [PopoverService: [UsageAccount]]) {
        for account in found.values.flatMap({ $0 }) {
            guard let binding = successfulBindings[account.id], !binding.matchesOwner(of: account.identity) else {
                continue
            }
            states[account.id] = nil
            successfulBindings[account.id] = nil
        }
    }

    // MARK: - 메뉴바 계정

    func canShowInMenuBar(_ account: UsageAccount) -> Bool {
        provider(for: account.service)?.menuBar?.target(for: account) != nil && !isRuntime(account)
    }

    func showInMenuBar(_ account: UsageAccount) {
        guard let policy = provider(for: account.service)?.menuBar, let target = policy.target(for: account) else {
            return
        }
        preferences[account.service].isMenuBarAccountChosen = true
        preferences.hidden.remove(account.id)
        if target != policy.currentTarget { show(target, policy: policy, service: account.service) }
        onChange?()
    }

    /// 메뉴바 계정을 숨기면 다음 계정이 메뉴바로 온다. 대신할 계정이 없으면 숨길 수 없다.
    func canHide(_ account: UsageAccount) -> Bool {
        guard isRuntime(account) else { return true }
        return replacementForMenuBar(excluding: account) != nil
    }

    private func replacementForMenuBar(excluding account: UsageAccount) -> UsageAccount? {
        provider(for: account.service)?.menuBar?.replacement(
            among: visibleAccounts(for: account.service).filter { $0.id != account.id })
    }

    /// 숨긴 계정이 메뉴바에 남지 않게 하고, 사용자가 정하기 전에는 서비스가 정한 기본 계정을 메뉴바에 둔다.
    private func applyMenuBarDefault(_ provider: any UsageAccountProvider) {
        guard let policy = provider.menuBar else { return }
        let service = provider.service
        let current = policy.currentTarget
        if adoptsCurrentMenuBarAccount, current != nil, lastMenuBarTarget[service] == nil {
            preferences[service].isMenuBarAccountChosen = true
        }
        if let last = lastMenuBarTarget[service], let current, current != last,
            current != scheduledMenuBarTarget[service]
        {
            preferences[service].isMenuBarAccountChosen = true
        }
        lastMenuBarTarget[service] = current

        if let runtime = accounts[service]?.first(where: provider.isRuntime), preferences.hidden.contains(runtime.id) {
            if let replacement = replacementForMenuBar(excluding: runtime), let target = policy.target(for: replacement)
            {
                show(target, policy: policy, service: service)
            }
            return
        }
        guard !preferences[service].isMenuBarAccountChosen,
            let choice = policy.defaultChoice(among: visibleAccounts(for: service))
        else { return }
        if let target = policy.target(for: choice.preferred.account), target != current {
            show(target, policy: policy, service: service)
        }
        guard choice.alternative != nil, let ask = onMenuBarChoiceNeeded, askingMenuBarChoice.insert(service).inserted
        else { return }
        Task { @MainActor [weak self] in
            ask(choice) { picked in
                self?.askingMenuBarChoice.remove(service)
                self?.showInMenuBar(picked)
            }
        }
    }

    /// 저장소를 바꾸면 다시 찾기가 불리므로 지금 찾는 중인 흐름이 끝난 뒤 바꾼다.
    private func show(_ target: String, policy: any UsageAccountMenuBarPolicy, service: PopoverService) {
        scheduledMenuBarTarget[service] = target
        Task { @MainActor in policy.show(target) }
    }

    // MARK: - 조회

    func refreshIfNeeded(force: Bool = false) {
        let now = Date()
        let due = activeProviders.filter { preferences[$0.service].isMultiAccountEnabled }.flatMap { provider in
            (accounts[provider.service] ?? []).filter { account in
                !preferences.hidden.contains(account.id) && !preferences.archived.contains(account.id)
                    && !provider.isRuntime(account) && !queued.contains(account.id)
                    && (force || isDue(states[account.id], now: now))
            }
        }
        guard !due.isEmpty else { return }
        queued.formUnion(due.map(\.id))
        let previous = refreshTask
        refreshTask = Task { [weak self] in
            await previous?.value
            for account in due {
                guard let self, !Task.isCancelled else { return }
                await self.refresh(account)
            }
        }
    }

    private func isDue(_ state: UsageAccountState?, now: Date) -> Bool {
        guard let attempted = state?.attemptedAt else { return true }
        return now.timeIntervalSince(attempted) >= Self.refreshInterval - Self.refreshTolerance
    }

    func grantPermission(for account: UsageAccount) {
        interactiveOnce.insert(account.id)
        refresh(soon: account)
    }

    private func refresh(soon account: UsageAccount) {
        guard queued.insert(account.id).inserted else { return }
        let previous = refreshTask
        refreshTask = Task { [weak self] in
            await previous?.value
            await self?.refresh(account)
        }
    }

    private func refresh(_ queuedAccount: UsageAccount) async {
        defer { queued.remove(queuedAccount.id) }
        guard let provider = provider(for: queuedAccount.service),
            let account = accounts[queuedAccount.service]?.first(where: { $0.id == queuedAccount.id }),
            canRefresh(account, provider: provider)
        else { return }
        let interactive = interactiveOnce.remove(account.id) != nil
        var state = states[account.id] ?? UsageAccountState()
        state.attemptedAt = Date()
        do {
            let result = try await provider.fetchUsage(for: account, interactive: interactive)
            try Task.checkCancellation()
            guard account.sources.contains(result.binding.account.source) else {
                rediscover()
                return
            }
            try await provider.validateFetchBinding(result.binding)
            try Task.checkCancellation()
            guard let current = currentAccount(for: account, binding: result.binding),
                canRefresh(current, provider: provider)
            else {
                rediscover()
                return
            }
            guard result.binding.matchesOwner(of: account.identity), result.binding.matchesOwner(of: current.identity)
            else {
                rememberLearnedIdentity(result)
                rediscover()
                return
            }
            let destination =
                current.identity.mergeKey == nil
                ? adoptObservedAccount(result.binding.account, replacing: current) : current
            guard canRefresh(destination, provider: provider) else { return }
            state.usage = result.usage
            state.fetchedAt = Date()
            state.consecutiveFailures = 0
            state.issue = nil
            successfulBindings[destination.id] = result.binding
            states[destination.id] = state
            let learned = rememberLearnedIdentity(result)
            onChange?()
            if learned { rediscover() }
            return
        } catch UsageAccountFetchError.accountChanged {
            rediscover()
            return
        } catch UsageAccountFetchError.loginExpired {
            state.issue = .loginExpired
        } catch UsageAccountFetchError.needsPermission {
            state.issue = .needsPermission
        } catch UsageAccountFetchError.executableNotFound {
            state.consecutiveFailures += 1
            state.issue = .executableNotFound
        } catch is CancellationError {
            return
        } catch {
            state.consecutiveFailures += 1
            state.issue = nil
        }
        guard !Task.isCancelled, let current = accounts[account.service]?.first(where: { $0.id == account.id }),
            current.identity == account.identity, current.sources == account.sources,
            canRefresh(current, provider: provider)
        else { return }
        states[account.id] = state
        onChange?()
    }

    private func canRefresh(_ account: UsageAccount, provider: any UsageAccountProvider) -> Bool {
        isServiceEnabled(account.service) && preferences[account.service].isMultiAccountEnabled
            && !preferences.hidden.contains(account.id) && !preferences.archived.contains(account.id)
            && !provider.isRuntime(account)
    }

    private func currentAccount(for captured: UsageAccount, binding: UsageAccountFetchBinding) -> UsageAccount? {
        let current = accounts[captured.service]?.first { $0.sources.contains(binding.account.source) }
        guard let current else { return nil }
        if captured.identity.mergeKey != nil, current.id != captured.id { return nil }
        return current
    }

    @discardableResult
    private func rememberLearnedIdentity(_ result: UsageAccountFetchResult) -> Bool {
        guard let learned = result.learnedIdentity,
            result.binding.account.source == UsageAccountSource(role: .web, reference: learned.reference),
            learned.identity == result.binding.account.identity,
            preferences.knownIdentities[learned.reference] != learned.identity
        else { return false }
        preferences.knownIdentities[learned.reference] = learned.identity
        return true
    }

    private func adoptObservedAccount(_ candidate: UsageAccountCandidate, replacing account: UsageAccount)
        -> UsageAccount
    {
        let previous = accounts
        let candidates = (accounts[account.service] ?? []).flatMap { value in
            value.sources.filter { $0 != candidate.source }.map {
                UsageAccountCandidate(source: $0, identity: value.identity)
            }
        }
        let merged = UsageAccount.merge(candidates + [candidate], service: account.service)
        let destination = merged.first { $0.matches(candidate) }!
        let hadState = states[destination.id] != nil
        carryOverRenamedAccounts(from: previous, to: [account.service: merged])
        // A mutable CLI directory's older anonymous values have no proven owner.
        if candidate.source.role != .web, destination.id != account.id, !hadState {
            states[destination.id] = nil
            successfulBindings[destination.id] = nil
        }
        accounts[account.service] = merged
        preferences.remember(merged)
        return destination
    }

    // MARK: - 사용자 동작

    func toggleSelection(_ id: String, service: PopoverService) {
        var current = selection(for: service)
        if let index = current.firstIndex(of: id) {
            guard current.count > 1 else { return }
            current.remove(at: index)
        } else {
            current.append(id)
        }
        preferences[service].selected = current
        onChange?()
    }

    func setHidden(_ hidden: Bool, _ account: UsageAccount) {
        if hidden, isRuntime(account) {
            guard let replacement = replacementForMenuBar(excluding: account) else { return }
            preferences.hidden.insert(account.id)
            showInMenuBar(replacement)
            return
        }
        if hidden { preferences.hidden.insert(account.id) } else { preferences.hidden.remove(account.id) }
        onChange?()
    }

    func setArchived(_ archived: Bool, _ account: UsageAccount) {
        if archived { preferences.archived.insert(account.id) } else { preferences.archived.remove(account.id) }
        if !archived { refresh(soon: account) }
        onChange?()
    }

    func rename(_ account: UsageAccount, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.aliases[account.id] = trimmed.isEmpty ? nil : trimmed
        onChange?()
    }

    func addDirectory(_ url: URL, service: PopoverService) {
        if !preferences[service].directories.contains(url.path) { preferences[service].directories.append(url.path) }
        Task {
            await discoverAndWait()
            refreshIfNeeded(force: true)
        }
    }

    /// 사용자가 추가한 폴더만 목록에서 뺀다. 폴더와 그 안의 로그인은 지우지 않는다.
    func removeDirectory(_ account: UsageAccount) {
        let paths = Set(account.sources.map(\.reference))
        preferences[account.service].directories.removeAll { paths.contains($0) }
        rediscover()
    }

    /// 앱이 만든 로그인 폴더를 휴지통으로 옮긴다. 그 계정의 로그인은 서비스에서 끊기지 않는다.
    func deleteManagedLogin(_ account: UsageAccount) -> Bool {
        let folders = managedFolders(of: account)
        guard !folders.isEmpty else { return false }
        for folder in folders {
            guard (try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)) != nil else { return false }
        }
        states[account.id] = nil
        successfulBindings[account.id] = nil
        if account.sources.allSatisfy({ source in
            folders.contains { source.reference == $0.path || source.reference.hasPrefix($0.path + "/") }
        }) {
            ResetCreditSeenStore.remove(accountKey: account.id, defaults: defaults)
        }
        rediscover()
        return true
    }

    func removeResetCreditStateForDeletedWebLogin(_ reference: String) {
        ResetCreditSeenStore.removeWebSession(reference: reference, defaults: defaults)
        for account in accounts[.claude] ?? []
        where !account.sources.isEmpty
            && account.sources.allSatisfy({ $0.role == .web && $0.reference == reference })
        {
            ResetCreditSeenStore.remove(accountKey: account.id, defaults: defaults)
        }
    }

    // MARK: - 기본 로그인 전환

    func canSwitch(to account: UsageAccount) -> Bool {
        provider(for: account.service)?.canSwitch(to: account) ?? false
    }

    func switchPlan(for account: UsageAccount) -> UsageAccountSwitchPlan? {
        provider(for: account.service)?.switchPlan(for: account, name: displayName(for: account))
    }

    /// 성공하면 nil, 실패하면 보여줄 문구를 돌려준다.
    func switchDefault(to account: UsageAccount, plan: UsageAccountSwitchPlan) async -> String? {
        guard let provider = provider(for: account.service) else { return "이 계정은 전환할 수 없습니다." }
        do {
            try await provider.switchDefault(to: account, plan: plan)
        } catch let error as AccountSwitchError {
            return Self.message(for: error, cliName: provider.cliName)
        } catch {
            return "전환하지 못했습니다. 로그인은 바뀌지 않았습니다."
        }
        preferences[account.service].expectedDefault = account.identity
        onDefaultLoginSwitched?(account.service)
        await discoverAndWait()
        refreshIfNeeded(force: true)
        return nil
    }

    static func message(for error: AccountSwitchError, cliName: String) -> String {
        switch error {
        case .busy: return "\(cliName)가 로그인을 갱신하는 중입니다. 잠시 뒤 다시 시도하세요."
        case .cancelled: return "전환을 취소했습니다."
        case .verificationFailed: return "전환한 로그인을 확인하지 못해 원래대로 되돌렸습니다."
        case .rollbackFailed: return "전환한 로그인을 확인하지 못했고 되돌리지도 못했습니다. \(cliName)에 다시 로그인하세요."
        case .runningAppsNotTerminated: return "실행 중인 \(cliName)를 종료하지 못했습니다. 직접 종료한 뒤 다시 시도하세요."
        case .runningAppsStarted: return "그사이 \(cliName)가 실행됐습니다. 다시 시도하세요."
        case .unavailable, .writeFailed: return "전환하지 못했습니다. 로그인은 바뀌지 않았습니다."
        }
    }

    /// 앱이 바꾼 기본 로그인이 나중에 다른 계정으로 돌아가 있으면 한 번 알린다.
    private func detectRevertedSwitch(in discovered: [PopoverService: [UsageAccount]]) {
        for provider in activeProviders {
            let service = provider.service
            guard let expected = preferences[service].expectedDefault,
                let current = discovered[service]?.first(where: \.isDefaultLogin)?.identity,
                !expected.isSameAccount(as: current)
            else { continue }
            preferences[service].expectedDefault = nil
            let message =
                "\(service.displayName) 기본 로그인이 \(expected.email ?? "전환한") 계정에서 \(current.email ?? "다른") 계정으로 바뀌었습니다."
            revertedSwitch[service] = message
            notifyAccountChange("기본 로그인이 바뀌었습니다", message)
        }
    }

    func dismissRevertNotice(_ service: PopoverService) { revertedSwitch[service] = nil }
}
