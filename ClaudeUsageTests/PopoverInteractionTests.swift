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

    func testServiceSettingsActionsUseCanonicalDestinationCallback() throws {
        let suite = "PopoverSettingsRouting.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let coordinator = AppPopoverCoordinator(settings: settings, reduceMotion: { true })
        var destinations: [SettingsDestination] = []
        coordinator.configure(
            initialService: .claude,
            onRefreshService: { _ in },
            onOpenSettingsDestination: { destinations.append($0) },
            onServiceSelected: { _ in },
            onLayoutChanged: { _, _ in },
            onPinChanged: { _, _ in }
        )
        let model = coordinator.viewModel

        for service in [PopoverService.claude, .codex, .antigravity] {
            model.selectService(service)
            let host = ProviderPopoverContentHost(
                viewModel: model, settings: settings, service: service,
                layoutSpec: model.layoutSpec(for: service, settings: settings), sections: [],
                onOpenDisplaySettings: {}
            )
            destinations.removeAll()
            model.openSettings()
            host.action(for: .openSettings)?()
            XCTAssertEqual(
                destinations,
                [
                    SettingsDestination(panel: .service(service.providerKind), section: .connection),
                    SettingsDestination(panel: .service(service.providerKind), section: .connection),
                ])
            XCTAssertEqual(model.selectedService, service)
        }
    }

    func testEmptySelectionAndDesignIntroductionRouteToTheirOwnSettingsSections() throws {
        let suite = "PopoverSettingsDisplayRouting.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = PopoverViewModel(updateRuntimeState: UpdateRuntimeState(settings: settings))
        var destinations: [SettingsDestination] = []
        model.onOpenSettingsDestination = { destinations.append($0) }
        for service in [PopoverService.claude, .codex, .antigravity] {
            model.selectService(service)
            destinations.removeAll()
            model.openSettings(for: service, section: .popover)
            model.openSettings(panel: .display)
            XCTAssertEqual(
                destinations,
                [
                    SettingsDestination(panel: .service(service.providerKind), section: .popover),
                    SettingsDestination(panel: .display),
                ])
            XCTAssertEqual(model.selectedService, service)
        }

        let summary = CatalogPopoverPresentationAdapter.emptySelectionSummary()
        for service in [PopoverService.claude, .codex] {
            model.selectService(service)
            let host = ProviderPopoverContentHost(
                viewModel: model, settings: settings, service: service,
                layoutSpec: model.layoutSpec(for: service, settings: settings), sections: [],
                onOpenDisplaySettings: { model.openSettings(for: service, section: .popover) }
            )
            destinations.removeAll()
            host.action(for: summary.action)?()
            XCTAssertEqual(
                destinations, [SettingsDestination(panel: .service(service.providerKind), section: .popover)])
            XCTAssertEqual(model.selectedService, service)
        }
    }

    func testLoginFallbackRoutesClaudeConnectionWithoutChangingVisibleService() {
        let model = PopoverViewModel()
        model.selectService(.codex)
        var destinations: [SettingsDestination] = []
        model.onOpenSettingsDestination = { destinations.append($0) }

        model.startClaudeLogin()

        XCTAssertEqual(destinations, [SettingsDestination(panel: .claude, section: .connection)])
        XCTAssertEqual(model.selectedService, .codex)
        var loginsStarted = 0
        model.onStartClaudeLogin = { loginsStarted += 1 }
        model.startClaudeLogin()
        XCTAssertEqual(loginsStarted, 1)
        XCTAssertEqual(destinations.count, 1)
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
