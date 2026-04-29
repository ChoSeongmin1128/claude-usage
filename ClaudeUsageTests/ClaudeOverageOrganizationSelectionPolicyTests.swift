import XCTest
@testable import ClaudeUsage

final class ClaudeOverageOrganizationSelectionPolicyTests: XCTestCase {
    func testSelectBestPrefersFirstEnabledOverageOrganization() {
        let selected = ClaudeOverageOrganizationSelectionPolicy.selectBest(
            from: [
                candidate("org-disabled", isEnabled: false),
                candidate("org-enabled", isEnabled: true),
                candidate("org-enabled-later", isEnabled: true),
            ]
        )

        XCTAssertEqual(selected?.organizationID, "org-enabled")
    }

    func testSelectBestFallsBackToFirstCandidateWhenNoEnabledOverageExists() {
        let selected = ClaudeOverageOrganizationSelectionPolicy.selectBest(
            from: [
                candidate("org-a", isEnabled: false),
                candidate("org-b", isEnabled: false),
            ]
        )

        XCTAssertEqual(selected?.organizationID, "org-a")
    }

    func testSelectBestReturnsNilForEmptyCandidates() {
        XCTAssertNil(ClaudeOverageOrganizationSelectionPolicy.selectBest(from: []))
    }

    private func candidate(
        _ organizationID: String,
        isEnabled: Bool
    ) -> ClaudeOverageOrganizationCandidate {
        ClaudeOverageOrganizationCandidate(
            organizationID: organizationID,
            overage: OverageSpendLimitResponse(
                monthlyCreditLimitCents: isEnabled ? 10_000 : 0,
                usedCreditsCents: isEnabled ? 2_500 : 0,
                isEnabled: isEnabled,
                outOfCredits: false,
                currency: "USD"
            )
        )
    }
}
