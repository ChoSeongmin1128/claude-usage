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
        usageAccountsObserver = NotificationCenter.default.addObserver(
            forName: .claudeAccountsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rediscoverUsageAccounts() }
        }
        rediscoverUsageAccounts()
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
            let visible = controller.visibleAccounts(for: service)
            guard visible.count >= 2 else { continue }
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
