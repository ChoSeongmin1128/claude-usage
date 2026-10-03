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
            summary: resetCreditSummary(for: service), seen: ResetCreditSeenStore.seen(service),
            mode: AppSettings.shared.resetCreditMenuBarMode(for: kind))
    }

    /// 팝오버에서 본 서비스의 초기화권은 닫을 때 신규에서 뺀다.
    func markViewedResetCreditsSeen() {
        let services = resetCreditViewedServices
        resetCreditViewedServices.removeAll()
        guard !services.isEmpty else { return }
        for service in services {
            ResetCreditSeenStore.markSeen(resetCreditSummary(for: service), service: service)
        }
        updateMenuBar()
    }
}
