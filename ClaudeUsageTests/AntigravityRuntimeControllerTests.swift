import Foundation
import XCTest
@testable import ClaudeUsage

final class AntigravityRuntimeControllerTests:
    XCTestCase
{
    func testDisplayBasisReprojectsWithoutQuotaRefreshSettingsWriteOrProcessRecovery() async {
        let fixture = makeFixture()
        let initial = await fixture.controller.bootstrap(performInitialRefresh: true)
        // 레거시 정리는 bootstrap 뒤에 비동기로 끝난다. 그 기록이 비교 사이에 끼지 않게 먼저 기다린다.
        await fixture.lifecycle.waitUntilCleanupFinished()
        await fixture.accountCleanup.waitUntilFinished()
        let events = await fixture.events.snapshot()
        let requests = await fixture.refresh.requests()
        let writes = await fixture.settings.displaySaveCount()
        let changed = await fixture.controller.setUsageDisplayBasis(.remaining, revision: 2)
        XCTAssertEqual(changed.publicationRevision, initial.publicationRevision + 1)
        XCTAssertEqual(changed.presentationState, initial.presentationState)
        XCTAssertEqual(changed.settings, initial.settings)
        let repeated = await fixture.controller.setUsageDisplayBasis(.remaining, revision: 2)
        XCTAssertEqual(repeated.publicationRevision, changed.publicationRevision)
        let stale = await fixture.controller.setUsageDisplayBasis(.used, revision: 1)
        XCTAssertEqual(stale.publicationRevision, changed.publicationRevision)
        let finalEvents = await fixture.events.snapshot()
        let finalRequests = await fixture.refresh.requests()
        let finalWrites = await fixture.settings.displaySaveCount()
        XCTAssertEqual(finalEvents, events)
        XCTAssertEqual(finalRequests.count, requests.count)
        XCTAssertEqual(finalWrites, writes)
        await fixture.controller.shutdown()
        let stopped = await fixture.controller.snapshot()
        let ignored = await fixture.controller.setUsageDisplayBasis(.used, revision: 3)
        XCTAssertEqual(ignored.publicationRevision, stopped.publicationRevision)
    }

    func testTimeFormatReprojectsWithoutQueryOrSettingsWrite() async {
        let fixture = makeFixture()
        _ = await fixture.controller.bootstrap(performInitialRefresh: true)
        await fixture.lifecycle.waitUntilCleanupFinished()
        await fixture.accountCleanup.waitUntilFinished()
        let clock = await fixture.controller.setTimeFormat(.h24)
        let requests = await fixture.refresh.requests()
        let writes = await fixture.settings.displaySaveCount()

        let remaining = await fixture.controller.setTimeFormat(.remaining)
        let repeated = await fixture.controller.setTimeFormat(.remaining)

        XCTAssertEqual(remaining.publicationRevision, clock.publicationRevision + 1)
        XCTAssertEqual(repeated.publicationRevision, remaining.publicationRevision)
        XCTAssertEqual(remaining.presentationState, clock.presentationState)
        XCTAssertEqual(remaining.settings, clock.settings)
        let finalRequests = await fixture.refresh.requests()
        let finalWrites = await fixture.settings.displaySaveCount()
        XCTAssertEqual(finalRequests.count, requests.count)
        XCTAssertEqual(finalWrites, writes)
        await fixture.controller.shutdown()
    }

    func testAccountMismatchClearsThePreviousSuccessfulTimestamp() async {
        let fixture = makeFixture()
        let first = await fixture.controller.bootstrap(performInitialRefresh: true)
        XCTAssertNotNil(first.lastSuccessfulAt)
        await fixture.refresh.setResult(
            .accountMismatch(
                expected: .init(email: "a@example.com"), received: .init(email: "b@example.com")))
        let mismatched = await fixture.controller.refresh(trigger: .scheduled)
        XCTAssertNil(mismatched.lastSuccessfulAt)
    }

    func testPersistedAppSelectionRefreshesTheCLIWithoutRewritingIt() async {
        var connection = AntigravityConnectionSettings.default
        connection.usageTarget = .app
        let fixture = makeFixture(connection: connection)
        let result = await fixture.controller.bootstrap(performInitialRefresh: true)
        let requests = await fixture.refresh.requests()
        let writes = await fixture.settings.connectionSaveCount()
        XCTAssertEqual(result.settings?.connection.usageTarget, .app)
        XCTAssertEqual(requests.last?.target, .cli)
        XCTAssertEqual(writes, 0)
    }

    func testLegacyCleanupNeverBlocksTheInitialRefresh()
        async throws
    {
        let cleanupGate = ControllerSuspensionGate()
        let fixture = makeFixture(legacyCleanupGate: cleanupGate)

        let snapshot = await fixture.controller.bootstrap(
            performInitialRefresh: true
        )
        await cleanupGate.waitUntilEntered()
        let requests = await fixture.refresh.requests()

        XCTAssertEqual(snapshot.readiness, .ready)
        XCTAssertEqual(
            snapshot.managedRuntimeAvailability,
            .available(
                displayPath:
                    "~/.local/bin/agy"
            )
        )
        XCTAssertEqual(requests.count, 1)

        await cleanupGate.resume()
        await fixture.lifecycle.waitUntilCleanupFinished()
        let cleanupCount = await fixture.lifecycle.cleanupCount()
        XCTAssertEqual(cleanupCount, 1)
    }

    func testLegacyAccountCleanupRunsOnceWithoutBlockingTheInitialRefresh()
        async
    {
        let cleanupGate = ControllerSuspensionGate()
        let fixture = makeFixture(accountCleanupGate: cleanupGate)

        let snapshot = await fixture.controller.bootstrap(
            performInitialRefresh: true
        )
        await cleanupGate.waitUntilEntered()
        let requests = await fixture.refresh.requests()
        XCTAssertEqual(snapshot.readiness, .ready)
        XCTAssertEqual(snapshot.presentationState, .ready(Self.emptyQuotaSnapshot))
        XCTAssertEqual(requests.count, 1)

        _ = await fixture.controller.bootstrap(performInitialRefresh: true)
        _ = await fixture.controller.refresh(trigger: .manual)
        await cleanupGate.resume()
        await fixture.accountCleanup.waitUntilFinished()
        let runCount = await fixture.accountCleanup.runCount()
        XCTAssertEqual(runCount, 1)
    }

    func testNewerRefreshRejectsTheLateResultOfAnOlderRefresh()
        async
    {
        let refreshGate = ControllerRefreshGate()
        let fixture = makeFixture(
            refreshGate: refreshGate
        )
        _ = await fixture.controller.bootstrap(
            performInitialRefresh: false
        )

        let older = Task {
            await fixture.controller.refresh(
                trigger: .scheduled
            )
        }
        await refreshGate.waitUntilRequestCount(1)
        let newer = Task {
            await fixture.controller.refresh(
                trigger: .manual
            )
        }
        await refreshGate.waitUntilRequestCount(2)

        await refreshGate.resolveRequest(
            at: 0,
            with: .ready(Self.oldQuotaSnapshot)
        )
        let olderResult = await older.value
        XCTAssertEqual(
            olderResult.presentationState,
            .refreshing(previous: Self.emptyQuotaSnapshot)
        )

        await refreshGate.resolveRequest(
            at: 1,
            with: .ready(Self.newQuotaSnapshot)
        )
        let newerResult = await newer.value
        XCTAssertEqual(
            newerResult.presentationState,
            .ready(Self.newQuotaSnapshot)
        )
        let final = await fixture.controller.snapshot()
        XCTAssertEqual(
            final.presentationState,
            .ready(Self.newQuotaSnapshot)
        )
    }

    func testUnreadableSettingsBlockWithoutRefreshing()
        async
    {
        let fixture = makeFixture()
        await fixture.settings.failLoads()

        let snapshot = await fixture.controller.bootstrap(
            performInitialRefresh: true
        )
        let requests = await fixture.refresh.requests()

        XCTAssertEqual(snapshot.readiness, .blocked(.typedSettings))
        XCTAssertEqual(
            snapshot.presentationState,
            .failed(.invalidRefreshContext)
        )
        XCTAssertTrue(requests.isEmpty)
    }

    func testDisplayOnlyUpdateDoesNotRefresh()
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

        let requests = await fixture.refresh.requests()
        let displaySaveCount =
            await fixture.settings.displaySaveCount()
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

    func testShutdownQuiescesRefreshBeforeStoppingRuntimeAndRejectsMutations()
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
            await fixture.lifecycle.shutdownCount()
        let shutdownSnapshot =
            await fixture.controller.snapshot()
        let events = await fixture.events.snapshot()
        XCTAssertLessThan(
            try XCTUnwrap(events.firstIndex(of: "refresh.quiesce")),
            try XCTUnwrap(events.firstIndex(of: "runtime.shutdown"))
        )
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
                .updateMenuBarStyle(.circular)
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
        let displaySaveCount =
            await fixture.settings.displaySaveCount()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(
            displaySaveCount,
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
        let runtimeShutdownCount =
            await fixture.lifecycle.shutdownCount()
        XCTAssertEqual(quiesceCount, 1)
        XCTAssertEqual(runtimeShutdownCount, 1)
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
            requests.first?.target,
            .cli
        )
        XCTAssertEqual(
            snapshot.presentationState,
            .setupRequired(
                .noAmbientLocalSession
            )
        )
    }

    private func makeFixture(
        connection:
            AntigravityConnectionSettings = .default,
        legacyCleanupGate: ControllerSuspensionGate? = nil,
        accountCleanupGate: ControllerSuspensionGate? = nil,
        refreshResult:
            AntigravityPresentationState? = nil,
        refreshGate:
            ControllerRefreshGate? = nil
    ) -> ControllerFixture {
        let events = ControllerEventRecorder()
        let settings =
            ControllerSettingsStoreDouble(
                snapshot:
                    AntigravitySettingsSnapshot(
                        connection: connection,
                        display: .default
                    ),
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
        let lifecycle =
            ControllerRuntimeLifecycleDouble(
                cleanupGate: legacyCleanupGate,
                events: events
            )
        let accountCleanup =
            ControllerAccountCleanupDouble(
                gate: accountCleanupGate,
                events: events
            )
        let controller = AntigravityRuntimeController(
            settingsStore: settings,
            refreshCoordinator: refresh,
            runtimeLifecycle: lifecycle,
            settingsBootstrap:
                .ready(.alreadyCurrent),
            agyExecutableStatus:
                .verified(
                    displayPath:
                        "~/.local/bin/agy"
                ),
            legacyAccountCleanup: {
                await accountCleanup.run()
            },
            now: {
                Date(
                    timeIntervalSince1970:
                        1_900_000_000
                )
            }
        )
        return ControllerFixture(
            controller: controller,
            settings: settings,
            refresh: refresh,
            lifecycle: lifecycle,
            accountCleanup: accountCleanup,
            events: events
        )
    }

    private static let emptyQuotaSnapshot =
        AntigravityQuotaSnapshot(
            identity: nil,
            plan: nil,
            lanes: [],
            decodeIssues: [],
            provenance:
                AntigravityQuotaProvenance(
                    transport: .cliUsageReport,
                    endpointOwner: .managed,
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
                    transport: .cliUsageReport,
                    endpointOwner: .managed,
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
    let settings: ControllerSettingsStoreDouble
    let refresh: ControllerRefreshCoordinatorDouble
    let lifecycle: ControllerRuntimeLifecycleDouble
    let accountCleanup: ControllerAccountCleanupDouble
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

private actor ControllerSettingsStoreDouble:
    AntigravitySettingsStoring
{
    private var current: AntigravitySettingsSnapshot
    private let events: ControllerEventRecorder
    private var connectionSaves = 0
    private var displaySaves = 0
    private var loadsFail = false

    func failLoads() { loadsFail = true }

    init(
        snapshot: AntigravitySettingsSnapshot,
        events: ControllerEventRecorder
    ) {
        current = snapshot
        self.events = events
    }

    func load() async throws
        -> AntigravitySettingsSnapshot
    {
        await events.record("settings.load")
        if loadsFail {
            throw AntigravitySettingsStoreError.invalid(.connection)
        }
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
    ControllerRefreshCoordinatorDouble:
    AntigravityRefreshCoordinating
{
    private var result: AntigravityPresentationState
    func setResult(_ value: AntigravityPresentationState) { result = value }
    private let events: ControllerEventRecorder
    private let refreshGate: ControllerRefreshGate?
    private var recordedRequests:
        [AntigravityRefreshRequest] = []
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

private actor ControllerRuntimeLifecycleDouble:
    AntigravityRuntimeLifecycling
{
    private let cleanupGate: ControllerSuspensionGate?
    private let events: ControllerEventRecorder
    private var cleanups = 0
    private var finishedCleanups = 0
    private var cleanupWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdowns = 0

    init(
        cleanupGate: ControllerSuspensionGate?,
        events: ControllerEventRecorder
    ) {
        self.cleanupGate = cleanupGate
        self.events = events
    }

    func cleanUpLegacyManagedProcesses() async {
        cleanups += 1
        await events.record("runtime.legacyCleanup")
        await cleanupGate?.suspend()
        finishedCleanups += 1
        cleanupWaiters.forEach { $0.resume() }
        cleanupWaiters.removeAll()
    }

    func shutdown() async {
        shutdowns += 1
        await events.record("runtime.shutdown")
    }

    func cleanupCount() -> Int {
        cleanups
    }

    func waitUntilCleanupFinished() async {
        guard finishedCleanups == 0 else { return }
        await withCheckedContinuation { cleanupWaiters.append($0) }
    }

    func shutdownCount() -> Int {
        shutdowns
    }
}

private actor ControllerAccountCleanupDouble {
    private let gate: ControllerSuspensionGate?
    private let events: ControllerEventRecorder
    private var runs = 0
    private var finishedRuns = 0
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        gate: ControllerSuspensionGate?,
        events: ControllerEventRecorder
    ) {
        self.gate = gate
        self.events = events
    }

    func run() async {
        runs += 1
        await events.record("runtime.legacyAccountCleanup")
        await gate?.suspend()
        finishedRuns += 1
        finishWaiters.forEach { $0.resume() }
        finishWaiters.removeAll()
    }

    func runCount() -> Int {
        runs
    }

    func waitUntilFinished() async {
        guard finishedRuns == 0 else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }
}
