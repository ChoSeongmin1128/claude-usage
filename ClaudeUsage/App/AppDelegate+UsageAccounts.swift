import AppKit

extension AppDelegate {
    func bootstrapUsageAccounts() {
        usageAccountsController.onChange = { [weak self] in self?.updatePopoverViewModel() }
        popoverViewModel.accountActions = PopoverAccountActions(
            toggle: { [weak self] service, id in self?.usageAccountsController.toggleSelection(id, service: service) },
            reconnect: { [weak self] service, _ in
                self?.closePopover()
                AppSettings.shared.settingsLastTab = ServiceSelectionHelper.settingsRootTab(for: service)
                self?.showSettingsWindow()
            },
            allow: { [weak self] service, id in
                guard let self,
                    let account = self.usageAccountsController.visibleAccounts(for: service).first(where: {
                        $0.id == id
                    })
                else { return }
                self.usageAccountsController.grantPermission(for: account)
            })
        usageAccountsController.onMenuBarChoiceNeeded = { [weak self] claudeApp, claudeCode in
            self?.askMenuBarAccount(claudeApp: claudeApp, claudeCode: claudeCode)
        }
        usageAccountsObserver = NotificationCenter.default.addObserver(
            forName: .claudeAccountsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rediscoverUsageAccounts() }
        }
        rediscoverUsageAccounts()
    }

    /// Claude 앱과 Claude Code에 다른 계정이 로그인돼 있을 때 한 번만 묻는다. 기본 버튼은 Claude 앱 계정이다.
    private func askMenuBarAccount(claudeApp: UsageAccount, claudeCode: UsageAccount) {
        let controller = usageAccountsController
        let all = controller.visibleAccounts(for: .claude)
        let appName = controller.preferences.displayName(for: claudeApp, among: all)
        let codeName = controller.preferences.displayName(for: claudeCode, among: all)
        let alert = NSAlert()
        alert.messageText = "메뉴바에 표시할 Claude 계정"
        alert.informativeText =
            "Claude 앱은 \(appName), Claude Code는 \(codeName)로 로그인돼 있습니다. 고른 계정이 메뉴바와 팝오버에 나오며, 설정의 계정 목록에서 바꿀 수 있습니다."
        alert.addButton(withTitle: "\(appName) (Claude 앱)")
        alert.addButton(withTitle: "\(codeName) (Claude Code)")
        NSApp.activate(ignoringOtherApps: true)
        let choice = alert.runModal() == .alertSecondButtonReturn ? claudeCode : claudeApp
        controller.resolveMenuBarChoice(choice)
    }

    func rediscoverUsageAccounts() {
        usageAccountsController.discover(claudeRuntimeAccountID: ClaudeAccountStore.shared.state().activeAccountID)
        usageAccountsController.refreshIfNeeded()
    }

    func multiAccountPresentations() -> [PopoverService: MultiAccountPresentation] {
        var result: [PopoverService: MultiAccountPresentation] = [:]
        let controller = usageAccountsController
        for service in [PopoverService.claude, .codex] where AppSettings.shared.isProviderEnabled(service.providerKind)
        {
            guard controller.isMultiAccount(service) else { continue }
            let visible = controller.visibleAccounts(for: service)
            let runtime = runtimeProviderSnapshot(for: service)
            let basis = AppSettings.shared.usageValueBasis(for: service)
            let rows = visible.map { account -> PopoverAccountRowData in
                let isRuntime = controller.isRuntimeAccount(account)
                var state = controller.states[account.id] ?? UsageAccountState()
                if isRuntime {
                    state = UsageAccountState(
                        claudeUsage: runtime.claudeUsage, codexUsage: runtime.codexUsage, fetchedAt: runtime.lastUpdated
                    )
                }
                let codex = state.codexUsage
                return PopoverAccountRowData(
                    id: account.id, service: service,
                    name: controller.preferences.displayName(for: account, among: visible),
                    badges: account.badges,
                    status: isRuntime
                        ? .current : state.status(isArchived: controller.preferences.archived.contains(account.id)),
                    fiveHour: state.fiveHourPercentage, weekly: state.weeklyPercentage,
                    fiveHourResetAt: state.claudeUsage?.fiveHour?.resetsAt
                        ?? Self.isoString(codex?.sessionWindow?.resetAt),
                    weeklyResetAt: state.claudeUsage?.sevenDay?.resetsAt
                        ?? Self.isoString(codex?.weeklyWindow?.resetAt),
                    fetchedAt: state.fetchedAt, isRuntime: isRuntime, basis: basis)
            }
            result[service] = MultiAccountPresentation(
                service: service, mode: controller.preferences.popoverMode, rows: rows,
                selectedIDs: controller.preferences.selection(for: service, visible: visible))
        }
        return result
    }

    private static func isoString(_ seconds: Double?) -> String? {
        seconds.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) }
    }
}
