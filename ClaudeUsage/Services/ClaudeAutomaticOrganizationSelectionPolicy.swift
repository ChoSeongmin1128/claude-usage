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
        var score = 0
        if candidate.organization.hasTeamPlanSignal {
            score += 1_000
        }
        if candidate.overage?.isEnabled == true {
            score += 200
        } else if candidate.overage != nil {
            score += 100
        }
        // 조직 metadata가 비어 있어도 명확한 개인 workspace보다 일반 조직
        // 후보를 우선한다. 사용자의 직접 선택은 이 정책 호출 전에 처리된다.
        if candidate.organization.hasPersonalAccountSignal {
            score -= 500
        }
        return score
    }
}
