import Foundation

enum InFlightRefreshDecision {
    case start
    case skip
    case recoverStale(elapsed: Int)
}

enum RefreshExecutionPolicy {
    static func remainingBackoffSeconds(until allowedAt: Date?) -> Int? {
        guard let allowedAt else { return nil }
        let remaining = Int(ceil(allowedAt.timeIntervalSinceNow))
        return remaining > 0 ? remaining : nil
    }

    static func inFlightDecision(
        isLoading: Bool,
        startedAt: Date?,
        staleAfter: TimeInterval = 90
    ) -> InFlightRefreshDecision {
        guard isLoading else { return .start }
        guard let startedAt else { return .skip }

        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= staleAfter {
            return .recoverStale(elapsed: Int(elapsed))
        }
        return .skip
    }

    static func nextBackoffDate(
        for error: APIError,
        minimumInterval: TimeInterval,
        existingAllowedAt: Date?
    ) -> (candidate: Date?, seconds: Int?) {
        guard error.isTemporaryFailure else {
            return (nil, nil)
        }

        let retryAfterSeconds: Int = {
            switch error {
            case .rateLimited(let retryAfter), .cloudflareBlocked(let retryAfter):
                return retryAfter ?? 0
            case .networkError:
                return 10
            case .serverError(let statusCode):
                return statusCode >= 500 ? 20 : 10
            case .invalidSessionKey, .codexReauthRequired, .claudeOAuthPathRetired, .parseError, .unknownError:
                return 0
            }
        }()

        let floor = Int(max(15, minimumInterval))
        let backoffSeconds = max(floor, retryAfterSeconds)
        let candidate = Date().addingTimeInterval(TimeInterval(backoffSeconds))

        if let existingAllowedAt, existingAllowedAt > candidate {
            return (existingAllowedAt, nil)
        }

        return (candidate, backoffSeconds)
    }
}
