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

/// Confirms that the newly discovered AGY listener has completed its local RPC
/// initialization. A bound port is necessary discovery evidence, but is not
/// sufficient readiness evidence.
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
    }
}

/// Uses PTY output only to detect blocking user interaction or early exit.
/// Runtime readiness requires both Stage 4's exact process/port discovery and
/// a validated RPC response from that exact endpoint.
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

        var classifier = AntigravityManagedCLIOutputClassifier()
        var interactions = Set<AntigravityManagedCLIInteraction>()

        while true {
            do {
                try deadline.check(.request)
            } catch is CancellationError {
                throw AntigravityManagedSessionError.cancelled
            } catch {
                throw AntigravityManagedSessionError.readinessTimedOut
            }

            let beforeDiscovery = consumeOutput(
                from: handle,
                classifier: &classifier,
                interactions: &interactions
            )
            if let interaction = firstInteraction(
                in: beforeDiscovery
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

            let afterDiscovery = consumeOutput(
                from: handle,
                classifier: &classifier,
                interactions: &interactions
            )
            if let interaction = firstInteraction(
                in: afterDiscovery
            ) {
                throw AntigravityManagedSessionError
                    .interactionRequired(interaction)
            }
            if let status = handle.terminationStatus() {
                throw AntigravityManagedSessionError
                    .processExited(status)
            }

            if let endpoint = snapshot?.endpoints.first(
                where: {
                    $0.processIdentity == processIdentity
                        && $0.transport == .agyCLI
                        && $0.ownership == .managed
                        && $0.authentication == .cliTokenless
                }
            ),
            await processInspector.revalidate(processIdentity),
            let runtime = AntigravityManagedRuntime(
                processIdentity: processIdentity,
                endpoint: endpoint
            ) {
                do {
                    try await rpcProbe.probe(
                        runtime,
                        deadline: deadline
                    )

                    let afterProbe = consumeOutput(
                        from: handle,
                        classifier: &classifier,
                        interactions: &interactions
                    )
                    if let interaction = firstInteraction(
                        in: afterProbe
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
                        diagnostics: AntigravityManagedSessionDiagnostics(
                            interactions: interactions,
                            outputWasTruncated:
                                classifier.outputWasTruncated
                        )
                    )
                } catch is CancellationError {
                    throw AntigravityManagedSessionError.cancelled
                } catch AntigravityLocalRPCError.cancelled {
                    throw AntigravityManagedSessionError.cancelled
                } catch let error as AntigravityManagedSessionError {
                    throw error
                } catch {
                    // A listener may bind before AGY finishes initializing its
                    // RPC service. Keep draining the PTY and retry within the
                    // original monotonic readiness budget.
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

    private func consumeOutput(
        from handle: any AntigravityManagedCLIProcessHandling,
        classifier: inout AntigravityManagedCLIOutputClassifier,
        interactions: inout Set<AntigravityManagedCLIInteraction>
    ) -> Set<AntigravityManagedCLIInteraction> {
        let drained = handle.drainOutput(
            maximumBytes: maximumDrainBytes
        )
        guard !drained.isEmpty else { return [] }
        let newlyObserved = classifier.ingest(drained)
        interactions.formUnion(newlyObserved)
        return newlyObserved
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
