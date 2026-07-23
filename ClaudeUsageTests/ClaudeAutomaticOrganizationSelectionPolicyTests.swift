import XCTest
@testable import ClaudeUsage

final class ClaudeAutomaticOrganizationSelectionPolicyTests: XCTestCase {
    func testSelectBestPrefersTeamPlanSignalOverPersonalOrganization() {
        let selected = ClaudeAutomaticOrganizationSelectionPolicy.selectBest(
            from: [
                candidate("org-personal", planLabel: "pro", isOverageEnabled: false),
                candidate("org-team", planLabel: "team", isOverageEnabled: false),
            ]
        )

        XCTAssertEqual(selected?.organization.id, "org-team")
    }

    func testSelectBestPrefersOrganizationNameOverClaudePersonalWorkspace() {
        let selected = ClaudeAutomaticOrganizationSelectionPolicy.selectBest(
            from: [
                candidate(
                    "org-personal",
                    name: "nathan@example.com's Organization",
                    isOverageEnabled: true
                ),
                candidate(
                    "org-company",
                    name: "Glorang",
                    isOverageEnabled: false
                ),
            ]
        )

        XCTAssertEqual(selected?.organization.id, "org-company")
    }

    func testSelectBestPrefersEnabledOverageWhenPlanSignalIsUnavailable() {
        let selected = ClaudeAutomaticOrganizationSelectionPolicy.selectBest(
            from: [
                candidate("org-disabled", isOverageEnabled: false),
                candidate("org-enabled", isOverageEnabled: true),
                candidate("org-enabled-later", isOverageEnabled: true),
            ]
        )

        XCTAssertEqual(selected?.organization.id, "org-enabled")
    }

    func testSelectBestFallsBackToFirstCandidateWhenNoTeamOrOverageSignalExists() {
        let selected = ClaudeAutomaticOrganizationSelectionPolicy.selectBest(
            from: [
                candidate("org-a", isOverageEnabled: false),
                candidate("org-b", isOverageEnabled: false),
            ]
        )

        XCTAssertEqual(selected?.organization.id, "org-a")
    }

    func testSelectBestKeepsFirstOrganizationWhenNoProbeSucceeded() {
        let selected = ClaudeAutomaticOrganizationSelectionPolicy.selectBest(
            from: [
                candidate("org-a", overage: nil),
                candidate("org-b", overage: nil),
            ]
        )

        XCTAssertEqual(selected?.organization.id, "org-a")
    }

    func testSelectBestReturnsNilForEmptyCandidates() {
        XCTAssertNil(ClaudeAutomaticOrganizationSelectionPolicy.selectBest(from: []))
    }

    func testResolvedOrganizationMetadataIsNotWrittenToPreviousChromeAccount() {
        let previous = ClaudeAccount(
            id: ClaudeAccountStore.webSessionAccountID(
                fingerprint: ClaudeAccountStore.fingerprint(for: "previous-session")
            ),
            kind: .webSession,
            displayName: "Previous Chrome"
        )

        XCTAssertFalse(
            ClaudeAPIService.shouldRememberResolvedOrganization(
                activeAccount: previous,
                sessionKey: "new-session"
            )
        )
        XCTAssertTrue(
            ClaudeAPIService.shouldRememberResolvedOrganization(
                activeAccount: previous,
                sessionKey: "previous-session"
            )
        )
    }

    private func candidate(
        _ organizationID: String,
        name: String? = nil,
        planLabel: String? = nil,
        isOverageEnabled: Bool
    ) -> ClaudeAutomaticOrganizationCandidate {
        candidate(
            organizationID,
            name: name,
            planLabel: planLabel,
            overage: OverageSpendLimitResponse(
                monthlyCreditLimitCents: isOverageEnabled ? 10_000 : 0,
                usedCreditsCents: isOverageEnabled ? 2_500 : 0,
                isEnabled: isOverageEnabled,
                outOfCredits: false,
                currency: "USD"
            )
        )
    }

    private func candidate(
        _ organizationID: String,
        name: String? = nil,
        planLabel: String? = nil,
        overage: OverageSpendLimitResponse?
    ) -> ClaudeAutomaticOrganizationCandidate {
        ClaudeAutomaticOrganizationCandidate(
            organization: ClaudeAPIService.OrganizationSummary(
                id: organizationID,
                name: name ?? organizationID,
                planLabel: planLabel
            ),
            overage: overage
        )
    }
}
