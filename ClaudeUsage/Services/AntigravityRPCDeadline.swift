import Foundation

nonisolated enum AntigravityRPCDeadlinePhase: String, Sendable, Equatable {
    case discovery
    case request
}

nonisolated enum AntigravityRPCDeadlineError: Error, Sendable, Equatable {
    case timedOut(AntigravityRPCDeadlinePhase)
    case invalidTimeout
}

/// A single monotonic budget shared by discovery and RPC work.
///
/// Discovery receives a bounded prefix of the total budget. Consumers must pass
/// this same value through the transaction instead of creating a fresh deadline
/// for each subprocess, endpoint, or retry.
nonisolated struct AntigravityRPCDeadline: Sendable {
    static let defaultTotalTimeout: Duration = .seconds(8)
    static let maximumDiscoveryTimeout: Duration = .seconds(2)

    private let startedAt: ContinuousClock.Instant
    private let totalExpiresAt: ContinuousClock.Instant
    private let discoveryExpiresAt: ContinuousClock.Instant
    private let now: @Sendable () -> ContinuousClock.Instant

    init(
        totalTimeout: Duration = Self.defaultTotalTimeout,
        discoveryTimeout: Duration = Self.maximumDiscoveryTimeout
    ) {
        let clock = ContinuousClock()
        self.init(
            startedAt: clock.now,
            totalTimeout: totalTimeout,
            discoveryTimeout: discoveryTimeout,
            now: { clock.now }
        )
    }

    init(
        startedAt: ContinuousClock.Instant,
        totalTimeout: Duration = Self.defaultTotalTimeout,
        discoveryTimeout: Duration = Self.maximumDiscoveryTimeout,
        now: @escaping @Sendable () -> ContinuousClock.Instant
    ) {
        let boundedTotal = max(.zero, totalTimeout)
        let boundedDiscovery = min(
            max(.zero, discoveryTimeout),
            min(Self.maximumDiscoveryTimeout, boundedTotal)
        )
        self.startedAt = startedAt
        self.totalExpiresAt = startedAt.advanced(by: boundedTotal)
        self.discoveryExpiresAt = startedAt.advanced(by: boundedDiscovery)
        self.now = now
    }

    var elapsed: Duration {
        max(.zero, startedAt.duration(to: now()))
    }

    var remaining: Duration {
        remaining(until: totalExpiresAt)
    }

    var remainingDiscovery: Duration {
        min(remaining, remaining(until: discoveryExpiresAt))
    }

    var isExpired: Bool {
        remaining <= .zero
    }

    func check(_ phase: AntigravityRPCDeadlinePhase) throws {
        try Task.checkCancellation()
        guard remaining(for: phase) > .zero else {
            throw AntigravityRPCDeadlineError.timedOut(phase)
        }
    }

    func timeout(
        for phase: AntigravityRPCDeadlinePhase,
        maximum requestedMaximum: Duration? = nil
    ) throws -> Duration {
        try check(phase)
        let available = remaining(for: phase)
        guard let requestedMaximum else {
            return available
        }
        guard requestedMaximum > .zero else {
            throw AntigravityRPCDeadlineError.invalidTimeout
        }
        return min(available, requestedMaximum)
    }

    func timeInterval(
        for phase: AntigravityRPCDeadlinePhase,
        maximum requestedMaximum: TimeInterval? = nil
    ) throws -> TimeInterval {
        if let requestedMaximum {
            guard requestedMaximum.isFinite, requestedMaximum > 0 else {
                throw AntigravityRPCDeadlineError.invalidTimeout
            }
        }
        let maximumDuration = requestedMaximum.map(Duration.seconds)
        let duration = try timeout(for: phase, maximum: maximumDuration)
        return duration.timeInterval
    }

    private func remaining(for phase: AntigravityRPCDeadlinePhase) -> Duration {
        switch phase {
        case .discovery:
            remainingDiscovery
        case .request:
            remaining
        }
    }

    private func remaining(until instant: ContinuousClock.Instant) -> Duration {
        max(.zero, now().duration(to: instant))
    }
}

nonisolated private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + (TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000)
    }
}
