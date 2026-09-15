import Foundation

enum RefreshSchedulerChange: Equatable {
    case started(TimeInterval)
    case stopped
    case unchanged
}

final class RefreshScheduler {
    private var timer: Timer?
    private var activeInterval: TimeInterval?

    func sync(
        autoRefresh: Bool,
        shouldPoll: Bool,
        interval: TimeInterval,
        onTick: @escaping @MainActor @Sendable () -> Void
    ) -> RefreshSchedulerChange {
        guard autoRefresh, shouldPoll else {
            return stop()
        }

        let normalizedInterval = AppSettings.normalizedRefreshInterval(interval)
        if timer != nil, activeInterval == normalizedInterval {
            return .unchanged
        }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: normalizedInterval, repeats: true) { _ in
            // This timer belongs to the main run loop where sync is isolated.
            MainActor.assumeIsolated { onTick() }
        }
        activeInterval = normalizedInterval
        return .started(normalizedInterval)
    }

    @discardableResult
    func stop() -> RefreshSchedulerChange {
        let wasRunning = timer != nil
        timer?.invalidate()
        timer = nil
        activeInterval = nil
        return wasRunning ? .stopped : .unchanged
    }
}
