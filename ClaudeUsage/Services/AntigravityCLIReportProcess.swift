import Darwin
import Foundation

nonisolated struct AntigravityCLIReportProcessRequest: Sendable, Equatable {
    let executable: AntigravityCanonicalExecutable
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryURL: URL
    let timeout: Duration
    let maximumOutputBytes: Int

    init(
        executable: AntigravityCanonicalExecutable,
        arguments: [String],
        environment: [String: String],
        workingDirectoryURL: URL,
        timeout: Duration,
        maximumOutputBytes: Int = 1_024 * 1_024
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
    }
}

nonisolated struct AntigravityCLIReportProcessResult: Sendable, Equatable {
    let standardOutput: Data
    let standardError: Data
    // The exit code, or 128 plus the terminating signal number.
    let exitStatus: Int32
}

nonisolated enum AntigravityCLIReportProcessError: Error, Sendable, Equatable {
    case invalidRequest
    case executableNotAllowed
    case launchFailed
    case processGroupInvalid
    case timedOut
    case outputLimitExceeded
}

nonisolated protocol AntigravityCLIReportProcessRunning: Sendable {
    func run(
        _ request: AntigravityCLIReportProcessRequest
    ) async throws -> AntigravityCLIReportProcessResult
}

nonisolated struct AntigravityCLIReportProcessRunner:
    AntigravityCLIReportProcessRunning
{
    private let executableRevalidator: any AntigravityExecutableRevalidating
    private let runningExecutableImageValidator: any AntigravityRunningExecutableImageValidating
    private let terminationGracePeriod: Duration

    init(
        executableRevalidator: any AntigravityExecutableRevalidating =
            AntigravityPinnedAGYExecutableRevalidator(),
        runningExecutableImageValidator:
            any AntigravityRunningExecutableImageValidating =
            AntigravitySystemRunningExecutableImageValidator(),
        terminationGracePeriod: Duration = .milliseconds(250)
    ) {
        self.executableRevalidator = executableRevalidator
        self.runningExecutableImageValidator = runningExecutableImageValidator
        self.terminationGracePeriod = terminationGracePeriod
    }

    // AGY's auto-updater may be rewriting the binary during a launch (ETXTBSY).
    static func spawnRetryingTextFileBusy(
        maximumAttempts: Int = 3,
        sleepBetweenAttempts: () -> Void = { usleep(10_000) },
        spawn: () -> Int32
    ) -> Int32 {
        precondition(maximumAttempts > 0)
        var status = spawn()
        for _ in 1..<maximumAttempts where status == ETXTBSY {
            sleepBetweenAttempts()
            status = spawn()
        }
        return status
    }

    func run(
        _ request: AntigravityCLIReportProcessRequest
    ) async throws -> AntigravityCLIReportProcessResult {
        guard request.timeout > .zero,
            request.maximumOutputBytes > 0,
            request.arguments.allSatisfy({ !$0.contains("\0") }),
            request.environment.allSatisfy({
                !$0.key.isEmpty
                    && !$0.key.contains("\0")
                    && !$0.key.contains("=")
                    && !$0.value.contains("\0")
            }),
            !request.workingDirectoryURL.path.contains("\0")
        else {
            throw AntigravityCLIReportProcessError.invalidRequest
        }
        guard request.executable.role == .agyCLI,
            executableRevalidator.isCurrent(request.executable)
        else {
            throw AntigravityCLIReportProcessError.executableNotAllowed
        }
        try Task.checkCancellation()

        let child = try launch(request)
        let outputCollector = AntigravityBoundedPipeCollector(
            fileDescriptor: child.standardOutputFileDescriptor,
            maximumBytes: request.maximumOutputBytes,
            owner: child
        )
        let errorCollector = AntigravityBoundedPipeCollector(
            fileDescriptor: child.standardErrorFileDescriptor,
            maximumBytes: request.maximumOutputBytes,
            owner: child
        )
        let outputTask = Task.detached(priority: .utility) {
            await outputCollector.collect()
        }
        let errorTask = Task.detached(priority: .utility) {
            await errorCollector.collect()
        }

        let outcome = await waitForExit(of: child, timeout: request.timeout)
        switch outcome {
        case .exited:
            child.signalGroup(SIGKILL)
        case .timedOut, .cancelled, .outputLimitReached:
            child.signalGroup(SIGTERM)
            await Self.sleepIgnoringCancellation(terminationGracePeriod)
            child.signalGroup(SIGKILL)
        }
        let exitStatus = await child.reap()

        let output = await outputTask.value
        let errorOutput = await errorTask.value

        switch outcome {
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            throw AntigravityCLIReportProcessError.timedOut
        case .outputLimitReached:
            throw AntigravityCLIReportProcessError.outputLimitExceeded
        case .exited:
            guard !output.exceededLimit, !errorOutput.exceededLimit else {
                throw AntigravityCLIReportProcessError.outputLimitExceeded
            }
            return AntigravityCLIReportProcessResult(
                standardOutput: output.data,
                standardError: errorOutput.data,
                exitStatus: exitStatus
            )
        }
    }

    private enum WaitOutcome: Sendable {
        case exited
        case timedOut
        case cancelled
        case outputLimitReached
    }

    // kqueue reports the exit without reaping, so the root keeps its IDs
    // reserved. The event can precede waitpid visibility; reap() tolerates that.
    private func waitForExit(
        of child: AntigravityCLIReportChildProcess,
        timeout: Duration
    ) async -> WaitOutcome {
        let race = OwnedSubprocessOneShotRace<WaitOutcome>()
        child.onOutputLimitReached { race.finish(.outputLimitReached) }
        let exitEvents = DispatchSource.makeProcessSource(
            identifier: child.processID,
            eventMask: .exit,
            queue: .global(qos: .utility)
        )
        exitEvents.setEventHandler { race.finish(.exited) }
        exitEvents.activate()
        defer { exitEvents.cancel() }
        if child.hasExited() {
            race.finish(.exited)
        }
        return await withTaskCancellationHandler {
            await race.wait(timeout: timeout.timeInterval, orElse: .timedOut)
        } onCancel: {
            race.finish(.cancelled)
        }
    }

    private static func sleepIgnoringCancellation(_ duration: Duration) async {
        guard duration > .zero else { return }
        await Task.detached {
            try? await Task.sleep(for: duration)
        }.value
    }

    private func launch(
        _ request: AntigravityCLIReportProcessRequest
    ) throws -> AntigravityCLIReportChildProcess {
        guard
            let spawned = OwnedSubprocessSpawn.spawn(
                executablePath: request.executable.canonicalURL.standardizedFileURL.path,
                arguments: request.arguments,
                environment: request.environment,
                options: .init(
                    workingDirectoryPath: request.workingDirectoryURL.path,
                    ownProcessGroup: true,
                    startSuspended: true,
                    // The report is background polling; keep its CPU and IO below the user's own work.
                    qosClass: QOS_CLASS_UTILITY
                ),
                attempt: { Self.spawnRetryingTextFileBusy(spawn: $0) }
            )
        else {
            throw AntigravityCLIReportProcessError.launchFailed
        }
        let processID = spawned.processID
        let child = AntigravityCLIReportChildProcess(
            processID: processID,
            standardOutputFileDescriptor: spawned.standardOutputFileDescriptor,
            standardErrorFileDescriptor: spawned.standardErrorFileDescriptor
        )

        // A suspended root has not run AGY code, so it cannot have created
        // descendants. Killing and reaping it is exact.
        guard getpgid(processID) == processID else {
            child.discardSuspended()
            throw AntigravityCLIReportProcessError.processGroupInvalid
        }
        guard
            runningExecutableImageValidator.validatesRunningImage(
                processID: processID,
                executable: request.executable
            )
        else {
            child.discardSuspended()
            throw AntigravityCLIReportProcessError.executableNotAllowed
        }
        guard child.resume() else {
            child.discardSuspended()
            throw AntigravityCLIReportProcessError.launchFailed
        }
        return child
    }
}

// Signals are sent under the same lock as `waitpid` and only while the root is
// unreaped, so neither its PID nor its process-group ID can have been reused.
nonisolated final class AntigravityCLIReportChildProcess:
    AntigravityBoundedPipeOwning,
    @unchecked Sendable
{
    let processID: pid_t
    let standardOutputFileDescriptor: Int32
    let standardErrorFileDescriptor: Int32

    private let lock = NSLock()
    private var reapedStatus: Int32?
    private var limitReached = false
    private var outputLimitHandler: (@Sendable () -> Void)?

    fileprivate init(
        processID: pid_t,
        standardOutputFileDescriptor: Int32,
        standardErrorFileDescriptor: Int32
    ) {
        self.processID = processID
        self.standardOutputFileDescriptor = standardOutputFileDescriptor
        self.standardErrorFileDescriptor = standardErrorFileDescriptor
    }

    var hasReleasedOwnership: Bool {
        lock.withLock { reapedStatus != nil }
    }

    func cancelOwnedProcess() {
        let handler = lock.withLock {
            limitReached = true
            return outputLimitHandler
        }
        handler?()
    }

    fileprivate func onOutputLimitReached(_ handler: @escaping @Sendable () -> Void) {
        let reached = lock.withLock {
            outputLimitHandler = handler
            return limitReached
        }
        if reached {
            handler()
        }
    }

    fileprivate func resume() -> Bool {
        lock.withLock {
            reapedStatus == nil && Darwin.kill(processID, SIGCONT) == 0
        }
    }

    // WNOWAIT keeps the exited root unreaped so its IDs stay reserved.
    fileprivate func hasExited() -> Bool {
        lock.withLock {
            guard reapedStatus == nil else { return true }
            var information = siginfo_t()
            let result = waitid(
                P_PID,
                id_t(processID),
                &information,
                WEXITED | WNOHANG | WNOWAIT
            )
            return result == 0 && information.si_pid != 0
        }
    }

    fileprivate func signalGroup(_ signal: Int32) {
        lock.withLock { signalLocked(signal) }
    }

    fileprivate func reap() async -> Int32 {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline {
            if let status = lock.withLock({ reapIfExitedLocked() }) {
                return status
            }
            await Task.detached {
                try? await Task.sleep(for: .milliseconds(10))
            }.value
        }
        // SIGKILL has already been sent on every path that reaches here; a
        // blocking wait returns once the kernel finishes tearing the root down.
        return await Task.detached(priority: .utility) { [self] in
            lock.withLock {
                signalLocked(SIGKILL)
                if let reapedStatus { return reapedStatus }
                var status: Int32 = 0
                while waitpid(processID, &status, 0) == -1, errno == EINTR {}
                let normalized = Self.normalizedStatus(status)
                reapedStatus = normalized
                return normalized
            }
        }.value
    }

    fileprivate func discardSuspended() {
        lock.withLock {
            guard reapedStatus == nil else { return }
            _ = Darwin.kill(processID, SIGKILL)
            var status: Int32 = 0
            while waitpid(processID, &status, 0) == -1, errno == EINTR {}
            reapedStatus = Self.normalizedStatus(status)
        }
        Darwin.close(standardOutputFileDescriptor)
        Darwin.close(standardErrorFileDescriptor)
    }

    private func signalLocked(_ signal: Int32) {
        guard reapedStatus == nil else { return }
        _ = Darwin.kill(-processID, signal)
        // The root may have moved itself to another group; its unreaped PID
        // still identifies exactly this child.
        _ = Darwin.kill(processID, signal)
    }

    private func reapIfExitedLocked() -> Int32? {
        if let reapedStatus {
            return reapedStatus
        }
        var status: Int32 = 0
        while true {
            let result = waitpid(processID, &status, WNOHANG)
            if result == processID {
                let normalized = Self.normalizedStatus(status)
                reapedStatus = normalized
                return normalized
            }
            if result == -1, errno == EINTR {
                continue
            }
            if result == -1, errno == ECHILD {
                reapedStatus = 0
                return 0
            }
            return nil
        }
    }

    private static func normalizedStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + signal
    }
}
