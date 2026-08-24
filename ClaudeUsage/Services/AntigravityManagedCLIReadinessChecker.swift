import Foundation

nonisolated protocol AntigravityManagedRuntimeDiscovering: Sendable {
    func discover(
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityRuntimeDiscoverySnapshot

    func invalidateCache() async
}

extension AntigravityRuntimeDiscovery:
    AntigravityManagedRuntimeDiscovering {}

nonisolated struct AntigravityManagedCLIReadinessResult:
    Sendable,
    Equatable
{
    let runtime: AntigravityManagedRuntime
    let diagnostics: AntigravityManagedSessionDiagnostics
}

nonisolated protocol AntigravityManagedCLIReadinessChecking: Sendable {
    func waitUntilReady(
        handle: any AntigravityManagedCLIProcessHandling,
        processIdentity: AntigravityVerifiedProcessIdentity,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityManagedCLIReadinessResult
}

nonisolated protocol AntigravityManagedCLIRPCReadinessProbing:
    Sendable
{
    func probe(
        _ runtime: AntigravityManagedRuntime,
        deadline: AntigravityRPCDeadline
    ) async throws
}

/// The managed AGY listener answered its RPC with HTTP 200, but the response
/// is not yet authentication evidence. Both states are retryable within the
/// launch budget, not fatal launch failures, and they stay distinct so a
/// readiness timeout can be attributed to the right cause.
nonisolated enum AntigravityManagedCLIRPCReadinessProbeError:
    Error,
    Equatable
{
    /// The response decoded, but carries no account identity yet because
    /// AGY's asynchronous keyring authentication has not completed.
    case authenticationPending
    /// The response body does not carry a decodable `userStatus` envelope.
    /// AGY can answer with such bodies inside its bootstrap window; a body
    /// that stays malformed until the deadline indicates an upstream shape
    /// change rather than a signed-out session.
    case malformedUserStatus
}

/// Confirms that the newly discovered AGY listener has completed its local RPC
/// initialization and restored an authenticated account session. A bound port
/// is necessary discovery evidence, but is not sufficient readiness evidence:
/// AGY answers `GetUserStatus` with HTTP 200 before its asynchronous keyring
/// authentication completes, and quota RPCs against that window fail.
nonisolated struct AntigravityManagedCLIRPCReadinessProbe:
    AntigravityManagedCLIRPCReadinessProbing
{
    private let connectionFactory:
        any AntigravityLocalRPCConnectionFactory

    init(
        connectionFactory:
            any AntigravityLocalRPCConnectionFactory
    ) {
        self.connectionFactory = connectionFactory
    }

    func probe(
        _ runtime: AntigravityManagedRuntime,
        deadline: AntigravityRPCDeadline
    ) async throws {
        let connection = try connectionFactory.makeConnection(
            endpoint: runtime.endpoint
        )
        defer { connection.invalidate() }

        let response = try await connection.perform(
            .getUserStatus,
            deadline: deadline
        )
        try AntigravityLocalRPCResponseValidator.validate(response)

        // A validated 200 alone is not authentication evidence. Until the
        // response carries a decoded account identity, report a retryable
        // pending state so the readiness loop keeps polling within its
        // budget. A genuinely signed-out CLI is detected separately through
        // its blocking login prompt on the managed PTY.
        switch AntigravityUserStatusAuthenticationEvidence.classify(
            response.body
        ) {
        case .authenticated:
            return
        case .authenticationPending:
            throw AntigravityManagedCLIRPCReadinessProbeError
                .authenticationPending
        case .malformed:
            throw AntigravityManagedCLIRPCReadinessProbeError
                .malformedUserStatus
        }
    }
}

/// Uses PTY output to detect blocking user interaction and AGY's authoritative
/// HTTPS listener announcement. Runtime readiness still requires Stage 4's
/// exact process/port discovery plus a validated RPC response from that exact
/// endpoint; text output alone never establishes ownership or readiness.
nonisolated struct AntigravityManagedCLIReadinessChecker:
    AntigravityManagedCLIReadinessChecking
{
    private let discovery: any AntigravityManagedRuntimeDiscovering
    private let processInspector: any AntigravityRuntimeProcessInspecting
    private let rpcProbe:
        any AntigravityManagedCLIRPCReadinessProbing
    private let pollInterval: Duration
    private let maximumDrainBytes: Int
    private let sleep:
        @Sendable (Duration) async throws -> Void

    init(
        discovery: any AntigravityManagedRuntimeDiscovering,
        processInspector: any AntigravityRuntimeProcessInspecting,
        rpcProbe:
            any AntigravityManagedCLIRPCReadinessProbing,
        pollInterval: Duration = .milliseconds(100),
        maximumDrainBytes: Int = 4 * 1_024,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        precondition(pollInterval >= .zero)
        precondition(maximumDrainBytes > 0)
        self.discovery = discovery
        self.processInspector = processInspector
        self.rpcProbe = rpcProbe
        self.pollInterval = pollInterval
        self.maximumDrainBytes = maximumDrainBytes
        self.sleep = sleep
    }

    func waitUntilReady(
        handle: any AntigravityManagedCLIProcessHandling,
        processIdentity: AntigravityVerifiedProcessIdentity,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityManagedCLIReadinessResult {
        guard handle.processID == processIdentity.processID,
              handle.processGroupID == processIdentity.processID,
              processIdentity.executable.role == .agyCLI else {
            throw AntigravityManagedSessionError.processIdentityUnavailable
        }

        let outputMonitor =
            AntigravityManagedCLIOutputMonitor(
                handle: handle,
                maximumDrainBytes: maximumDrainBytes
            )
        let drainTask = Task {
            while !Task.isCancelled {
                outputMonitor.drain()
                do {
                    try await Task.sleep(
                        for: .milliseconds(20)
                    )
                } catch {
                    return
                }
            }
        }
        defer { drainTask.cancel() }

        // Attribution for an exhausted readiness budget: when the verified
        // endpoint kept answering without authentication evidence, the
        // timeout is an authentication problem the user must resolve, not
        // launch infrastructure slowness.
        var authenticationStayedPending = false
        func budgetExhaustedError() -> AntigravityManagedSessionError {
            authenticationStayedPending
                ? .interactionRequired(.loginRequired)
                : .readinessTimedOut
        }

        while true {
            do {
                try deadline.check(.request)
            } catch is CancellationError {
                throw AntigravityManagedSessionError.cancelled
            } catch {
                throw budgetExhaustedError()
            }

            outputMonitor.drain()
            let beforeDiscovery = outputMonitor.snapshot()
            if let interaction = firstInteraction(
                in: beforeDiscovery.interactions
            ) {
                throw AntigravityManagedSessionError
                    .interactionRequired(interaction)
            }
            if let status = handle.terminationStatus() {
                throw AntigravityManagedSessionError
                    .processExited(status)
            }

            await discovery.invalidateCache()

            let snapshot: AntigravityRuntimeDiscoverySnapshot?
            do {
                let attemptBudget = min(
                    deadline.remaining,
                    AntigravityRPCDeadline.maximumDiscoveryTimeout
                )
                guard attemptBudget > .zero else {
                    throw AntigravityManagedSessionError
                        .readinessTimedOut
                }
                snapshot = try await discovery.discover(
                    deadline: AntigravityRPCDeadline(
                        totalTimeout: attemptBudget,
                        discoveryTimeout: attemptBudget
                    )
                )
            } catch is CancellationError {
                throw AntigravityManagedSessionError.cancelled
            } catch {
                snapshot = nil
            }

            outputMonitor.drain()
            let afterDiscovery = outputMonitor.snapshot()
            if let interaction = firstInteraction(
                in: afterDiscovery.interactions
            ) {
                throw AntigravityManagedSessionError
                    .interactionRequired(interaction)
            }
            if let status = handle.terminationStatus() {
                throw AntigravityManagedSessionError
                    .processExited(status)
            }

            let discoveredEndpoints =
                snapshot?.endpoints.filter {
                    $0.processIdentity == processIdentity
                        && $0.transport == .agyCLI
                        && $0.ownership == .managed
                        && $0.authentication == .cliTokenless
                } ?? []
            let endpoints = prioritizedEndpoints(
                discoveredEndpoints,
                announcedPort:
                    afterDiscovery
                        .announcedLocalServerPort
            )
            if !endpoints.isEmpty,
               await processInspector.revalidate(processIdentity)
            {
                for endpoint in endpoints {
                    guard let runtime = AntigravityManagedRuntime(
                        processIdentity: processIdentity,
                        endpoint: endpoint
                    ) else {
                        continue
                    }
                    endpointProbe: while true {
                        do {
                            try deadline.check(.request)
                        } catch is CancellationError {
                            throw AntigravityManagedSessionError
                                .cancelled
                        } catch {
                            throw budgetExhaustedError()
                        }

                        do {
                            try await rpcProbe.probe(
                                runtime,
                                deadline: deadline
                            )

                            outputMonitor.drain()
                            let afterProbe =
                                outputMonitor.snapshot()
                            if let interaction = firstInteraction(
                                in: afterProbe.interactions
                            ) {
                                throw AntigravityManagedSessionError
                                    .interactionRequired(interaction)
                            }
                            if let status = handle.terminationStatus() {
                                throw AntigravityManagedSessionError
                                    .processExited(status)
                            }
                            guard await processInspector.revalidate(
                                processIdentity
                            ) else {
                                throw AntigravityLocalRPCError
                                    .endpointOwnershipChanged
                            }

                            return AntigravityManagedCLIReadinessResult(
                                runtime: runtime,
                                diagnostics:
                                    AntigravityManagedSessionDiagnostics(
                                        interactions:
                                            afterProbe.interactions,
                                        outputWasTruncated:
                                            afterProbe
                                                .outputWasTruncated
                                    )
                            )
                        } catch is CancellationError {
                            throw AntigravityManagedSessionError.cancelled
                        } catch AntigravityLocalRPCError.cancelled {
                            throw AntigravityManagedSessionError.cancelled
                        } catch let error
                            as AntigravityManagedSessionError
                        {
                            throw error
                        } catch let error
                            as AntigravityManagedCLIRPCReadinessProbeError
                        {
                            // The listener already passed process, port and
                            // response validation; it only lacks
                            // authentication evidence. Keep polling this
                            // exact endpoint instead of paying cache
                            // invalidation and ps/lsof rediscovery on every
                            // attempt.
                            authenticationStayedPending =
                                error == .authenticationPending
                            outputMonitor.drain()
                            let pendingSnapshot = outputMonitor.snapshot()
                            if let interaction = firstInteraction(
                                in: pendingSnapshot.interactions
                            ) {
                                throw AntigravityManagedSessionError
                                    .interactionRequired(interaction)
                            }
                            if let status = handle.terminationStatus() {
                                throw AntigravityManagedSessionError
                                    .processExited(status)
                            }
                            guard await processInspector.revalidate(
                                processIdentity
                            ) else {
                                break endpointProbe
                            }
                            do {
                                try await sleep(
                                    min(pollInterval, deadline.remaining)
                                )
                            } catch is CancellationError {
                                throw AntigravityManagedSessionError
                                    .cancelled
                            } catch {
                                throw AntigravityManagedSessionError
                                    .endpointUnavailable
                            }
                        } catch {
                            // AGY can own multiple loopback listeners, and a
                            // listener may bind before its RPC service is
                            // ready. Try every endpoint owned by this exact
                            // process, then rediscover within the monotonic
                            // readiness budget.
                            break endpointProbe
                        }
                    }
                }
            }

            do {
                try await sleep(
                    min(pollInterval, deadline.remaining)
                )
            } catch is CancellationError {
                throw AntigravityManagedSessionError.cancelled
            } catch {
                throw AntigravityManagedSessionError.endpointUnavailable
            }
        }
    }

    private func prioritizedEndpoints(
        _ endpoints:
            [AntigravityVerifiedRuntimeEndpoint],
        announcedPort: AntigravityTCPPort?
    ) -> [AntigravityVerifiedRuntimeEndpoint] {
        if let announcedPort {
            // A managed AGY process can own both its TLS quota server and
            // unrelated plaintext listeners. Once AGY announces the quota
            // server, probing any other listener as TLS is both noisy and
            // unsafe. Keep waiting for the announced listener to become
            // ready instead of falling through to sibling ports.
            return endpoints.filter {
                $0.port == announcedPort
            }
        }

        // A single exact process-owned listener is unambiguous. With multiple
        // listeners, wait for the managed PTY announcement rather than
        // guessing which protocol each port serves.
        return endpoints.count == 1 ? endpoints : []
    }

    private func firstInteraction(
        in interactions: Set<AntigravityManagedCLIInteraction>
    ) -> AntigravityManagedCLIInteraction? {
        let priority: [AntigravityManagedCLIInteraction] = [
            .projectTrustRequired,
            .loginRequired,
            .browserAuthenticationRequired,
        ]
        return priority.first(where: interactions.contains)
    }
}

/// Continuously drains the owned PTY while readiness performs network I/O.
///
/// AGY's supported bootstrap log can be verbose enough to fill the PTY buffer.
/// If the reader pauses during TLS setup, the child can block in `write(2)` and
/// stop servicing the very RPC request used to prove readiness. This monitor
/// retains only the classifier's bounded typed state; raw terminal output is
/// never exposed to callers or logs.
private nonisolated final class AntigravityManagedCLIOutputMonitor:
    @unchecked Sendable
{
    struct Snapshot: Sendable {
        let interactions:
            Set<AntigravityManagedCLIInteraction>
        let announcedLocalServerPort:
            AntigravityTCPPort?
        let outputWasTruncated: Bool
    }

    private let handle:
        any AntigravityManagedCLIProcessHandling
    private let maximumDrainBytes: Int
    private let lock = NSLock()
    private var classifier =
        AntigravityManagedCLIOutputClassifier()

    init(
        handle: any AntigravityManagedCLIProcessHandling,
        maximumDrainBytes: Int
    ) {
        precondition(maximumDrainBytes > 0)
        self.handle = handle
        self.maximumDrainBytes = maximumDrainBytes
    }

    func drain() {
        lock.withLock {
            let drained = handle.drainOutput(
                maximumBytes: maximumDrainBytes
            )
            guard !drained.isEmpty else { return }
            _ = classifier.ingest(drained)
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                interactions: classifier.interactions,
                announcedLocalServerPort:
                    classifier
                        .announcedLocalServerPort,
                outputWasTruncated:
                    classifier.outputWasTruncated
            )
        }
    }
}
