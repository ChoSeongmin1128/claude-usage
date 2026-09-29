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
    /// The exit code, or 128 plus the terminating signal number.
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

/// Runs one short-lived, catalog-approved AGY command in its own process group.
///
/// The child starts suspended, so no AGY code runs before the kernel-mapped
/// image is validated. The root stays unreaped until every signal has been
/// sent: its PID, and therefore its process-group ID, cannot be reused while
/// it is signalled. Once the root exits, remaining members of its group are
/// killed because nothing AGY starts for a report may outlive it.
nonisolated struct AntigravityCLIReportProcessRunner:
    AntigravityCLIReportProcessRunning
{
    private let executableRevalidator: any AntigravityExecutableRevalidating
    private let runningExecutableImageValidator: any AntigravityRunningExecutableImageValidating
    private let terminationGracePeriod: Duration
    private let pollInterval: Duration

    init(
        executableRevalidator: any AntigravityExecutableRevalidating =
            AntigravityPinnedAGYExecutableRevalidator(),
        runningExecutableImageValidator:
            any AntigravityRunningExecutableImageValidating =
            AntigravitySystemRunningExecutableImageValidator(),
        terminationGracePeriod: Duration = .milliseconds(250),
        pollInterval: Duration = .milliseconds(10)
    ) {
        self.executableRevalidator = executableRevalidator
        self.runningExecutableImageValidator = runningExecutableImageValidator
        self.terminationGracePeriod = terminationGracePeriod
        self.pollInterval = pollInterval
    }

    /// AGY's auto-updater can be rewriting the binary while a launch is in
    /// flight, which surfaces as `ETXTBSY`. Only that status is retried; a
    /// retried launch still passes the same image validation.
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
            outputCollector.collect()
        }
        let errorTask = Task.detached(priority: .utility) {
            errorCollector.collect()
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

    private enum WaitOutcome {
        case exited
        case timedOut
        case cancelled
        case outputLimitReached
    }

    private func waitForExit(
        of child: AntigravityCLIReportChildProcess,
        timeout: Duration
    ) async -> WaitOutcome {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            if child.hasExited() {
                return .exited
            }
            if Task.isCancelled {
                return .cancelled
            }
            if child.outputLimitReached {
                return .outputLimitReached
            }
            if ContinuousClock.now >= deadline {
                return .timedOut
            }
            try? await Task.sleep(for: pollInterval)
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
        let executablePath =
            request.executable.canonicalURL.standardizedFileURL.path
        var standardOutputPipe = [Int32](repeating: -1, count: 2)
        var standardErrorPipe = [Int32](repeating: -1, count: 2)
        guard AntigravitySubprocessPipe.make(&standardOutputPipe),
            AntigravitySubprocessPipe.make(&standardErrorPipe)
        else {
            AntigravitySubprocessPipe.close(standardOutputPipe)
            AntigravitySubprocessPipe.close(standardErrorPipe)
            throw AntigravityCLIReportProcessError.launchFailed
        }
        func closePipes() {
            AntigravitySubprocessPipe.close(standardOutputPipe)
            AntigravitySubprocessPipe.close(standardErrorPipe)
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            closePipes()
            throw AntigravityCLIReportProcessError.launchFailed
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let workingDirectoryStatus = request.workingDirectoryURL.path.withCString {
            posix_spawn_file_actions_addchdir_np(&fileActions, $0)
        }
        let fileActionResults = [
            posix_spawn_file_actions_addopen(
                &fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0
            ),
            posix_spawn_file_actions_adddup2(
                &fileActions, standardOutputPipe[1], STDOUT_FILENO
            ),
            posix_spawn_file_actions_adddup2(
                &fileActions, standardErrorPipe[1], STDERR_FILENO
            ),
            posix_spawn_file_actions_addclose(&fileActions, standardOutputPipe[0]),
            posix_spawn_file_actions_addclose(&fileActions, standardOutputPipe[1]),
            posix_spawn_file_actions_addclose(&fileActions, standardErrorPipe[0]),
            posix_spawn_file_actions_addclose(&fileActions, standardErrorPipe[1]),
            workingDirectoryStatus,
        ]
        guard fileActionResults.allSatisfy({ $0 == 0 }) else {
            closePipes()
            throw AntigravityCLIReportProcessError.launchFailed
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            closePipes()
            throw AntigravityCLIReportProcessError.launchFailed
        }
        defer { posix_spawnattr_destroy(&attributes) }

        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] {
            sigaddset(&defaultSignals, signal)
        }
        var emptySignalMask = sigset_t()
        sigemptyset(&emptySignalMask)
        let flags =
            POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETPGROUP
            | POSIX_SPAWN_SETSIGDEF
            | POSIX_SPAWN_SETSIGMASK
            | POSIX_SPAWN_START_SUSPENDED
        guard posix_spawnattr_setflags(&attributes, Int16(flags)) == 0,
            posix_spawnattr_setpgroup(&attributes, 0) == 0,
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
            posix_spawnattr_setsigmask(&attributes, &emptySignalMask) == 0
        else {
            closePipes()
            throw AntigravityCLIReportProcessError.launchFailed
        }

        let argumentStrings = [executablePath] + request.arguments
        let environmentStrings: [String] = request.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var arguments: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { strdup($0) }
        var environment: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { strdup($0) }
        defer {
            arguments.forEach { free($0) }
            environment.forEach { free($0) }
        }
        guard arguments.allSatisfy({ $0 != nil }),
            environment.allSatisfy({ $0 != nil })
        else {
            closePipes()
            throw AntigravityCLIReportProcessError.launchFailed
        }
        arguments.append(nil)
        environment.append(nil)

        var processID: pid_t = 0
        let spawnStatus = Self.spawnRetryingTextFileBusy {
            executablePath.withCString { executable in
                posix_spawn(
                    &processID,
                    executable,
                    &fileActions,
                    &attributes,
                    &arguments,
                    &environment
                )
            }
        }
        guard spawnStatus == 0, processID > 0 else {
            closePipes()
            throw AntigravityCLIReportProcessError.launchFailed
        }

        Darwin.close(standardOutputPipe[1])
        Darwin.close(standardErrorPipe[1])
        let child = AntigravityCLIReportChildProcess(
            processID: processID,
            standardOutputFileDescriptor: standardOutputPipe[0],
            standardErrorFileDescriptor: standardErrorPipe[0]
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

/// Owns one spawned report process until it is reaped.
///
/// Every signal is sent under the same lock as `waitpid`, and only while the
/// root is unreaped, so neither the PID nor the process-group ID can refer to
/// another process at that moment.
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

    var outputLimitReached: Bool {
        lock.withLock { limitReached }
    }

    func cancelOwnedProcess() {
        lock.withLock { limitReached = true }
    }

    fileprivate func resume() -> Bool {
        lock.withLock {
            reapedStatus == nil && Darwin.kill(processID, SIGCONT) == 0
        }
    }

    /// Reports an exited root without reaping it, keeping its IDs reserved.
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
