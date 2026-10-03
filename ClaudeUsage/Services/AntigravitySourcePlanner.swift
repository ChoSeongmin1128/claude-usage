import Foundation

/// Pure product policy. It has no process, account repository, or
/// last-successful-source dependency, so a stale source can never gain hidden
/// priority.
nonisolated enum AntigravitySourcePlanner {
    static func plannedSources(
        target: AntigravityUsageTarget
    ) -> [AntigravityUsageSourceID] {
        [.cliReport]
    }

    static func plannedSources(
        for request: AntigravityRefreshRequest
    ) -> [AntigravityUsageSourceID] {
        plannedSources(target: request.target)
    }
}
