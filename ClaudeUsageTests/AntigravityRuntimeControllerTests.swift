import Foundation
import XCTest
@testable import ClaudeUsage

final class AntigravityRuntimeControllerTests:
    XCTestCase
{
    func testBootstrapRecoversManagedRuntimeBeforeInitialRefresh()
        async throws
    {
        let fixture = makeFixture()

        let snapshot = await fixture.controller.bootstrap(
            performInitialRefresh: true
        )
        let events = await fixture.events.snapshot()

        XCTAssertEqual(snapshot.readiness, .ready)
        XCTAssertEqual(
            snapshot.managedRuntimeAvailability,
            .available(
                displayPath:
                    "~/.local/bin/agy"
            )
        )
        XCTAssertLessThan(
            try XCTUnwrap(
                events.firstIndex(of: "managed.recover")
            ),
            try XCTUnwrap(
                events.firstIndex(of: "refresh.run")
            )
        )
        let requests = await fixture.refresh.requests()
        XCTAssertEqual(requests.count, 1)
    }

    func testAccountSwitchInvalidatesBoundaryAndRefreshesExactlyOnce()
        async throws
    {
        let fixture = makeFixture()
        _ = await fixture.controller.bootstrap(
            performInitialRefresh: false
        )

        let snapshot = try await fixture.controller
            .selectAccount(Self.secondAccountID)

        let requests = await fixture.refresh.requests()
        let invalidationCount =
            await fixture.refresh.invalidationCount()
        let selectionCount =
            await fixture.repository.selectionCount()
        XCTAssertEqual(
            invalidationCount,
            1
        )
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            requests.first?.trigger,
            .accountBoundaryChanged
        )
        XCTAssertEqual(
            requests.first?.accountTarget,
            .selectedOAuth(Self.secondAccountID)
        )
        XCTAssertEqual(
            selectionCount,
            1
        )
        XCTAssertEqual(
            snapshot.activeAccountID,
            Self.secondAccountID
        )
    }

    func testAccountSwitchPreemptsInFlightRefreshAndRejectsItsLateResult()
        async throws
    {
        let refreshGate = ControllerRefreshGate()
        let fixture = makeFixture(
            refreshGate: refreshGate
        )
        _ = await fixture.controller.bootstrap(
            performInitialRefresh: false
        )

        let oldRefresh = Task {
            await fixture.controller.refresh(
                trigger: .manual
            )
        }
        await refreshGate.waitUntilRequestCount(1)

        let accountSwitch = Task {
            try await fixture.controller
                .selectAccount(Self.secondAccountID)
        }
        await refreshGate.waitUntilRequestCount(2)

        let invalidated =
            await fixture.controller.snapshot()
        XCTAssertEqual(
            invalidated.activeAccountID,
            Self.secondAccountID
        )
        XCTAssertEqual(
            invalidated.presentationState,
            .refreshing(previous: nil)
        )

        await refreshGate.resolveRequest(
            at: 0,
            with: .ready(Self.oldQuotaSnapshot)
        )
        let oldResult = await oldRefresh.value
        XCTAssertEqual(
            oldResult.activeAccountID,
            Self.secondAccountID
        )
        XCTAssertEqual(
            oldResult.presentationState,
            .refreshing(previous: nil)
        )

        await refreshGate.resolveRequest(
            at: 1,
            with: .ready(Self.newQuotaSnapshot)
        )
        let switched = try await accountSwitch.value
        XCTAssertEqual(
            switched.activeAccountID,
            Self.secondAccountID
        )
        XCTAssertEqual(
            switched.presentationState,
            .ready(Self.newQuotaSnapshot)
        )
    }

    func testSupersededAccountMutationReportsCancellationInsteadOfSuccess()
        async throws
    {
        let refreshGate = ControllerRefreshGate()
        let fixture = makeFixture(
            refreshGate: refreshGate
        )
        _ = await fixture.controller.bootstrap(
            performInitialRefresh: false
        )

        let firstSwitch = Task {
            try await fixture.controller
                .selectAccount(Self.secondAccountID)
        }
        await refreshGate.waitUntilRequestCount(1)

        let newerSwitch = Task {
            try await fixture.controller
                .selectAccount(Self.firstAccountID)
        }
        await refreshGate.waitUntilRequestCount(2)

        await refreshGate.resolveRequest(
            at: 0,
            with: .ready(Self.oldQuotaSnapshot)
        )
        do {
            _ = try await firstSwitch.value
            XCTFail(
                "Expected superseded mutation failure"
            )
        } catch {
            XCTAssertEqual(
                error as?
                    AntigravityRuntimeControllerError,
                .operationSuperseded
            )
        }

        await refreshGate.resolveRequest(
            at: 1,
            with: .ready(Self.newQuotaSnapshot)
        )
        let final = try await newerSwitch.value
        XCTAssertEqual(
            final.activeAccountID,
            Self.firstAccountID
        )
        XCTAssertEqual(
            final.presentationState,
            .ready(Self.newQuotaSnapshot)
        )
    }

    func testInvalidAccountBoundaryFailureRestoresPreviousPresentation()
        async throws
    {
        let fixture = makeFixture()
        let previous =
            await fixture.controller.bootstrap(
                performInitialRefresh: false
            )
        let missing = AntigravityAccountID(
            rawValue:
                "00000000-0000-0000-0000-000000000099"
        )

        do {
            _ = try await fixture.controller
                .selectAccount(missing)
            XCTFail("Expected account-not-found failure")
        } catch {
            XCTAssertEqual(
                error as?
                    AntigravityRuntimeControllerError,
                .accountNotFound
            )
        }

        let recovered =
            await fixture.controller.snapshot()
        XCTAssertEqual(
            recovered.presentationState,
            previous.presentationState
        )
        XCTAssertEqual(
            recovered.activeAccountID,
            previous.activeAccountID
        )
        XCTAssertNotEqual(
            recovered.presentationState,
            .refreshing(previous: nil)
        )

        var display =
            AntigravityDisplaySettings.default
        display.menuBar
            .showsSelectedLaneResetTime
            .toggle()
        let displayUpdated =
            try await fixture.controller
                .updateDisplay(
                    display,
                    replacing: .default
                )
        XCTAssertEqual(
            displayUpdated.presentationState,
            previous.presentationState
        )
    }

    func testRepositoryMutationFailurePublishesTerminalFailureInsteadOfSpinner()
        async
    {
        let fixture = makeFixture(
            selectionFails: true
        )
        _ = await fixture.controller.bootstrap(
            performInitialRefresh: false
        )

        do {
            _ = try await fixture.controller
                .selectAccount(Self.secondAccountID)
            XCTFail("Expected repository failure")
        } catch {
            XCTAssertEqual(
                error as?
                    AntigravityAccountRepositoryError,
                .metadataPersistenceVerificationFailed
            )
        }

        let recovered =
            await fixture.controller.snapshot()
        XCTAssertEqual(recovered.readiness, .ready)
        XCTAssertEqual(
            recovered.activeAccountID,
            Self.firstAccountID
        )
        XCTAssertEqual(
            recovered.presentationState,
            .failed(.repositoryUnavailable)
        )
        let requests = await fixture.refresh.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testSelectingAmbientModeInvalidatesAndRefreshesExactlyOnce()
        async throws
    {
        let fixture = makeFixture()
        _ = await fixture.controller.bootstrap(
            performInitialRefresh: false
        )
        let snapshot = try await fixture.controller
            .selectAccount(nil)

        let requests = await fixture.refresh.requests()
        let invalidationCount =
            await fixture.refresh.invalidationCount()
        XCTAssertEqual(
            invalidationCount,
            1
        )
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            requests.first?.trigger,
            .accountBoundaryChanged
        )
        XCTAssertEqual(
            requests.first?.accountTarget,
            .ambientLocal
        )
        XCTAssertNil(snapshot.activeAccountID)
    }

    func testAmbientSelectionPreemptsInFlightRefreshAndRejectsItsLateResult()
        async throws
    {
        let refreshGate = ControllerRefreshGate()
        let fixture = makeFixture(
            refreshGate: refreshGate
        )
        _ = await fixture.controller.bootstrap(
            performInitialRefresh: false
        )

        let oldRefresh = Task {
            await fixture.controller.refresh(
                trigger: .scheduled
            )
        }
        await refreshGate.waitUntilRequestCount(1)

        let sourceSwitch = Task {
            try await fixture.controller
                .selectAccount(nil)
        }
        await refreshGate.waitUntilRequestCount(2)

        let invalidated =
            await fixture.controller.snapshot()
        XCTAssertNil(invalidated.activeAccountID)
        XCTAssertEqual(
            invalidated.presentationState,
            .refreshing(previous: nil)
        )

        await refreshGate.resolveRequest(
            at: 0,
            with: .ready(Self.oldQuotaSnapshot)
        )
        let oldResult = await oldRefresh.value
        XCTAssertNil(oldResult.activeAccountID)
        XCTAssertEqual(
            oldResult.presentationState,
            .refreshing(previous: nil)
        )

        await refreshGate.resolveRequest(
            at: 1,
            with: .ready(Self.newQuotaSnapshot)
        )
        let switched = try await sourceSwitch.value
        XCTAssertNil(switched.activeAccountID)
        XCTAssertEqual(
            switched.presentationState,
            .ready(Self.newQuotaSnapshot)
        )
    }

    func testDisplayOnlyUpdateDoesNotInvalidateOrRefresh()
        async throws
    {
        let fixture = makeFixture()
        _ = await fixture.controller.bootstrap(
            performInitialRefresh: false
        )
        var display = AntigravityDisplaySettings.default
        display.menuBar.showsSelectedLaneResetTime =
            true

        let snapshot = try await fixture.controller
            .updateDisplay(
                display,
                replacing: .default
            )

        let invalidationCount =
            await fixture.refresh.invalidationCount()
        let requests = await fixture.refresh.requests()
        let displaySaveCount =
            await fixture.settings.displaySaveCount()
        XCTAssertEqual(
            invalidationCount,
            0
        )
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(
            displaySaveCount,
            1
        )
        XCTAssertEqual(
            snapshot.settings?.display,
            display
        )
    }

    func testMenuBarStyleUpdatePreservesLatestDisplayFields()
        async throws
    {
        let fixture = makeFixture()
        _ = await fixture.controller.bootstrap(
            performInitialRefresh: false
        )
        var settingsDisplay =
            AntigravityDisplaySettings.default
        settingsDisplay.menuBar
            .showsSelectedLaneResetTime = true
        _ = try await fixture.controller
            .updateDisplay(
                settingsDisplay,
                replacing: .default
            )

        let snapshot = try await fixture.controller
            .updateMenuBarStyle(.circular)

        XCTAssertEqual(
            snapshot.settings?.display.menuBar.style,
            .circular
        )
        XCTAssertEqual(
            snapshot.settings?.display.menuBar
                .showsSelectedLaneResetTime,
            true
        )
        let displaySaveCount =
            await fixture.settings.displaySaveCount()
        XCTAssertEqual(displaySaveCount, 2)
    }

    func testDisplayUpdateRejectsSnapshotOlderThanMenuBarStyleMutation()
        async throws
    {
        let fixture = makeFixture()
        _ = await fixture.controller.bootstrap(
            performInitialRefresh: false
        )
        _ = try await fixture.controller
            .updateMenuBarStyle(.circular)
        var staleDisplay =
            AntigravityDisplaySettings.default
        staleDisplay.menuBar
            .showsSelectedLaneResetTime = true

        do {
            _ = try await fixture.controller
                .updateDisplay(
                    staleDisplay,
                    replacing: .default
                )
            XCTFail(
                "Expected stale display snapshot rejection"
            )
        } catch {
            XCTAssertEqual(
                error as?
                    AntigravityRuntimeControllerError,
                .operationSuperseded
            )
        }

        let snapshot =
            await fixture.controller.snapshot()
        XCTAssertEqual(
            snapshot.settings?.display.menuBar.style,
            .circular
        )
        XCTAssertEqual(
            snapshot.settings?.display.menuBar
                .showsSelectedLaneResetTime,
            false
        )
        let displaySaveCount =
            await fixture.settings.displaySaveCount()
        XCTAssertEqual(displaySaveCount, 1)
    }

    func testDisplayUpdateCannotRepublishAnOlderAccountBoundary()
        async throws
    {
        let displaySaveGate = ControllerSuspensionGate()
        let fixture = makeFixture(
            displaySaveGate: displaySaveGate
        )
        _ = await fixture.controller.bootstrap(
            performInitialRefresh: false
        )
        var display = AntigravityDisplaySettings.default
        display.menuBar.showsSelectedLaneResetTime =
            true

        let displayUpdate = Task {
            try await fixture.controller
                .updateDisplay(
                    display,
                    replacing: .default
                )
        }
        await displaySaveGate.waitUntilEntered()

        let accountSwitch = Task {
            try await fixture.controller
                .selectAccount(Self.secondAccountID)
        }
        await waitUntilRefreshing(fixture.controller)
        await displaySaveGate.resume()

        let displayResult = try await displayUpdate.value
        XCTAssertEqual(
            displayResult.presentationState,
            .refreshing(previous: nil)
        )

        let switched = try await accountSwitch.value
        XCTAssertEqual(
            switched.activeAccountID,
            Self.secondAccountID
        )
    }

    func testNoticeConsumptionCannotRepublishAnOlderAccountBoundary()
        async throws
    {
        let noticeGate = ControllerSuspensionGate()
        let fixture = makeFixture(
            noticeConsumptionGate: noticeGate
        )
        _ = await fixture.controller.bootstrap(
            performInitialRefresh: false
        )

        let noticeConsumption = Task {
            await fixture.controller
                .consumePendingSettingsNotice()
        }
        await noticeGate.waitUntilEntered()

        let accountSwitch = Task {
            try await fixture.controller
                .selectAccount(Self.secondAccountID)
        }
        await waitUntilRefreshing(fixture.controller)
        await noticeGate.resume()

        let noticeResult =
            await noticeConsumption.value
        XCTAssertEqual(
            noticeResult.presentationState,
            .refreshing(previous: nil)
        )

        let switched = try await accountSwitch.value
        XCTAssertEqual(
            switched.activeAccountID,
            Self.secondAccountID
        )
    }

    func testManagedRecoveryFailureDisablesManagedSourceForRefresh()
        async
    {
        let fixture = makeFixture(
            recoveryFails: true
        )

        let snapshot = await fixture.controller.bootstrap(
            performInitialRefresh: true
        )
        let requests = await fixture.refresh.requests()

        XCTAssertEqual(
            snapshot.managedRuntimeAvailability,
            .recoveryBlocked(
                displayPath:
                    "~/.local/bin/agy"
            )
        )
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            requests.first?.managedLaunch,
            .recoveryBlocked
        )
    }

    func testShutdownQuiescesRefreshStopsManagedSessionAndRejectsMutations()
        async throws
    {
        let fixture = makeFixture()
        _ = await fixture.controller.bootstrap(
            performInitialRefresh: false
        )

        await fixture.controller.shutdown()

        let quiesceCount =
            await fixture.refresh.quiesceCount()
        let shutdownCount =
            await fixture.managed.shutdownCount()
        let shutdownSnapshot =
            await fixture.controller.snapshot()
        XCTAssertEqual(
            quiesceCount,
            1
        )
        XCTAssertEqual(
            shutdownCount,
            1
        )
        XCTAssertEqual(
            shutdownSnapshot.readiness,
            .shuttingDown
        )

        do {
            _ = try await fixture.controller
                .selectAccount(Self.secondAccountID)
            XCTFail("Expected shutdown rejection")
        } catch {
            XCTAssertEqual(
                error as?
                    AntigravityRuntimeControllerError,
                .appShuttingDown
            )
        }

        _ = await fixture.controller.refresh(
            trigger: .manual
        )
        let requests = await fixture.refresh.requests()
        let selectionCount =
            await fixture.repository.selectionCount()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(
            selectionCount,
            0
        )
    }

    func testShutdownIsNotQueuedBehindInFlightRefresh()
        async
    {
        let refreshGate = ControllerRefreshGate()
        let fixture = makeFixture(
            refreshGate: refreshGate
        )
        _ = await fixture.controller.bootstrap(
            performInitialRefresh: false
        )

        let refresh = Task {
            await fixture.controller.refresh(
                trigger: .manual
            )
        }
        await refreshGate.waitUntilRequestCount(1)

        let shutdownCompleted = expectation(
            description:
                "shutdown bypasses refresh operation gate"
        )
        Task {
            await fixture.controller.shutdown()
            shutdownCompleted.fulfill()
        }
        await fulfillment(
            of: [shutdownCompleted],
            timeout: 1
        )

        let quiesceCount =
            await fixture.refresh.quiesceCount()
        let managedShutdownCount =
            await fixture.managed.shutdownCount()
        XCTAssertEqual(quiesceCount, 1)
        XCTAssertEqual(managedShutdownCount, 1)
        let shutdownSnapshot =
            await fixture.controller.snapshot()
        XCTAssertEqual(
            shutdownSnapshot.readiness,
            .shuttingDown
        )
        XCTAssertEqual(
            shutdownSnapshot.presentationState,
            .failed(.appShuttingDown)
        )

        await refreshGate.resolveRequest(
            at: 0,
            with: .ready(Self.oldQuotaSnapshot)
        )
        _ = await refresh.value
        let finalSnapshot =
            await fixture.controller.snapshot()
        XCTAssertEqual(
            finalSnapshot.readiness,
            .shuttingDown
        )
        XCTAssertEqual(
            finalSnapshot.presentationState,
            .failed(.appShuttingDown)
        )
    }

    func testAmbientModeWithoutLocalSessionKeepsSetupRequirement()
        async
    {
        let fixture = makeFixture(
            activeAccountID: nil,
            refreshResult:
                .setupRequired(
                    .noAmbientLocalSession
                )
        )

        let snapshot = await fixture.controller.bootstrap(
            performInitialRefresh: true
        )
        let requests = await fixture.refresh.requests()

        XCTAssertEqual(
            requests.first?.accountTarget,
            .ambientLocal
        )
        XCTAssertEqual(
            snapshot.presentationState,
            .setupRequired(
                .noAmbientLocalSession
            )
        )
    }

    private func makeFixture(
        activeAccountID:
            AntigravityAccountID? =
                AntigravityAccountID(
                    rawValue:
                        "00000000-0000-0000-0000-000000000001"
                ),
        connection:
            AntigravityConnectionSettings = .default,
        recoveryFails: Bool = false,
        selectionFails: Bool = false,
        refreshResult:
            AntigravityPresentationState? = nil,
        refreshGate:
            ControllerRefreshGate? = nil,
        displaySaveGate:
            ControllerSuspensionGate? = nil,
        noticeConsumptionGate:
            ControllerSuspensionGate? = nil
    ) -> ControllerFixture {
        let events = ControllerEventRecorder()
        let repository =
            ControllerAccountRepositoryDouble(
                state: Self.repositoryState(
                    activeAccountID:
                        activeAccountID
                ),
                events: events,
                selectionFails: selectionFails
            )
        let settings =
            ControllerSettingsStoreDouble(
                snapshot:
                    AntigravitySettingsSnapshot(
                        connection: connection,
                        display: .default
                    ),
                events: events,
                displaySaveGate: displaySaveGate,
                noticeConsumptionGate:
                    noticeConsumptionGate
            )
        let migration =
            ControllerMigrationCoordinatorDouble(
                status: Self.completeMigrationStatus,
                events: events
            )
        let refresh =
            ControllerRefreshCoordinatorDouble(
                result:
                    refreshResult
                    ?? .ready(
                        Self.emptyQuotaSnapshot
                    ),
                events: events,
                refreshGate: refreshGate
            )
        let managed =
            ControllerManagedSessionDouble(
                recoveryFails: recoveryFails,
                events: events
            )
        let controller = AntigravityRuntimeController(
            repository: repository,
            settingsStore: settings,
            migrationCoordinator: migration,
            refreshCoordinator: refresh,
            managedSession: managed,
            settingsBootstrap:
                .ready(.alreadyCurrent),
            agyExecutableStatus:
                .verified(
                    displayPath:
                        "~/.local/bin/agy"
                ),
            now: {
                Date(
                    timeIntervalSince1970:
                        1_900_000_000
                )
            }
        )
        return ControllerFixture(
            controller: controller,
            repository: repository,
            settings: settings,
            refresh: refresh,
            managed: managed,
            events: events
        )
    }

    private func waitUntilRefreshing(
        _ controller: AntigravityRuntimeController
    ) async {
        for _ in 0..<100 {
            let snapshot = await controller.snapshot()
            if snapshot.presentationState
                == .refreshing(previous: nil)
            {
                return
            }
            await Task.yield()
        }
        XCTFail(
            "Timed out waiting for account boundary invalidation"
        )
    }

    private static let firstAccountID =
        AntigravityAccountID(
            rawValue:
                "00000000-0000-0000-0000-000000000001"
        )
    private static let secondAccountID =
        AntigravityAccountID(
            rawValue:
                "00000000-0000-0000-0000-000000000002"
        )

    private static func repositoryState(
        activeAccountID: AntigravityAccountID?
    ) -> AntigravityAccountRepositoryState {
        AntigravityAccountRepositoryState(
            revision: 7,
            activeAccountID: activeAccountID,
            accounts: [
                account(
                    id: firstAccountID,
                    suffix:
                        "00000000-0000-0000-0000-000000000011",
                    email: "first@example.com"
                ),
                account(
                    id: secondAccountID,
                    suffix:
                        "00000000-0000-0000-0000-000000000012",
                    email: "second@example.com"
                ),
            ]
        )
    }

    private static func account(
        id: AntigravityAccountID,
        suffix: String,
        email: String
    ) -> AntigravityStoredAccount {
        AntigravityStoredAccount(
            id: id,
            label: email,
            externalIdentity: .init(email: email),
            migrationAliases: [],
            lifecycle: .active,
            credentialReference: .init(
                rawValue:
                    AntigravityCredentialReference
                        .namespacePrefix
                    + suffix
            ),
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1
        )
    }

    private static let completeMigrationStatus =
        AntigravityMigrationStatus(
            phase: .complete,
            sourceOutcomes: [:],
            plannedAccountCount: 0,
            blocker: nil,
            requiredAction: nil,
            authorizationCancelledThisSession: false
        )

    private static let emptyQuotaSnapshot =
        AntigravityQuotaSnapshot(
            identity: nil,
            plan: nil,
            lanes: [],
            decodeIssues: [],
            provenance:
                AntigravityQuotaProvenance(
                    transport: .googleOAuth,
                    endpointOwner: .external,
                    accountIdentity: nil,
                    capability:
                        .groupedQuotaSummary,
                    processIdentity: nil
                ),
            fetchedAt: Date(
                timeIntervalSince1970:
                    1_900_000_000
            )
        )

    private static let oldQuotaSnapshot =
        quotaSnapshot(at: 1_900_000_001)

    private static let newQuotaSnapshot =
        quotaSnapshot(at: 1_900_000_002)

    private static func quotaSnapshot(
        at timestamp: TimeInterval
    ) -> AntigravityQuotaSnapshot {
        AntigravityQuotaSnapshot(
            identity: nil,
            plan: nil,
            lanes: [],
            decodeIssues: [],
            provenance:
                AntigravityQuotaProvenance(
                    transport: .googleOAuth,
                    endpointOwner: .external,
                    accountIdentity: nil,
                    capability:
                        .groupedQuotaSummary,
                    processIdentity: nil
                ),
            fetchedAt: Date(
                timeIntervalSince1970: timestamp
            )
        )
    }
}

private struct ControllerFixture {
    let controller: AntigravityRuntimeController
    let repository:
        ControllerAccountRepositoryDouble
    let settings: ControllerSettingsStoreDouble
    let refresh: ControllerRefreshCoordinatorDouble
    let managed: ControllerManagedSessionDouble
    let events: ControllerEventRecorder
}

private actor ControllerEventRecorder {
    private var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

private actor ControllerAccountRepositoryDouble:
    AntigravityRuntimeAccountPersisting
{
    private var current:
        AntigravityAccountRepositoryState
    private let events: ControllerEventRecorder
    private let selectionFails: Bool
    private var selections = 0

    init(
        state: AntigravityAccountRepositoryState,
        events: ControllerEventRecorder,
        selectionFails: Bool = false
    ) {
        current = state
        self.events = events
        self.selectionFails = selectionFails
    }

    func state() async throws
        -> AntigravityAccountRepositoryState
    {
        await events.record("repository.state")
        return current
    }

    func createAccount(
        credentials: AntigravityOAuthCredentials,
        label: String,
        externalIdentity:
            AntigravityExternalAccountIdentity,
        migrationAliases: [String],
        makeActive: Bool,
        expectedRevision: UInt64
    ) async throws
        -> AntigravityAccountRepositoryState
    {
        try requireRevision(expectedRevision)
        return current
    }

    func replaceCredential(
        for accountID: AntigravityAccountID,
        with credentials: AntigravityOAuthCredentials,
        externalIdentity:
            AntigravityExternalAccountIdentity?,
        expectedRevision: UInt64
    ) async throws
        -> AntigravityAccountRepositoryState
    {
        try requireRevision(expectedRevision)
        return current
    }

    func setActiveAccountID(
        _ accountID: AntigravityAccountID?,
        expectedRevision: UInt64
    ) async throws
        -> AntigravityAccountRepositoryState
    {
        await events.record("repository.select")
        try requireRevision(expectedRevision)
        if selectionFails {
            throw AntigravityAccountRepositoryError
                .metadataPersistenceVerificationFailed
        }
        selections += 1
        current.revision += 1
        current.activeAccountID = accountID
        return current
    }

    func deleteAccount(
        id accountID: AntigravityAccountID,
        expectedRevision: UInt64
    ) async throws
        -> AntigravityAccountRepositoryState
    {
        try requireRevision(expectedRevision)
        return current
    }

    func selectionCount() -> Int {
        selections
    }

    private func requireRevision(
        _ expectedRevision: UInt64
    ) throws {
        guard current.revision == expectedRevision else {
            throw AntigravityAccountRepositoryError
                .revisionConflict(
                    expected: expectedRevision,
                    actual: current.revision
                )
        }
    }
}

private actor ControllerSettingsStoreDouble:
    AntigravitySettingsStoring
{
    private var current: AntigravitySettingsSnapshot
    private let events: ControllerEventRecorder
    private let displaySaveGate:
        ControllerSuspensionGate?
    private let noticeConsumptionGate:
        ControllerSuspensionGate?
    private var connectionSaves = 0
    private var displaySaves = 0

    init(
        snapshot: AntigravitySettingsSnapshot,
        events: ControllerEventRecorder,
        displaySaveGate:
            ControllerSuspensionGate? = nil,
        noticeConsumptionGate:
            ControllerSuspensionGate? = nil
    ) {
        current = snapshot
        self.events = events
        self.displaySaveGate = displaySaveGate
        self.noticeConsumptionGate =
            noticeConsumptionGate
    }

    func load() async throws
        -> AntigravitySettingsSnapshot
    {
        await events.record("settings.load")
        return current
    }

    func saveConnection(
        _ connection: AntigravityConnectionSettings
    ) async throws
        -> AntigravityConnectionSettings
    {
        connectionSaves += 1
        current.connection = connection
        return connection
    }

    func saveDisplay(
        _ display: AntigravityDisplaySettings
    ) async throws -> AntigravityDisplaySettings {
        await displaySaveGate?.suspend()
        displaySaves += 1
        current.display = display
        return display
    }

    func save(
        _ snapshot: AntigravitySettingsSnapshot
    ) async throws -> AntigravitySettingsSnapshot {
        current = snapshot
        return snapshot
    }

    func consumePendingNotice() async throws
        -> AntigravitySettingsMigrationNotice?
    {
        await noticeConsumptionGate?.suspend()
        let notice = current.display.pendingNotice
        current.display.pendingNotice = nil
        return notice
    }

    func connectionSaveCount() -> Int {
        connectionSaves
    }

    func displaySaveCount() -> Int {
        displaySaves
    }
}

private actor
    ControllerMigrationCoordinatorDouble:
    AntigravityRuntimeMigrationCoordinating
{
    private let status: AntigravityMigrationStatus
    private let events: ControllerEventRecorder

    init(
        status: AntigravityMigrationStatus,
        events: ControllerEventRecorder
    ) {
        self.status = status
        self.events = events
    }

    func checkForMigration() async
        -> AntigravityMigrationStatus
    {
        await events.record("migration.check")
        return status
    }

    func performInteractiveMigration() async
        -> AntigravityMigrationStatus
    {
        status
    }

    func removeAllAccounts() async
        -> AntigravityMigrationStatus
    {
        status
    }

    func removeAllAccountsInteractively() async
        -> AntigravityMigrationStatus
    {
        status
    }
}

private actor
    ControllerRefreshCoordinatorDouble:
    AntigravityRefreshCoordinating
{
    private let result: AntigravityPresentationState
    private let events: ControllerEventRecorder
    private let refreshGate: ControllerRefreshGate?
    private var recordedRequests:
        [AntigravityRefreshRequest] = []
    private var invalidations = 0
    private var quiesces = 0
    private var current:
        AntigravityPresentationState

    init(
        result: AntigravityPresentationState,
        events: ControllerEventRecorder,
        refreshGate: ControllerRefreshGate? = nil
    ) {
        self.result = result
        current = result
        self.events = events
        self.refreshGate = refreshGate
    }

    func quiesceForShutdown() async {
        quiesces += 1
        current = .failed(.appShuttingDown)
        await events.record("refresh.quiesce")
    }

    func invalidateBoundary() async {
        invalidations += 1
        current = .refreshing(previous: nil)
        await events.record("refresh.invalidate")
    }

    func refresh(
        _ request: AntigravityRefreshRequest
    ) async -> AntigravityPresentationState {
        recordedRequests.append(request)
        current = .refreshing(previous: nil)
        await events.record("refresh.run")
        let resolved: AntigravityPresentationState
        if let refreshGate {
            resolved = await refreshGate.wait(
                for: request
            )
        } else {
            resolved = result
        }
        current = resolved
        return resolved
    }

    func presentationState() async
        -> AntigravityPresentationState
    {
        current
    }

    func requests() -> [AntigravityRefreshRequest] {
        recordedRequests
    }

    func invalidationCount() -> Int {
        invalidations
    }

    func quiesceCount() -> Int {
        quiesces
    }
}

private actor ControllerRefreshGate {
    private struct PendingRequest {
        var continuation:
            CheckedContinuation<
                AntigravityPresentationState,
                Never
            >?
    }

    private struct CountWaiter {
        let count: Int
        let continuation:
            CheckedContinuation<Void, Never>
    }

    private var pending: [PendingRequest] = []
    private var countWaiters: [CountWaiter] = []

    func wait(
        for _: AntigravityRefreshRequest
    ) async -> AntigravityPresentationState {
        await withCheckedContinuation { continuation in
            pending.append(
                PendingRequest(
                    continuation: continuation
                )
            )
            resumeSatisfiedCountWaiters()
        }
    }

    func waitUntilRequestCount(_ count: Int) async {
        guard pending.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            countWaiters.append(
                CountWaiter(
                    count: count,
                    continuation: continuation
                )
            )
        }
    }

    func resolveRequest(
        at index: Int,
        with state: AntigravityPresentationState
    ) {
        precondition(pending.indices.contains(index))
        guard let continuation =
                pending[index].continuation
        else {
            preconditionFailure(
                "Refresh request already resolved"
            )
        }
        pending[index].continuation = nil
        continuation.resume(returning: state)
    }

    private func resumeSatisfiedCountWaiters() {
        var remaining: [CountWaiter] = []
        for waiter in countWaiters {
            if pending.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        countWaiters = remaining
    }
}

private actor ControllerSuspensionGate {
    private var didEnter = false
    private var entryWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var suspension:
        CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            suspension = continuation
            didEnter = true
            for waiter in entryWaiters {
                waiter.resume()
            }
            entryWaiters.removeAll()
        }
    }

    func waitUntilEntered() async {
        guard !didEnter else {
            return
        }
        await withCheckedContinuation {
            entryWaiters.append($0)
        }
    }

    func resume() {
        suspension?.resume()
        suspension = nil
    }
}

private actor ControllerManagedSessionDouble:
    AntigravityManagedSessionLifecycling
{
    private enum RecoveryError: Error {
        case blocked
    }

    private let recoveryFails: Bool
    private let events: ControllerEventRecorder
    private var shutdowns = 0

    init(
        recoveryFails: Bool,
        events: ControllerEventRecorder
    ) {
        self.recoveryFails = recoveryFails
        self.events = events
    }

    func recoverOrphanedProcesses() async throws {
        await events.record("managed.recover")
        if recoveryFails {
            throw RecoveryError.blocked
        }
    }

    func shutdown() async {
        shutdowns += 1
        await events.record("managed.shutdown")
    }

    func shutdownCount() -> Int {
        shutdowns
    }
}
