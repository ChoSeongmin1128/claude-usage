import Foundation

struct ClaudeAutomaticOrganizationCandidate: Equatable {
    let organization: ClaudeAPIService.OrganizationSummary
    let overage: OverageSpendLimitResponse?
}

enum ClaudeAutomaticOrganizationSelectionPolicy {
    nonisolated static func selectBest(
        from candidates: [ClaudeAutomaticOrganizationCandidate]
    ) -> ClaudeAutomaticOrganizationCandidate? {
        candidates
            .map { candidate in (candidate, score(candidate)) }
            .max { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return false
                }
                return lhs.1 < rhs.1
            }?
            .0
    }

    private nonisolated static func score(_ candidate: ClaudeAutomaticOrganizationCandidate) -> Int {
        if candidate.organization.hasTeamPlanSignal {
            return 300
        }
        if candidate.overage?.isEnabled == true {
            return 200
        }
        if candidate.overage != nil {
            return 100
        }
        return 0
    }
}
