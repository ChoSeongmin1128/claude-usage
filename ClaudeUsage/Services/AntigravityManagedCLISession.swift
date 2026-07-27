import Darwin
import Foundation

private nonisolated struct AntigravityManagedCLIStartedProcess:
    Sendable
{
    let sessionID: UUID
    let handle: any AntigravityManagedCLIProcessHandling
    let runtime: AntigravityManagedRuntime
    let diagnostics: AntigravityManagedSessionDiagnostics
    let removedPendingRecordIDs: Set<UUID>
}

private nonisolated struct AntigravityManagedCLIPreparedProcess:
    Sendable
{
    let sessionID: UUID
    let handle: any AntigravityManagedCLIProcessHandling
    let processIdentity: AntigravityVerifiedProcessIdentity
}

/// Owns only AGY processes launched by this object. Borrowed and external
/// runtime candidates never cross this boundary and therefore cannot be
/// signalled by reset, cancellation, idle teardown, or app shutdown.
actor AntigravityManagedCLISession {
    private struct Starting {
        let generation: UInt64
        let executable: AntigravityCanonicalExecutable
        let idleTimeout: Duration
        let task: Task<AntigravityManagedCLIStartedProcess, Error>
        var waiters: Set<UUID>
    }

    private struct Running {
        let generation: UInt64
        let sessionID: UUID
        let handle: any AntigravityManagedCLIProcessHandling
        let runtime: AntigravityManagedRuntime
        var diagnostics: AntigravityManagedSessionDiagnostics
        var idleTimeout: Duration
        var leases: Set<UUID>
        var pendingAcquisitions: Set<UUID>
        var pendingReset: AntigravityManagedSessionResetReason?
        var outputMonitor: Task<Void, Never>?
        var processTreeMonitor: Task<Void, Never>?
    }

    private enum State {
        case stopped
        case starting(Starting)
        case running(Running)
    }

    private let launcher: any AntigravityManagedCLIProcessLaunching
    private let executableRevalidator:
        any AntigravityExecutableRevalidating
    private let identityProvider:
        any AntigravityManagedProcessIdentityProviding
    private let recordStore:
        any AntigravityManagedProcessLedgerStoring
    private let launchCoordinator:
        any AntigravityManagedLaunchCoordinating
    private let recovery:
        any AntigravityManagedSessionLifecycleRecovering
    private let processTreeController:
        any AntigravityManagedProcessTreeControlling
    private let registry: any AntigravityManagedRuntimeRegistering
    private let readinessChecker:
        any AntigravityManagedCLIReadinessChecking
    private let environment: AntigravityManagedCLIEnvironment
    private let currentDirectoryURL: URL
    private let now: @Sendable () -> Date
    private let idleSleep:
        @Sendable (Duration) async throws -> Void
    private let monitorInterval: Duration
    private let monitorSleep:
        @Sendable (Duration) async throws -> Void
    private let processObservationInterval: Duration
    private let processObservationSleep:
        @Sendable (Duration) async throws -> Void
    private let terminationGracePeriod: Duration
    private let cleanupCoordinationTimeout: Duration
    private let recoveryCoordinationTimeout: Duration

    private var state: State = .stopped
    private var generation: UInt64 = 0
    private var idleTask: Task<Void, Never>?
    private var shuttingDown = false
    private var externallyCleaningStartingGenerations = Set<UInt64>()
    private var pendingRecordRemovalIDs = Set<UUID>()
    private var activeCleanupCount = 0
    private var cleanupWaiters:
        [CheckedContinuation<Void, Never>] = []

    init(
        launcher: any AntigravityManagedCLIProcessLaunching,
        executableRevalidator:
            any AntigravityExecutableRevalidating,
        identityProvider:
            any AntigravityManagedProcessIdentityProviding,
        recordStore:
            any AntigravityManagedProcessLedgerStoring,
        launchCoordinator:
            any AntigravityManagedLaunchCoordinating =
                AntigravityManagedLaunchFileCoordinator(),
        recovery:
            any AntigravityManagedSessionLifecycleRecovering,
        processTreeController:
            (any AntigravityManagedProcessTreeControlling)? = nil,
        registry: any AntigravityManagedRuntimeRegistering,
        readinessChecker:
            any AntigravityManagedCLIReadinessChecking,
        environment: AntigravityManagedCLIEnvironment =
            AntigravityManagedCLIEnvironment(),
        currentDirectoryURL: URL =
            FileManager.default.realHomeDirectory,
        now: @escaping @Sendable () -> Date = Date.init,
        idleSleep:
            @escaping @Sendable (Duration) async throws -> Void = {
                try await Task.sleep(for: $0)
            },
        monitorInterval: Duration = .milliseconds(100),
        monitorSleep:
            @escaping @Sendable (Duration) async throws -> Void = {
                try await Task.sleep(for: $0)
            },
        processObservationInterval: Duration = .seconds(1),
        processObservationSleep:
            @escaping @Sendable (Duration) async throws -> Void = {
                try await Task.sleep(for: $0)
            },
        terminationGracePeriod: Duration = .milliseconds(250),
        cleanupCoordinationTimeout: Duration = .seconds(1),
        recoveryCoordinationTimeout: Duration = .seconds(2)
    ) {
        precondition(monitorInterval > .zero)
        precondition(processObservationInterval > .zero)
        precondition(cleanupCoordinationTimeout > .zero)
        precondition(recoveryCoordinationTimeout > .zero)
        self.launcher = launcher
        self.executableRevalidator = executableRevalidator
        self.identityProvider = identityProvider
        self.recordStore = recordStore
        self.launchCoordinator = launchCoordinator
        self.recovery = recovery
        if let processTreeController {
            self.processTreeController = processTreeController
        } else {
            let recordedInspector =
                AntigravitySystemRecordedProcessInspector(
                    identityProvider: identityProvider
                )
            self.processTreeController =
                AntigravityManagedProcessTreeController(
                    recordStore: recordStore,
                    processInspector: recordedInspector,
                    processTreeInspector:
                        AntigravitySystemManagedProcessTreeInspector(
                            identityProvider: identityProvider
                        )
                )
        }
        self.registry = registry
        self.readinessChecker = readinessChecker
        self.environment = environment
        self.currentDirectoryURL =
            currentDirectoryURL.standardizedFileURL
        self.now = now
        self.idleSleep = idleSleep
        self.monitorInterval = monitorInterval
        self.monitorSleep = monitorSleep
        self.processObservationInterval =
            processObservationInterval
        self.processObservationSleep =
            processObservationSleep
        self.terminationGracePeriod = terminationGracePeriod
        self.cleanupCoordinationTimeout =
            cleanupCoordinationTimeout
        self.recoveryCoordinationTimeout =
            recoveryCoordinationTimeout
    }

    func withRuntime<T: Sendable>(
        authorization: AntigravityManagedLaunchAuthorization,
        executable: AntigravityCanonicalExecutable,
        deadline: AntigravityRPCDeadline,
        operation:
            @Sendable (AntigravityManagedRuntime) async throws -> T
    ) async throws -> T {
        let leaseID = UUID()
        let runtime = try await acquire(
            leaseID: leaseID,
            authorization: authorization,
            executable: executable,
            deadline: deadline
        )

        do {
            try Self.checkRequestIsActive(deadline)
            let result = try await operation(runtime)
            await release(leaseID: leaseID)
            return result
        } catch {
            await release(leaseID: leaseID)
            throw error
        }
    }

    func recoverOrphanedProcesses() async throws {
        guard !shuttingDown else {
            throw AntigravityManagedSessionError.appShuttingDown
        }
        let deadline = AntigravityRPCDeadline(
            totalTimeout: recoveryCoordinationTimeout,
            discoveryTimeout: .zero
        )
        do {
            try await launchCoordinator.withExclusiveLaunch(
                deadline: deadline
            ) {
                try await recovery.recoverOrphanedProcesses()
            }
        } catch is CancellationError {
            throw AntigravityManagedSessionError.cancelled
        } catch is AntigravityRPCDeadlineError {
            throw AntigravityManagedSessionError
                .launchCoordinationUnavailable
        } catch is AntigravityManagedLaunchCoordinatorError {
            throw AntigravityManagedSessionError
                .launchCoordinationUnavailable
        } catch {
            throw error
        }
    }

    func reset(
        reason: AntigravityManagedSessionResetReason
    ) async {
        idleTask?.cancel()
        idleTask = nil

        switch state {
        case .stopped:
            await waitForActiveCleanups()
            return
        case .starting(let starting):
            externallyCleaningStartingGenerations.insert(
                starting.generation
            )
            starting.task.cancel()
            state = .stopped
            beginCleanup()
            defer { finishCleanup() }
            if case .success(let started) = await starting.task.result {
                await cleanUp(started)
            }
        case .running(var running):
            guard running.leases.isEmpty
                    || reason == .appShutdown else {
                running.pendingReset = reason
                state = .running(running)
                return
            }
            state = .stopped
            await cleanUp(running)
        }
    }

    func shutdown() async {
        guard !shuttingDown else {
            await waitForActiveCleanups()
            return
        }
        shuttingDown = true
        await reset(reason: .appShutdown)
        await waitForActiveCleanups()
    }

    private func acquire(
        leaseID: UUID,
        authorization: AntigravityManagedLaunchAuthorization,
        executable: AntigravityCanonicalExecutable,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityManagedRuntime {
        try Self.checkRequestIsActive(deadline)
        guard !shuttingDown else {
            throw AntigravityManagedSessionError.appShuttingDown
        }
        guard executable.role == .agyCLI else {
            throw AntigravityManagedSessionError.executableNotAllowed
        }
        guard case .userOptIn(let idleTimeout) = authorization else {
            throw AntigravityManagedSessionError.launchDisabled
        }
        guard idleTimeout > .zero else {
            throw AntigravityManagedSessionError.invalidIdleTimeout
        }

        try await waitForActiveCleanups(deadline: deadline)
        try Self.checkRequestIsActive(deadline)
        guard !shuttingDown else {
            throw AntigravityManagedSessionError.appShuttingDown
        }

        idleTask?.cancel()
        idleTask = nil

        while true {
            switch state {
            case .stopped:
                let starting = start(
                    executable: executable,
                    idleTimeout: idleTimeout,
                    waiterID: leaseID
                )
                state = .starting(starting)
                observeCompletion(of: starting)

            case .starting(var starting):
                guard starting.executable == executable else {
                    throw AntigravityManagedSessionError
                        .differentExecutableInUse
                }
                starting.waiters.insert(leaseID)
                state = .starting(starting)
                do {
                    let started = try await
                        AntigravityManagedCLIStartTaskWaiter()
                            .value(
                                of: starting.task,
                                deadline: deadline
                            )
                    return try claimStartedProcess(
                        generation: starting.generation,
                        leaseID: leaseID,
                        idleTimeout: starting.idleTimeout,
                        started: started
                    )
                } catch is CancellationError {
                    await abandonStartingWaiter(
                        generation: starting.generation,
                        waiterID: leaseID
                    )
                    throw AntigravityManagedSessionError.cancelled
                } catch is AntigravityRPCDeadlineError {
                    await abandonStartingWaiter(
                        generation: starting.generation,
                        waiterID: leaseID
                    )
                    throw AntigravityManagedSessionError
                        .readinessTimedOut
                } catch {
                    await abandonStartingWaiter(
                        generation: starting.generation,
                        waiterID: leaseID
                    )
                    throw error
                }

            case .running(var running):
                guard running.runtime.processIdentity.executable
                        == executable else {
                    throw AntigravityManagedSessionError
                        .differentExecutableInUse
                }
                guard running.pendingReset == nil else {
                    throw AntigravityManagedSessionError.resetPending
                }
                running.idleTimeout = idleTimeout
                running.leases.insert(leaseID)
                state = .running(running)
                return running.runtime
            }
        }
    }

    private func start(
        executable: AntigravityCanonicalExecutable,
        idleTimeout: Duration,
        waiterID: UUID
    ) -> Starting {
        generation &+= 1
        let currentGeneration = generation
        let launcher = self.launcher
        let executableRevalidator =
            self.executableRevalidator
        let identityProvider = self.identityProvider
        let recordStore = self.recordStore
        let launchCoordinator = self.launchCoordinator
        let recovery = self.recovery
        let processTreeController =
            self.processTreeController
        let registry = self.registry
        let readinessChecker = self.readinessChecker
        let environment = self.environment
        let currentDirectoryURL = self.currentDirectoryURL
        let now = self.now
        let processObservationInterval =
            self.processObservationInterval
        let processObservationSleep =
            self.processObservationSleep
        let terminationGracePeriod = self.terminationGracePeriod
        let cleanupCoordinationTimeout =
            self.cleanupCoordinationTimeout
        let pendingRecordRemovalIDs =
            self.pendingRecordRemovalIDs
        let operationDeadline = AntigravityRPCDeadline()

        let task = Task.detached(priority: .utility) {
            try await Self.launch(
                executable: executable,
                deadline: operationDeadline,
                launcher: launcher,
                executableRevalidator:
                    executableRevalidator,
                identityProvider: identityProvider,
                recordStore: recordStore,
                launchCoordinator: launchCoordinator,
                recovery: recovery,
                processTreeController:
                    processTreeController,
                registry: registry,
                readinessChecker: readinessChecker,
                environment: environment,
                currentDirectoryURL: currentDirectoryURL,
                now: now,
                pendingRecordRemovalIDs:
                    pendingRecordRemovalIDs,
                processObservationInterval:
                    processObservationInterval,
                processObservationSleep:
                    processObservationSleep,
                terminationGracePeriod: terminationGracePeriod,
                cleanupCoordinationTimeout:
                    cleanupCoordinationTimeout
            )
        }
        return Starting(
            generation: currentGeneration,
            executable: executable,
            idleTimeout: idleTimeout,
            task: task,
            waiters: [waiterID]
        )
    }

    private func observeCompletion(
        of starting: Starting
    ) {
        Task { [weak self] in
            let result = await starting.task.result
            await self?.observedLaunchCompletion(
                generation: starting.generation,
                result: result
            )
        }
    }

    private func observedLaunchCompletion(
        generation completedGeneration: UInt64,
        result: Result<AntigravityManagedCLIStartedProcess, Error>
    ) async {
        if externallyCleaningStartingGenerations.remove(
            completedGeneration
        ) != nil {
            return
        }

        if case .running(let running) = state,
           case .success(let started) = result,
           running.generation == completedGeneration,
           running.sessionID == started.sessionID {
            return
        }

        guard case .starting(let starting) = state,
              starting.generation == completedGeneration else {
            if case .success(let started) = result {
                await cleanUp(started)
            }
            return
        }

        switch result {
        case .success:
            // A successful waiter claims the process and its first lease.
            // Leaving it in `starting` avoids an idle-running gap after every
            // waiter has already timed out or been cancelled.
            break
        case .failure:
            state = .stopped
        }
    }

    private func claimStartedProcess(
        generation completedGeneration: UInt64,
        leaseID: UUID,
        idleTimeout: Duration,
        started: AntigravityManagedCLIStartedProcess
    ) throws -> AntigravityManagedRuntime {
        switch state {
        case .starting(var starting)
        where starting.generation == completedGeneration:
            guard starting.waiters.remove(leaseID) != nil else {
                throw AntigravityManagedSessionError.cancelled
            }
            pendingRecordRemovalIDs.subtract(
                started.removedPendingRecordIDs
            )
            state = .running(Running(
                generation: completedGeneration,
                sessionID: started.sessionID,
                handle: started.handle,
                runtime: started.runtime,
                diagnostics: started.diagnostics,
                idleTimeout: idleTimeout,
                leases: [leaseID],
                pendingAcquisitions: starting.waiters,
                pendingReset: nil,
                outputMonitor: nil,
                processTreeMonitor: nil
            ))
            startOutputMonitor(
                generation: completedGeneration,
                sessionID: started.sessionID
            )
            startProcessTreeMonitor(
                generation: completedGeneration,
                sessionID: started.sessionID
            )
            return started.runtime

        case .running(var running)
        where running.generation == completedGeneration
            && running.sessionID == started.sessionID:
            guard running.pendingReset == nil,
                  running.pendingAcquisitions.remove(leaseID) != nil else {
                throw AntigravityManagedSessionError.resetPending
            }
            running.idleTimeout = idleTimeout
            running.leases.insert(leaseID)
            state = .running(running)
            return running.runtime

        case .stopped, .starting, .running:
            throw AntigravityManagedSessionError.cancelled
        }
    }

    private func abandonStartingWaiter(
        generation abandonedGeneration: UInt64,
        waiterID: UUID
    ) async {
        switch state {
        case .starting(var starting)
        where starting.generation == abandonedGeneration:
            guard starting.waiters.remove(waiterID) != nil else {
                return
            }
            guard starting.waiters.isEmpty else {
                state = .starting(starting)
                return
            }

            externallyCleaningStartingGenerations.insert(
                abandonedGeneration
            )
            state = .stopped
            starting.task.cancel()
            beginCleanup()
            defer { finishCleanup() }
            if case .success(let started) = await starting.task.result {
                await cleanUp(started)
            }

        case .running(var running)
        where running.generation == abandonedGeneration:
            guard running.pendingAcquisitions.remove(waiterID) != nil else {
                return
            }
            if running.leases.isEmpty,
               running.pendingReset != nil {
                state = .stopped
                await cleanUp(running)
            } else {
                state = .running(running)
                if running.leases.isEmpty,
                   running.pendingAcquisitions.isEmpty
                {
                    guard await observeRunningProcessTree(
                        generation: running.generation,
                        sessionID: running.sessionID
                    ) else {
                        return
                    }
                }
                scheduleIdleIfNeeded()
            }

        case .stopped, .starting, .running:
            return
        }
    }

    private func release(
        leaseID: UUID
    ) async {
        guard case .running(var running) = state,
              running.leases.remove(leaseID) != nil else {
            return
        }

        if running.leases.isEmpty,
           running.pendingReset != nil {
            state = .stopped
            await cleanUp(running)
            return
        }

        state = .running(running)
        if running.leases.isEmpty {
            guard await observeRunningProcessTree(
                generation: running.generation,
                sessionID: running.sessionID
            ) else {
                return
            }
        }
        scheduleIdleIfNeeded()
    }

    private func scheduleIdleIfNeeded() {
        idleTask?.cancel()
        idleTask = nil

        guard case .running(let running) = state,
              running.leases.isEmpty,
              running.pendingAcquisitions.isEmpty,
              running.pendingReset == nil else {
            return
        }

        let expectedGeneration = running.generation
        let timeout = running.idleTimeout
        let idleSleep = self.idleSleep
        idleTask = Task { [weak self] in
            do {
                try await idleSleep(timeout)
                await self?.idleExpired(
                    generation: expectedGeneration
                )
            } catch {
                // A new lease, reset, or shutdown invalidated this timer.
            }
        }
    }

    private func idleExpired(
        generation expectedGeneration: UInt64
    ) async {
        guard case .running(let running) = state,
              running.generation == expectedGeneration,
              running.leases.isEmpty,
              running.pendingReset == nil else {
            return
        }
        idleTask = nil
        state = .stopped
        await cleanUp(running)
    }

    private func startOutputMonitor(
        generation expectedGeneration: UInt64,
        sessionID expectedSessionID: UUID
    ) {
        guard case .running(var running) = state,
              running.generation == expectedGeneration,
              running.sessionID == expectedSessionID,
              running.outputMonitor == nil else {
            return
        }

        let handle = running.handle
        let interval = monitorInterval
        let sleep = monitorSleep
        running.outputMonitor = Task.detached(
            priority: .utility
        ) { [weak self] in
            var classifier =
                AntigravityManagedCLIOutputClassifier()
            while !Task.isCancelled {
                let output = handle.drainOutput(
                    maximumBytes: 4 * 1_024
                )
                if !output.isEmpty {
                    let interactions = classifier.ingest(output)
                    if let interaction = Self.firstInteraction(
                        in: interactions
                    ) {
                        await self?.outputMonitorDetectedIssue(
                            generation: expectedGeneration,
                            sessionID: expectedSessionID,
                            resetReason: .authenticationRequired,
                            interaction: interaction
                        )
                        return
                    }
                }
                if handle.terminationStatus() != nil {
                    await self?.outputMonitorDetectedIssue(
                        generation: expectedGeneration,
                        sessionID: expectedSessionID,
                        resetReason: .unhealthyRuntime,
                        interaction: nil
                    )
                    return
                }

                do {
                    try await sleep(interval)
                } catch {
                    return
                }
            }
        }
        state = .running(running)
    }

    private func startProcessTreeMonitor(
        generation expectedGeneration: UInt64,
        sessionID expectedSessionID: UUID
    ) {
        guard case .running(var running) = state,
              running.generation == expectedGeneration,
              running.sessionID == expectedSessionID,
              running.processTreeMonitor == nil else {
            return
        }

        let interval = processObservationInterval
        let sleep = processObservationSleep
        running.processTreeMonitor = Task.detached(
            priority: .utility
        ) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
                guard await self?.observeRunningProcessTree(
                    generation: expectedGeneration,
                    sessionID: expectedSessionID
                ) == true else {
                    return
                }
            }
        }
        state = .running(running)
    }

    private func observeRunningProcessTree(
        generation expectedGeneration: UInt64,
        sessionID expectedSessionID: UUID
    ) async -> Bool {
        guard case .running(let current) = state,
              current.generation == expectedGeneration,
              current.sessionID == expectedSessionID,
              current.pendingReset == nil else {
            return false
        }

        let observation: AntigravityManagedProcessObservationResult
        observation = await Self.observeManagedProcessTree(
            sessionID: expectedSessionID,
            launchCoordinator: launchCoordinator,
            processTreeController: processTreeController,
            coordinationTimeout: cleanupCoordinationTimeout
        )

        guard case .running(var running) = state,
              running.generation == expectedGeneration,
              running.sessionID == expectedSessionID else {
            return false
        }
        guard observation == .complete else {
            running.pendingReset = .unhealthyRuntime
            running.processTreeMonitor?.cancel()
            guard running.leases.isEmpty else {
                state = .running(running)
                return false
            }
            state = .stopped
            await cleanUp(running)
            return false
        }
        return true
    }

    private func outputMonitorDetectedIssue(
        generation expectedGeneration: UInt64,
        sessionID expectedSessionID: UUID,
        resetReason: AntigravityManagedSessionResetReason,
        interaction: AntigravityManagedCLIInteraction?
    ) async {
        guard case .running(var running) = state,
              running.generation == expectedGeneration,
              running.sessionID == expectedSessionID else {
            return
        }

        if let interaction {
            var interactions =
                running.diagnostics.interactions
            interactions.insert(interaction)
            running.diagnostics =
                AntigravityManagedSessionDiagnostics(
                    interactions: interactions,
                    outputWasTruncated:
                        running.diagnostics.outputWasTruncated
                )
            running.pendingReset = resetReason
        } else {
            running.pendingReset = resetReason
        }

        guard running.leases.isEmpty else {
            state = .running(running)
            return
        }
        state = .stopped
        await cleanUp(running)
    }

    private func cleanUp(
        _ running: Running
    ) async {
        beginCleanup()
        defer { finishCleanup() }
        running.outputMonitor?.cancel()
        running.processTreeMonitor?.cancel()
        let cleanupResult = await terminateManagedProcess(
            sessionID: running.sessionID,
            handle: running.handle
        )
        await updateRegistryAfterCleanup(
            identity: running.runtime.processIdentity,
            result: cleanupResult
        )
        switch cleanupResult {
        case .complete:
            pendingRecordRemovalIDs.remove(running.sessionID)
        case .recordRemovalFailed:
            pendingRecordRemovalIDs.insert(running.sessionID)
        case .incomplete:
            pendingRecordRemovalIDs.remove(running.sessionID)
        }
    }

    private func cleanUp(
        _ started: AntigravityManagedCLIStartedProcess
    ) async {
        beginCleanup()
        defer { finishCleanup() }
        let cleanupResult = await terminateManagedProcess(
            sessionID: started.sessionID,
            handle: started.handle
        )
        await updateRegistryAfterCleanup(
            identity: started.runtime.processIdentity,
            result: cleanupResult
        )
        pendingRecordRemovalIDs.subtract(
            started.removedPendingRecordIDs
        )
        switch cleanupResult {
        case .complete:
            pendingRecordRemovalIDs.remove(started.sessionID)
        case .recordRemovalFailed:
            pendingRecordRemovalIDs.insert(started.sessionID)
        case .incomplete:
            pendingRecordRemovalIDs.remove(started.sessionID)
        }
    }

    private func terminateManagedProcess(
        sessionID: UUID,
        handle: any AntigravityManagedCLIProcessHandling
    ) async -> AntigravityManagedProcessCleanupResult {
        await Self.terminateManagedProcess(
            sessionID: sessionID,
            handle: handle,
            launchCoordinator: launchCoordinator,
            processTreeController: processTreeController,
            gracePeriod: terminationGracePeriod,
            coordinationTimeout: cleanupCoordinationTimeout
        )
    }

    private func updateRegistryAfterCleanup(
        identity: AntigravityVerifiedProcessIdentity,
        result: AntigravityManagedProcessCleanupResult
    ) async {
        switch result {
        case .complete, .recordRemovalFailed:
            await registry.unregister(identity)
        case .incomplete:
            await registry.quarantine(identity)
        }
    }

    private func beginCleanup() {
        activeCleanupCount += 1
    }

    private func finishCleanup() {
        precondition(activeCleanupCount > 0)
        activeCleanupCount -= 1
        guard activeCleanupCount == 0 else { return }

        let waiters = cleanupWaiters
        cleanupWaiters.removeAll()
        for continuation in waiters {
            continuation.resume()
        }
    }

    private func waitForActiveCleanups() async {
        guard activeCleanupCount > 0 else { return }
        await withCheckedContinuation { continuation in
            if activeCleanupCount == 0 {
                continuation.resume()
            } else {
                cleanupWaiters.append(continuation)
            }
        }
    }

    private func waitForActiveCleanups(
        deadline: AntigravityRPCDeadline
    ) async throws {
        while activeCleanupCount > 0 {
            try Self.checkRequestIsActive(deadline)
            let wait = min(
                Duration.milliseconds(10),
                deadline.remaining
            )
            do {
                try await Task.sleep(for: wait)
            } catch is CancellationError {
                throw AntigravityManagedSessionError.cancelled
            }
        }
        try Self.checkRequestIsActive(deadline)
    }

    private nonisolated static func checkRequestIsActive(
        _ deadline: AntigravityRPCDeadline
    ) throws {
        do {
            try Task.checkCancellation()
            try deadline.check(.request)
        } catch is CancellationError {
            throw AntigravityManagedSessionError.cancelled
        } catch is AntigravityRPCDeadlineError {
            throw AntigravityManagedSessionError.readinessTimedOut
        }
    }

    private nonisolated static func firstInteraction(
        in interactions: Set<AntigravityManagedCLIInteraction>
    ) -> AntigravityManagedCLIInteraction? {
        let priority: [AntigravityManagedCLIInteraction] = [
            .projectTrustRequired,
            .loginRequired,
            .browserAuthenticationRequired,
        ]
        return priority.first(where: interactions.contains)
    }

    private nonisolated static func launch(
        executable: AntigravityCanonicalExecutable,
        deadline: AntigravityRPCDeadline,
        launcher: any AntigravityManagedCLIProcessLaunching,
        executableRevalidator:
            any AntigravityExecutableRevalidating,
        identityProvider:
            any AntigravityManagedProcessIdentityProviding,
        recordStore:
            any AntigravityManagedProcessLedgerStoring,
        launchCoordinator:
            any AntigravityManagedLaunchCoordinating,
        recovery:
            any AntigravityManagedSessionLifecycleRecovering,
        processTreeController:
            any AntigravityManagedProcessTreeControlling,
        registry: any AntigravityManagedRuntimeRegistering,
        readinessChecker:
            any AntigravityManagedCLIReadinessChecking,
        environment: AntigravityManagedCLIEnvironment,
        currentDirectoryURL: URL,
        now: @escaping @Sendable () -> Date,
        pendingRecordRemovalIDs: Set<UUID>,
        processObservationInterval: Duration,
        processObservationSleep:
            @escaping @Sendable (Duration) async throws -> Void,
        terminationGracePeriod: Duration,
        cleanupCoordinationTimeout: Duration
    ) async throws -> AntigravityManagedCLIStartedProcess {
        let prepared: AntigravityManagedCLIPreparedProcess
        do {
            prepared = try await
                launchCoordinator.withExclusiveLaunch(
                    deadline: deadline
                ) {
                    try await prepareLaunch(
                        executable: executable,
                        launcher: launcher,
                        executableRevalidator:
                            executableRevalidator,
                        identityProvider: identityProvider,
                        recordStore: recordStore,
                        recovery: recovery,
                        processTreeController:
                            processTreeController,
                        environment: environment,
                        currentDirectoryURL: currentDirectoryURL,
                        now: now,
                        pendingRecordRemovalIDs:
                            pendingRecordRemovalIDs,
                        deadline: deadline,
                        terminationGracePeriod:
                            terminationGracePeriod
                    )
                }
        } catch is CancellationError {
            throw AntigravityManagedSessionError.cancelled
        } catch is AntigravityRPCDeadlineError {
            throw AntigravityManagedSessionError.readinessTimedOut
        } catch let error as AntigravityManagedSessionError {
            throw error
        } catch is AntigravityManagedLaunchCoordinatorError {
            throw AntigravityManagedSessionError
                .launchCoordinationUnavailable
        } catch {
            throw AntigravityManagedSessionError.launchFailed
        }

        var registered = false
        do {
            await registry.register(prepared.processIdentity)
            registered = true

            let ready = try await waitUntilReadyWhileObserving(
                prepared: prepared,
                readinessChecker: readinessChecker,
                processTreeController:
                    processTreeController,
                launchCoordinator: launchCoordinator,
                deadline: deadline,
                observationInterval:
                    processObservationInterval,
                observationSleep:
                    processObservationSleep
            )
            let observation = try await
                launchCoordinator.withExclusiveLaunch(
                    deadline: deadline
                ) {
                    await processTreeController.observe(
                        sessionID: prepared.sessionID
                    )
                }
            guard observation == .complete else {
                throw AntigravityManagedSessionError
                    .recordRecoveryBlocked
            }
            return AntigravityManagedCLIStartedProcess(
                sessionID: prepared.sessionID,
                handle: prepared.handle,
                runtime: ready.runtime,
                diagnostics: ready.diagnostics,
                removedPendingRecordIDs:
                    pendingRecordRemovalIDs
            )
        } catch {
            let cleanupResult =
                await terminateManagedProcess(
                    sessionID: prepared.sessionID,
                    handle: prepared.handle,
                    launchCoordinator: launchCoordinator,
                    processTreeController:
                        processTreeController,
                    gracePeriod: terminationGracePeriod,
                    coordinationTimeout:
                        cleanupCoordinationTimeout
                )
            if registered {
                switch cleanupResult {
                case .complete, .recordRemovalFailed:
                    await registry.unregister(
                        prepared.processIdentity
                    )
                case .incomplete:
                    await registry.quarantine(
                        prepared.processIdentity
                    )
                }
            }
            if error is CancellationError {
                throw AntigravityManagedSessionError.cancelled
            }
            throw error
        }
    }

    private nonisolated static func waitUntilReadyWhileObserving(
        prepared: AntigravityManagedCLIPreparedProcess,
        readinessChecker:
            any AntigravityManagedCLIReadinessChecking,
        processTreeController:
            any AntigravityManagedProcessTreeControlling,
        launchCoordinator:
            any AntigravityManagedLaunchCoordinating,
        deadline: AntigravityRPCDeadline,
        observationInterval: Duration,
        observationSleep:
            @escaping @Sendable (Duration) async throws -> Void
    ) async throws -> AntigravityManagedCLIReadinessResult {
        try await withThrowingTaskGroup(
            of: AntigravityManagedCLIReadinessResult?.self
        ) { group in
            group.addTask {
                try await readinessChecker.waitUntilReady(
                    handle: prepared.handle,
                    processIdentity: prepared.processIdentity,
                    deadline: deadline
                )
            }
            group.addTask {
                while true {
                    try await observationSleep(
                        min(
                            observationInterval,
                            deadline.remaining
                        )
                    )
                    try deadline.check(.request)
                    let observation = try await
                        launchCoordinator.withExclusiveLaunch(
                            deadline: deadline
                        ) {
                            await processTreeController.observe(
                                sessionID: prepared.sessionID
                            )
                        }
                    guard observation == .complete else {
                        throw AntigravityManagedSessionError
                            .recordRecoveryBlocked
                    }
                }
            }
            defer { group.cancelAll() }

            guard let first = try await group.next(),
                  let ready = first else {
                throw AntigravityManagedSessionError.cancelled
            }
            return ready
        }
    }

    /// Cleanup must outlive cancellation of the request that triggered it.
    /// Coordination is still bounded so a live process holding the launch
    /// lock cannot stall shutdown indefinitely.
    private nonisolated static func terminateManagedProcess(
        sessionID: UUID,
        handle: any AntigravityManagedCLIProcessHandling,
        launchCoordinator:
            any AntigravityManagedLaunchCoordinating,
        processTreeController:
            any AntigravityManagedProcessTreeControlling,
        gracePeriod: Duration,
        coordinationTimeout: Duration
    ) async -> AntigravityManagedProcessCleanupResult {
        await Task.detached(priority: .utility) {
            let deadline = AntigravityRPCDeadline(
                totalTimeout: coordinationTimeout,
                discoveryTimeout: .zero
            )
            do {
                return try await
                    launchCoordinator.withExclusiveLaunch(
                        deadline: deadline
                    ) {
                        await processTreeController.terminate(
                            sessionID: sessionID,
                            handle: handle,
                            gracePeriod: gracePeriod
                        )
                    }
            } catch {
                // The unreaped root and its original process group remain
                // this handle's authority even when durable coordination is
                // unavailable. The ledger is preserved and discovery keeps
                // the execution quarantined for later exact recovery.
                _ = await handle.terminateTree(
                    gracePeriod: gracePeriod
                )
                return .incomplete
            }
        }.value
    }

    /// Lease-boundary observations may be triggered by a cancelled waiter.
    /// Run the ownership transaction in an independent bounded task so the
    /// caller's cancellation cannot turn a healthy runtime into an
    /// artificial incomplete observation.
    private nonisolated static func observeManagedProcessTree(
        sessionID: UUID,
        launchCoordinator:
            any AntigravityManagedLaunchCoordinating,
        processTreeController:
            any AntigravityManagedProcessTreeControlling,
        coordinationTimeout: Duration
    ) async -> AntigravityManagedProcessObservationResult {
        await Task.detached(priority: .utility) {
            let deadline = AntigravityRPCDeadline(
                totalTimeout: coordinationTimeout,
                discoveryTimeout: .zero
            )
            do {
                return try await
                    launchCoordinator.withExclusiveLaunch(
                        deadline: deadline
                    ) {
                        await processTreeController.observe(
                            sessionID: sessionID
                        )
                    }
            } catch {
                return .incomplete
            }
        }.value
    }

    private nonisolated static func createIntentDurably(
        _ intent: AntigravityManagedLaunchIntent,
        recordStore:
            any AntigravityManagedProcessLedgerStoring
    ) throws {
        do {
            try recordStore.createIntent(intent)
            return
        } catch {
            // rename(2) may have made the intent visible before a following
            // directory fsync/read-back failure. Visibility is not enough to
            // authorize spawn under the strict durable-before-spawn
            // contract, so roll back the exact intent and fail this attempt.
            if let snapshot = try? recordStore.loadLedger(),
               snapshot.bootSessionID
                    == intent.bootSessionID,
               snapshot.entries == [.launchIntent(intent)] {
                do {
                    try recordStore.removeIntent(intent)
                } catch {
                    // Preserve any uncertain entry. The next exclusive
                    // lifecycle recovery will resolve it without spawning.
                }
            }
            throw AntigravityManagedSessionError
                .recordPersistenceFailed
        }
    }

    private nonisolated static func prepareLaunch(
        executable: AntigravityCanonicalExecutable,
        launcher: any AntigravityManagedCLIProcessLaunching,
        executableRevalidator:
            any AntigravityExecutableRevalidating,
        identityProvider:
            any AntigravityManagedProcessIdentityProviding,
        recordStore:
            any AntigravityManagedProcessLedgerStoring,
        recovery:
            any AntigravityManagedSessionLifecycleRecovering,
        processTreeController:
            any AntigravityManagedProcessTreeControlling,
        environment: AntigravityManagedCLIEnvironment,
        currentDirectoryURL: URL,
        now: @escaping @Sendable () -> Date,
        pendingRecordRemovalIDs: Set<UUID>,
        deadline: AntigravityRPCDeadline,
        terminationGracePeriod: Duration
    ) async throws -> AntigravityManagedCLIPreparedProcess {
        try checkRequestIsActive(deadline)
        guard executableRevalidator.isCurrent(executable) else {
            throw AntigravityManagedSessionError
                .executableNotAllowed
        }
        for sessionID in pendingRecordRemovalIDs.sorted(
            by: {
                $0.uuidString < $1.uuidString
            }
        ) {
            do {
                try recordStore.remove(sessionID: sessionID)
            } catch {
                throw AntigravityManagedSessionError
                    .recordPersistenceFailed
            }
        }

        guard let request = AntigravityManagedCLIProcessLaunchRequest(
            executable: executable,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL
        ),
        let executableDescriptor =
            AntigravityManagedExecutableDescriptor(
                executable: executable
            ) else {
            throw AntigravityManagedSessionError.executableNotAllowed
        }
        guard let ownerIdentity = identityProvider.identity(
            for: Int32(getpid())
        ) else {
            throw AntigravityManagedSessionError
                .ownerIdentityUnavailable
        }

        let bootSessionID = try await recovery.prepareForLaunch(
            owner: ownerIdentity,
            executable: executableDescriptor
        )
        try checkRequestIsActive(deadline)

        let createdSessionID = UUID()
        guard let intent = AntigravityManagedLaunchIntent(
            sessionID: createdSessionID,
            bootSessionID: bootSessionID,
            owner: ownerIdentity,
            executable: executableDescriptor,
            createdAt: now()
        ) else {
            throw AntigravityManagedSessionError
                .recordPersistenceFailed
        }
        try createIntentDurably(
            intent,
            recordStore: recordStore
        )

        var handle: (any AntigravityManagedCLIProcessHandling)?
        var recordWasPromoted = false
        var unpromotedTerminationWasConfirmed = true
        do {
            try checkRequestIsActive(deadline)
            guard executableRevalidator.isCurrent(
                executable
            ) else {
                throw AntigravityManagedSessionError
                    .executableNotAllowed
            }
            let launched: any AntigravityManagedCLIProcessHandling
            do {
                launched = try launcher.launchSuspended(request)
            } catch let error as AntigravityManagedSessionError {
                throw error
            } catch {
                throw AntigravityManagedSessionError.launchFailed
            }
            handle = launched

            guard executableRevalidator.isCurrent(
                executable
            ) else {
                throw AntigravityManagedSessionError
                    .executableNotAllowed
            }
            guard launched.processGroupID == launched.processID,
                  identityProvider.processGroupID(
                      for: launched.processID
                  ) == launched.processID,
                  let recordedChild = identityProvider.identity(
                      for: launched.processID
                  ),
                  let processIdentity = recordedChild
                    .verifiedIdentity(matching: executable),
                  processIdentity.processID == launched.processID,
                  recordedChild.effectiveUserID
                    == ownerIdentity.effectiveUserID,
                  recordedChild.realUserID
                    == ownerIdentity.realUserID,
                  recordedChild.kernelIdentity.parentUniqueID
                    == ownerIdentity.kernelIdentity.uniqueID else {
                throw AntigravityManagedSessionError
                    .processIdentityUnavailable
            }

            guard let record = AntigravityManagedProcessRecord(
                sessionID: createdSessionID,
                bootSessionID: bootSessionID,
                child: recordedChild,
                processGroupID: launched.processGroupID,
                owner: ownerIdentity,
                observationCompleteness: .complete,
                createdAt: intent.createdAt
            ) else {
                throw AntigravityManagedSessionError
                    .recordPersistenceFailed
            }
            try checkRequestIsActive(deadline)
            do {
                try recordStore.promoteIntent(
                    intent,
                    to: record
                )
                recordWasPromoted = true
            } catch {
                // A post-rename failure can leave the exact process record
                // visible. It is authority for cleanup, never for resuming
                // user code without a successful durable commit result.
                if let snapshot = try? recordStore.loadLedger(),
                   snapshot.bootSessionID
                        == record.bootSessionID,
                   snapshot.entries == [.processRecord(record)] {
                    recordWasPromoted = true
                }
                throw AntigravityManagedSessionError
                    .recordPersistenceFailed
            }
            try checkRequestIsActive(deadline)
            try launched.resume()
            guard await processTreeController.observe(
                sessionID: createdSessionID
            ) == .complete else {
                throw AntigravityManagedSessionError
                    .recordRecoveryBlocked
            }

            return AntigravityManagedCLIPreparedProcess(
                sessionID: createdSessionID,
                handle: launched,
                processIdentity: processIdentity
            )
        } catch {
            if recordWasPromoted, let handle {
                _ = await processTreeController.terminate(
                    sessionID: createdSessionID,
                    handle: handle,
                    gracePeriod: terminationGracePeriod
                )
            } else if let handle {
                unpromotedTerminationWasConfirmed =
                    await handle.terminateTree(
                        gracePeriod: .zero
                    ) == .confirmed
            }

            if !recordWasPromoted,
               unpromotedTerminationWasConfirmed
            {
                do {
                    try recordStore.removeIntent(intent)
                } catch {
                    throw AntigravityManagedSessionError
                        .recordPersistenceFailed
                }
            }
            if error is CancellationError {
                throw AntigravityManagedSessionError.cancelled
            }
            throw error
        }
    }
}

private nonisolated final class AntigravityManagedCLIStartTaskWaiter:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<
            AntigravityManagedCLIStartedProcess,
            Error
        >?
    private var result:
        Result<AntigravityManagedCLIStartedProcess, Error>?

    func value(
        of task: Task<AntigravityManagedCLIStartedProcess, Error>,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityManagedCLIStartedProcess {
        let timeout = try deadline.timeout(for: .request)
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                self?.finish(with: .failure(
                    AntigravityRPCDeadlineError.timedOut(.request)
                ))
            } catch {
                // The shared launch or caller cancellation completed first.
            }
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                continuation in
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
            CheckedContinuation<
                AntigravityManagedCLIStartedProcess,
                Error
            >
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
        with result:
            Result<AntigravityManagedCLIStartedProcess, Error>
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
