import Foundation

/// Extra usage has the same account boundary as quota, but a slower refresh cadence.
struct ClaudeSupplementalUsage {
    let accountID: String
    let value: OverageSpendLimitResponse
    let fetchedAt: Date
    var lastRefreshFailed = false
}

/// A skipped refresh does not erase a successful value or its failure marker.
enum ClaudeSupplementalRefreshResult {
    case unchanged
    case success(OverageSpendLimitResponse, fetchedAt: Date)
    case failed
}
