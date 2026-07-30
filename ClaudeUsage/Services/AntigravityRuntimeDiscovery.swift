import Foundation

actor AntigravityRuntimeDiscovery {
    private struct InFlight {
        let id: UUID
        let task: Task<AntigravityRuntimeDiscoverySnapshot, Error>
        var waiters: Set<UUID>
    }

    private let processInspector: any AntigravityRuntimeProcessInspecting
    private let portInspector: any AntigravityPortOwnershipInspecting
    private let installations: [AntigravityCanonicalExecutable]
    private let now: @Sendable () -> Date

    /// Only endpoint-bearing snapshots are cached. Empty and non-queryable
    /// observations are intentionally rediscovered on the next call.
    private var positiveCache: AntigravityRuntimeDiscoverySnapshot?
    private var inFlight: InFlight?

    init(
        processInspector: any AntigravityRuntimeProcessInspecting,
        portInspector: any AntigravityPortOwnershipInspecting,
        installations: [AntigravityCanonicalExecutable],
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.processInspector = processInspector
        self.portInspector = portInspector
        self.installations = installations
        self.now = now
    }

    func discover(
        deadline: AntigravityRPCDeadline = AntigravityRPCDeadline()
    ) async throws -> AntigravityRuntimeDiscoverySnapshot {
        try deadline.check(.discovery)

        let waiterID = UUID()
        let operation: InFlight
        if var existing = inFlight {
            existing.waiters.insert(waiterID)
            inFlight = existing
            operation = existing
        } else {
            let operationID = UUID()
            let processInspector = self.processInspector
            let portInspector = self.portInspector
            let installations = self.installations
            let cached = self.positiveCache
            let now = self.now
            let operationDeadline = AntigravityRPCDeadline(
                totalTimeout: .seconds(2),
                discoveryTimeout: .seconds(2)
            )

            let task = Task.detached(priority: .utility) {
                try await Self.resolveSnapshot(
                    cached: cached,
                    processInspector: processInspector,
                    portInspector: portInspector,
                    installations: installations,
                    deadline: operationDeadline,
                    now: now
                )
            }
            let created = InFlight(
                id: operationID,
                task: task,
                waiters: [waiterID]
            )
            inFlight = created
            operation = created
        }

        let waiter = AntigravityDiscoveryTaskWaiter()
        do {
            let snapshot = try await waiter.value(
                of: operation.task,
                deadline: deadline
            )
            finishSuccessfulOperation(
                operationID: operation.id,
                waiterID: waiterID,
                snapshot: snapshot
            )
            return snapshot
        } catch {
            finishFailedOrCancelledWaiter(
                operationID: operation.id,
                waiterID: waiterID,
                error: error
            )
            throw error
        }
    }

    func invalidateCache() {
        positiveCache = nil
    }

    private func finishSuccessfulOperation(
        operationID: UUID,
        waiterID: UUID,
        snapshot: AntigravityRuntimeDiscoverySnapshot
    ) {
        guard var operation = inFlight,
              operation.id == operationID else {
            return
        }
        positiveCache = snapshot.endpoints.isEmpty ? nil : snapshot
        operation.waiters.remove(waiterID)
        inFlight = operation.waiters.isEmpty ? nil : operation
    }

    private func finishFailedOrCancelledWaiter(
        operationID: UUID,
        waiterID: UUID,
        error: Error
    ) {
        guard var operation = inFlight,
              operation.id == operationID else {
            return
        }

        if error is CancellationError
            || error is AntigravityRPCDeadlineError
        {
            operation.waiters.remove(waiterID)
            if operation.waiters.isEmpty {
                operation.task.cancel()
                inFlight = nil
            } else {
                inFlight = operation
            }
        } else {
            // A security revalidation failure must never fall back to the
            // previous snapshot.
            positiveCache = nil
            operation.task.cancel()
            inFlight = nil
        }
    }

    private nonisolated static func resolveSnapshot(
        cached: AntigravityRuntimeDiscoverySnapshot?,
        processInspector: any AntigravityRuntimeProcessInspecting,
        portInspector: any AntigravityPortOwnershipInspecting,
        installations: [AntigravityCanonicalExecutable],
        deadline: AntigravityRPCDeadline,
        now: @escaping @Sendable () -> Date
    ) async throws -> AntigravityRuntimeDiscoverySnapshot {
        if let cached,
           try await revalidate(
               cached,
               processInspector: processInspector,
               portInspector: portInspector,
               deadline: deadline
           ) {
            return cached
        }

        return try await discoverFresh(
            processInspector: processInspector,
            portInspector: portInspector,
            installations: installations,
            deadline: deadline,
            now: now
        )
    }

    private nonisolated static func discoverFresh(
        processInspector: any AntigravityRuntimeProcessInspecting,
        portInspector: any AntigravityPortOwnershipInspecting,
        installations: [AntigravityCanonicalExecutable],
        deadline: AntigravityRPCDeadline,
        now: @escaping @Sendable () -> Date
    ) async throws -> AntigravityRuntimeDiscoverySnapshot {
        let processTimeout = try deadline.timeInterval(for: .discovery)
        let discovered = try await processInspector.discoverProcesses(
            timeout: processTimeout
        )
        try deadline.check(.discovery)

        guard !discovered.isEmpty else {
            return AntigravityRuntimeDiscoverySnapshot(
                installations: installations,
                processes: [],
                endpoints: [],
                observedAt: now()
            )
        }

        let processIDs = Set(
            discovered.map(\.processIdentity.processID)
        )
        let portTimeout = try deadline.timeInterval(for: .discovery)
        let endpointsByProcess = try await portInspector.listeningEndpoints(
            ownedBy: processIDs,
            timeout: portTimeout
        )
        try deadline.check(.discovery)

        let stillValid = await revalidatedCandidates(
            discovered,
            processInspector: processInspector
        )
        try deadline.check(.discovery)

        let endpoints = endpoints(
            for: stillValid,
            listeningEndpointsByProcess: endpointsByProcess
        )
        return AntigravityRuntimeDiscoverySnapshot(
            installations: installations,
            processes: stillValid,
            endpoints: endpoints,
            observedAt: now()
        )
    }

    private nonisolated static func revalidate(
        _ snapshot: AntigravityRuntimeDiscoverySnapshot,
        processInspector: any AntigravityRuntimeProcessInspecting,
        portInspector: any AntigravityPortOwnershipInspecting,
        deadline: AntigravityRPCDeadline
    ) async throws -> Bool {
        guard !snapshot.endpoints.isEmpty else {
            return false
        }

        let beforePortCheck = await revalidatedCandidates(
            snapshot.processes,
            processInspector: processInspector
        )
        guard beforePortCheck.count == snapshot.processes.count else {
            return false
        }
        try deadline.check(.discovery)

        let processIDs = Set(
            beforePortCheck.map(\.processIdentity.processID)
        )
        let endpointsByProcess = try await portInspector.listeningEndpoints(
            ownedBy: processIDs,
            timeout: try deadline.timeInterval(for: .discovery)
        )
        try deadline.check(.discovery)

        let afterPortCheck = await revalidatedCandidates(
            beforePortCheck,
            processInspector: processInspector
        )
        guard afterPortCheck.count == beforePortCheck.count else {
            return false
        }
        try deadline.check(.discovery)

        let endpoints = endpoints(
            for: afterPortCheck,
            listeningEndpointsByProcess: endpointsByProcess
        )
        return endpoints == snapshot.endpoints
    }

    private nonisolated static func revalidatedCandidates(
        _ candidates: [AntigravityRuntimeProcessCandidate],
        processInspector: any AntigravityRuntimeProcessInspecting
    ) async -> [AntigravityRuntimeProcessCandidate] {
        var valid: [AntigravityRuntimeProcessCandidate] = []
        for candidate in candidates {
            if Task.isCancelled {
                return []
            }
            if let revalidated = await processInspector.revalidate(candidate) {
                valid.append(revalidated)
            }
        }
        return valid
    }

    private nonisolated static func endpoints(
        for candidates: [AntigravityRuntimeProcessCandidate],
        listeningEndpointsByProcess:
            [Int32: Set<AntigravityOwnedListeningEndpoint>]
    ) -> [AntigravityVerifiedRuntimeEndpoint] {
        candidates.flatMap { candidate in
            let ownedEndpoints =
                listeningEndpointsByProcess[
                    candidate.processIdentity.processID
                ] ?? []
            return candidateEndpoints(
                for: candidate,
                ownedEndpoints: ownedEndpoints
            ).compactMap {
                listeningEndpoint
                    -> AntigravityVerifiedRuntimeEndpoint? in
                let authentication:
                    AntigravityRuntimeEndpointAuthentication
                switch candidate.transport {
                case .antigravityApp:
                    guard let token =
                            candidate.connectionHints.csrfToken
                    else {
                        return nil
                    }
                    authentication = .appCSRF(token)
                case .agyCLI:
                    authentication = .cliTokenless
                }

                return AntigravityVerifiedRuntimeEndpoint(
                    processIdentity: candidate.processIdentity,
                    host: listeningEndpoint.host,
                    port: listeningEndpoint.port,
                    transport: candidate.transport,
                    ownership: candidate.ownership,
                    authentication: authentication
                )
            }
        }
        .sorted {
            if $0.transport != $1.transport {
                return $0.transport.rawValue < $1.transport.rawValue
            }
            if $0.processIdentity.processID != $1.processIdentity.processID {
                return $0.processIdentity.processID
                    < $1.processIdentity.processID
            }
            return $0.port.rawValue < $1.port.rawValue
        }
    }

    /// AGY does not publish its quota-server port on the command line and
    /// currently owns more than one loopback listener. Every candidate still
    /// belongs to the exact verified process; the RPC readiness probe selects
    /// the listener that implements the expected API. App endpoints keep the
    /// stricter single hinted-port contract because they also carry CSRF
    /// authentication.
    private nonisolated static func candidateEndpoints(
        for candidate: AntigravityRuntimeProcessCandidate,
        ownedEndpoints: Set<AntigravityOwnedListeningEndpoint>
    ) -> [AntigravityOwnedListeningEndpoint] {
        if candidate.transport == .agyCLI,
           candidate.connectionHints.requestedPort == nil {
            return ownedEndpoints
                .filter { $0.host == .ipv4 }
                .sorted {
                    $0.port.rawValue < $1.port.rawValue
                }
        }

        guard case .selected(let endpoint) =
                AntigravityPortOwnershipInspector.resolvePort(
                    requestedPort:
                        candidate.connectionHints.requestedPort,
                    ownedEndpoints: ownedEndpoints
                )
        else {
            return []
        }
        return [endpoint]
    }
}

private nonisolated final class AntigravityDiscoveryTaskWaiter:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<AntigravityRuntimeDiscoverySnapshot, Error>?
    private var result: Result<AntigravityRuntimeDiscoverySnapshot, Error>?

    func value(
        of task: Task<AntigravityRuntimeDiscoverySnapshot, Error>,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityRuntimeDiscoverySnapshot {
        let timeout = try deadline.timeout(for: .discovery)
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                self?.finish(with: .failure(
                    AntigravityRPCDeadlineError.timedOut(.discovery)
                ))
            } catch {
                // Shared discovery or caller cancellation completed first.
            }
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation)
                Task.detached(priority: .utility) {
                    self.finish(with: await task.result)
                }
            }
        } onCancel: {
            finish(with: .failure(CancellationError()))
        }
    }

    private func install(
        _ continuation:
            CheckedContinuation<AntigravityRuntimeDiscoverySnapshot, Error>
    ) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func finish(
        with result: Result<AntigravityRuntimeDiscoverySnapshot, Error>
    ) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: result)
    }
}
