import Foundation

nonisolated protocol AntigravityRefreshAccountRepository:
    Sendable
{
    func state() async throws
        -> AntigravityAccountRepositoryState

}

extension AntigravityAccountRepository:
    AntigravityRefreshAccountRepository
{}

private nonisolated struct AntigravityRefreshFlightKey:
    Sendable,
    Equatable
{
    let repositoryRevision: UInt64
    let connection: AntigravityConnectionSettings
    let managedLaunch: AntigravityManagedLaunchState
    let clearsPreviousSnapshot: Bool
    let forcesDiscovery: Bool

    init(_ request: AntigravityRefreshRequest) {
        forcesDiscovery = request.forcesDiscovery
        repositoryRevision = request.repositoryRevision
        connection = request.connection
        managedLaunch = request.managedLaunch
        clearsPreviousSnapshot =
            request.trigger.clearsPreviousSnapshot
    }
}

private nonisolated enum AntigravityRefreshOutput:
    Sendable
{
    case setupRequired(AntigravitySetupReason)
    case snapshot(AntigravityQuotaSnapshot)
    case limited(AntigravityLimitedQuotaCapability)
    case identityOnly(AntigravityIdentityOnlyUsage)
    case accountMismatch(
        expected: ProviderAccountIdentity,
        received: ProviderAccountIdentity?
    )
    case failure(AntigravityFailure)
}

private nonisolated struct AntigravityRefreshExecutionResult:
    Sendable
{
    let output: AntigravityRefreshOutput
    let repositoryWasValidated: Bool
    var observedIdentity: ProviderAccountIdentity? = nil

    static func failure(
        _ failure: AntigravityFailure,
        repositoryWasValidated: Bool = false,
        observedIdentity: ProviderAccountIdentity? = nil
    ) -> Self {
        Self(
            output: .failure(failure),
            repositoryWasValidated:
                repositoryWasValidated,
            observedIdentity: observedIdentity
        )
    }
}

actor AntigravityRefreshCoordinator:
    AntigravityRefreshCoordinating
{
    private struct InFlight {
        let id: UUID
        let startedAt: ContinuousClock.Instant
        let generation: UInt64
        let key: AntigravityRefreshFlightKey
        let request: AntigravityRefreshRequest
        var driver: Task<Void, Never>?
        var waiters:
            [UUID:
                AntigravityRefreshOneShotWaiter<
                    AntigravityPresentationState
                >]
    }

    private let runtimeEnvironment: AntigravityRuntimeEnvironment?
    private let repository:
        any AntigravityRefreshAccountRepository
    private let sources:
        [AntigravityUsageSourceID: any AntigravityUsageSource]
    private let deadlineFactory:
        @Sendable () -> AntigravityRPCDeadline

    private var isShutDown = false
    private var generation: UInt64 = 0
    private var state: AntigravityPresentationState = .disabled
    private var lastGoodSnapshot: AntigravityQuotaSnapshot?
    private var inFlight: InFlight?
    init(
        repository:
            any AntigravityRefreshAccountRepository,
        sources: [any AntigravityUsageSource],
        runtimeEnvironment: AntigravityRuntimeEnvironment? = nil,
        deadlineFactory:
            @escaping @Sendable () -> AntigravityRPCDeadline = {
                AntigravityRPCDeadline(
                    totalTimeout:
                        AntigravityRPCDeadline
                            .defaultRefreshTimeout
                )
            }
    ) {
        var registry:
            [AntigravityUsageSourceID:
                any AntigravityUsageSource] = [:]
        for source in sources {
            precondition(
                registry[source.id] == nil,
                "Duplicate Antigravity usage source"
            )
            registry[source.id] = source
        }
        self.repository = repository
        self.runtimeEnvironment = runtimeEnvironment
        self.sources = registry
        self.deadlineFactory = deadlineFactory
    }

    func presentationState() -> AntigravityPresentationState {
        state
    }

    func inFlightWaiterCountForTesting() -> Int {
        inFlight?.waiters.count ?? 0
    }

    func quiesceForShutdown() async {
        if !isShutDown {
            isShutDown = true
            detachCurrentFlight()
            lastGoodSnapshot = nil
            _ = advanceGeneration()
            state = .failed(.appShuttingDown)
        }
    }

    func invalidateBoundary() async {
        guard !isShutDown else {
            return
        }
        detachCurrentFlight()
        lastGoodSnapshot = nil
        guard advanceGeneration() else {
            state = .failed(.generationExhausted)
            return
        }
        state = .refreshing(previous: nil)
    }

    func refresh(
        _ request: AntigravityRefreshRequest
    ) async -> AntigravityPresentationState {
        guard !isShutDown else {
            return .failed(.appShuttingDown)
        }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        let key = AntigravityRefreshFlightKey(request)
        let waiterID = UUID()
        let waiter =
            AntigravityRefreshOneShotWaiter<
                AntigravityPresentationState
            >()
        if var current = inFlight, current.key == key {
            current.waiters[waiterID] = waiter
            inFlight = current
            return await waitForCaller(
                waiter,
                operationID: current.id,
                waiterID: waiterID
            )
        }
        detachCurrentFlight()
        guard advanceGeneration() else {
            lastGoodSnapshot = nil
            state = .failed(.generationExhausted)
            return state
        }
        if request.trigger.clearsPreviousSnapshot {
            lastGoodSnapshot = nil
        }
        state = .refreshing(previous: lastGoodSnapshot)

        let operationID = UUID()
        let operationGeneration = generation
        let repository = self.repository
        let sources = self.sources
        let runtimeEnvironment = self.runtimeEnvironment
        let deadline = deadlineFactory()
        inFlight = InFlight(
            id: operationID,
            startedAt: ContinuousClock.now,
            generation: operationGeneration,
            key: key,
            request: request,
            driver: nil,
            waiters: [waiterID: waiter]
        )
        let driver = Task.detached(
            priority: .utility
        ) { [weak self] in
            let result = await Self.executeWithEnvironment(
                runtimeEnvironment: runtimeEnvironment,
                generation: operationGeneration,
                request: request,
                repository: repository,
                sources: sources,
                deadline: deadline
            )
            await self?.finishFlight(
                operationID: operationID,
                generation: operationGeneration,
                result: result
            )
        }
        inFlight?.driver = driver

        return await waitForCaller(
            waiter,
            operationID: operationID,
            waiterID: waiterID
        )
    }

    private func waitForCaller(
        _ waiter:
            AntigravityRefreshOneShotWaiter<
                AntigravityPresentationState
            >,
        operationID: UUID,
        waiterID: UUID
    ) async -> AntigravityPresentationState {
        let result = await withTaskCancellationHandler {
            await waiter.value()
        } onCancel: {
            waiter.resolve(.failed(.cancelled))
            Task { [weak self] in
                await self?.cancelWaiter(
                    waiterID,
                    operationID: operationID
                )
            }
        }
        if Task.isCancelled {
            cancelWaiter(
                waiterID,
                operationID: operationID
            )
            return .failed(.cancelled)
        }
        return result
    }

    private func finishFlight(
        operationID: UUID,
        generation operationGeneration: UInt64,
        result: AntigravityRefreshExecutionResult
    ) async {
        guard generation == operationGeneration,
            let operation = inFlight,
              operation.id == operationID
        else {
            return
        }
        let finalState = await apply(
            result,
            operation: operation
        )
        if generation == operationGeneration,
           inFlight?.id == operationID
        {
            state = finalState
            // One event per accepted flight, never per coalesced waiter or RPC poll.
            OperationalLog.record(.antigravity(finalState), elapsed: operation.startedAt.duration(to: .now))
            let waiters = inFlight.map {
                Array($0.waiters.values)
            } ?? []
            inFlight = nil
            for waiter in waiters {
                waiter.resolve(finalState)
            }
        }
    }

    private func apply(
        _ result: AntigravityRefreshExecutionResult,
        operation: InFlight
    ) async -> AntigravityPresentationState {
        guard isCurrent(operation) else {
            return state
        }

        var output = result.output
        if let observed = result.observedIdentity, let previous = lastGoodSnapshot,
            !AntigravityAccountIdentityMatcher.match(
                expected: previous.identity ?? previous.provenance.accountIdentity ?? ProviderAccountIdentity(),
                received: observed
            ).isMatch
        {
            lastGoodSnapshot = nil
        }

        if result.repositoryWasValidated {
            do {
                let verified = try await repository.state()
                guard verified.revision == operation.request.repositoryRevision else {
                    output = .failure(
                        .repositoryRevisionChanged
                    )
                    return presentation(
                        for: output,
                        operation: operation
                    )
                }
            } catch {
                output = .failure(.repositoryUnavailable)
            }
        }

        guard isCurrent(operation) else {
            return state
        }
        return presentation(
            for: output,
            operation: operation
        )
    }

    private func presentation(
        for output: AntigravityRefreshOutput,
        operation: InFlight
    ) -> AntigravityPresentationState {
        guard isCurrent(operation) else {
            return state
        }
        switch output {
        case .setupRequired(let reason):
            lastGoodSnapshot = nil
            return .setupRequired(reason)

        case .snapshot(let snapshot):
            lastGoodSnapshot = snapshot
            if snapshot.decodeIssues.isEmpty {
                return .ready(snapshot)
            }
            return .partial(
                snapshot,
                issues: snapshot.decodeIssues
            )

        case .limited(let capability):
            lastGoodSnapshot = nil
            return .limited(capability)

        case .identityOnly(let observation):
            lastGoodSnapshot = nil
            return .identityOnly(observation)

        case .accountMismatch(let expected, let received):
            return .accountMismatch(
                expected: expected,
                received: received
            )

        case .failure(let failure):
            if Self.failureInvalidatesPrevious(failure) {
                lastGoodSnapshot = nil
                return .failed(failure)
            }
            if let lastGoodSnapshot {
                return .stale(
                    lastGoodSnapshot,
                    failure: failure
                )
            }
            return .failed(failure)
        }
    }

    private func isCurrent(_ operation: InFlight) -> Bool {
        generation == operation.generation
            && inFlight?.id == operation.id
    }

    private func detachCurrentFlight() {
        guard let current = inFlight else { return }
        current.driver?.cancel()
        inFlight = nil
        for waiter in current.waiters.values { waiter.resolve(.failed(.cancelled)) }
    }

    private func cancelWaiter(
        _ waiterID: UUID,
        operationID: UUID
    ) {
        guard var current = inFlight,
              current.id == operationID
        else {
            return
        }
        current.waiters.removeValue(forKey: waiterID)
        if current.waiters.isEmpty {
            current.driver?.cancel()
            inFlight = nil
            if let lastGoodSnapshot {
                state = .stale(
                    lastGoodSnapshot,
                    failure: .cancelled
                )
            } else {
                state = .failed(.cancelled)
            }
        } else {
            inFlight = current
        }
    }

    private func advanceGeneration() -> Bool {
        guard generation < UInt64.max else {
            return false
        }
        generation += 1
        return true
    }

    private nonisolated static func executeWithEnvironment(
        runtimeEnvironment: AntigravityRuntimeEnvironment?,
        generation: UInt64,
        request: AntigravityRefreshRequest,
        repository: any AntigravityRefreshAccountRepository,
        sources: [AntigravityUsageSourceID: any AntigravityUsageSource],
        deadline: AntigravityRPCDeadline
    ) async -> AntigravityRefreshExecutionResult {
        guard request.target != .unselected else {
            return .init(output: .setupRequired(.usageTargetSelection), repositoryWasValidated: false)
        }
        guard let runtimeEnvironment else {
            return await execute(generation: generation, request: request, repository: repository, sources: sources, deadline: deadline)
        }
        do {
            return try await runtimeEnvironment.withSources(
                forceDiscovery: request.forcesDiscovery, deadline: deadline
            ) { localSources in
                var registry = sources
                for source in localSources { registry[source.id] = source }
                // Environment sources own the current launch capability. A disabled
                // capability is represented by a non-launching typed failure source.
                let currentRequest = AntigravityRefreshRequest(
                    trigger: request.trigger,
                    repositoryRevision: request.repositoryRevision, connection: request.connection,
                    managedLaunch: .enabled
                )
                return await execute(generation: generation, request: currentRequest, repository: repository, sources: registry, deadline: deadline.beginningDiscoveryNow())
            }
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.deadlineExceeded(.managedCLI))
        }
    }

    private nonisolated static func execute(
        generation: UInt64,
        request: AntigravityRefreshRequest,
        repository: any AntigravityRefreshAccountRepository,
        sources: [AntigravityUsageSourceID: any AntigravityUsageSource],
        deadline: AntigravityRPCDeadline
    ) async -> AntigravityRefreshExecutionResult {
        guard request.target != .unselected else {
            return .init(output: .setupRequired(.usageTargetSelection), repositoryWasValidated: false)
        }
        do {
            try Task.checkCancellation()
            guard try await repository.state().revision == request.repositoryRevision else {
                return .failure(.repositoryRevisionChanged)
            }
            var lastFailure: AntigravityFailure = .noEligibleSource
            var actionableFailure: AntigravityFailure?
            var observedIdentity: ProviderAccountIdentity?
            for sourceID in AntigravitySourcePlanner.plannedSources(for: request) {
                try Task.checkCancellation()
                guard let source = sources[sourceID] else {
                    lastFailure = .sourceUnavailable(sourceID)
                    continue
                }
                guard source.id == sourceID else {
                    return .failure(.sourceContractViolation(sourceID), repositoryWasValidated: true)
                }
                let authorization: AntigravityManagedLaunchAuthorization =
                    sourceID == .managedCLI
                        && request.managedLaunch.allowsLaunch
                    ? .automatic(idleTimeout: .seconds(request.connection.managedSession.idleTimeoutSeconds))
                    : .disabled
                let sourceRequest = AntigravityUsageSourceRequest(
                    generation: generation, managedLaunchAuthorization: authorization,
                    deadline: deadline, refreshAuthentication: request.forcesDiscovery)
                let inspection: AntigravityUsageSourceInspection
                do {
                    inspection = try await source.inspectAccounts(sourceRequest)
                    try Task.checkCancellation()
                } catch is CancellationError {
                    return .failure(.cancelled)
                } catch {
                    let sourceError = error as? AntigravityUsageSourceError ?? .transportFailure
                    if sourceError == .cancelled { return .failure(.cancelled) }
                    if case .verifiedAccountFailure(let identity, _) = sourceError {
                        guard AntigravityAccountIdentityMatcher.match(expected: identity, received: identity).isMatch
                        else {
                            return .failure(.sourceContractViolation(sourceID))
                        }
                        if let observedIdentity,
                            !AntigravityAccountIdentityMatcher.match(expected: observedIdentity, received: identity)
                                .isMatch
                        {
                            return .failure(.accountChanged)
                        }
                        observedIdentity = identity
                    }
                    lastFailure = failure(sourceError, source: sourceID)
                    if sourceError != .unavailable && sourceError != .managedLaunchDisabled {
                        actionableFailure = lastFailure
                    }
                    continue
                }
                var evidence = AntigravityLocalAccountInventory()
                for response in inspection.responses {
                    guard let identity = validObservedIdentity(in: response, from: sourceID) else {
                        return .failure(.sourceContractViolation(sourceID), repositoryWasValidated: true)
                    }
                    evidence.observe(identity, source: sourceID)
                }
                if inspection.hasUnverifiedCandidates { evidence.markUnverified(sourceID) }
                guard !inspection.responses.isEmpty else {
                    lastFailure = .sourceUnavailable(sourceID)
                    continue
                }
                // Never resolve multiple live logins by process order, and never
                // combine a quota payload from one account with another identity.
                guard let account = evidence.uniqueVerifiedAccount else {
                    return .init(output: .setupRequired(.ambiguousLocalSessions), repositoryWasValidated: true)
                }
                if let observedIdentity,
                    !AntigravityAccountIdentityMatcher.match(expected: observedIdentity, received: account.identity)
                        .isMatch
                {
                    return .failure(.accountChanged)
                }
                for response in inspection.responses {
                    if case .grouped(let snapshot) = response.payload {
                        return .init(output: .snapshot(snapshot), repositoryWasValidated: true)
                    }
                }
                for response in inspection.responses {
                    if case .limited(let capability) = response.payload {
                        return .init(output: .limited(capability), repositoryWasValidated: true)
                    }
                }
                if case .identityOnly(let observation) = inspection.responses[0].payload {
                    return .init(output: .identityOnly(observation), repositoryWasValidated: true)
                }
            }
            if let actionableFailure {
                return .failure(actionableFailure, repositoryWasValidated: true, observedIdentity: observedIdentity)
            }
            if request.target == .cli && request.managedLaunch == .recoveryBlocked {
                return .init(output: .setupRequired(.managedRecoveryBlocked), repositoryWasValidated: true)
            }
            return .failure(lastFailure, repositoryWasValidated: true)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.repositoryUnavailable)
        }
    }

    private nonisolated static func failure(
        _ error: AntigravityUsageSourceError, source: AntigravityUsageSourceID
    ) -> AntigravityFailure {
        switch error {
        case .accountChanged: .accountChanged
        case .verifiedAccountFailure(_, let cause): failure(cause, source: source)
        case .unavailable, .managedLaunchDisabled: .sourceUnavailable(source)
        case .localAuthentication(let problem): .localAuthentication(source, problem)
        case .authenticationRequired: .authenticationRequired(source)
        case .interactionRequired: .interactionRequired(source)
        case .deadlineExceeded: .deadlineExceeded(source)
        case .malformedResponse: .schemaChanged(source)
        case .runtimeUnavailable(let reason): .runtimeUnavailable(reason)
        case .transportFailure: .transportUnavailable(source)
        case .cancelled: .cancelled
        }
    }

    private nonisolated static func validObservedIdentity(
        in response: AntigravityUsageSourceResponse,
        from sourceID: AntigravityUsageSourceID
    ) -> ProviderAccountIdentity? {
        let provenance: AntigravityQuotaProvenance
        let payloadIdentity: ProviderAccountIdentity?
        switch response.payload {
        case .grouped(let snapshot):
            guard !snapshot.lanes.isEmpty,
                  snapshot.provenance.capability
                    == .groupedQuotaSummary
            else {
                return nil
            }
            provenance = snapshot.provenance
            payloadIdentity = snapshot.identity

        case .limited(let limited):
            guard limited.provenance.capability
                    == .limitedQuota,
                  limitedEvidence(
                      limited,
                      matches: sourceID
                  )
            else {
                return nil
            }
            provenance = limited.provenance
            payloadIdentity = limited.evidence.identity

        case .identityOnly(let observation):
            provenance = observation.provenance
            payloadIdentity = observation.identity
        }

        guard provenanceMatchesSource(
            provenance,
            sourceID: sourceID
        ) else {
            return nil
        }

        let provenanceIdentity =
            provenance.accountIdentity
        if let provenanceIdentity, let payloadIdentity {
            guard AntigravityAccountIdentityMatcher
                .match(
                    expected: provenanceIdentity,
                    received: payloadIdentity
                ).isMatch
            else {
                return nil
            }
        }
        let identity = provenanceIdentity
            ?? payloadIdentity
        guard let identity,
              AntigravityAccountIdentityMatcher
                .match(
                    expected: identity,
                    received: identity
                ).isMatch
        else {
            return nil
        }
        return identity
    }

    private nonisolated static func limitedEvidence(
        _ capability: AntigravityLimitedQuotaCapability,
        matches sourceID: AntigravityUsageSourceID
    ) -> Bool {
        switch (
            sourceID,
            capability.evidence,
            capability.reason
        ) {
        case (
            .googleOAuth,
            .googleOAuth,
            .googleOAuth
        ):
            true
        case (
            .localApp,
            .localLegacy,
            .localLegacy
        ), (
            .borrowedCLI,
            .localLegacy,
            .localLegacy
        ), (
            .managedCLI,
            .localLegacy,
            .localLegacy
        ):
            true
        default:
            false
        }
    }

    private nonisolated static func provenanceMatchesSource(
        _ provenance: AntigravityQuotaProvenance,
        sourceID: AntigravityUsageSourceID
    ) -> Bool {
        switch sourceID {
        case .localApp:
            provenance.transport == .localAppRPC
                && provenance.endpointOwner == .external
                && provenance.processIdentity != nil
        case .borrowedCLI:
            provenance.transport == .borrowedAGYRPC
                && provenance.endpointOwner == .borrowed
                && provenance.processIdentity != nil
        case .managedCLI:
            provenance.transport == .managedAGYRPC
                && provenance.endpointOwner == .managed
                && provenance.processIdentity != nil
        case .googleOAuth:
            false
        }
    }

    private nonisolated static func failureInvalidatesPrevious(
        _ failure: AntigravityFailure
    ) -> Bool {
        switch failure {
        case .appShuttingDown,
            .accountChanged,
            .authenticationRequired,
            .interactionRequired,
             .invalidRefreshContext,
             .generationExhausted,
             .repositoryUnavailable,
             .repositoryRevisionChanged,
             .credentialCommitFailed,
             .credentialCommitAmbiguous,
             .selectedAccountUnavailable,
             .selectedAccountIdentityUnavailable:
            true
        case .cancelled,
             .localAuthentication,
             .noEligibleSource,
             .sourceUnavailable,
             .deadlineExceeded,
             .schemaChanged,
             .transportUnavailable,
             .sourceContractViolation,
             .numericQuotaUnavailable,
             .runtimeUnavailable:
            false
        }
    }
}

private nonisolated final class AntigravityRefreshOneShotWaiter<
    Value: Sendable
>:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<Value, Never>?
    private var result: Value?

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            install(continuation)
        }
    }

    private func install(
        _ continuation:
            CheckedContinuation<Value, Never>
    ) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ result: Value) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
