import Foundation

nonisolated enum AntigravitySourcePlanError:
    Error,
    Sendable,
    Equatable
{
    case incompatiblePolicyAndAccountTarget
}

/// Pure product policy. It has no process, account repository, or
/// last-successful-source dependency, so a stale source can never gain hidden
/// priority.
nonisolated enum AntigravitySourcePlanner {
    static func plannedSources(
        policy: AntigravityConnectionSettings.SourcePolicy,
        accountTarget: AntigravityRefreshAccountTarget,
        allowManagedCLI: Bool
    ) throws -> [AntigravityUsageSourceID] {
        switch (policy, accountTarget) {
        case (.automatic, .selectedOAuth):
            return [
                .localApp,
                .borrowedCLI,
                .googleOAuth,
            ]

        case (.automatic, .ambientLocal):
            return [
                .localApp,
                .borrowedCLI,
            ]

        case (.localSession, .ambientLocal):
            var sources: [AntigravityUsageSourceID] = [
                .localApp,
                .borrowedCLI,
            ]
            if allowManagedCLI {
                sources.append(.managedCLI)
            }
            return sources

        case (.googleAccount, .selectedOAuth):
            return [.googleOAuth]

        case (.localSession, .selectedOAuth),
             (.googleAccount, .ambientLocal):
            throw AntigravitySourcePlanError
                .incompatiblePolicyAndAccountTarget
        }
    }

    static func plannedSources(
        for request: AntigravityRefreshRequest
    ) throws -> [AntigravityUsageSourceID] {
        let connection = request.connection
        return try plannedSources(
            policy: connection.sourcePolicy,
            accountTarget: request.accountTarget,
            allowManagedCLI: connection.allowManagedCLI
        )
    }
}
