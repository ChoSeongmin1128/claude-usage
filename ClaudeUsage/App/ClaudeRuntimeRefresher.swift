import Foundation

struct ClaudeRuntimeRefreshSuccess {
    let usage: ClaudeUsageResponse
    let provenance: ClaudeFetchProvenance
    let metadata: RuntimeProviderFetchMetadata
    let supplementalUsage: ClaudeSupplementalRefreshResult
}

enum ClaudeRuntimeRefresher {
    private static let overageRefreshInterval: TimeInterval = 300

    static func refresh(
        apiService: ClaudeAPIService,
        lastOverageFetchAt: Date?
    ) async throws -> ClaudeRuntimeRefreshSuccess {
        let outcome = try await apiService.fetchUsageWithRetryOutcome()
        let shouldFetchOverage = shouldRefreshOverage(lastFetchedAt: lastOverageFetchAt)
        let supplementalUsage: ClaudeSupplementalRefreshResult
        if outcome.provenance.source == .oauth {
            supplementalUsage = embeddedSupplementalUsage(outcome.usage, fetchedAt: Date())
        } else if shouldFetchOverage {
            do {
                let overage = try await apiService.fetchOverageSpendLimit()
                supplementalUsage = .success(overage, fetchedAt: Date())
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Logger.debug("추가 사용량 조회 실패: \(error.localizedDescription)")
                supplementalUsage = .failed
            }
        } else {
            supplementalUsage = .unchanged
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

    /// Claude Code 토큰으로는 추가 사용량 API를 부를 수 없어 사용량 응답에 함께 오는 값을 쓴다.
    /// 응답에 없으면 추가 사용량을 켜지 않은 계정이다.
    static func embeddedSupplementalUsage(
        _ usage: ClaudeUsageResponse, fetchedAt: Date
    ) -> ClaudeSupplementalRefreshResult {
        .success(usage.extraUsage ?? .notEnabled, fetchedAt: fetchedAt)
    }

    private static func shouldRefreshOverage(lastFetchedAt: Date?) -> Bool {
        guard let lastFetchedAt else { return true }
        return Date().timeIntervalSince(lastFetchedAt) >= overageRefreshInterval
    }
}
