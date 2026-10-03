import XCTest
@testable import ClaudeUsage

final class AntigravityRefreshCoordinatorTests: XCTestCase {
    func testUnavailableCLIReportNamesTheReportSource() async {
        let appScript = RefreshSourceScript(outcomes: [.failure(.unavailable)])
        let coordinator = AntigravityRefreshCoordinator(
            repository: RefreshRepositoryDouble(accounts: [], activeAccountID: nil, credentials: [:]),
            sources: [
                ScriptedRefreshSource(id: .localApp, script: appScript),
                ScriptedRefreshSource(
                    id: .cliReport,
                    script: RefreshSourceScript(outcomes: [.failure(.unavailable)])),
            ]
        )

        let result = await coordinator.refresh(selectedRequest(target: .cli, revision: 0))

        XCTAssertEqual(result, .failed(.sourceUnavailable(.cliReport)))
        let appCalls = await appScript.callCount()
        XCTAssertEqual(appCalls, 0)
    }

    func testChangedConnectionSnapshotSupersedesInFlightRefresh() async {
        let snapshot = makeReportSnapshot()
        let sourceScript =
            ConnectionSnapshotRefreshSourceScript(
                response: .init(payload: .grouped(snapshot))
            )
        let coordinator = AntigravityRefreshCoordinator(
            repository: RefreshRepositoryDouble(
                accounts: [],
                activeAccountID: nil,
                credentials: [:]
            ),
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
            repositoryRevision: 0,
            connection: makeConnectionSettings(target: .cli)
        )
        let secondRequest = AntigravityRefreshRequest(
            trigger: .manual,
            repositoryRevision: 0,
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

    func testCLISelectionReadsOnlyTheUsageReport() async throws {
        let localScript = RefreshSourceScript(outcomes: [
            .success(
                .init(
                    payload: .grouped(
                        makeSnapshot(
                            identity: .init(
                                stableAccountID: "subject-b",
                                email: "b@example.com"
                            ),
                            source: .localApp
                        )
                    )))
        ])
        let report = makeReportSnapshot()
        let reportScript = RefreshSourceScript(outcomes: [
            .success(.init(payload: .grouped(report)))
        ])
        let coordinator = AntigravityRefreshCoordinator(
            repository: RefreshRepositoryDouble(accounts: [], activeAccountID: nil, credentials: [:]),
            sources: [
                ScriptedRefreshSource(id: .localApp, script: localScript),
                ScriptedRefreshSource(id: .cliReport, script: reportScript),
            ]
        )

        let result = await coordinator.refresh(selectedRequest(target: .cli, revision: 0))

        XCTAssertEqual(result, .ready(report))
        let localCallCount = await localScript.callCount()
        let reportCallCount = await reportScript.callCount()
        XCTAssertEqual(localCallCount, 0)
        XCTAssertEqual(reportCallCount, 1)
    }

    func testCLIReportFailuresKeepTheLastReportUntilABoundaryChange() async {
        let report = makeReportSnapshot()
        let coordinator = AntigravityRefreshCoordinator(
            repository: RefreshRepositoryDouble(accounts: [], activeAccountID: nil, credentials: [:]),
            sources: [
                ScriptedRefreshSource(
                    id: .cliReport,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(payload: .grouped(report))),
                        .failure(.runtimeUnavailable(.reportDisabled)),
                        .failure(.transportFailure),
                    ]))
            ]
        )
        let scheduled = AntigravityRefreshRequest(
            trigger: .scheduled, repositoryRevision: 0, connection: makeConnectionSettings(target: .cli))
        let boundary = AntigravityRefreshRequest(
            trigger: .accountBoundaryChanged, repositoryRevision: 0,
            connection: makeConnectionSettings(target: .cli))

        let ready = await coordinator.refresh(scheduled)
        let disabled = await coordinator.refresh(scheduled)
        let cleared = await coordinator.refresh(boundary)

        XCTAssertEqual(ready, .ready(report))
        XCTAssertEqual(disabled, .stale(report, failure: .runtimeUnavailable(.reportDisabled)))
        XCTAssertEqual(cleared, .failed(.transportUnavailable(.cliReport)))
    }

    func testFailedCLIReportDropsTheLastReport() async {
        let report = makeReportSnapshot()
        let coordinator = AntigravityRefreshCoordinator(
            repository: RefreshRepositoryDouble(accounts: [], activeAccountID: nil, credentials: [:]),
            sources: [
                ScriptedRefreshSource(
                    id: .cliReport,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(payload: .grouped(report))),
                        .failure(.reportFailed),
                        .failure(.transportFailure),
                    ]))
            ]
        )
        let scheduled = AntigravityRefreshRequest(
            trigger: .scheduled, repositoryRevision: 0, connection: makeConnectionSettings(target: .cli))

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
                repository: RefreshRepositoryDouble(accounts: [], activeAccountID: nil, credentials: [:]),
                sources: [
                    ScriptedRefreshSource(
                        id: .cliReport,
                        script: RefreshSourceScript(outcomes: [.failure(.runtimeUnavailable(reason))]))
                ]
            )

            let result = await coordinator.refresh(selectedRequest(target: .cli, revision: 0))

            XCTAssertEqual(result, .failed(.runtimeUnavailable(reason)))
        }
    }

    func testCLIReportMustComeFromAReportWithoutAProcessEndpointOrIdentity() async {
        let base = makeReportSnapshot()
        let endpointBacked = AntigravityQuotaSnapshot(
            identity: nil, plan: nil, lanes: base.lanes, decodeIssues: [],
            provenance: AntigravityQuotaProvenance(
                transport: .cliUsageReport, endpointOwner: .managed, accountIdentity: nil,
                capability: .groupedQuotaSummary, processIdentity: ProcessIdentity(processID: 42)),
            fetchedAt: base.fetchedAt)
        let appTransport = makeSnapshot(identity: nil, source: .localApp)
        let empty = AntigravityQuotaSnapshot(
            identity: nil, plan: nil, lanes: [], decodeIssues: [],
            provenance: base.provenance, fetchedAt: base.fetchedAt)
        let identity = ProviderAccountIdentity(email: "a@example.com")
        let withIdentity = AntigravityQuotaSnapshot(
            identity: identity, plan: nil, lanes: base.lanes, decodeIssues: [],
            provenance: base.provenance, fetchedAt: base.fetchedAt)
        let withProvenanceIdentity = AntigravityQuotaSnapshot(
            identity: nil, plan: nil, lanes: base.lanes, decodeIssues: [],
            provenance: AntigravityQuotaProvenance(
                transport: .cliUsageReport, endpointOwner: .managed, accountIdentity: identity,
                capability: .groupedQuotaSummary, processIdentity: nil),
            fetchedAt: base.fetchedAt)

        for invalid in [endpointBacked, appTransport, empty, withIdentity, withProvenanceIdentity] {
            let coordinator = AntigravityRefreshCoordinator(
                repository: RefreshRepositoryDouble(accounts: [], activeAccountID: nil, credentials: [:]),
                sources: [
                    ScriptedRefreshSource(
                        id: .cliReport,
                        script: RefreshSourceScript(outcomes: [.success(.init(payload: .grouped(invalid)))]))
                ]
            )

            let result = await coordinator.refresh(selectedRequest(target: .cli, revision: 0))

            XCTAssertEqual(result, .failed(.sourceContractViolation(.cliReport)))
        }
    }

    func testCLIReportCannotBeAnIdentityOnlyOrLimitedPayload() async {
        let identity = ProviderAccountIdentity(email: "a@example.com")
        let payloads: [AntigravityUsageSourcePayload] = [
            .identityOnly(makeIdentityOnlyUsage(identity: identity, source: .cliReport)),
            .limited(makeLocalLimitedCapability(identity: identity)),
        ]
        for payload in payloads {
            let coordinator = AntigravityRefreshCoordinator(
                repository: RefreshRepositoryDouble(accounts: [], activeAccountID: nil, credentials: [:]),
                sources: [
                    ScriptedRefreshSource(
                        id: .cliReport,
                        script: RefreshSourceScript(outcomes: [.success(.init(payload: payload))]))
                ]
            )

            let result = await coordinator.refresh(selectedRequest(target: .cli, revision: 0))

            XCTAssertEqual(result, .failed(.sourceContractViolation(.cliReport)))
        }
    }

    func testManualRefreshDoesNotJoinScheduledFlight() async throws {
        let account = makeAccount(id: "account-a", subject: "subject-a", email: "a@example.com")
        let repository = RefreshRepositoryDouble(accounts: [account], activeAccountID: account.id,
            credentials: [account.id: makeCredentials("a")])
        let snapshot = makeSnapshot(identity: nil, source: .cliReport)
        let source = DiscoveryPolicySource(snapshot: snapshot)
        let coordinator = AntigravityRefreshCoordinator(repository: repository, sources: [source])
        let scheduled = AntigravityRefreshRequest(
            trigger: .scheduled, repositoryRevision: 0, connection: makeConnectionSettings(target: .cli))
        let first = Task { await coordinator.refresh(scheduled) }
        await source.waitUntilStarted()
        let manual = selectedRequest(target: .cli, revision: 0)
        let result = await coordinator.refresh(manual)
        _ = await first.value
        let calls = await source.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result, .ready(snapshot))
    }

    func testConcurrentEquivalentRequestsUseOneSourceFetch() async throws {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let repository = RefreshRepositoryDouble(
            accounts: [account],
            activeAccountID: account.id,
            credentials: [account.id: makeCredentials("a")]
        )
        let snapshot = makeSnapshot(
            identity: nil,
            source: .cliReport
        )
        let gate = BlockingRefreshSourceScript()
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                BlockingRefreshSource(
                    id: .cliReport,
                    script: gate
                ),
            ]
        )
        let request = selectedRequest(target: .cli, revision: 0)

        async let first = coordinator.refresh(request)
        await gate.waitUntilStarted()
        async let second = coordinator.refresh(request)
        await gate.resume(
            with: .init(payload: .grouped(snapshot))
        )

        let values = await [first, second]
        let callCount = await gate.callCount()
        XCTAssertEqual(values, [.ready(snapshot), .ready(snapshot)])
        XCTAssertEqual(callCount, 1)
    }

    func testCancelledWaiterDetachesWithoutCancellingSharedFlight() async throws {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let repository = RefreshRepositoryDouble(
            accounts: [account],
            activeAccountID: account.id,
            credentials: [account.id: makeCredentials("a")]
        )
        let snapshot = makeSnapshot(
            identity: nil,
            source: .cliReport
        )
        let gate = BlockingRefreshSourceScript()
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                BlockingRefreshSource(
                    id: .cliReport,
                    script: gate
                ),
            ]
        )
        let request = selectedRequest(target: .cli, revision: 0)

        let cancelled = Task {
            await coordinator.refresh(request)
        }
        await gate.waitUntilStarted()
        let survivor = Task {
            await coordinator.refresh(request)
        }
        await Task.yield()
        cancelled.cancel()

        let cancelledResult = await cancelled.value
        let callCount = await gate.callCount()
        XCTAssertEqual(
            cancelledResult,
            .failed(.cancelled)
        )
        XCTAssertEqual(callCount, 1)

        await gate.resume(
            with: .init(payload: .grouped(snapshot))
        )
        let survivorResult = await survivor.value
        let presentation =
            await coordinator.presentationState()
        XCTAssertEqual(survivorResult, .ready(snapshot))
        XCTAssertEqual(presentation, .ready(snapshot))
    }

    func testCancellingOnlyWaiterCancelsSourceAndRejectsLateUsage() async throws {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let original = makeCredentials("old")
        let repository = RefreshRepositoryDouble(
            accounts: [account],
            activeAccountID: account.id,
            credentials: [account.id: original]
        )
        let snapshot = makeSnapshot(
            identity: nil,
            source: .cliReport
        )
        let gate = BlockingRefreshSourceScript()
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                BlockingRefreshSource(
                    id: .cliReport,
                    script: gate
                ),
            ]
        )
        let request = selectedRequest(target: .cli, revision: 0)

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
        let initialReplaceCount =
            await repository.replaceCountValue()
        let cancelledPresentation =
            await coordinator.presentationState()
        XCTAssertEqual(initialReplaceCount, 0)
        XCTAssertEqual(
            cancelledPresentation,
            .failed(.cancelled)
        )

        await gate.resume(
            with: .init(
                payload: .grouped(snapshot)
            )
        )
        await gate.waitUntilFinished()
        await Task.yield()

        let finalReplaceCount =
            await repository.replaceCountValue()
        let storedCredentials =
            await repository.credentialsValue(
                for: account.id
            )
        let finalPresentation =
            await coordinator.presentationState()
        XCTAssertEqual(finalReplaceCount, 0)
        XCTAssertEqual(
            storedCredentials,
            original
        )
        XCTAssertEqual(
            finalPresentation,
            .failed(.cancelled)
        )
    }

    func testQuiesceCancelsNoncooperativeFlightAndRejectsFutureRefresh() async {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let snapshot = makeSnapshot(
            identity: nil,
            source: .cliReport
        )
        let sourceGate = BlockingRefreshSourceScript()
        let coordinator = AntigravityRefreshCoordinator(
            repository: RefreshRepositoryDouble(
                accounts: [account],
                activeAccountID: account.id,
                credentials: [
                    account.id: makeCredentials("a"),
                ]
            ),
            sources: [
                BlockingRefreshSource(
                    id: .cliReport,
                    script: sourceGate
                ),
            ]
        )
        let request = selectedRequest(target: .cli, revision: 0)
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
            with: .init(payload: .grouped(snapshot))
        )
        await sourceGate.waitUntilFinished()
        let completedCaller = await caller.value
        XCTAssertEqual(completedCaller, .failed(.cancelled))
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

private actor RefreshRepositoryDouble:
    AntigravityRefreshAccountRepository
{
    private var storedState: AntigravityAccountRepositoryState
    private var credentials:
        [AntigravityAccountID: AntigravityOAuthCredentials]
    private var replaceCount = 0

    init(
        accounts: [AntigravityStoredAccount],
        activeAccountID: AntigravityAccountID?,
        credentials:
            [AntigravityAccountID: AntigravityOAuthCredentials]
    ) {
        storedState = AntigravityAccountRepositoryState(
            revision: 0,
            activeAccountID: activeAccountID,
            accounts: accounts
        )
        self.credentials = credentials
    }

    func state() async throws -> AntigravityAccountRepositoryState {
        storedState
    }

    func credentialSnapshot(
        for accountID: AntigravityAccountID
    ) async throws -> AntigravityCredentialSnapshot? {
        guard let account = storedState.accounts.first(
            where: { $0.id == accountID }
        ), let credentials = credentials[accountID] else {
            return nil
        }
        return AntigravityCredentialSnapshot(
            repositoryRevision: storedState.revision,
            account: account,
            credentials: credentials
        )
    }

    func replaceCredential(
        for accountID: AntigravityAccountID,
        with credentials: AntigravityOAuthCredentials,
        externalIdentity: AntigravityExternalAccountIdentity?,
        expectedRevision: UInt64
    ) async throws -> AntigravityAccountRepositoryState {
        guard storedState.revision == expectedRevision else {
            throw AntigravityAccountRepositoryError
                .revisionConflict(
                    expected: expectedRevision,
                    actual: storedState.revision
                )
        }
        guard storedState.accounts.contains(
            where: { $0.id == accountID }
        ) else {
            throw AntigravityAccountRepositoryError
                .accountNotFound
        }
        replaceCount += 1
        self.credentials[accountID] = credentials
        storedState.revision += 1
        return storedState
    }

    func switchActive(
        to accountID: AntigravityAccountID,
        expectedRevision: UInt64
    ) throws -> AntigravityAccountRepositoryState {
        guard storedState.revision == expectedRevision else {
            throw AntigravityAccountRepositoryError
                .revisionConflict(
                    expected: expectedRevision,
                    actual: storedState.revision
                )
        }
        storedState.activeAccountID = accountID
        storedState.revision += 1
        return storedState
    }

    func stateValue() -> AntigravityAccountRepositoryState {
        storedState
    }

    func credentialsValue(
        for accountID: AntigravityAccountID
    ) -> AntigravityOAuthCredentials? {
        credentials[accountID]
    }

    func replaceCountValue() -> Int {
        replaceCount
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
            throw AntigravityUsageSourceError.unavailable
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
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
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
    target: AntigravityUsageTarget = .app,
    revision: UInt64
) -> AntigravityRefreshRequest {
    return AntigravityRefreshRequest(
        trigger: .manual,
        repositoryRevision: revision,
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

private func makeAccount(
    id: String,
    subject: String?,
    email: String?
) -> AntigravityStoredAccount {
    AntigravityStoredAccount(
        id: AntigravityAccountID(rawValue: id),
        label: email ?? id,
        externalIdentity: .init(
            googleSubject: subject,
            email: email
        ),
        migrationAliases: [],
        lifecycle: .active,
        credentialReference:
            AntigravityCredentialReference(
                rawValue:
                    "\(AntigravityCredentialReference.namespacePrefix)\(id)"
            ),
        createdAtMilliseconds: 1,
        updatedAtMilliseconds: 1
    )
}

private func makeCredentials(
    _ seed: String
) -> AntigravityOAuthCredentials {
    AntigravityOAuthCredentials(
        accessToken: "access-\(seed)",
        refreshToken: "refresh-\(seed)",
        expiryDate: Date(timeIntervalSince1970: 2_000_000_000),
        email: "a@example.com",
        clientID: "client",
        clientSecret: "secret"
    )
}

private func makeSnapshot(
    identity: ProviderAccountIdentity?,
    source: AntigravityUsageSourceID,
    fraction: Double = 0.75
) -> AntigravityQuotaSnapshot {
    let provenance = makeProvenance(
        identity: identity,
        source: source,
        capability: .groupedQuotaSummary
    )

    return AntigravityQuotaSnapshot(
        identity: identity,
        plan: "Pro",
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
        provenance: provenance,
        fetchedAt: Date(timeIntervalSince1970: 1_900_000_000)
    )
}

/// Mirrors a decoded `agy -p /usage` report: no account identity or plan.
private func makeReportSnapshot(fraction: Double = 0.75) -> AntigravityQuotaSnapshot {
    let snapshot = makeSnapshot(identity: nil, source: .cliReport, fraction: fraction)
    return AntigravityQuotaSnapshot(
        identity: nil,
        plan: nil,
        lanes: snapshot.lanes,
        decodeIssues: [],
        provenance: snapshot.provenance,
        fetchedAt: snapshot.fetchedAt
    )
}

private func makeIdentityOnlyUsage(
    identity: ProviderAccountIdentity,
    source: AntigravityUsageSourceID
) -> AntigravityIdentityOnlyUsage {
    AntigravityIdentityOnlyUsage(
        identity: identity,
        plan: "Pro",
        provenance: makeProvenance(
            identity: identity,
            source: source,
            capability: .groupedQuotaSummary
        ),
        fetchedAt: Date(timeIntervalSince1970: 1_900_000_001)
    )
}

private func makeLocalLimitedCapability(
    identity: ProviderAccountIdentity
) -> AntigravityLimitedQuotaCapability {
    .localLegacy(
        evidence:
            AntigravityLegacyCapabilityEvidence(
                method: .getUserStatus,
                identity: identity,
                plan: "Pro",
                modelConfigCount: 2
            ),
        fallbackReason: .groupedQuotaUnavailable,
        provenance: makeProvenance(
            identity: identity,
            source: .localApp,
            capability: .limitedQuota
        ),
        fetchedAt: Date(
            timeIntervalSince1970: 1_900_000_002
        )
    )
}

private func makeProvenance(
    identity: ProviderAccountIdentity?,
    source: AntigravityUsageSourceID,
    capability: AntigravityQuotaProvenance.Capability
) -> AntigravityQuotaProvenance {
    let transport: AntigravityQuotaProvenance.Transport
    let owner: AntigravityQuotaProvenance.EndpointOwner
    let processIdentity: ProcessIdentity?
    switch source {
    case .localApp:
        transport = .localAppRPC
        owner = .external
        processIdentity = ProcessIdentity(
            processID: 101,
            startedAt: Date(timeIntervalSince1970: 100),
            executablePath: "/Applications/Antigravity.app/agy"
        )
    case .cliReport:
        transport = .cliUsageReport
        owner = .managed
        processIdentity = nil
    case .googleOAuth:
        transport = .googleOAuth
        owner = .external
        processIdentity = nil
    }

    return AntigravityQuotaProvenance(
        transport: transport,
        endpointOwner: owner,
        accountIdentity: identity,
        capability: capability,
        processIdentity: processIdentity
    )
}

private actor DiscoveryPolicySource: AntigravityUsageSource {
    nonisolated let id = AntigravityUsageSourceID.cliReport
    let snapshot: AntigravityQuotaSnapshot
    var calls = 0
    init(snapshot: AntigravityQuotaSnapshot) { self.snapshot = snapshot }
    func waitUntilStarted() async { while calls == 0 { await Task.yield() } }
    func fetch(_ request: AntigravityUsageSourceRequest) async throws -> AntigravityUsageSourceResponse {
        calls += 1
        if calls == 1 { try await Task.sleep(for: .seconds(2)) }
        return .init(payload: .grouped(snapshot))
    }
}
