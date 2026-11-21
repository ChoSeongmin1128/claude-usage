import Foundation

/// The set of requests to which a reported quota applies. Display IDs and
/// durations identify measurements and cannot establish this relationship.
nonisolated enum QuotaCoverage: Equatable, Sendable {
    case shared
    case baseGroup
    case group(String)
    case isolated
}

nonisolated enum QuotaIndicator: String, Equatable, Sendable {
    case exhausted, checking
}

/// Evaluates one validated account snapshot before any visibility or layout filters.
nonisolated struct QuotaAvailability: Equatable, Sendable {
    struct Blocker: Equatable, Sendable {
        let limitID: String?
        let title: String
        let resetAt: Date?
        let periodSeconds: Int?
    }

    struct Status: Equatable, Sendable {
        let blockers: [Blocker]
        let awaitingRefresh: Bool
        let canUsePaidCredits: Bool

        var indicator: QuotaIndicator? {
            if !blockers.isEmpty { return .exhausted }
            return awaitingRefresh ? .checking : nil
        }

        func blocks(_ limitID: String) -> Bool { blockers.contains { $0.limitID == limitID } }

        var automaticRecovery: Blocker? {
            guard !awaitingRefresh, blockers.allSatisfy({ $0.resetAt != nil }) else { return nil }
            return blockers.max { ($0.resetAt ?? .distantPast) < ($1.resetAt ?? .distantPast) }
        }
    }

    struct Row: Equatable, Sendable {
        let status: Status
        let isExhausted: Bool
    }

    private var statuses: [String: Status] = [:]
    private(set) var accountRestriction: String?
    private var limits: [UsageLimit] = []
    static let empty = Self()

    private init() {}

    init(
        limits: [UsageLimit], isCurrent: Bool = true, accountRestriction: String? = nil,
        paidCoverage: QuotaCoverage? = nil, now: Date = Date()
    ) {
        self.limits = limits
        guard isCurrent else { return }
        self.accountRestriction = accountRestriction
        let exhausted = limits.filter { ($0.usedPercentage ?? -1) >= 100 }
        for target in limits {
            let applicable = exhausted.filter { Self.applies($0.coverage, limitID: $0.id, to: target) }
            var blockers = applicable.filter { $0.resetAt.map { $0 > now } ?? true }.map {
                Blocker(limitID: $0.id, title: $0.title, resetAt: $0.resetAt, periodSeconds: $0.periodSeconds)
            }
            let awaitingRefresh = applicable.count != blockers.count
            if let accountRestriction {
                blockers.insert(
                    Blocker(limitID: nil, title: accountRestriction, resetAt: nil, periodSeconds: nil), at: 0)
            }
            guard !blockers.isEmpty || awaitingRefresh else { continue }
            let paid = paidCoverage.map { Self.applies($0, limitID: nil, to: target) } ?? false
            statuses[target.id] = Status(
                blockers: blockers, awaitingRefresh: awaitingRefresh,
                canUsePaidCredits: paid && accountRestriction == nil && !blockers.isEmpty)
        }
    }

    private static func applies(_ coverage: QuotaCoverage, limitID: String?, to target: UsageLimit) -> Bool {
        if limitID == target.id { return true }
        switch coverage {
        case .shared: return true
        case .baseGroup, .group: return coverage == target.coverage
        case .isolated: return false
        }
    }

    subscript(id: String) -> Status? { statuses[id] }

    func row(for id: String) -> Row? {
        statuses[id].map { Row(status: $0, isExhausted: $0.blocks(id)) }
    }

    func row(legacyKey: String, slot: String? = nil) -> Row? {
        limits.first { $0.legacyKey == legacyKey && (slot == nil || $0.windowSlot == slot) }
            .flatMap { row(for: $0.id) }
    }

    var affectedStatuses: [Status] { limits.compactMap { statuses[$0.id] } }

    func isExhausted(periodSeconds: Int) -> Bool {
        limits.contains { limit in
            limit.periodSeconds == periodSeconds && (limit.coverage == .shared || limit.coverage == .baseGroup)
                && statuses[limit.id]?.blocks(limit.id) == true
        }
    }
}