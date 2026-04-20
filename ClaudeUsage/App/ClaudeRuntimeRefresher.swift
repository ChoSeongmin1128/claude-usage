import Foundation

struct ClaudeRuntimeRefreshSuccess {
    let usage: ClaudeUsageResponse
    let overage: OverageSpendLimitResponse?
    let overageFetchedAt: Date?
}

enum ClaudeRuntimeRefresher {
    private static let overageRefreshInterval: TimeInterval = 300

    static func refresh(
        apiService: ClaudeAPIService,
        lastOverageFetchAt: Date?
    ) async throws -> ClaudeRuntimeRefreshSuccess {
        let usage = try await apiService.fetchUsageWithRetry()
        let shouldFetchOverage = shouldRefreshOverage(lastFetchedAt: lastOverageFetchAt)
        let overage = shouldFetchOverage ? (try? await apiService.fetchOverageSpendLimit()) : nil

        return ClaudeRuntimeRefreshSuccess(
            usage: usage,
            overage: overage,
            overageFetchedAt: overage != nil ? Date() : nil
        )
    }

    private static func shouldRefreshOverage(lastFetchedAt: Date?) -> Bool {
        guard let lastFetchedAt else { return true }
        return Date().timeIntervalSince(lastFetchedAt) >= overageRefreshInterval
    }
}
