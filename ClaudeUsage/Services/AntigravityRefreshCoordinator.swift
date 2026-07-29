import Foundation

nonisolated protocol AntigravityRefreshAccountRepository:
    Sendable
{
    func state() async throws
        -> AntigravityAccountRepositoryState

    func credentialSnapshot(
        for accountID: AntigravityAccountID
    ) async throws -> AntigravityCredentialSnapshot?

    func replaceCredential(
        for accountID: AntigravityAccountID,
        with credentials: AntigravityOAuthCredentials,
        externalIdentity:
            AntigravityExternalAccountIdentity?,
        expectedRevision: UInt64
    ) async throws -> AntigravityAccountRepositoryState
}

extension AntigravityAccountRepository:
    AntigravityRefreshAccountRepository
{}

private nonisolated struct AntigravityRefreshFlightKey:
    Sendable,
    Equatable
{
    let accountTarget: AntigravityRefreshAccountTarget
    let repositoryRevision: UInt64
    let connection: AntigravityConnectionSettings
    let managedLaunchEnabled: Bool
    let clearsPreviousSnapshot: Bool

    init(_ request: AntigravityRefreshRequest) {
        accountTarget = request.accountTarget
        repositoryRevision = request.repositoryRevision
        connection = request.connection
        managedLaunchEnabled =
            request.managedLaunchEnabled
        clearsPreviousSnapshot =
            request.trigger.clearsPreviousSnapshot
    }
}

private nonisolated struct AntigravityRefreshCredentialMutation:
    Sendable
{
    let accountID: AntigravityAccountID
    let expectedRevision: UInt64
    let original: AntigravityOAuthCredentials
    let refreshed: AntigravityOAuthCredentials
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
    let credentialMutation:
        AntigravityRefreshCredentialMutation?
    let repositoryWasValidated: Bool

    static func failure(
        _ failure: AntigravityFailure,
        repositoryWasValidated: Bool = false
    ) -> Self {
        Self(
            output: .failure(failure),
            credentialMutation: nil,
            repositoryWasValidated:
                repositoryWasValidated
        )
    }
}

private nonisolated enum AntigravityCredentialCommitResolution:
    Sendable
{
    case committed(revision: UInt64)
    case failed(AntigravityFailure)
}

private nonisolated enum AntigravityCredentialCommitWaitResult:
    Sendable,
    Equatable
{
    case notNeeded
    case completed
    case cancelled
}

/// Owns refresh transaction boundaries, single-flight sharing, credential
/// settlement, and shutdown quiescence for Antigravity usage.
actor AntigravityRefreshCoordinator:
    AntigravityRefreshCoordinating
{
    private struct InFlight {
        let id: UUID
        let generation: UInt64
        let key: AntigravityRefreshFlightKey
        let request: AntigravityRefreshRequest
        var driver: Task<Void, Never>?
        var isFinishing: Bool
        var waiters:
            [UUID:
                AntigravityRefreshOneShotWaiter<
                    AntigravityPresentationState
                >]
    }

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
    private var lastCompletedFlight:
        (
            key: AntigravityRefreshFlightKey,
            state: AntigravityPresentationState
        )?
    private var credentialCommitInProgress = false
    private var credentialCommitWaiters:
        [UUID:
            AntigravityRefreshOneShotWaiter<
                AntigravityCredentialCommitWaitResult
            >] = [:]

    init(
        repository:
            any AntigravityRefreshAccountRepository,
        sources: [any AntigravityUsageSource],
        deadlineFactory:
            @escaping @Sendable () -> AntigravityRPCDeadline = {
                AntigravityRPCDeadline()
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
        self.sources = registry
        self.deadlineFactory = deadlineFactory
    }

    func presentationState() -> AntigravityPresentationState {
        state
    }

    func inFlightWaiterCountForTesting() -> Int {
        inFlight?.waiters.count ?? 0
    }

    func credentialCommitWaiterCountForTesting() -> Int {
        credentialCommitWaiters.count
    }

    func quiesceForShutdown() async {
        if !isShutDown {
            isShutDown = true
            detachCurrentFlight(
                cancelNonCommittingFinisher: true
            )
            lastGoodSnapshot = nil
            lastCompletedFlight = nil
            _ = advanceGeneration()
            state = .failed(.appShuttingDown)
        }
        _ = await waitForCredentialCommit()
    }

    func invalidateBoundary() async {
        guard !isShutDown else {
            _ = await waitForCredentialCommit()
            return
        }
        detachCurrentFlight()
        lastGoodSnapshot = nil
        lastCompletedFlight = nil
        guard advanceGeneration() else {
            state = .failed(.generationExhausted)
            _ = await waitForCredentialCommit()
            return
        }
        state = .refreshing(previous: nil)
        _ = await waitForCredentialCommit()
    }

    func refresh(
        _ request: AntigravityRefreshRequest
    ) async -> AntigravityPresentationState {
        guard !isShutDown else {
            return .failed(.appShuttingDown)
        }
        let entryGeneration = generation
        let commitWait = await waitForCredentialCommit()
        guard commitWait
                != .cancelled,
              !Task.isCancelled
        else {
            return .failed(.cancelled)
        }
        guard !isShutDown else {
            return .failed(.appShuttingDown)
        }
        guard generation == entryGeneration else {
            return state
        }

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
        if commitWait == .completed,
           let completed = lastCompletedFlight,
           completed.key == key
        {
            guard !Task.isCancelled else {
                return .failed(.cancelled)
            }
            return completed.state
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
        let deadline = deadlineFactory()
        inFlight = InFlight(
            id: operationID,
            generation: operationGeneration,
            key: key,
            request: request,
            driver: nil,
            isFinishing: false,
            waiters: [waiterID: waiter]
        )
        let driver = Task.detached(
            priority: .utility
        ) { [weak self] in
            let result = await Self.execute(
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
              var operation = inFlight,
              operation.id == operationID
        else {
            return
        }
        operation.isFinishing = true
        inFlight = operation

        let finalState = await apply(
            result,
            operation: operation
        )
        if generation == operationGeneration,
           inFlight?.id == operationID
        {
            state = finalState
            lastCompletedFlight = (
                key: operation.key,
                state: finalState
            )
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
        var finalExpectedRevision =
            operation.request.repositoryRevision

        if let mutation = result.credentialMutation,
           mutation.refreshed != mutation.original
        {
            credentialCommitInProgress = true
            do {
                _ = try await repository
                    .replaceCredential(
                        for: mutation.accountID,
                        with: mutation.refreshed,
                        externalIdentity: nil,
                        expectedRevision:
                            mutation.expectedRevision
                    )
            } catch {
                // The repository may throw after metadata commit while
                // cleaning the old immutable reference or journal. Reconcile
                // from canonical state instead of misclassifying a committed
                // refresh as unavailable.
            }
            switch await reconcileCredentialCommit(
                mutation,
                target: operation.request.accountTarget
            ) {
            case .committed(let revision):
                finalExpectedRevision = revision
            case .failed(let failure):
                output = .failure(failure)
            }
            finishCredentialCommit()
        } else if result.repositoryWasValidated {
            do {
                let verified = try await repository.state()
                guard Self.repositoryState(
                    verified,
                    matches: operation.request.accountTarget,
                    revision: finalExpectedRevision
                ) else {
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

    private func reconcileCredentialCommit(
        _ mutation: AntigravityRefreshCredentialMutation,
        target: AntigravityRefreshAccountTarget
    ) async -> AntigravityCredentialCommitResolution {
        do {
            let current = try await repository.state()
            let snapshot = try await repository
                .credentialSnapshot(for: mutation.accountID)
            let committedRevision =
                mutation.expectedRevision < UInt64.max
                    ? mutation.expectedRevision + 1
                    : nil

            if let committedRevision {
                if current.revision == committedRevision,
                   Self.repositoryState(
                       current,
                       matches: target,
                       revision: committedRevision
                   ),
                   snapshot?.repositoryRevision
                        == committedRevision,
                   snapshot?.credentials == mutation.refreshed
                {
                    return .committed(
                        revision: committedRevision
                    )
                }
            }

            if current.revision == mutation.expectedRevision,
               Self.repositoryState(
                   current,
                   matches: target,
                   revision: mutation.expectedRevision
               ),
               snapshot?.repositoryRevision
                    == mutation.expectedRevision,
               snapshot?.credentials == mutation.original
            {
                return .failed(.credentialCommitFailed)
            }

            if current.revision != mutation.expectedRevision,
               current.revision != committedRevision
            {
                return .failed(.repositoryRevisionChanged)
            }
            return .failed(.credentialCommitAmbiguous)
        } catch {
            return .failed(.credentialCommitAmbiguous)
        }
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
            return .limited(capability)

        case .identityOnly(let observation):
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

    private func detachCurrentFlight(
        cancelNonCommittingFinisher: Bool = false
    ) {
        guard let current = inFlight else { return }
        if !current.isFinishing
            || (
                cancelNonCommittingFinisher
                    && !credentialCommitInProgress
            )
        {
            current.driver?.cancel()
        }
        inFlight = nil
        for waiter in current.waiters.values {
            waiter.resolve(.failed(.cancelled))
        }
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
        if current.waiters.isEmpty && !current.isFinishing {
            current.driver?.cancel()
            inFlight = nil
            lastCompletedFlight = nil
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

    private func waitForCredentialCommit() async
        -> AntigravityCredentialCommitWaitResult
    {
        guard !Task.isCancelled else {
            return .cancelled
        }
        guard credentialCommitInProgress else {
            return .notNeeded
        }
        let waiterID = UUID()
        let waiter =
            AntigravityRefreshOneShotWaiter<
                AntigravityCredentialCommitWaitResult
            >()
        credentialCommitWaiters[waiterID] = waiter
        let result = await withTaskCancellationHandler {
            await waiter.value()
        } onCancel: {
            waiter.resolve(.cancelled)
            Task { [weak self] in
                await self?.removeCredentialCommitWaiter(
                    waiterID
                )
            }
        }
        if Task.isCancelled {
            credentialCommitWaiters.removeValue(
                forKey: waiterID
            )
            return .cancelled
        }
        return result
    }

    private func finishCredentialCommit() {
        credentialCommitInProgress = false
        let waiters = credentialCommitWaiters
        credentialCommitWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resolve(.completed)
        }
    }

    private func removeCredentialCommitWaiter(
        _ waiterID: UUID
    ) {
        credentialCommitWaiters.removeValue(forKey: waiterID)
    }

    private nonisolated static func execute(
        generation: UInt64,
        request: AntigravityRefreshRequest,
        repository:
            any AntigravityRefreshAccountRepository,
        sources:
            [AntigravityUsageSourceID:
                any AntigravityUsageSource],
        deadline: AntigravityRPCDeadline
    ) async -> AntigravityRefreshExecutionResult {
        do {
            try Task.checkCancellation()
            let connection = request.connection
            let repositoryState = try await repository.state()
            guard repositoryState.revision
                    == request.repositoryRevision
            else {
                return .failure(.repositoryRevisionChanged)
            }

            let selectedContext:
                AntigravitySelectedRefreshContext?
            switch request.accountTarget {
            case .ambientLocal:
                selectedContext = nil

            case .selectedOAuth(let accountID):
                guard repositoryState.activeAccountID
                        == accountID,
                      let snapshot = try await repository
                        .credentialSnapshot(for: accountID),
                      snapshot.repositoryRevision
                        == request.repositoryRevision
                else {
                    return .failure(
                        .selectedAccountUnavailable(accountID)
                    )
                }
                let expected =
                    snapshot.account.externalIdentity
                        .providerAccountIdentity
                guard AntigravityAccountIdentityMatcher
                    .match(
                        expected: expected,
                        received: expected
                    ).isMatch
                else {
                    return .failure(
                        .selectedAccountIdentityUnavailable(
                            accountID
                        )
                    )
                }
                selectedContext =
                    AntigravitySelectedRefreshContext(
                        accountID: accountID,
                        identity: expected,
                        credentials: snapshot.credentials
                    )
            }

            let planned = AntigravitySourcePlanner
                .plannedSources(for: request)
            guard !planned.isEmpty else {
                return .failure(.noEligibleSource)
            }

            var bestLimited:
                AntigravityLimitedQuotaCapability?
            var bestIdentityOnly:
                AntigravityIdentityOnlyUsage?
            var acceptedCredentialMutation:
                AntigravityRefreshCredentialMutation?
            var mismatchedIdentity:
                ProviderAccountIdentity?
            var observedMismatch = false
            var lastFailure: AntigravityFailure =
                .noEligibleSource
            var actionableFailure: AntigravityFailure?
            var sawUnavailableSource = false

            for sourceID in planned {
                do {
                    try Task.checkCancellation()
                } catch {
                    return .failure(
                        .cancelled,
                        repositoryWasValidated: true
                    )
                }

                guard let source = sources[sourceID] else {
                    sawUnavailableSource = true
                    lastFailure = .sourceUnavailable(sourceID)
                    continue
                }
                guard source.id == sourceID else {
                    let failure =
                        AntigravityFailure
                            .sourceContractViolation(sourceID)
                    lastFailure = failure
                    actionableFailure = failure
                    continue
                }

                let oauthAuthorization:
                    AntigravityOAuthSourceAuthorization?
                if sourceID == .googleOAuth,
                   let selectedContext
                {
                    oauthAuthorization =
                        AntigravityOAuthSourceAuthorization(
                            accountID:
                                selectedContext.accountID,
                            repositoryRevision:
                                request.repositoryRevision,
                            credentials:
                                selectedContext.credentials
                        )
                } else {
                    oauthAuthorization = nil
                }
                let managedAuthorization:
                    AntigravityManagedLaunchAuthorization
                if sourceID == .managedCLI,
                   request.managedLaunchEnabled
                {
                    managedAuthorization = .automatic(
                        idleTimeout: .seconds(
                            connection.managedSession
                                .idleTimeoutSeconds
                        )
                    )
                } else {
                    managedAuthorization = .disabled
                }
                let sourceRequest =
                    AntigravityUsageSourceRequest(
                        generation: generation,
                        accountTarget:
                            request.accountTarget,
                        expectedIdentity:
                            selectedContext?.identity,
                        oauthAuthorization:
                            oauthAuthorization,
                        managedLaunchAuthorization:
                            managedAuthorization,
                        deadline: deadline
                    )

                let response: AntigravityUsageSourceResponse
                do {
                    response = try await source.fetch(
                        sourceRequest
                    )
                    try Task.checkCancellation()
                } catch is CancellationError {
                    return .failure(
                        .cancelled,
                        repositoryWasValidated: true
                    )
                } catch let error
                    as AntigravityUsageSourceError
                {
                    if error == .cancelled {
                        return .failure(
                            .cancelled,
                            repositoryWasValidated: true
                        )
                    }
                    let failure: AntigravityFailure
                    switch error {
                    case .unavailable,
                         .managedLaunchDisabled:
                        sawUnavailableSource = true
                        failure = .sourceUnavailable(sourceID)
                    case .authenticationRequired:
                        failure = .authenticationRequired(
                            sourceID
                        )
                    case .interactionRequired:
                        failure = .interactionRequired(sourceID)
                    case .deadlineExceeded:
                        failure = .deadlineExceeded(sourceID)
                    case .malformedResponse:
                        failure = .schemaChanged(sourceID)
                    case .transportFailure:
                        failure = .transportUnavailable(
                            sourceID
                        )
                    case .cancelled:
                        failure = .cancelled
                    }
                    lastFailure = failure
                    if error != .unavailable,
                       error != .managedLaunchDisabled
                    {
                        actionableFailure = failure
                    }
                    continue
                } catch {
                    let failure =
                        AntigravityFailure
                            .transportUnavailable(sourceID)
                    lastFailure = failure
                    actionableFailure = failure
                    continue
                }

                guard let received =
                        validObservedIdentity(
                            in: response,
                            from: sourceID
                        ),
                      validCredentialBoundary(
                          response,
                          sourceID: sourceID,
                          selectedContext: selectedContext
                      )
                else {
                    let failure =
                        AntigravityFailure
                            .sourceContractViolation(sourceID)
                    lastFailure = failure
                    actionableFailure = failure
                    continue
                }

                let isAccepted: Bool
                switch request.accountTarget {
                case .selectedOAuth:
                    let expected = selectedContext!.identity
                    let match =
                        AntigravityAccountIdentityMatcher
                            .match(
                                expected: expected,
                                received: received
                            )
                    isAccepted = match.isMatch
                    if !isAccepted {
                        observedMismatch = true
                        if mismatchedIdentity == nil {
                            mismatchedIdentity = received
                        }
                    }
                case .ambientLocal:
                    isAccepted =
                        AntigravityAccountIdentityMatcher
                            .match(
                                expected: received,
                                received: received
                            ).isMatch
                }
                guard isAccepted else { continue }

                let mutation:
                    AntigravityRefreshCredentialMutation?
                do {
                    mutation = try credentialMutation(
                        response,
                        sourceID: sourceID,
                        selectedContext: selectedContext,
                        expectedRevision:
                            request.repositoryRevision
                    )
                } catch {
                    let failure =
                        AntigravityFailure
                            .sourceContractViolation(sourceID)
                    lastFailure = failure
                    actionableFailure = failure
                    continue
                }
                if let mutation {
                    acceptedCredentialMutation = mutation
                }
                switch response.payload {
                case .grouped(let snapshot):
                    return AntigravityRefreshExecutionResult(
                        output: .snapshot(snapshot),
                        credentialMutation:
                            acceptedCredentialMutation,
                        repositoryWasValidated: true
                    )

                case .limited(let capability):
                    if bestLimited == nil {
                        bestLimited = capability
                    }

                case .identityOnly(let observation):
                    if bestIdentityOnly == nil {
                        bestIdentityOnly = observation
                    }
                }
            }

            if let bestLimited {
                return AntigravityRefreshExecutionResult(
                    output: .limited(bestLimited),
                    credentialMutation:
                        acceptedCredentialMutation,
                    repositoryWasValidated: true
                )
            }
            if let bestIdentityOnly {
                return AntigravityRefreshExecutionResult(
                    output: .identityOnly(
                        bestIdentityOnly
                    ),
                    credentialMutation:
                        acceptedCredentialMutation,
                    repositoryWasValidated: true
                )
            }
            if let actionableFailure {
                return .failure(
                    actionableFailure,
                    repositoryWasValidated: true
                )
            }
            if observedMismatch,
               let expected = selectedContext?.identity
            {
                return AntigravityRefreshExecutionResult(
                    output: .accountMismatch(
                        expected: expected,
                        received: mismatchedIdentity
                    ),
                    credentialMutation: nil,
                    repositoryWasValidated: true
                )
            }
            if case .ambientLocal = request.accountTarget,
               sawUnavailableSource
            {
                return AntigravityRefreshExecutionResult(
                    output: .setupRequired(
                        .noAmbientLocalSession
                    ),
                    credentialMutation: nil,
                    repositoryWasValidated: true
                )
            }
            return .failure(
                lastFailure,
                repositoryWasValidated: true
            )
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error
            as AntigravityAccountRepositoryError
        {
            switch error {
            case .revisionConflict:
                return .failure(.repositoryRevisionChanged)
            default:
                return .failure(.repositoryUnavailable)
            }
        } catch {
            return .failure(.repositoryUnavailable)
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
            provenance.transport == .googleOAuth
                && provenance.endpointOwner == .external
                && provenance.processIdentity == nil
        }
    }

    private nonisolated static func validCredentialBoundary(
        _ response: AntigravityUsageSourceResponse,
        sourceID: AntigravityUsageSourceID,
        selectedContext: AntigravitySelectedRefreshContext?
    ) -> Bool {
        guard let credential = response.refreshedCredential
        else {
            return true
        }
        return sourceID == .googleOAuth
            && selectedContext != nil
            && credential.hasTokenMaterial
    }

    private nonisolated static func credentialMutation(
        _ response: AntigravityUsageSourceResponse,
        sourceID: AntigravityUsageSourceID,
        selectedContext: AntigravitySelectedRefreshContext?,
        expectedRevision: UInt64
    ) throws -> AntigravityRefreshCredentialMutation? {
        guard sourceID == .googleOAuth,
              let selectedContext,
              let refreshed = response.refreshedCredential
        else {
            return nil
        }
        let merged = try AntigravityRefreshedCredentialMerger
            .merge(
                original: selectedContext.credentials,
                refreshed: refreshed,
                expectedIdentity: selectedContext.identity
            )
        return AntigravityRefreshCredentialMutation(
            accountID: selectedContext.accountID,
            expectedRevision: expectedRevision,
            original: selectedContext.credentials,
            refreshed: merged
        )
    }

    private nonisolated static func repositoryState(
        _ state: AntigravityAccountRepositoryState,
        matches target: AntigravityRefreshAccountTarget,
        revision: UInt64
    ) -> Bool {
        guard state.revision == revision else {
            return false
        }
        switch target {
        case .ambientLocal:
            return true
        case .selectedOAuth(let accountID):
            return state.activeAccountID == accountID
                && state.usableAccounts.contains {
                    $0.id == accountID
                }
        }
    }

    private nonisolated static func failureInvalidatesPrevious(
        _ failure: AntigravityFailure
    ) -> Bool {
        switch failure {
        case .appShuttingDown,
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
             .noEligibleSource,
             .sourceUnavailable,
             .authenticationRequired,
             .interactionRequired,
             .deadlineExceeded,
             .schemaChanged,
             .transportUnavailable,
             .sourceContractViolation,
             .numericQuotaUnavailable:
            false
        }
    }
}

private nonisolated struct AntigravitySelectedRefreshContext:
    Sendable
{
    let accountID: AntigravityAccountID
    let identity: ProviderAccountIdentity
    let credentials: AntigravityOAuthCredentials
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
