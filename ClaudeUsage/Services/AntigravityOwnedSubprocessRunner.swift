import Darwin
import Foundation

nonisolated struct AntigravityOwnedSubprocessRequest: Sendable, Equatable {
    let executableURL: URL
    let arguments: [String]
    let timeout: TimeInterval
    let maximumOutputBytes: Int

    init(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int = 4 * 1_024 * 1_024
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
    }
}

nonisolated struct AntigravityOwnedSubprocessResult: Sendable, Equatable {
    let standardOutput: Data
    let standardError: Data
    let terminationStatus: Int32
}

nonisolated protocol AntigravityOwnedSubprocessRunning: Sendable {
    func run(
        _ request: AntigravityOwnedSubprocessRequest
    ) async throws -> AntigravityOwnedSubprocessResult
}

nonisolated enum AntigravityOwnedSubprocessError: Error, Equatable {
    case executableNotAllowed
    case invalidTimeout
    case invalidOutputLimit
    case launchFailed
    case waitFailed
    case timedOut
    case outputLimitExceeded
}

/// Runs only the short-lived discovery helpers created by ClaudeUsage itself.
///
/// The child PID stays owned until this runner reaps it with `waitpid(2)`.
/// Every signal is issued while holding the same lock used by `waitpid`, after
/// a `WNOHANG` ownership check. Therefore an exited child remains a zombie
/// (and its PID cannot be reused) between that check and `kill(2)`.
///
/// A PID discovered in `ps` output is never passed to `kill(2)`.
nonisolated final class AntigravityOwnedSubprocessRunner:
    AntigravityOwnedSubprocessRunning,
    @unchecked Sendable
{
    private static let forcedExitDelay: TimeInterval = 0.2
    private static let boundedReapWait: TimeInterval = 1

    private let allowedCanonicalExecutables: Set<String>
    private let environment: [String: String]

    init(
        allowedExecutableURLs: [URL] = [
            URL(fileURLWithPath: "/bin/ps"),
            URL(fileURLWithPath: "/usr/sbin/lsof"),
            URL(fileURLWithPath: "/usr/bin/lsof"),
        ],
        environment: [String: String] = [
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
    ) {
        self.allowedCanonicalExecutables = Set(
            allowedExecutableURLs.map(Self.canonicalPath(for:))
        )
        self.environment = environment
    }

    func run(
        _ request: AntigravityOwnedSubprocessRequest
    ) async throws -> AntigravityOwnedSubprocessResult {
        guard request.timeout.isFinite, request.timeout > 0 else {
            throw AntigravityOwnedSubprocessError.invalidTimeout
        }
        guard request.maximumOutputBytes > 0 else {
            throw AntigravityOwnedSubprocessError.invalidOutputLimit
        }
        let canonicalExecutable = Self.canonicalPath(for: request.executableURL)
        guard allowedCanonicalExecutables.contains(canonicalExecutable) else {
            throw AntigravityOwnedSubprocessError.executableNotAllowed
        }

        try Task.checkCancellation()

        let child = try Self.spawn(
            executablePath: canonicalExecutable,
            arguments: request.arguments,
            environment: environment
        )
        let lifecycle = AntigravityOwnedProcessLifecycle(
            processID: child.processID,
            forcedExitDelay: Self.forcedExitDelay
        )
        let exitRace = AntigravityProcessExitRace()
        let exitSignal = AntigravityOwnedProcessExitSignal()

        let outputCollector = AntigravityBoundedPipeCollector(
            fileDescriptor: child.standardOutputFileDescriptor,
            maximumBytes: request.maximumOutputBytes,
            lifecycle: lifecycle
        )
        let errorCollector = AntigravityBoundedPipeCollector(
            fileDescriptor: child.standardErrorFileDescriptor,
            maximumBytes: request.maximumOutputBytes,
            lifecycle: lifecycle
        )
        let outputTask = Task.detached(priority: .utility) {
            outputCollector.collect()
        }
        let errorTask = Task.detached(priority: .utility) {
            errorCollector.collect()
        }
        Task.detached(priority: .utility) {
            let result = lifecycle.waitUntilReaped()
            exitSignal.finish(result)
            switch result {
            case .terminated(let status):
                exitRace.finish(.terminated(status))
            case .failed:
                exitRace.finish(.waitFailed)
            }
        }

        let outcome = await withTaskCancellationHandler {
            await exitRace.wait(timeout: request.timeout)
        } onCancel: {
            lifecycle.cancelOwnedProcess()
            outputCollector.cancel()
            errorCollector.cancel()
            exitRace.finish(.cancelled)
        }

        switch outcome {
        case .terminated:
            break
        case .waitFailed:
            outputCollector.cancel()
            errorCollector.cancel()
        case .timedOut:
            lifecycle.cancelOwnedProcess()
            outputCollector.cancel()
            errorCollector.cancel()
        case .cancelled:
            lifecycle.cancelOwnedProcess()
            outputCollector.cancel()
            errorCollector.cancel()
        }

        if case .timedOut = outcome {
            _ = await exitSignal.wait(timeout: Self.boundedReapWait)
        } else if case .cancelled = outcome {
            _ = await exitSignal.wait(timeout: Self.boundedReapWait)
        }

        // Collectors use non-blocking poll and are explicitly cancelled on
        // timeout. They cannot wait forever when a descendant inherited a pipe
        // descriptor.
        let output = await outputTask.value
        let errorOutput = await errorTask.value

        switch outcome {
        case .waitFailed:
            throw AntigravityOwnedSubprocessError.waitFailed
        case .timedOut:
            throw AntigravityOwnedSubprocessError.timedOut
        case .cancelled:
            throw CancellationError()
        case .terminated(let status):
            try Task.checkCancellation()
            guard !output.exceededLimit, !errorOutput.exceededLimit else {
                throw AntigravityOwnedSubprocessError.outputLimitExceeded
            }
            return AntigravityOwnedSubprocessResult(
                standardOutput: output.data,
                standardError: errorOutput.data,
                terminationStatus: status
            )
        }
    }

    private static func spawn(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> AntigravitySpawnedOwnedProcess {
        guard !executablePath.contains("\0"),
              arguments.allSatisfy({ !$0.contains("\0") }),
              environment.allSatisfy({
                  !$0.key.contains("\0")
                      && !$0.key.contains("=")
                      && !$0.value.contains("\0")
              }) else {
            throw AntigravityOwnedSubprocessError.launchFailed
        }

        var standardOutputPipe = [Int32](repeating: -1, count: 2)
        var standardErrorPipe = [Int32](repeating: -1, count: 2)
        guard Self.makePipe(&standardOutputPipe),
              Self.makePipe(&standardErrorPipe) else {
            Self.closePipe(standardOutputPipe)
            Self.closePipe(standardErrorPipe)
            throw AntigravityOwnedSubprocessError.launchFailed
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            Self.closePipe(standardOutputPipe)
            Self.closePipe(standardErrorPipe)
            throw AntigravityOwnedSubprocessError.launchFailed
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            Self.closePipe(standardOutputPipe)
            Self.closePipe(standardErrorPipe)
            throw AntigravityOwnedSubprocessError.launchFailed
        }
        defer { posix_spawnattr_destroy(&attributes) }

        let spawnFlags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        let actionResults = [
            posix_spawnattr_setflags(&attributes, spawnFlags),
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDIN_FILENO,
                "/dev/null",
                O_RDONLY,
                0
            ),
            posix_spawn_file_actions_adddup2(
                &fileActions,
                standardOutputPipe[1],
                STDOUT_FILENO
            ),
            posix_spawn_file_actions_adddup2(
                &fileActions,
                standardErrorPipe[1],
                STDERR_FILENO
            ),
            posix_spawn_file_actions_addclose(
                &fileActions,
                standardOutputPipe[0]
            ),
            posix_spawn_file_actions_addclose(
                &fileActions,
                standardOutputPipe[1]
            ),
            posix_spawn_file_actions_addclose(
                &fileActions,
                standardErrorPipe[0]
            ),
            posix_spawn_file_actions_addclose(
                &fileActions,
                standardErrorPipe[1]
            ),
        ]
        guard actionResults.allSatisfy({ $0 == 0 }) else {
            Self.closePipe(standardOutputPipe)
            Self.closePipe(standardErrorPipe)
            throw AntigravityOwnedSubprocessError.launchFailed
        }

        let argumentStrings = [executablePath] + arguments
        let environmentStrings = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var argumentPointers = argumentStrings.map { strdup($0) }
        var environmentPointers = environmentStrings.map { strdup($0) }
        guard argumentPointers.allSatisfy({ $0 != nil }),
              environmentPointers.allSatisfy({ $0 != nil }) else {
            argumentPointers.forEach { free($0) }
            environmentPointers.forEach { free($0) }
            Self.closePipe(standardOutputPipe)
            Self.closePipe(standardErrorPipe)
            throw AntigravityOwnedSubprocessError.launchFailed
        }
        argumentPointers.append(nil)
        environmentPointers.append(nil)
        defer {
            argumentPointers.forEach { free($0) }
            environmentPointers.forEach { free($0) }
        }

        var processID: pid_t = 0
        let spawnResult = executablePath.withCString { executablePointer in
            argumentPointers.withUnsafeMutableBufferPointer { arguments in
                environmentPointers.withUnsafeMutableBufferPointer {
                    environment in
                    posix_spawn(
                        &processID,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        arguments.baseAddress,
                        environment.baseAddress
                    )
                }
            }
        }

        guard spawnResult == 0, processID > 0 else {
            Self.closePipe(standardOutputPipe)
            Self.closePipe(standardErrorPipe)
            throw AntigravityOwnedSubprocessError.launchFailed
        }

        Darwin.close(standardOutputPipe[1])
        Darwin.close(standardErrorPipe[1])
        return AntigravitySpawnedOwnedProcess(
            processID: processID,
            standardOutputFileDescriptor: standardOutputPipe[0],
            standardErrorFileDescriptor: standardErrorPipe[0]
        )
    }

    private static func makePipe(_ descriptors: inout [Int32]) -> Bool {
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.pipe(buffer.baseAddress!)
        }
        guard result == 0 else {
            return false
        }

        // File actions target descriptors 0, 1 and 2. Normalize both pipe
        // endpoints above that range so a parent with a closed standard stream
        // cannot turn a later `addclose` into closing the child's redirected
        // stdout or stderr.
        for index in descriptors.indices where descriptors[index] <= STDERR_FILENO {
            let duplicated = fcntl(
                descriptors[index],
                F_DUPFD_CLOEXEC,
                STDERR_FILENO + 1
            )
            guard duplicated >= 0 else {
                Self.closePipe(descriptors)
                descriptors = [-1, -1]
                return false
            }
            Darwin.close(descriptors[index])
            descriptors[index] = duplicated
        }

        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFD)
            if flags < 0 || fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) < 0 {
                Self.closePipe(descriptors)
                descriptors = [-1, -1]
                return false
            }
        }
        return true
    }

    private static func closePipe(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    private static func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

private nonisolated enum AntigravityTerminationRace: Sendable {
    case terminated(Int32)
    case waitFailed
    case timedOut
    case cancelled
}

private nonisolated struct AntigravitySpawnedOwnedProcess: Sendable {
    let processID: pid_t
    let standardOutputFileDescriptor: Int32
    let standardErrorFileDescriptor: Int32
}

private nonisolated struct AntigravityCappedSubprocessOutput: Sendable {
    let data: Data
    let exceededLimit: Bool
}

private nonisolated enum AntigravityOwnedProcessExit: Sendable {
    case terminated(Int32)
    case failed
}

private nonisolated final class AntigravityOwnedProcessLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private let processID: pid_t
    private let forcedExitDelay: TimeInterval
    private var terminalResult: AntigravityOwnedProcessExit?
    private var terminationRequested = false

    init(processID: pid_t, forcedExitDelay: TimeInterval) {
        self.processID = processID
        self.forcedExitDelay = forcedExitDelay
    }

    func waitUntilReaped() -> AntigravityOwnedProcessExit {
        while true {
            lock.lock()
            let result = observeOwnedChildLocked()
            lock.unlock()

            switch result {
            case .running:
                usleep(10_000)
            case .terminal(let terminalResult):
                return terminalResult
            }
        }
    }

    func cancelOwnedProcess() {
        lock.lock()
        let shouldScheduleForcedExit = !terminationRequested
        terminationRequested = true
        signalOwnedChildLocked(SIGTERM)
        lock.unlock()

        guard shouldScheduleForcedExit else {
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + forcedExitDelay
        ) { [self] in
            lock.withLock {
                signalOwnedChildLocked(SIGKILL)
            }
        }
    }

    var hasReleasedOwnership: Bool {
        lock.withLock { terminalResult != nil }
    }

    private func signalOwnedChildLocked(_ signal: Int32) {
        guard case .running = observeOwnedChildLocked() else {
            return
        }

        // The waitpid ownership check and kill are performed under the same
        // lock. If the child exits after WNOHANG reports it running, it remains
        // an unreaped zombie until this lock is released, so this PID still
        // cannot refer to another process here.
        _ = Darwin.kill(processID, signal)
    }

    private func observeOwnedChildLocked() -> AntigravityOwnedChildObservation {
        if let terminalResult {
            return .terminal(terminalResult)
        }

        var status: Int32 = 0
        while true {
            let waitResult = Darwin.waitpid(processID, &status, WNOHANG)
            if waitResult == 0 {
                return .running
            }
            if waitResult == processID {
                let result = AntigravityOwnedProcessExit.terminated(
                    Self.terminationStatus(from: status)
                )
                terminalResult = result
                return .terminal(result)
            }
            if waitResult < 0, errno == EINTR {
                continue
            }

            let result = AntigravityOwnedProcessExit.failed
            terminalResult = result
            return .terminal(result)
        }
    }

    private static func terminationStatus(from waitStatus: Int32) -> Int32 {
        let terminatingSignal = waitStatus & 0x7F
        if terminatingSignal == 0 {
            return (waitStatus >> 8) & 0xFF
        }
        return terminatingSignal
    }
}

private nonisolated enum AntigravityOwnedChildObservation {
    case running
    case terminal(AntigravityOwnedProcessExit)
}

private nonisolated final class AntigravityOwnedProcessExitSignal:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var result: AntigravityOwnedProcessExit?
    private var continuations: [
        UUID: CheckedContinuation<AntigravityOwnedProcessExit?, Never>
    ] = [:]

    func finish(_ result: AntigravityOwnedProcessExit) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuations = Array(self.continuations.values)
        self.continuations.removeAll()
        lock.unlock()

        continuations.forEach { $0.resume(returning: result) }
    }

    func wait(timeout: TimeInterval) async -> AntigravityOwnedProcessExit? {
        let identifier = UUID()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout
        ) { [weak self] in
            self?.timeOut(identifier)
        }

        return await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                continuations[identifier] = continuation
                lock.unlock()
            }
        }
    }

    private func timeOut(_ identifier: UUID) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: identifier)
        lock.unlock()
        continuation?.resume(returning: nil)
    }
}

private nonisolated final class AntigravityProcessExitRace: @unchecked Sendable {
    private let lock = NSLock()
    private var result: AntigravityTerminationRace?
    private var continuation:
        CheckedContinuation<AntigravityTerminationRace, Never>?

    func finish(_ result: AntigravityTerminationRace) {
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

    func wait(timeout: TimeInterval) async -> AntigravityTerminationRace {
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout
        ) { [weak self] in
            self?.finish(.timedOut)
        }

        return await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

private nonisolated final class AntigravityBoundedPipeCollector:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let fileDescriptor: Int32
    private let maximumBytes: Int
    private let lifecycle: AntigravityOwnedProcessLifecycle
    private var cancelled = false

    init(
        fileDescriptor: Int32,
        maximumBytes: Int,
        lifecycle: AntigravityOwnedProcessLifecycle
    ) {
        self.fileDescriptor = fileDescriptor
        self.maximumBytes = maximumBytes
        self.lifecycle = lifecycle
        let existingFlags = fcntl(fileDescriptor, F_GETFL)
        if existingFlags >= 0 {
            _ = fcntl(fileDescriptor, F_SETFL, existingFlags | O_NONBLOCK)
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
        }
    }

    func collect() -> AntigravityCappedSubprocessOutput {
        defer { Darwin.close(fileDescriptor) }
        var data = Data()
        var exceededLimit = false
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)

        while true {
            if lock.withLock({ cancelled }) {
                break
            }

            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = Darwin.poll(&descriptor, 1, 50)

            if pollResult > 0,
               drainAvailable(
                   into: &data,
                   exceededLimit: &exceededLimit,
                   buffer: &buffer
               ) {
                return AntigravityCappedSubprocessOutput(
                    data: data,
                    exceededLimit: exceededLimit
                )
            }

            if lifecycle.hasReleasedOwnership {
                // The child may have written and exited immediately after a
                // zero-result poll. Reap ownership is therefore followed by
                // one unconditional non-blocking drain before the pipe closes.
                _ = drainAvailable(
                    into: &data,
                    exceededLimit: &exceededLimit,
                    buffer: &buffer
                )
                break
            }
        }

        return AntigravityCappedSubprocessOutput(
            data: data,
            exceededLimit: exceededLimit
        )
    }

    /// Drains all bytes currently readable from the non-blocking descriptor.
    /// Returns true after EOF or a terminal read error.
    private func drainAvailable(
        into data: inout Data,
        exceededLimit: inout Bool,
        buffer: inout [UInt8]
    ) -> Bool {
        while true {
            let bufferCount = buffer.count
            let count = buffer.withUnsafeMutableBytes { pointer in
                Darwin.read(
                    fileDescriptor,
                    pointer.baseAddress,
                    bufferCount
                )
            }
            if count > 0 {
                let remaining = max(0, maximumBytes - data.count)
                if remaining > 0 {
                    data.append(
                        contentsOf: buffer.prefix(min(count, remaining))
                    )
                }
                if count > remaining {
                    exceededLimit = true
                    lifecycle.cancelOwnedProcess()
                }
                continue
            }
            if count == 0 {
                return true
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return false
            }
            return true
        }
    }
}
