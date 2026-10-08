import AppKit
import Combine

extension AppDelegate {
    static func makeUsageAccountsController() -> UsageAccountsController {
        // 이 버전에서 처음 실행하는 기존 설치는 이전에 고른 메뉴바 계정을 그대로 쓴다.
        let isFirstRunWithAccounts = UserDefaults.standard.data(forKey: UsageAccountPreferences.key) == nil
        return UsageAccountsController(
            providers: [ClaudeUsageAccountProvider(), CodexUsageAccountProvider()],
            adoptsCurrentMenuBarAccount: isFirstRunWithAccounts && AppSettings.shared.welcomeState != .pending,
            isServiceEnabled: { AppSettings.shared.isProviderEnabled($0.providerKind) })
    }

    func bootstrapUsageAccounts() {
        let controller = usageAccountsController
        controller.onChange = { [weak self] in self?.updatePopoverViewModel() }
        controller.onMenuBarChoiceNeeded = { [weak self] choice, completion in
            self?.askMenuBarAccount(choice, completion: completion)
        }
        controller.onDefaultLoginSwitched = { [weak self] service in self?.defaultLoginDidSwitch(service) }
        popoverViewModel.accountActions = PopoverAccountActions(
            toggle: { [weak controller] service, id in controller?.toggleSelection(id, service: service) },
            reconnect: { [weak self] service, _ in
                self?.closePopover()
                AppSettings.shared.settingsLastTab = ServiceSelectionHelper.settingsRootTab(for: service)
                self?.showSettingsWindow()
            },
            allow: { [weak controller] service, id in
                guard let account = controller?.visibleAccounts(for: service).first(where: { $0.id == id }) else {
                    return
                }
                controller?.grantPermission(for: account)
            })
        usageAccountsObserver = NotificationCenter.default.addObserver(
            forName: .claudeAccountsDidChange, object: nil, queue: .main
        ) { [weak controller] _ in
            MainActor.assumeIsolated { controller?.rediscover() }
        }
        // 서비스를 켜고 끄면 그 서비스의 계정을 찾거나 목록에서 뺀다.
        let enabledServices = {
            MainActor.assumeIsolated {
                Set(PopoverService.allCases.filter { AppSettings.shared.isProviderEnabled($0.providerKind) })
            }
        }
        usageAccountsProviderObservation = AppSettings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .map { _ in enabledServices() }
            .prepend(enabledServices())
            .removeDuplicates()
            .dropFirst()
            .sink { [weak controller] _ in
                Task { @MainActor in
                    await controller?.discoverAndWait()
                    controller?.refreshIfNeeded()
                }
            }
        usageAccountsTimer = Timer.scheduledTimer(
            withTimeInterval: UsageAccountsController.refreshInterval, repeats: true
        ) { [weak controller] _ in
            MainActor.assumeIsolated { controller?.refreshIfNeeded() }
        }
        Task {
            await controller.discoverAndWait()
            controller.refreshIfNeeded()
        }
    }

    /// 메뉴바 계정 후보가 둘일 때 한 번만 묻는다. 기본 버튼은 서비스가 먼저 고른 계정이다.
    private func askMenuBarAccount(
        _ choice: UsageAccountMenuBarDefault, completion: @escaping (UsageAccount) -> Void
    ) {
        guard let alternative = choice.alternative else { return }
        let controller = usageAccountsController
        let preferred = choice.preferred
        let preferredName = controller.displayName(for: preferred.account)
        let alternativeName = controller.displayName(for: alternative.account)
        let alert = NSAlert()
        alert.messageText = "메뉴바에 표시할 \(preferred.account.service.displayName) 계정"
        alert.informativeText =
            "\(preferred.origin): \(preferredName)\n\(alternative.origin): \(alternativeName)"
        alert.addButton(withTitle: "\(preferredName) (\(preferred.origin))")
        alert.addButton(withTitle: "\(alternativeName) (\(alternative.origin))")
        NSApp.activate(ignoringOtherApps: true)
        completion(alert.runModal() == .alertSecondButtonReturn ? alternative.account : preferred.account)
    }

    private func defaultLoginDidSwitch(_ service: PopoverService) {
        switch service {
        case .claude:
            handleClaudeCredentialContextChanged(refreshOAuthCredentialInventory: true)
        case .codex:
            CodexAuthManager.shared.clearCache()
            refreshCodexUsage(force: true)
        case .antigravity:
            break
        }
    }

    func multiAccountPresentations() -> [PopoverService: MultiAccountPresentation] {
        let controller = usageAccountsController
        var result: [PopoverService: MultiAccountPresentation] = [:]
        for provider in controller.providers where controller.isMultiAccount(provider.service) {
            let service = provider.service
            let visible = controller.visibleAccounts(for: service)
            let runtime = runtimeProviderSnapshot(for: service)
            let runtimeUsage = provider.runtimeUsage(from: runtime)
            let basis = AppSettings.shared.usageValueBasis(for: service)
            let rows = visible.map { account -> PopoverAccountRowData in
                let candidate = runtime.lastSuccessfulMetadata?.account
                let isRuntime =
                    controller.isRuntime(account)
                    && candidate.map {
                        account.matches($0)
                    } == true
                let state = controller.states[account.id] ?? UsageAccountState()
                return PopoverAccountRowData(
                    id: account.id, service: service, name: controller.displayName(for: account),
                    badges: controller.badges(for: account),
                    status: isRuntime
                        ? runtime.accountRowStatus(hasUsage: runtimeUsage != nil)
                        : state.status(isArchived: controller.isArchived(account)),
                    usage: isRuntime ? runtimeUsage : state.usage,
                    fetchedAt: isRuntime ? runtime.lastUpdated : state.fetchedAt, isRuntime: isRuntime, basis: basis)
            }
            result[service] = MultiAccountPresentation(
                service: service, mode: controller.popoverMode(for: service), rows: rows,
                selectedIDs: controller.selection(for: service))
        }
        return result
    }
}
