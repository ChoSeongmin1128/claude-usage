import AppKit

extension AppDelegate {
    func resetCreditSummary(for service: PopoverService) -> ResetCreditSummary? {
        switch service {
        case .claude: return ResetCreditSummary.claude(runtimeProviderSnapshot(for: .claude).claudeUsage?.resetGrants)
        case .codex: return ResetCreditSummary.codex(runtimeProviderSnapshot(for: .codex).codexUsage)
        case .antigravity: return nil
        }
    }

    func resetCreditBadge(for kind: AppProviderKind) -> MenuBarResetCreditBadge? {
        guard let service = kind.runtimeService else { return nil }
        return MenuBarResetCreditBadge.resolve(
            summary: resetCreditSummary(for: service),
            isNew: ResetCreditSeenStore.isNew(accountKey: resetCreditAccountKey(for: service)),
            mode: AppSettings.shared.resetCreditMenuBarMode(for: kind))
    }

    func resetCreditAccountKey(for service: PopoverService) -> String? {
        usageAccountsController.orderedAccounts(for: service)
            .first { usageAccountsController.isRuntime($0) && $0.identity.mergeKey != nil }?.id
    }

    func observeResetCredits() {
        for service in [PopoverService.claude, .codex] {
            let summary = resetCreditSummary(for: service)
            let count =
                service == .codex
                ? runtimeProviderSnapshot(for: .codex).codexUsage?.resetCredits?.availableCount()
                : summary?.availableCount
            ResetCreditSeenStore.observe(
                summary: summary, count: count, accountKey: resetCreditAccountKey(for: service))
        }
    }

    func recordVisibleResetCredits(_ receipt: ResetCreditSeenReceipt) {
        guard popover?.isShown == true, popoverViewModel.selectedService == receipt.service,
            resetCreditAccountKey(for: receipt.service) == receipt.accountKey
        else { return }
        resetCreditViewedReceipts[receipt.accountKey] = receipt
    }

    func markViewedResetCreditsSeen() {
        let receipts = Array(resetCreditViewedReceipts.values)
        resetCreditViewedReceipts.removeAll()
        for receipt in receipts { ResetCreditSeenStore.markSeen(receipt) }
        updateMenuBar()
        updatePopoverViewModel()
    }
}
