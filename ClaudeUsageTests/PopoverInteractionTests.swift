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
        facade.applyClaudeOverage(overage, accountID: "A", fetchedAt: Date())
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
        facade.applyClaudeOverage(overage, accountID: "A", fetchedAt: Date())
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
        facade.applyClaudeOverage(overage, accountID: "B", fetchedAt: Date())
        facade[.claude] = quotaState(accountID: "A")
        XCTAssertNil(facade.snapshot(for: .claude, codexAuthenticated: false).claudeOverage)
    }

    func testRefreshCooldownIsVisibleAndIndependentAcrossServices() {
        var clock = Date(timeIntervalSince1970: 100)
        let viewModel = PopoverViewModel(now: { clock })
        var requests: [PopoverService] = []
        viewModel.onRefreshService = { requests.append($0) }
        viewModel.refresh(service: .claude)
        viewModel.refresh(service: .claude)
        XCTAssertEqual(requests, [.claude])
        XCTAssertNotNil(viewModel.manualRefreshAvailableAt(for: .claude))
        XCTAssertTrue(viewModel.refreshHelp(for: .claude, isLoading: false).contains("잠시 후"))
        viewModel.selectService(.codex)
        XCTAssertNil(viewModel.manualRefreshAvailableAt(for: .codex))
        viewModel.refresh()
        XCTAssertEqual(requests, [.claude, .codex])
        clock.addTimeInterval(5)
        XCTAssertNil(viewModel.manualRefreshAvailableAt(for: .claude))
        viewModel.refresh(service: .claude)
        XCTAssertEqual(requests, [.claude, .codex, .claude])
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
