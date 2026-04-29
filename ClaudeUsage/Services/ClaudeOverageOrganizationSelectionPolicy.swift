import Foundation

struct ClaudeOverageOrganizationCandidate: Equatable {
    let organizationID: String
    let overage: OverageSpendLimitResponse
}

enum ClaudeOverageOrganizationSelectionPolicy {
    nonisolated static func selectBest(
        from candidates: [ClaudeOverageOrganizationCandidate]
    ) -> ClaudeOverageOrganizationCandidate? {
        candidates.first(where: { $0.overage.isEnabled }) ?? candidates.first
    }
}
