import Foundation

struct ClaudeSupplementalUsage {
    let accountID: String
    let ownerKey: String
    let value: OverageSpendLimitResponse
    let fetchedAt: Date
    var lastRefreshFailed = false
}

enum ClaudeSupplementalRefreshResult: Sendable {
    case unchanged
    case success(OverageSpendLimitResponse, fetchedAt: Date)
    case failed

    private nonisolated static let fallbackRefreshInterval: TimeInterval = 300

    nonisolated static func refresh(
        embeddedUsage: OverageSpendLimitResponse?,
        source: ClaudeUsageSource,
        lastAttemptAt: Date? = nil,
        now: Date = Date(),
        fetchFallback: @Sendable () async throws -> OverageSpendLimitResponse
    ) async throws -> Self {
        if embeddedUsage != nil || source == .oauth {
            return .success(embeddedUsage ?? .notEnabled, fetchedAt: now)
        }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < fallbackRefreshInterval {
            return .unchanged
        }
        do {
            return .success(try await fetchFallback(), fetchedAt: Date())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Logger.debug("추가 사용량 조회 실패: \(error.localizedDescription)")
            return .failed
        }
    }
}
