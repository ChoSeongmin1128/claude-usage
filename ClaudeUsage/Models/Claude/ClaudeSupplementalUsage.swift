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
        embeddedUsageIsMalformed: Bool = false,
        source: ClaudeUsageSource,
        lastAttemptAt: Date? = nil,
        now: Date = Date(),
        fetchFallback: @Sendable () async throws -> OverageSpendLimitResponse
    ) async throws -> Self {
        if let embeddedUsage { return .success(embeddedUsage, fetchedAt: now) }
        if source == .oauth {
            // OAuth 응답은 추가 사용량을 함께 주므로 항목이 없으면 꺼짐이다. 읽지 못한 항목은 꺼짐으로 보지 않는다.
            return embeddedUsageIsMalformed ? .failed : .success(.notEnabled, fetchedAt: now)
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
