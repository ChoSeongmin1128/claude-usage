import XCTest
@testable import ClaudeUsage

@MainActor
final class PopoverInteractionTests: XCTestCase {
    private let overage = OverageSpendLimitResponse(
        monthlyCreditLimitCents: 10000, usedCreditsCents: 300,
        isEnabled: true, outOfCredits: false, currency: "USD"
    )

    func testSupplementalUsageCannotSurviveAnAccountBoundary() {
        let facade = AppRuntimeStateFacade()
        let viewModel = PopoverViewModel()
        facade.activeClaudeAccountID = "A"
        facade.applyClaudeSupplementalUsage(.success(overage, fetchedAt: Date()), accountID: "A")
        facade[.claude] = quotaState(accountID: "A")
        viewModel.update(snapshots: [facade.snapshot(for: .claude, codexAuthenticated: false)])
        XCTAssertEqual(viewModel.overage, overage)

        let revisionA = facade.claudeRequestRevision
        facade.activeClaudeAccountID = "B"
        facade[.claude] = RuntimeProviderState()
        viewModel.update(snapshots: [facade.snapshot(for: .claude, codexAuthenticated: false)])
        XCTAssertNil(viewModel.overage)
        facade[.claude] = quotaState(accountID: "B")
        viewModel.update(snapshots: [facade.snapshot(for: .claude, codexAuthenticated: false)])
        XCTAssertNil(viewModel.overage)
        XCTAssertNil(facade.lastOverageFetchAt)

        facade.activeClaudeAccountID = "A"
        XCTAssertNotEqual(facade.claudeRequestRevision, revisionA, "A → B → A must reject the original request")
    }

    func testSameAccountTemporaryFailureRetainsSupplementalUsage() {
        let facade = AppRuntimeStateFacade()
        facade.activeClaudeAccountID = "A"
        facade.applyClaudeSupplementalUsage(.success(overage, fetchedAt: Date()), accountID: "A")
        var state = quotaState(accountID: "A")
        _ = RuntimeProviderRefreshCoordinator.applyFailure(
            state: &state, error: .networkError("fixture"), minimumInterval: 30
        )
        facade[.claude] = state
        XCTAssertEqual(facade.snapshot(for: .claude, codexAuthenticated: false).claudeOverage, overage)
        facade.clearClaudePresentationState()
        XCTAssertNil(facade.snapshot(for: .claude, codexAuthenticated: false).claudeOverage)
    }

    func testSnapshotDoesNotAttachSupplementalUsageToAnotherQuotaAccount() {
        let facade = AppRuntimeStateFacade()
        facade.activeClaudeAccountID = "B"
        facade.applyClaudeSupplementalUsage(.success(overage, fetchedAt: Date()), accountID: "B")
        facade[.claude] = quotaState(accountID: "A")
        XCTAssertNil(facade.snapshot(for: .claude, codexAuthenticated: false).claudeOverage)
    }

    func testSupplementalFailureAndSkippedFetchKeepTheSuccessfulValueAndTime() {
        let facade = AppRuntimeStateFacade()
        let checkedAt = Date(timeIntervalSince1970: 100)
        facade.activeClaudeAccountID = "A"
        facade[.claude] = quotaState(accountID: "A")
        facade.applyClaudeSupplementalUsage(.success(overage, fetchedAt: checkedAt), accountID: "A")
        facade.applyClaudeSupplementalUsage(.failed, accountID: "A")
        facade.applyClaudeSupplementalUsage(.unchanged, accountID: "A")
        let snapshot = facade.snapshot(for: .claude, codexAuthenticated: false)
        XCTAssertEqual(snapshot.claudeOverage, overage)
        XCTAssertEqual(snapshot.claudeOverageUpdatedAt, checkedAt)
        XCTAssertTrue(snapshot.claudeOverageIsStale)
        facade.applyClaudeSupplementalUsage(
            .success(overage, fetchedAt: checkedAt.addingTimeInterval(300)), accountID: "A")
        XCTAssertFalse(facade.snapshot(for: .claude, codexAuthenticated: false).claudeOverageIsStale)
    }

    func testManualRefreshIgnoresRepeatsUntilDoneThenStaysQuietForTenSeconds() {
        let base = Date()
        var clock = base
        let viewModel = PopoverViewModel(now: { clock })
        var requests: [PopoverService] = []
        viewModel.onRefreshService = { requests.append($0) }

        viewModel.refresh(service: .claude)
        viewModel.refresh(service: .claude)
        XCTAssertEqual(requests, [.claude])
        XCTAssertEqual(viewModel.refreshHelp(for: .claude, isLoading: false), "사용량 갱신 중")

        viewModel.selectService(.codex)
        XCTAssertNil(viewModel.manualRefreshAvailableAt(for: .codex))
        viewModel.refresh()
        XCTAssertEqual(requests, [.claude, .codex])

        let facade = AppRuntimeStateFacade()
        facade[.claude] = quotaState(accountID: "A")
        viewModel.update(snapshots: [facade.snapshot(for: .claude, codexAuthenticated: false)])
        XCTAssertNotNil(viewModel.manualRefreshAvailableAt(for: .claude))
        XCTAssertEqual(viewModel.refreshHelp(for: .claude, isLoading: false), "방금 갱신됨")
        viewModel.refresh(service: .claude)
        XCTAssertEqual(requests, [.claude, .codex])

        clock = base.addingTimeInterval(11)
        XCTAssertNil(viewModel.manualRefreshAvailableAt(for: .claude))
        viewModel.refresh(service: .claude)
        XCTAssertEqual(requests, [.claude, .codex, .claude])
    }

    func testRetryAfterBlocksManualRefreshWithCountdown() {
        let base = Date()
        let viewModel = PopoverViewModel(now: { base })
        var state = quotaState(accountID: "A")
        _ = RuntimeProviderRefreshCoordinator.applyFailure(
            state: &state, error: .rateLimited(retryAfter: 90), minimumInterval: 120)
        let facade = AppRuntimeStateFacade()
        facade[.claude] = state
        viewModel.update(snapshots: [facade.snapshot(for: .claude, codexAuthenticated: false)])
        XCTAssertNotNil(viewModel.manualRefreshAvailableAt(for: .claude))
        XCTAssertTrue(viewModel.refreshHelp(for: .claude, isLoading: false).hasSuffix("초 후 다시 시도"))
    }

    private func quotaState(accountID: String) -> RuntimeProviderState {
        var state = RuntimeProviderState()
        RuntimeProviderRefreshCoordinator.applySuccess(
            state: &state,
            payload: .claude(
                ClaudeUsageResponse(
                    fiveHour: UsageWindow(utilization: 8, resetsAt: nil), sevenDay: nil
                )),
            metadata: RuntimeProviderFetchMetadata(accountID: accountID)
        )
        return state
    }
}
