import AppKit
import Foundation

extension AppDelegate {
    func adaptiveRefreshIntervals(now: Date = Date()) -> [PopoverService: TimeInterval] {
        let isPopoverOpen = popover?.isShown ?? false
        return refreshableServices.reduce(into: [:]) { result, service in
            result[service] = AdaptiveRefreshPolicy.interval(
                .init(
                    now: now,
                    isPopoverOpen: isPopoverOpen,
                    lastPopoverOpenedAt: lastPopoverOpenedAt,
                    lastActivityAt: sessionActivityMonitor.lastActivityAt[service],
                    hasLowRemainingLimit: usageLimits(for: service).contains { limit in
                        guard let used = limit.usedPercentage else { return false }
                        return 100 - used <= AdaptiveRefreshPolicy.lowRemainingPercent
                    }))
        }
    }

    /// 조회 결과나 화면 상태가 바뀔 때마다 주기와 초기화 직후 조회 예약을 다시 맞춘다.
    func refreshAdaptiveSchedule() {
        syncRefreshTimerState()
        scheduleResetFollowUps()
    }

    func startSessionActivityMonitoring() {
        sessionActivityMonitor.onActivity = { [weak self] _ in
            self?.syncRefreshTimerState()
        }
        sessionActivityMonitor.start()
        popoverCloseObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let closedID = (notification.object as? NSPopover).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let popover = self.popover, closedID == ObjectIdentifier(popover) else { return }
                self.syncRefreshTimerState()
            }
        }
    }

    func stopAdaptiveRefresh() {
        sessionActivityMonitor.stop()
        resetFollowUpTimers.values.forEach { $0.invalidate() }
        resetFollowUpTimers.removeAll()
        if let popoverCloseObserver {
            NotificationCenter.default.removeObserver(popoverCloseObserver)
            self.popoverCloseObserver = nil
        }
    }

    private func usageLimits(for service: PopoverService) -> [UsageLimit] {
        switch runtimeProviderSnapshot(for: service).displayPayload {
        case .claude(let usage): return UsageLimitCatalog.claude(usage)
        case .codex(let usage): return UsageLimitCatalog.codex(usage)
        case nil: return []
        }
    }

    /// 한도가 초기화된 직후 한 번 조회해 새 값을 바로 보여준다.
    private func scheduleResetFollowUps(now: Date = Date()) {
        guard refreshConfiguration.autoRefresh, shouldPollRuntimeProviders else {
            resetFollowUpTimers.values.forEach { $0.invalidate() }
            resetFollowUpTimers.removeAll()
            return
        }
        for service in PopoverService.allCases {
            let followUp =
                refreshableServices.contains(service)
                ? AdaptiveRefreshPolicy.nextResetFollowUp(
                    resetDates: usageLimits(for: service).compactMap(\.resetAt), now: now)
                : nil
            if let existing = resetFollowUpTimers[service], existing.fireDate == followUp { continue }
            resetFollowUpTimers[service]?.invalidate()
            resetFollowUpTimers[service] = nil
            guard let followUp else { continue }
            let timer = Timer(fire: followUp, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.resetFollowUpTimers[service] = nil
                    guard self.refreshConfiguration.autoRefresh, self.refreshableServices.contains(service) else {
                        return
                    }
                    self.performRuntimeAction(.refresh(service: service, force: false))
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            resetFollowUpTimers[service] = timer
        }
    }
}
