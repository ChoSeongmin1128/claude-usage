import Foundation

/// Pure product policy. It has no process, account repository, or
/// last-successful-source dependency, so a stale source can never gain hidden
/// priority.
nonisolated enum AntigravitySourcePlanner {
    static func plannedSources(
        target: AntigravityUsageTarget,
        managedLaunch: AntigravityManagedLaunchState
    ) -> [AntigravityUsageSourceID] {
        switch target {
        case .unselected: return []
        case .app: return [.localApp]
        case .cli: break
        }
        var sources: [AntigravityUsageSourceID] = [.borrowedCLI]
        if managedLaunch.allowsLaunch {
            sources.append(.managedCLI)
        }
        return sources
    }

    static func plannedSources(
        for request: AntigravityRefreshRequest
    ) -> [AntigravityUsageSourceID] {
        plannedSources(
            target: request.target,
            managedLaunch: request.managedLaunch
        )
    }
}
