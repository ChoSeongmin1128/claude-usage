import AppKit

extension AppDelegate {
    // MARK: - Service Status Panel

    func setupServiceStatusPanel() {
        serviceStatusHover.contentProvider = { [weak self] in
            self?.serviceStatusPanelContent()
        }
        serviceStatusHover.isSuppressed = { [weak self] in
            guard let self else { return true }
            return self.popover?.isShown == true || self.isPresentingPopover || self.isShowingStatusContextMenu
        }
    }

    /// 꺼 둔 서비스는 빼고, 한 번도 읽지 못한 서비스도 뺀다.
    func serviceStatusPanelContent(now: Date = Date()) -> ServiceStatusPanelContent? {
        let settings = AppSettings.shared
        var statuses: [AppProviderKind: ProviderSystemStatus] = [:]
        for kind in ServiceStatusPanelContent.serviceOrder where settings.isProviderEnabled(kind) {
            statuses[kind] = providerSystemStatus(for: kind)
        }
        return ServiceStatusPanelContent.make(statuses: statuses, now: now)
    }

    /// 메뉴바 그림의 갱신 여부와 관계없이 상태가 바뀌면 접근성 도움말과 떠 있는 패널을 맞춘다.
    func refreshServiceStatusPresentation() {
        statusItem?.button?.setAccessibilityHelp(serviceStatusPanelContent()?.accessibilitySummary)
        serviceStatusHover.contentDidChange()
    }
}
