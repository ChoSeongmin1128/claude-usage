import Foundation

enum RefreshSchedulerChange: Equatable {
    case started(TimeInterval)
    case stopped
    case unchanged
}

/// Owns each provider's monotonic cadence. A response's completion time never
/// moves the next scheduled refresh, and missed ticks coalesce after sleep.
@MainActor
final class RefreshScheduler {
    private var timer: Timer?
    private var intervals: [PopoverService: TimeInterval] = [:]
    private var deadlines: [PopoverService: ContinuousClock.Instant] = [:]
    private var generation = 0
    private var onTick: (@MainActor @Sendable ([PopoverService]) -> Void)?
    private let now: () -> ContinuousClock.Instant
    private let makeTimer: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Timer

    init(
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
        makeTimer: @escaping (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Timer = { interval, tick in
            Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
                MainActor.assumeIsolated { tick() }
            }
        }
    ) {
        self.now = now
        self.makeTimer = makeTimer
    }

    func sync(
        autoRefresh: Bool,
        shouldPoll: Bool,
        intervals requested: [PopoverService: TimeInterval],
        onTick: @escaping @MainActor @Sendable ([PopoverService]) -> Void
    ) -> RefreshSchedulerChange {
        let normalized = requested.mapValues { AppSettings.normalizedRefreshInterval($0) }
        guard autoRefresh, shouldPoll, let minimumInterval = normalized.values.min() else { return stop() }
        self.onTick = onTick
        if timer != nil, intervals == normalized { return .unchanged }

        let instant = now()
        deadlines = normalized.reduce(into: [:]) { result, entry in
            let (service, interval) = entry
            result[service] =
                intervals[service] == interval
                ? deadlines[service] ?? instant.advanced(by: .seconds(interval))
                : instant.advanced(by: .seconds(interval))
        }
        intervals = normalized
        armNextTimer()
        return .started(minimumInterval)
    }

    private func armNextTimer() {
        timer?.invalidate()
        timer = nil
        generation += 1
        guard let next = deadlines.values.min() else { return }
        let scheduledGeneration = generation
        let delay = max(0, seconds(now().duration(to: next)))
        timer = makeTimer(delay) { [weak self] in
            guard let self, self.generation == scheduledGeneration, self.timer != nil else { return }
            self.fire()
        }
    }

    private func fire() {
        let instant = now()
        let due = PopoverService.allCases.filter { service in
            deadlines[service].map { $0 <= instant } ?? false
        }
        for service in due {
            guard let deadline = deadlines[service], let interval = intervals[service] else { continue }
            let missedIntervals = floor(max(0, seconds(deadline.duration(to: instant))) / interval)
            deadlines[service] = deadline.advanced(by: .seconds((missedIntervals + 1) * interval))
        }
        // Rearm before invoking clients: a synchronous settings change in a
        // client can then replace or stop the next timer without being undone.
        armNextTimer()
        if !due.isEmpty { onTick?(due) }
    }

    @discardableResult
    func stop() -> RefreshSchedulerChange {
        let wasRunning = timer != nil
        generation += 1
        timer?.invalidate()
        timer = nil
        intervals.removeAll()
        deadlines.removeAll()
        onTick = nil
        return wasRunning ? .stopped : .unchanged
    }

    private func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
