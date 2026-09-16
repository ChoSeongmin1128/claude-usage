import Foundation

/// Extra usage has the same account boundary as quota, but a slower refresh cadence.
struct ClaudeSupplementalUsage {
    let accountID: String
    let value: OverageSpendLimitResponse
    let fetchedAt: Date
}
