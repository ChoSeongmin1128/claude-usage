import Foundation

private nonisolated struct AntigravityRefreshFlightKey:
    Sendable,
    Equatable
{
    let connection: AntigravityConnectionSettings

    init(_ request: AntigravityRefreshRequest) {
        connection = request.connection
    }
}

private nonisolated enum AntigravityRefreshOutput:
    Sendable
{
    case snapshot(AntigravityQuotaSnapshot)
    case failure(AntigravityFailure)
}

actor AntigravityRefreshCoordinator:
    AntigravityRefreshCoordinating
{
    private struct InFlight {
        let id: UUID
        let startedAt: ContinuousClock.Instant
        let generation: UInt64
        let key: AntigravityRefreshFlightKey
        var driver: Task<Void, Never>?
        var waiters:
            [UUID:
                AntigravityRefreshOneShotWaiter<
                    AntigravityPresentationState
                >]
    }

    private let runtimeEnvironment: AntigravityRuntimeEnvironment?
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
        state = .refreshing(previous: lastGoodSnapshot)

        let operationID = UUID()
        let operationGeneration = generation
        let sources = self.sources
        let runtimeEnvironment = self.runtimeEnvironment
        let deadline = deadlineFactory()
        inFlight = InFlight(
            id: operationID,
            startedAt: ContinuousClock.now,
            generation: operationGeneration,
            key: key,
            driver: nil,
            waiters: [waiterID: waiter]
        )
        let driver = Task.detached(
            priority: .utility
        ) { [weak self] in
            let result = await Self.executeWithEnvironment(
                runtimeEnvironment: runtimeEnvironment,
                generation: operationGeneration,
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
        result: AntigravityRefreshOutput
    ) async {
        guard generation == operationGeneration,
            let operation = inFlight,
              operation.id == operationID
        else {
            return
        }
        let finalState = apply(
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
        _ output: AntigravityRefreshOutput,
        operation: InFlight
    ) -> AntigravityPresentationState {
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
        case .snapshot(let snapshot):
            lastGoodSnapshot = snapshot
            if snapshot.decodeIssues.isEmpty {
                return .ready(snapshot)
            }
            return .partial(
                snapshot,
                issues: snapshot.decodeIssues
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
        sources: [AntigravityUsageSourceID: any AntigravityUsageSource],
        deadline: AntigravityRPCDeadline
    ) async -> AntigravityRefreshOutput {
        guard let runtimeEnvironment else {
            return await execute(generation: generation, sources: sources, deadline: deadline)
        }
        do {
            return try await runtimeEnvironment.withSources(deadline: deadline) { localSources in
                var registry = sources
                for source in localSources { registry[source.id] = source }
                return await execute(
                    generation: generation, sources: registry, deadline: deadline.beginningDiscoveryNow())
            }
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.deadlineExceeded(.cliReport))
        }
    }

    /// 보고는 계정 정보 없이 한 번에 답하므로 묶음 한도가 있는 응답만 받는다.
    private nonisolated static func execute(
        generation: UInt64,
        sources: [AntigravityUsageSourceID: any AntigravityUsageSource],
        deadline: AntigravityRPCDeadline
    ) async -> AntigravityRefreshOutput {
        guard let source = sources[.cliReport] else {
            return .failure(.sourceUnavailable(.cliReport))
        }
        guard source.id == .cliReport else {
            return .failure(.sourceContractViolation(.cliReport))
        }
        let response: AntigravityUsageSourceResponse
        do {
            try Task.checkCancellation()
            response = try await source.fetch(.init(generation: generation, deadline: deadline))
            try Task.checkCancellation()
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(failure(error as? AntigravityUsageSourceError ?? .transportFailure))
        }
        let snapshot = response.snapshot
        guard snapshot.identity == nil, !snapshot.lanes.isEmpty,
            snapshot.provenance.accountIdentity == nil
        else {
            return .failure(.sourceContractViolation(.cliReport))
        }
        return .snapshot(snapshot)
    }

    private nonisolated static func failure(_ error: AntigravityUsageSourceError) -> AntigravityFailure {
        switch error {
        case .deadlineExceeded: .deadlineExceeded(.cliReport)
        case .malformedResponse: .schemaChanged(.cliReport)
        case .runtimeUnavailable(let reason): .runtimeUnavailable(reason)
        case .transportFailure: .transportUnavailable(.cliReport)
        case .reportFailed: .cliReportFailed
        case .cancelled: .cancelled
        }
    }

    private nonisolated static func failureInvalidatesPrevious(
        _ failure: AntigravityFailure
    ) -> Bool {
        switch failure {
        case .appShuttingDown,
            .invalidRefreshContext,
            .generationExhausted,
            .cliReportFailed:
            true
        case .cancelled,
            .sourceUnavailable,
            .deadlineExceeded,
            .schemaChanged,
            .transportUnavailable,
            .sourceContractViolation,
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
