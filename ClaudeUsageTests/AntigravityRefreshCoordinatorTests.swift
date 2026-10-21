import XCTest
@testable import ClaudeUsage

final class AntigravityRefreshCoordinatorTests: XCTestCase {
    func testMissingCLIReportSourceNamesTheReportSource() async {
        let coordinator = AntigravityRefreshCoordinator(sources: [])

        let result = await coordinator.refresh(selectedRequest(target: .cli))

        XCTAssertEqual(result, .failed(.sourceUnavailable(.cliReport)))
    }

    func testChangedConnectionSnapshotSupersedesInFlightRefresh() async {
        let snapshot = makeReportSnapshot()
        let sourceScript =
            ConnectionSnapshotRefreshSourceScript(
                response: .init(snapshot: snapshot)
            )
        let coordinator = AntigravityRefreshCoordinator(
            sources: [
                ConnectionSnapshotRefreshSource(
                    script: sourceScript
                ),
            ]
        )
        let firstCompletion = expectation(
            description: "superseded connection snapshot"
        )
        let firstResultBox = RefreshPresentationResultBox()
        let firstRequest = AntigravityRefreshRequest(
            trigger: .manual,
            connection: makeConnectionSettings(target: .cli)
        )
        let secondRequest = AntigravityRefreshRequest(
            trigger: .manual,
            connection: makeConnectionSettings(target: .unselected)
        )

        let first = Task {
            let result = await coordinator.refresh(firstRequest)
            await firstResultBox.store(result)
            firstCompletion.fulfill()
            return result
        }
        await sourceScript.waitUntilFirstStarted()

        let second = await coordinator.refresh(secondRequest)
        await fulfillment(of: [firstCompletion], timeout: 1)
        let firstResult = await firstResultBox.value()
        let callCount = await sourceScript.callCount()
        XCTAssertEqual(firstResult, .failed(.cancelled))
        // 저장된 대상이 미선택이어도 2.10.0부터는 CLI 보고를 읽는다.
        XCTAssertEqual(second, .ready(snapshot))
        XCTAssertEqual(callCount, 2)

        await sourceScript.resumeFirst()
        let completedFirst = await first.value
        XCTAssertEqual(completedFirst, .failed(.cancelled))
    }

    func testRecoverableCLIReportFailuresKeepTheLastReport() async {
        let report = makeReportSnapshot()
        let coordinator = AntigravityRefreshCoordinator(
            sources: [
                ScriptedRefreshSource(
                    id: .cliReport,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(snapshot: report)),
                        .failure(.runtimeUnavailable(.reportDisabled)),
                        .failure(.transportFailure),
                    ]))
            ]
        )
        let scheduled = AntigravityRefreshRequest(
            trigger: .scheduled, connection: makeConnectionSettings(target: .cli))

        let ready = await coordinator.refresh(scheduled)
        let disabled = await coordinator.refresh(scheduled)
        let transport = await coordinator.refresh(scheduled)

        XCTAssertEqual(ready, .ready(report))
        XCTAssertEqual(disabled, .stale(report, failure: .runtimeUnavailable(.reportDisabled)))
        XCTAssertEqual(transport, .stale(report, failure: .transportUnavailable(.cliReport)))
    }

    func testFailedCLIReportDropsTheLastReport() async {
        let report = makeReportSnapshot()
        let coordinator = AntigravityRefreshCoordinator(
            sources: [
                ScriptedRefreshSource(
                    id: .cliReport,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(snapshot: report)),
                        .failure(.reportFailed),
                        .failure(.transportFailure),
                    ]))
            ]
        )
        let scheduled = AntigravityRefreshRequest(
            trigger: .scheduled, connection: makeConnectionSettings(target: .cli))

        let ready = await coordinator.refresh(scheduled)
        let failedReport = await coordinator.refresh(scheduled)
        let afterwards = await coordinator.refresh(scheduled)

        XCTAssertEqual(ready, .ready(report))
        XCTAssertEqual(failedReport, .failed(.cliReportFailed))
        XCTAssertEqual(afterwards, .failed(.transportUnavailable(.cliReport)))
    }

    func testCLIRuntimeFailuresAreNamed() async {
        for reason in [
            AntigravityRuntimeFailure.executableMissing, .executableChanged,
            .verificationRejected, .unsupportedVersion, .reportDisabled,
        ] {
            let coordinator = AntigravityRefreshCoordinator(
                sources: [
                    ScriptedRefreshSource(
                        id: .cliReport,
                        script: RefreshSourceScript(outcomes: [.failure(.runtimeUnavailable(reason))]))
                ]
            )

            let result = await coordinator.refresh(selectedRequest(target: .cli))

            XCTAssertEqual(result, .failed(.runtimeUnavailable(reason)))
        }
    }

    func testCLIReportMustHaveQuotaWithoutIdentity() async {
        let base = makeReportSnapshot()
        let empty = AntigravityQuotaSnapshot(
            identity: nil, plan: nil, lanes: [], decodeIssues: [],
            provenance: base.provenance, fetchedAt: base.fetchedAt)
        let identity = ProviderAccountIdentity(email: "a@example.com")
        let withIdentity = AntigravityQuotaSnapshot(
            identity: identity, plan: nil, lanes: base.lanes, decodeIssues: [],
            provenance: base.provenance, fetchedAt: base.fetchedAt)
        let withProvenanceIdentity = AntigravityQuotaSnapshot(
            identity: nil, plan: nil, lanes: base.lanes, decodeIssues: [],
            provenance: AntigravityQuotaProvenance(transport: .cliUsageReport, accountIdentity: identity),
            fetchedAt: base.fetchedAt)

        for invalid in [empty, withIdentity, withProvenanceIdentity] {
            let coordinator = AntigravityRefreshCoordinator(
                sources: [
                    ScriptedRefreshSource(
                        id: .cliReport,
                        script: RefreshSourceScript(outcomes: [.success(.init(snapshot: invalid))]))
                ]
            )

            let result = await coordinator.refresh(selectedRequest(target: .cli))

            XCTAssertEqual(result, .failed(.sourceContractViolation(.cliReport)))
        }
    }

    func testManualRefreshJoinsScheduledFlight() async throws {
        let snapshot = makeReportSnapshot()
        let source = SlowFirstReportSource(snapshot: snapshot)
        let coordinator = AntigravityRefreshCoordinator(sources: [source])
        let scheduled = AntigravityRefreshRequest(
            trigger: .scheduled, connection: makeConnectionSettings(target: .cli))
        let first = Task { await coordinator.refresh(scheduled) }
        await source.waitUntilStarted()
        let manual = selectedRequest(target: .cli)
        let result = await coordinator.refresh(manual)
        _ = await first.value
        let calls = await source.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result, .ready(snapshot))
    }

    func testConcurrentEquivalentRequestsUseOneSourceFetch() async throws {
        let snapshot = makeReportSnapshot()
        let gate = BlockingRefreshSourceScript()
        let coordinator = AntigravityRefreshCoordinator(
            sources: [
                BlockingRefreshSource(
                    id: .cliReport,
                    script: gate
                ),
            ]
        )
        let request = selectedRequest(target: .cli)

        let first = Task { await coordinator.refresh(request) }
        await gate.waitUntilStarted()
        let second = Task { await coordinator.refresh(request) }
        let joined = await waitForWaiterCount(2, coordinator: coordinator)
        XCTAssertTrue(joined, "Both callers must join the same in-flight request")
        if !joined {
            first.cancel()
            second.cancel()
            await coordinator.quiesceForShutdown()
        }
        await gate.resume(
            with: .init(snapshot: snapshot)
        )

        let values = await [first.value, second.value]
        let callCount = await gate.callCount()
        XCTAssertEqual(values, [.ready(snapshot), .ready(snapshot)])
        XCTAssertEqual(callCount, 1)
    }

    func testCancelledWaiterDetachesWithoutCancellingSharedFlight() async throws {
        let snapshot = makeReportSnapshot()
        let gate = BlockingRefreshSourceScript()
        let coordinator = AntigravityRefreshCoordinator(
            sources: [
                BlockingRefreshSource(
                    id: .cliReport,
                    script: gate
                ),
            ]
        )
        let request = selectedRequest(target: .cli)

        let cancelled = Task {
            await coordinator.refresh(request)
        }
        await gate.waitUntilStarted()
        let survivor = Task {
            await coordinator.refresh(request)
        }
        let joined = await waitForWaiterCount(2, coordinator: coordinator)
        XCTAssertTrue(joined, "The survivor must join before cancelling the first caller")
        if !joined {
            survivor.cancel()
            await coordinator.quiesceForShutdown()
        }
        cancelled.cancel()

        let cancelledResult = await cancelled.value
        let callCount = await gate.callCount()
        XCTAssertEqual(
            cancelledResult,
            .failed(.cancelled)
        )
        XCTAssertEqual(callCount, 1)

        await gate.resume(
            with: .init(snapshot: snapshot)
        )
        let survivorResult = await survivor.value
        let presentation =
            await coordinator.presentationState()
        XCTAssertEqual(survivorResult, .ready(snapshot))
        XCTAssertEqual(presentation, .ready(snapshot))
    }

    func testCancellingOnlyWaiterCancelsSourceAndRejectsLateUsage() async throws {
        let snapshot = makeReportSnapshot()
        let gate = BlockingRefreshSourceScript()
        let coordinator = AntigravityRefreshCoordinator(
            sources: [
                BlockingRefreshSource(
                    id: .cliReport,
                    script: gate
                ),
            ]
        )
        let request = selectedRequest(target: .cli)

        let caller = Task {
            await coordinator.refresh(request)
        }
        await gate.waitUntilStarted()
        caller.cancel()

        let callerResult = await caller.value
        XCTAssertEqual(
            callerResult,
            .failed(.cancelled)
        )
        await gate.waitUntilCancellationObserved()
        let cancelledPresentation =
            await coordinator.presentationState()
        XCTAssertEqual(
            cancelledPresentation,
            .failed(.cancelled)
        )

        await gate.resume(
            with: .init(snapshot: snapshot)
        )
        await gate.waitUntilFinished()
        await Task.yield()

        let finalPresentation =
            await coordinator.presentationState()
        XCTAssertEqual(
            finalPresentation,
            .failed(.cancelled)
        )
    }

    func testQuiesceCancelsNoncooperativeFlightAndRejectsFutureRefresh() async {
        let snapshot = makeReportSnapshot()
        let sourceGate = BlockingRefreshSourceScript()
        let coordinator = AntigravityRefreshCoordinator(
            sources: [
                BlockingRefreshSource(
                    id: .cliReport,
                    script: sourceGate
                ),
            ]
        )
        let request = selectedRequest(target: .cli)
        let callerCompletion = expectation(
            description: "quiesced caller"
        )
        let callerResultBox = RefreshPresentationResultBox()
        let caller = Task {
            let result = await coordinator.refresh(request)
            await callerResultBox.store(result)
            callerCompletion.fulfill()
            return result
        }
        await sourceGate.waitUntilStarted()

        await coordinator.quiesceForShutdown()
        await fulfillment(of: [callerCompletion], timeout: 1)
        let callerResult = await callerResultBox.value()
        let rejected = await coordinator.refresh(request)
        let sourceCallCount = await sourceGate.callCount()
        let presentation = await coordinator.presentationState()
        XCTAssertEqual(callerResult, .failed(.cancelled))
        XCTAssertEqual(rejected, .failed(.appShuttingDown))
        XCTAssertEqual(
            presentation,
            .failed(.appShuttingDown)
        )
        XCTAssertEqual(sourceCallCount, 1)

        await sourceGate.resume(
            with: .init(snapshot: snapshot)
        )
        await sourceGate.waitUntilFinished()
        let completedCaller = await caller.value
        XCTAssertEqual(completedCaller, .failed(.cancelled))
    }

    private func waitForWaiterCount(_ expected: Int, coordinator: AntigravityRefreshCoordinator) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await coordinator.inFlightWaiterCountForTesting() == expected { return true }
            await Task.yield()
        }
        return false
    }

}

private actor RefreshPresentationResultBox {
    private var result: AntigravityPresentationState?

    func store(_ result: AntigravityPresentationState) {
        self.result = result
    }

    func value() -> AntigravityPresentationState? {
        result
    }
}

private actor RefreshSourceScript {
    private var outcomes:
        [Result<
            AntigravityUsageSourceResponse,
            AntigravityUsageSourceError
        >]
    private var calls = 0

    init(
        outcomes: [Result<
            AntigravityUsageSourceResponse,
            AntigravityUsageSourceError
        >]
    ) {
        self.outcomes = outcomes
    }

    func next(
        _ request: AntigravityUsageSourceRequest
    ) throws -> AntigravityUsageSourceResponse {
        calls += 1
        guard !outcomes.isEmpty else {
            throw AntigravityUsageSourceError.transportFailure
        }
        return try outcomes.removeFirst().get()
    }

    func callCount() -> Int {
        calls
    }

}

private struct ScriptedRefreshSource:
    AntigravityUsageSource
{
    let id: AntigravityUsageSourceID
    let script: RefreshSourceScript

    func fetch(
        _ request: AntigravityUsageSourceRequest
    ) async throws -> AntigravityUsageSourceResponse {
        try await script.next(request)
    }
}

private actor ConnectionSnapshotRefreshSourceScript {
    private let response: AntigravityUsageSourceResponse
    private var calls = 0
    private var firstStarted = false
    private var firstStartedWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var firstContinuation:
        CheckedContinuation<
            AntigravityUsageSourceResponse,
            Never
        >?

    init(response: AntigravityUsageSourceResponse) {
        self.response = response
    }

    func fetch(
        _ request: AntigravityUsageSourceRequest
    ) async -> AntigravityUsageSourceResponse {
        calls += 1
        if calls > 1 {
            return response
        }

        firstStarted = true
        let waiters = firstStartedWaiters
        firstStartedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return await withCheckedContinuation {
            firstContinuation = $0
        }
    }

    func waitUntilFirstStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation {
            firstStartedWaiters.append($0)
        }
    }

    func resumeFirst() {
        firstContinuation?.resume(returning: response)
        firstContinuation = nil
    }

    func callCount() -> Int {
        calls
    }
}

private struct ConnectionSnapshotRefreshSource:
    AntigravityUsageSource
{
    let id = AntigravityUsageSourceID.cliReport
    let script: ConnectionSnapshotRefreshSourceScript

    func fetch(
        _ request: AntigravityUsageSourceRequest
    ) async throws -> AntigravityUsageSourceResponse {
        await script.fetch(request)
    }
}

private actor BlockingRefreshSourceScript {
    private var calls = 0
    private var started = false
    private var startedWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var responseContinuation:
        CheckedContinuation<
            AntigravityUsageSourceResponse,
            Never
        >?
    private var cancellationObserved = false
    private var cancellationWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var finished = false
    private var finishedWaiters:
        [CheckedContinuation<Void, Never>] = []

    func fetch(
        _ request: AntigravityUsageSourceRequest
    ) async throws -> AntigravityUsageSourceResponse {
        calls += 1
        defer {
            finished = true
            let waiters = finishedWaiters
            finishedWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                responseContinuation = $0
                started = true
                let waiters = startedWaiters
                startedWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        } onCancel: {
            Task {
                await self.markCancellationObserved()
            }
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation {
            startedWaiters.append($0)
        }
    }

    func waitUntilCancellationObserved() async {
        guard !cancellationObserved else { return }
        await withCheckedContinuation {
            cancellationWaiters.append($0)
        }
    }

    private func markCancellationObserved() {
        cancellationObserved = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func resume(
        with response: AntigravityUsageSourceResponse
    ) {
        responseContinuation?.resume(returning: response)
        responseContinuation = nil
    }

    func waitUntilFinished() async {
        guard !finished else { return }
        await withCheckedContinuation {
            finishedWaiters.append($0)
        }
    }

    func callCount() -> Int {
        calls
    }
}

private struct BlockingRefreshSource:
    AntigravityUsageSource
{
    let id: AntigravityUsageSourceID
    let script: BlockingRefreshSourceScript

    func fetch(
        _ request: AntigravityUsageSourceRequest
    ) async throws -> AntigravityUsageSourceResponse {
        try await script.fetch(request)
    }
}

private func selectedRequest(
    target: AntigravityUsageTarget = .cli
) -> AntigravityRefreshRequest {
    return AntigravityRefreshRequest(
        trigger: .manual,
        connection: makeConnectionSettings(target: target)
    )
}

private func makeConnectionSettings(
    target: AntigravityUsageTarget = .cli
) -> AntigravityConnectionSettings {
    AntigravityConnectionSettings(
        schemaVersion: AntigravityConnectionSettings.currentSchemaVersion,
        usageTarget: target
    )
}

/// Mirrors a decoded `agy -p /usage` report: no account identity or plan.
private func makeReportSnapshot(fraction: Double = 0.75) -> AntigravityQuotaSnapshot {
    AntigravityQuotaSnapshot(
        identity: nil,
        plan: nil,
        lanes: [
            AntigravityQuotaLane(
                id: .geminiFiveHour,
                upstreamGroupID: "gemini",
                upstreamBucketID: "five-hour",
                scope: .gemini,
                cadence: .fiveHour,
                remainingFraction: fraction,
                resetAt: Date(timeIntervalSince1970: 2_000_000_000),
                resetDescription: nil,
                availability: .available
            ),
        ],
        decodeIssues: [],
        provenance: AntigravityQuotaProvenance(transport: .cliUsageReport, accountIdentity: nil),
        fetchedAt: Date(timeIntervalSince1970: 1_900_000_000)
    )
}

private actor SlowFirstReportSource: AntigravityUsageSource {
    nonisolated let id = AntigravityUsageSourceID.cliReport
    let snapshot: AntigravityQuotaSnapshot
    var calls = 0
    init(snapshot: AntigravityQuotaSnapshot) { self.snapshot = snapshot }
    func waitUntilStarted() async { while calls == 0 { await Task.yield() } }
    func fetch(_ request: AntigravityUsageSourceRequest) async throws -> AntigravityUsageSourceResponse {
        calls += 1
        if calls == 1 { try await Task.sleep(for: .seconds(2)) }
        return .init(snapshot: snapshot)
    }
}
