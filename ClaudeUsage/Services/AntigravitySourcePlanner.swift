import Foundation

/// Pure product policy. It has no process, account repository, or
/// last-successful-source dependency, so a stale source can never gain hidden
/// priority.
nonisolated enum AntigravitySourcePlanner {
    static func plannedSources(
        accountTarget: AntigravityRefreshAccountTarget,
        managedLaunchEnabled: Bool
    ) -> [AntigravityUsageSourceID] {
        var sources: [AntigravityUsageSourceID] = [
            .localApp,
            .borrowedCLI,
        ]
        if managedLaunchEnabled {
            sources.append(.managedCLI)
        }
        if case .selectedOAuth = accountTarget {
            sources.append(.googleOAuth)
        }
        return sources
    }

    static func plannedSources(
        for request: AntigravityRefreshRequest
    ) -> [AntigravityUsageSourceID] {
        plannedSources(
            accountTarget: request.accountTarget,
            managedLaunchEnabled:
                request.managedLaunchEnabled
        )
    }
}
