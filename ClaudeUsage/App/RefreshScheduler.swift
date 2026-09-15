import Foundation

enum RefreshSchedulerChange: Equatable {
    case started(TimeInterval)
    case stopped
    case unchanged
}

final class RefreshScheduler {
    private var timer: Timer?
    private var activeInterval: TimeInterval?
    private var generation = 0
    private let makeTimer: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Timer

    init(
        makeTimer: @escaping (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Timer = { interval, tick in
            Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                // The factory is called on MainActor and registers on its run loop.
                MainActor.assumeIsolated { tick() }
            }
        }
    ) {
        self.makeTimer = makeTimer
    }

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
        generation += 1
        let scheduledGeneration = generation
        timer = makeTimer(normalizedInterval) { [weak self] in
            guard let self, self.generation == scheduledGeneration, self.timer != nil else { return }
            onTick()
        }
        activeInterval = normalizedInterval
        return .started(normalizedInterval)
    }

    @discardableResult
    func stop() -> RefreshSchedulerChange {
        let wasRunning = timer != nil
        generation += 1
        timer?.invalidate()
        timer = nil
        activeInterval = nil
        return wasRunning ? .stopped : .unchanged
    }
}
