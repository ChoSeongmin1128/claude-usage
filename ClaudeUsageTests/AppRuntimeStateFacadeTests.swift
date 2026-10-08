import XCTest
@testable import ClaudeUsage

@MainActor
final class AppRuntimeStateFacadeTests: XCTestCase {
    func testClaudeAccountChangeClearsRuntimeStateBeforeNextRefresh() async {
        await MainActor.run {
            let facade = AppRuntimeStateFacade()
            facade.activeClaudeAccountID = "old-account"
            facade.applyClaudeSupplementalUsage(
                .success(
                    OverageSpendLimitResponse(
                monthlyCreditLimitCents: 10000,
                usedCreditsCents: 300,
                isEnabled: true,
                outOfCredits: false,
                currency: "USD"
                    ), fetchedAt: Date()), accountID: "old-account",
                ownerKey: fixtureClaudeMetadata(accountID: "old-account").supplementalAccountKey)
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

    func testFailedOverageFetchCountsTowardTheInterval() {
        let facade = AppRuntimeStateFacade()
        facade.activeClaudeAccountID = "account"
        facade[.claude].lastSuccessfulMetadata = fixtureClaudeMetadata(accountID: "account")
        XCTAssertNil(facade.lastOverageAttemptAt)

        facade.applyClaudeSupplementalUsage(
            .failed, accountID: "account", ownerKey: fixtureClaudeMetadata(accountID: "account").supplementalAccountKey)

        XCTAssertNotNil(facade.lastOverageAttemptAt)
        XCTAssertNil(facade.lastOverageFetchAt, "실패한 시각을 갱신 시각으로 보이지 않습니다")
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


extension AppRuntimeStateFacadeTests {
    func testDiscardedCredentialResultReleasesOnlyItsOwnLoadingState() {
        let facade = AppRuntimeStateFacade()
        let metadata = RuntimeProviderFetchMetadata(sourceLabel: "fixture", accountID: "a")
        facade[.claude] = RuntimeProviderState(
            payload: .claude(.init(fiveHour: .init(utilization: 42, resetsAt: nil), sevenDay: nil)),
            isLoading: true, loadingStartedAt: Date(), lastUpdated: Date(), lastSuccessfulMetadata: metadata)
        let request = facade.beginClaudeUsageRequest()

        XCTAssertTrue(facade.finishCancelledClaudeUsageRequest(request))
        XCTAssertFalse(facade[.claude].isLoading)
        XCTAssertNil(facade[.claude].loadingStartedAt)
        XCTAssertEqual(facade[.claude].lastAttemptState, .idle)
        XCTAssertEqual(facade[.claude].lastSuccessfulMetadata, metadata)
        guard case .claude(let usage)? = facade[.claude].lastSuccessfulPayload else { return XCTFail("이전값 누락") }
        XCTAssertEqual(usage.fiveHour?.utilization, 42)
        XCTAssertEqual(
            RuntimeProviderRefreshCoordinator.prepareForRefresh(state: &facade[.claude], force: true), .start)
    }

    func testCancelledOlderRequestCannotClearNewRequestLoading() {
        let facade = AppRuntimeStateFacade()
        let first = facade.beginClaudeUsageRequest()
        let next = facade.beginClaudeUsageRequest()
        let startedAt = Date()
        facade[.claude] = RuntimeProviderState(isLoading: true, loadingStartedAt: startedAt)

        XCTAssertFalse(facade.finishCancelledClaudeUsageRequest(first))
        XCTAssertEqual(facade.claudeRequestRevision, next)
        XCTAssertTrue(facade[.claude].isLoading)
        XCTAssertEqual(facade[.claude].loadingStartedAt, startedAt)
        XCTAssertTrue(facade.finishCancelledClaudeUsageRequest(next))
        XCTAssertFalse(facade[.claude].isLoading)
    }
}

extension AppRuntimeStateFacadeTests {
    func testSupplementalMoneyAndCooldownCannotMoveToAnotherOrganizationOfSameSession() {
        let facade = AppRuntimeStateFacade()
        facade.activeClaudeAccountID = "web"
        let a = fixtureClaudeMetadata(accountID: "web", organizationID: "a")
        let b = fixtureClaudeMetadata(accountID: "web", organizationID: "b")
        facade[.claude].lastSuccessfulMetadata = a
        let value = OverageSpendLimitResponse(
            monthlyCreditLimitCents: 2000, usedCreditsCents: 500,
            isEnabled: true, outOfCredits: false, currency: "USD")
        facade.applyClaudeSupplementalUsage(
            .success(value, fetchedAt: Date()), accountID: "web", ownerKey: a.supplementalAccountKey)
        XCTAssertEqual(facade.currentOverage, value)
        XCTAssertNotNil(facade.lastOverageAttemptAt)
        facade[.claude].lastSuccessfulMetadata = b
        XCTAssertNil(facade.currentOverage)
        XCTAssertNil(facade.lastOverageAttemptAt)
        facade.applyClaudeSupplementalUsage(.unchanged, accountID: "web", ownerKey: b.supplementalAccountKey)
        XCTAssertNil(facade.currentOverage)
        facade.applyClaudeSupplementalUsage(.failed, accountID: "web", ownerKey: b.supplementalAccountKey)
        XCTAssertNil(facade.currentOverage)
        XCTAssertNotNil(facade.lastOverageAttemptAt)
    }

    func testUnknownNativeOwnerDoesNotReuseCachedMoneyButKeepsEmbeddedAmount() throws {
        let facade = AppRuntimeStateFacade()
        let slot = ClaudeAccountStore.claudeCodeExternalAccountID
        facade.activeClaudeAccountID = slot
        let known = RuntimeProviderFetchMetadata(
            accountID: slot,
            account: .init(
                source: .init(role: .defaultLogin, reference: "/fixture/.claude"),
                identity: .init(accountID: "a", organizationID: "org")))
        facade[.claude].lastSuccessfulMetadata = known
        let amount = OverageSpendLimitResponse(
            monthlyCreditLimitCents: 2000, usedCreditsCents: 500,
            isEnabled: true, outOfCredits: false, currency: "USD")
        facade.applyClaudeSupplementalUsage(
            .success(amount, fetchedAt: Date()), accountID: slot, ownerKey: known.supplementalAccountKey)
        let unknown = RuntimeProviderFetchMetadata(
            accountID: slot,
            account: .init(
                source: .init(role: .defaultLogin, reference: "/fixture/.claude"), identity: .init()))
        let usage = try JSONDecoder().decode(
            ClaudeUsageResponse.self,
            from: Data(
                #"{"five_hour":{"utilization":20},"extra_usage":{"is_enabled":true,"monthly_limit":1000,"used_credits":700}}"#
                    .utf8))
        facade[.claude] = .init(payload: .claude(usage), lastSuccessfulMetadata: unknown)
        XCTAssertNil(facade.currentOverage)
        XCTAssertNil(facade.lastOverageAttemptAt)
        XCTAssertEqual(facade.snapshot(for: .claude, codexAuthenticated: false).claudeOverage?.usedCredits, 7)
        XCTAssertEqual(facade.snapshot(for: .claude, codexAuthenticated: false).claudeUsage?.fiveHour?.utilization, 20)
    }
}
