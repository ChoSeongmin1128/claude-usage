import Foundation

struct ClaudeRuntimeRefreshSuccess {
    let usage: ClaudeUsageResponse
    let provenance: ClaudeFetchProvenance
    let metadata: RuntimeProviderFetchMetadata
    let overage: OverageSpendLimitResponse?
    let overageFetchedAt: Date?
}

enum ClaudeRuntimeRefresher {
    private static let overageRefreshInterval: TimeInterval = 300

    static func refresh(
        apiService: ClaudeAPIService,
        lastOverageFetchAt: Date?
    ) async throws -> ClaudeRuntimeRefreshSuccess {
        let outcome = try await apiService.fetchUsageWithRetryOutcome()
        let shouldFetchOverage = shouldRefreshOverage(lastFetchedAt: lastOverageFetchAt)
        let overage: OverageSpendLimitResponse?
        if shouldFetchOverage {
            do {
                overage = try await apiService.fetchOverageSpendLimit()
            } catch {
                Logger.debug("추가 사용량 조회 실패: \(error.localizedDescription)")
                overage = nil
            }
        } else {
            overage = nil
        }

        return ClaudeRuntimeRefreshSuccess(
            usage: outcome.usage,
            provenance: outcome.provenance,
            metadata: RuntimeProviderFetchMetadata(
                sourceLabel: outcome.provenance.source.displayName,
                accountID: outcome.provenance.accountID,
                attemptedSourceLabels: outcome.provenance.attemptedSources.map(\.displayName)),
            overage: overage,
            overageFetchedAt: overage != nil ? Date() : nil
        )
    }

    private static func shouldRefreshOverage(lastFetchedAt: Date?) -> Bool {
        guard let lastFetchedAt else { return true }
        return Date().timeIntervalSince(lastFetchedAt) >= overageRefreshInterval
    }
}
