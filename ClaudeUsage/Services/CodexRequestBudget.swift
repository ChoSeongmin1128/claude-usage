import Foundation
import os

nonisolated struct CodexRequestBudget: Sendable {
    let deadline: ContinuousClock.Instant
    private let ownerRecoveryUsed = OSAllocatedUnfairLock(initialState: false)

    init(timeout: TimeInterval = 30) {
        deadline = .now.advanced(by: .seconds(timeout))
    }

    var remaining: TimeInterval {
        let components = ContinuousClock.now.duration(to: deadline).components
        return max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }

    func check() throws {
        try Task.checkCancellation()
        guard remaining > 0 else { throw APIError.codexTokenRefreshTemporary(reason: "request_timed_out") }
    }

    func reserveOwnerRecovery() -> Bool {
        ownerRecoveryUsed.withLock { used in
            guard !used else { return false }
            used = true
            return true
        }
    }
}

nonisolated protocol CodexOwnerRefreshing: Sendable {
    func refresh(sourceURL: URL, expectedAccountID: String, budget: CodexRequestBudget) async throws
}

nonisolated enum CodexOwnerError: Error, Equatable {
    case unavailable
    case rejected
    case temporarilyUnavailable
    case invalidResponse
    case accountMismatch
    case timedOut
    case launchFailed
}
