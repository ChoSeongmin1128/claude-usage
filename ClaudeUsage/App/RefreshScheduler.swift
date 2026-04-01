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
        hasRefreshableService: Bool,
        interval: TimeInterval,
        onTick: @escaping () -> Void
    ) -> RefreshSchedulerChange {
        guard autoRefresh, hasRefreshableService else {
            return stop()
        }

        if timer != nil, activeInterval == interval {
            return .unchanged
        }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            onTick()
        }
        activeInterval = interval
        return .started(interval)
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
