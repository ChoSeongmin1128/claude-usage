import Foundation

struct ClaudeRuntimeRefreshSuccess {
    let usage: ClaudeUsageResponse
    let provenance: ClaudeFetchProvenance
    let metadata: RuntimeProviderFetchMetadata
    let supplementalUsage: ClaudeSupplementalRefreshResult
}

enum ClaudeRuntimeRefresher {
    static func refresh(
        apiService: ClaudeAPIService,
        lastOverageAttemptAt: Date?
    ) async throws -> ClaudeRuntimeRefreshSuccess {
        let outcome = try await apiService.fetchUsageWithRetryOutcome()
        let supplementalUsage = try await ClaudeSupplementalRefreshResult.refresh(
            embeddedUsage: outcome.usage.extraUsage,
            source: outcome.provenance.source,
            lastAttemptAt: lastOverageAttemptAt
        ) {
            try await apiService.fetchOverageSpendLimit()
        }

        return ClaudeRuntimeRefreshSuccess(
            usage: outcome.usage,
            provenance: outcome.provenance,
            metadata: RuntimeProviderFetchMetadata(
                sourceLabel: outcome.provenance.source.displayName,
                accountID: outcome.provenance.accountID,
                attemptedSourceLabels: outcome.provenance.attemptedSources.map(\.displayName)),
            supplementalUsage: supplementalUsage
        )
    }
}
