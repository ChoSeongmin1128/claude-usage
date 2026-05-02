import XCTest
@testable import ClaudeUsage

final class AppRuntimeStateFacadeTests: XCTestCase {
    func testClaudeAccountChangeClearsRuntimeStateBeforeNextRefresh() async {
        await MainActor.run {
            let facade = AppRuntimeStateFacade()
            facade.activeClaudeAccountID = "old-account"
            facade.lastOverageFetchAt = Date()
            facade.currentOverage = OverageSpendLimitResponse(
                monthlyCreditLimitCents: 10000,
                usedCreditsCents: 300,
                isEnabled: true,
                outOfCredits: false,
                currency: "USD"
            )
            facade[.claude] = RuntimeProviderState(
                error: .networkError("previous account"),
                isLoading: true,
                loadingStartedAt: Date(),
                nextRefreshAllowedAt: Date().addingTimeInterval(60)
            )

            _ = facade.applyClaudeUsageHealthSnapshot(makeSnapshot(activeAccountID: "new-account"))

            XCTAssertFalse(facade[.claude].isLoading)
            XCTAssertNil(facade[.claude].error)
            XCTAssertNil(facade[.claude].nextRefreshAllowedAt)
            XCTAssertNil(facade.currentOverage)
            XCTAssertNil(facade.lastOverageFetchAt)
            XCTAssertEqual(facade.activeClaudeAccountID, "new-account")
        }
    }

    private func makeSnapshot(activeAccountID: String?) -> ClaudeAPIService.UsageHealthSnapshot {
        let emptyPath = ClaudeAPIService.AuthPathHealthSnapshot(
            lastAttemptAt: nil,
            lastSuccessAt: nil,
            lastFailureAt: nil,
            lastErrorMessage: nil,
            consecutiveFailures: 0,
            totalAttempts: 0,
            totalFailures: 0
        )
        return ClaudeAPIService.UsageHealthSnapshot(
            lastOverallSuccessAt: nil,
            session: emptyPath,
            oauth: emptyPath,
            runtime: ClaudeAPIService.RuntimeAuthSnapshot(
                activePath: .sessionPrimary,
                credentialAvailability: ClaudeCredentialAvailability(
                    sessionCredentialAvailable: true,
                    oauthCredentialAvailable: false
                ),
                sessionValidationState: .verified,
                oauthValidationState: .unavailable,
                sessionCooldownRemaining: nil,
                oauthPreferredRemaining: nil
            ),
            accounts: [
                ClaudeAccount(
                    id: activeAccountID ?? "account",
                    kind: .webSession,
                    displayName: "Claude 계정"
                )
            ],
            activeAccountID: activeAccountID
        )
    }
}
