import Darwin
import Foundation

nonisolated enum OwnedSubprocessPipe {
    static func make(_ descriptors: inout [Int32]) -> Bool {
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
                Self.close(descriptors)
                descriptors = [-1, -1]
                return false
            }
            Darwin.close(descriptors[index])
            descriptors[index] = duplicated
        }

        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFD)
            if flags < 0 || fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) < 0 {
                Self.close(descriptors)
                descriptors = [-1, -1]
                return false
            }
        }
        return true
    }

    static func close(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }
}

nonisolated struct OwnedSpawnedSubprocess: Sendable {
    let processID: pid_t
    let standardOutputFileDescriptor: Int32
    let standardErrorFileDescriptor: Int32
}

// stdin is /dev/null and stdout/stderr are pipes whose read ends the caller
// owns; every other descriptor is closed in the child.
nonisolated enum OwnedSubprocessSpawn {
    struct Options {
        var workingDirectoryPath: String?
        var ownProcessGroup = false
        var startSuspended = false
        var qosClass: qos_class_t?
    }

    static func spawn(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        options: Options = Options(),
        attempt: (() -> Int32) -> Int32 = { $0() }
    ) -> OwnedSpawnedSubprocess? {
        var standardOutputPipe = [Int32](repeating: -1, count: 2)
        var standardErrorPipe = [Int32](repeating: -1, count: 2)
        guard OwnedSubprocessPipe.make(&standardOutputPipe),
            OwnedSubprocessPipe.make(&standardErrorPipe)
        else {
            OwnedSubprocessPipe.close(standardOutputPipe)
            OwnedSubprocessPipe.close(standardErrorPipe)
            return nil
        }
        func closePipes() {
            OwnedSubprocessPipe.close(standardOutputPipe)
            OwnedSubprocessPipe.close(standardErrorPipe)
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            closePipes()
            return nil
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var actionResults = [
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
        ]
        if let workingDirectoryPath = options.workingDirectoryPath {
            actionResults.append(
                workingDirectoryPath.withCString {
                    posix_spawn_file_actions_addchdir_np(&fileActions, $0)
                }
            )
        }
        guard actionResults.allSatisfy({ $0 == 0 }) else {
            closePipes()
            return nil
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            closePipes()
            return nil
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard configure(&attributes, options) else {
            closePipes()
            return nil
        }

        let argumentStrings = [executablePath] + arguments
        let environmentStrings: [String] =
            environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var argumentPointers: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { strdup($0) }
        var environmentPointers: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { strdup($0) }
        defer {
            argumentPointers.forEach { free($0) }
            environmentPointers.forEach { free($0) }
        }
        guard argumentPointers.allSatisfy({ $0 != nil }),
            environmentPointers.allSatisfy({ $0 != nil })
        else {
            closePipes()
            return nil
        }
        argumentPointers.append(nil)
        environmentPointers.append(nil)

        var processID: pid_t = 0
        let spawnResult = attempt {
            executablePath.withCString { executablePointer in
                argumentPointers.withUnsafeMutableBufferPointer { arguments in
                    environmentPointers.withUnsafeMutableBufferPointer { environment in
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
        }
        guard spawnResult == 0, processID > 0 else {
            closePipes()
            return nil
        }

        Darwin.close(standardOutputPipe[1])
        Darwin.close(standardErrorPipe[1])
        return OwnedSpawnedSubprocess(
            processID: processID,
            standardOutputFileDescriptor: standardOutputPipe[0],
            standardErrorFileDescriptor: standardErrorPipe[0]
        )
    }

    static func configure(
        _ attributes: inout posix_spawnattr_t?,
        _ options: Options
    ) -> Bool {
        var flags = POSIX_SPAWN_CLOEXEC_DEFAULT
        if options.ownProcessGroup {
            flags |= POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        }
        if options.startSuspended {
            flags |= POSIX_SPAWN_START_SUSPENDED
        }
        guard posix_spawnattr_setflags(&attributes, Int16(flags)) == 0 else {
            return false
        }
        if let qosClass = options.qosClass,
            posix_spawnattr_set_qos_class_np(&attributes, qosClass) != 0
        {
            return false
        }
        guard options.ownProcessGroup else {
            return true
        }
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] {
            sigaddset(&defaultSignals, signal)
        }
        var emptySignalMask = sigset_t()
        sigemptyset(&emptySignalMask)
        return posix_spawnattr_setpgroup(&attributes, 0) == 0
            && posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0
            && posix_spawnattr_setsigmask(&attributes, &emptySignalMask) == 0
    }
}

// The first outcome wins; later ones are ignored. `wait` is called once.
nonisolated final class OwnedSubprocessOneShotRace<Outcome: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?

    func finish(_ result: Outcome) {
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

    func wait(timeout: TimeInterval, orElse timeoutOutcome: Outcome) async -> Outcome {
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout
        ) { [weak self] in
            self?.finish(timeoutOutcome)
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
