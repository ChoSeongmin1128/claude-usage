import Darwin
import Foundation

nonisolated struct AntigravityManagedCLIEnvironment:
    Sendable,
    Equatable
{
    let values: [String: String]

    init(
        homeDirectory: URL = FileManager.default.realHomeDirectory,
        userName: String? = NSUserName()
    ) {
        let home = homeDirectory.standardizedFileURL.path
        var values = [
            "AGY_CLI_DISABLE_AUTO_UPDATE": "true",
            "HOME": home,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PATH":
                "\(home)/.local/bin:\(home)/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "TERM": "xterm-256color",
        ]
        if let userName = userName?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !userName.isEmpty {
            values["USER"] = userName
        }
        self.values = values
    }
}

nonisolated struct AntigravityManagedCLIProcessLaunchRequest:
    Sendable,
    Equatable
{
    let executable: AntigravityCanonicalExecutable
    let environment: AntigravityManagedCLIEnvironment
    let currentDirectoryURL: URL

    init?(
        executable: AntigravityCanonicalExecutable,
        environment: AntigravityManagedCLIEnvironment,
        currentDirectoryURL: URL
    ) {
        guard executable.role == .agyCLI else {
            return nil
        }
        self.executable = executable
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL.standardizedFileURL
    }
}

nonisolated protocol AntigravityManagedCLIProcessHandling:
    AnyObject,
    Sendable
{
    var processID: Int32 { get }
    var processGroupID: Int32 { get }

    /// Resumes a root that was created with
    /// `POSIX_SPAWN_START_SUSPENDED`. This is the only transition that lets
    /// AGY user code run, and must happen only after durable ownership state
    /// has been verified.
    func resume() throws

    /// Returns only newly drained bytes and never blocks.
    func drainOutput(maximumBytes: Int) -> Data

    /// Observes an exited root without reaping it, preserving PID and process
    /// group authority until `terminateTree` completes cleanup.
    func terminationStatus() -> Int32?

    /// Signals only the process group created by this handle.
    ///
    /// `.confirmed` means the suspended/managed root was positively reaped
    /// (or was already no longer this handle's child). Callers must preserve
    /// durable launch ownership when termination cannot be confirmed.
    func terminateTree(
        gracePeriod: Duration
    ) async -> AntigravityManagedCLIProcessTerminationEvidence
}

nonisolated enum AntigravityManagedCLIProcessTerminationEvidence:
    Sendable,
    Equatable
{
    case confirmed
    case unconfirmed
}

nonisolated protocol AntigravityManagedCLIProcessLaunching: Sendable {
    /// Returns only a suspended child whose kernel-mapped executable vnode
    /// matches the reviewed catalog identity. Implementations must fail closed
    /// and reap the child when that image cannot be established.
    func launchSuspended(
        _ request: AntigravityManagedCLIProcessLaunchRequest
    ) throws -> any AntigravityManagedCLIProcessHandling
}

/// Spawns one exact catalog-approved AGY binary, initially suspended, in its
/// own PTY and process group. No shell, profile script, inherited token
/// environment, or automatic TUI input crosses this boundary.
nonisolated struct AntigravityManagedCLIProcessLauncher:
    AntigravityManagedCLIProcessLaunching
{
    private let executableRevalidator:
        any AntigravityExecutableRevalidating
    private let runningExecutableImageValidator:
        any AntigravityRunningExecutableImageValidating

    init(
        executableRevalidator:
            any AntigravityExecutableRevalidating =
                AntigravityPinnedAGYExecutableRevalidator(),
        runningExecutableImageValidator:
            any AntigravityRunningExecutableImageValidating =
                AntigravitySystemRunningExecutableImageValidator()
    ) {
        self.executableRevalidator = executableRevalidator
        self.runningExecutableImageValidator =
            runningExecutableImageValidator
    }

    func launchSuspended(
        _ request: AntigravityManagedCLIProcessLaunchRequest
    ) throws -> any AntigravityManagedCLIProcessHandling {
        guard request.executable.role == .agyCLI,
              executableRevalidator.isCurrent(
                  request.executable
              ) else {
            throw AntigravityManagedSessionError.executableNotAllowed
        }

        let executablePath =
            request.executable.canonicalURL.standardizedFileURL.path
        guard FileManager.default.isExecutableFile(
            atPath: executablePath
        ) else {
            throw AntigravityManagedSessionError.executableNotAllowed
        }

        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var windowSize = winsize(
            ws_row: 50,
            ws_col: 160,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard openpty(
            &primaryFD,
            &secondaryFD,
            nil,
            nil,
            &windowSize
        ) == 0 else {
            throw AntigravityManagedSessionError.launchFailed
        }

        func closePTYPair() {
            if primaryFD >= 0 {
                Darwin.close(primaryFD)
                primaryFD = -1
            }
            if secondaryFD >= 0 {
                Darwin.close(secondaryFD)
                secondaryFD = -1
            }
        }

        guard fcntl(primaryFD, F_SETFL, O_NONBLOCK) == 0 else {
            closePTYPair()
            throw AntigravityManagedSessionError.launchFailed
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            closePTYPair()
            throw AntigravityManagedSessionError.launchFailed
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        guard posix_spawn_file_actions_adddup2(
            &fileActions,
            secondaryFD,
            STDIN_FILENO
        ) == 0,
        posix_spawn_file_actions_adddup2(
            &fileActions,
            secondaryFD,
            STDOUT_FILENO
        ) == 0,
        posix_spawn_file_actions_adddup2(
            &fileActions,
            secondaryFD,
            STDERR_FILENO
        ) == 0,
        posix_spawn_file_actions_addclose(
            &fileActions,
            primaryFD
        ) == 0,
        posix_spawn_file_actions_addclose(
            &fileActions,
            secondaryFD
        ) == 0 else {
            closePTYPair()
            throw AntigravityManagedSessionError.launchFailed
        }

        let workingDirectory = request.currentDirectoryURL.path
        let changeDirectoryStatus = workingDirectory.withCString { path in
            posix_spawn_file_actions_addchdir_np(&fileActions, path)
        }
        guard changeDirectoryStatus == 0 else {
            closePTYPair()
            throw AntigravityManagedSessionError.launchFailed
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            closePTYPair()
            throw AntigravityManagedSessionError.launchFailed
        }
        defer { posix_spawnattr_destroy(&attributes) }

        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGINT)
        sigaddset(&defaultSignals, SIGTERM)
        sigaddset(&defaultSignals, SIGHUP)
        var emptySignalMask = sigset_t()
        sigemptyset(&emptySignalMask)

        let flags = POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETPGROUP
            | POSIX_SPAWN_SETSIGDEF
            | POSIX_SPAWN_SETSIGMASK
            | POSIX_SPAWN_START_SUSPENDED
        guard posix_spawnattr_setflags(
            &attributes,
            Int16(flags)
        ) == 0,
        posix_spawnattr_setpgroup(&attributes, 0) == 0,
        posix_spawnattr_setsigdefault(
            &attributes,
            &defaultSignals
        ) == 0,
        posix_spawnattr_setsigmask(
            &attributes,
            &emptySignalMask
        ) == 0 else {
            closePTYPair()
            throw AntigravityManagedSessionError.launchFailed
        }

        var arguments = [strdup(executablePath), nil]
        defer {
            if let argument = arguments[0] {
                free(argument)
            }
        }
        var environment = request.environment.values
            .map { strdup("\($0.key)=\($0.value)") }
        environment.append(nil)
        defer {
            for entry in environment {
                if let entry {
                    free(entry)
                }
            }
        }

        var processID: pid_t = 0
        func terminateSpawnedRoot() {
            guard processID > 0 else {
                closePTYPair()
                return
            }
            // START_SUSPENDED guarantees that untrusted user code has not run
            // and therefore cannot have created descendants. The unreaped
            // child PID is exact authority until this wait completes.
            _ = Darwin.kill(processID, SIGKILL)
            var status: Int32 = 0
            while waitpid(processID, &status, 0) == -1,
                  errno == EINTR {}
            closePTYPair()
        }
        let spawnStatus = executablePath.withCString { executable in
            posix_spawn(
                &processID,
                executable,
                &fileActions,
                &attributes,
                &arguments,
                &environment
            )
        }
        guard spawnStatus == 0, processID > 0 else {
            closePTYPair()
            throw AntigravityManagedSessionError.launchFailed
        }

        Darwin.close(secondaryFD)
        secondaryFD = -1

        guard getpgid(processID) == processID else {
            terminateSpawnedRoot()
            throw AntigravityManagedSessionError.processGroupInvalid
        }
        guard runningExecutableImageValidator
            .validatesRunningImage(
                processID: processID,
                executable: request.executable
            ) else {
            terminateSpawnedRoot()
            throw AntigravityManagedSessionError.executableNotAllowed
        }

        let handle = AntigravitySpawnedManagedCLIProcess(
            processID: processID,
            processGroupID: processID,
            primaryFileDescriptor: primaryFD
        )
        primaryFD = -1
        return handle
    }
}

nonisolated final class AntigravitySpawnedManagedCLIProcess:
    AntigravityManagedCLIProcessHandling,
    @unchecked Sendable
{
    let processID: Int32
    let processGroupID: Int32

    private let lock = NSLock()
    private var primaryFileDescriptor: Int32
    private var reapedStatus: Int32?
    private var observedTerminationStatus: Int32?
    private var wasResumed = false

    fileprivate init(
        processID: Int32,
        processGroupID: Int32,
        primaryFileDescriptor: Int32
    ) {
        precondition(
            processID > 0
                && processGroupID == processID
                && primaryFileDescriptor >= 0
        )
        self.processID = processID
        self.processGroupID = processGroupID
        self.primaryFileDescriptor = primaryFileDescriptor
    }

    func resume() throws {
        try lock.withLock {
            guard !wasResumed else { return }
            guard reapedStatus == nil,
                  observedTerminationStatus == nil else {
                throw AntigravityManagedSessionError.launchFailed
            }

            // The root is still our unreaped child and cannot have been
            // replaced by PID reuse. It has not run user code yet, so it
            // cannot have created descendants that also need SIGCONT.
            guard Darwin.kill(processID, SIGCONT) == 0 else {
                throw AntigravityManagedSessionError.launchFailed
            }
            wasResumed = true
        }
    }

    deinit {
        lock.withLock {
            if reapedStatus == nil {
                _ = Darwin.kill(-processGroupID, SIGKILL)
                // The child may have moved itself to another process group.
                // Its unreaped PID cannot be reused, so the direct signal
                // remains exact authority for the original child.
                _ = Darwin.kill(processID, SIGKILL)
                var status: Int32 = 0
                while waitpid(processID, &status, 0) == -1,
                      errno == EINTR {}
                reapedStatus = Self.normalizedStatus(status)
            }
            closePTYLocked()
        }
    }

    func drainOutput(maximumBytes: Int) -> Data {
        guard maximumBytes > 0 else { return Data() }

        lock.lock()
        defer { lock.unlock() }
        guard primaryFileDescriptor >= 0 else { return Data() }

        var result = Data()
        var buffer = [UInt8](
            repeating: 0,
            count: min(8_192, maximumBytes)
        )
        while result.count < maximumBytes {
            let requested = min(
                buffer.count,
                maximumBytes - result.count
            )
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    primaryFileDescriptor,
                    bytes.baseAddress,
                    requested
                )
            }
            if count > 0 {
                result.append(buffer, count: count)
                continue
            }
            if count == -1, errno == EINTR {
                continue
            }
            break
        }
        return result
    }

    func terminationStatus() -> Int32? {
        lock.withLock {
            if let observedTerminationStatus {
                return observedTerminationStatus
            }
            if let reapedStatus {
                return reapedStatus
            }

            var information = siginfo_t()
            let result = waitid(
                P_PID,
                id_t(processID),
                &information,
                WEXITED | WNOHANG | WNOWAIT
            )
            if result == 0, information.si_pid != 0 {
                let status: Int32
                if information.si_code == CLD_EXITED {
                    status = information.si_status
                } else {
                    status = 128 + information.si_status
                }
                observedTerminationStatus = status
                return status
            }
            if result == -1, errno == ECHILD {
                reapedStatus = 0
                return 0
            }
            return nil
        }
    }

    func terminateTree(
        gracePeriod: Duration
    ) async -> AntigravityManagedCLIProcessTerminationEvidence {
        let shouldWaitForGracePeriod = lock.withLock {
            if reapedStatus == nil {
                if wasResumed,
                   getpgid(processID) == processGroupID {
                    _ = Darwin.kill(-processGroupID, SIGTERM)
                }
                if wasResumed {
                    // A group leader is not a session leader and may move
                    // itself into another group. The unreaped child PID is
                    // still reserved, so signalling it directly cannot hit
                    // a reused execution.
                    _ = Darwin.kill(processID, SIGTERM)
                } else {
                    // A suspended root cannot run a TERM handler. Kill it
                    // directly instead of waiting through a grace interval
                    // that cannot make progress.
                    _ = Darwin.kill(processID, SIGKILL)
                }
            }
            closePTYLocked()
            return wasResumed
        }

        if shouldWaitForGracePeriod, gracePeriod > .zero {
            try? await Task.sleep(for: gracePeriod)
        }

        // Do not reap between TERM and KILL. Even if the root has exited and
        // become a zombie, its PID remains reserved, so the recorded process
        // group ID cannot be reassigned to an unrelated process.
        lock.withLock {
            if reapedStatus == nil {
                _ = Darwin.kill(-processGroupID, SIGKILL)
                _ = Darwin.kill(processID, SIGKILL)
            }
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline {
            let status = lock.withLock {
                reapIfExitedLocked()
            }
            if status != nil {
                return .confirmed
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        return lock.withLock {
            reapIfExitedLocked() == nil
                ? .unconfirmed
                : .confirmed
        }
    }

    private func reapIfExitedLocked() -> Int32? {
        if let reapedStatus {
            return reapedStatus
        }
        var status: Int32 = 0
        let result = waitpid(processID, &status, WNOHANG)
        switch result {
        case processID:
            let normalized = Self.normalizedStatus(status)
            reapedStatus = normalized
            return normalized
        case -1 where errno == ECHILD:
            reapedStatus = 0
            return 0
        default:
            return nil
        }
    }

    private func closePTYLocked() {
        guard primaryFileDescriptor >= 0 else { return }
        Darwin.close(primaryFileDescriptor)
        primaryFileDescriptor = -1
    }

    private static func normalizedStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + signal
    }
}

nonisolated protocol AntigravityManagedProcessIdentityProviding:
    Sendable
{
    func identity(
        for processID: Int32
    ) -> AntigravityRecordedProcessIdentity?

    func processGroupID(for processID: Int32) -> Int32?
}

nonisolated protocol AntigravityKernelProcessIdentityReading:
    Sendable
{
    func kernelIdentity(
        for processID: Int32
    ) -> AntigravityKernelProcessIdentity?
}

/// Isolates the one Darwin-private process-info flavor used by managed
/// process containment.
///
/// The returned 56-byte structure is part of Apple's XNU user-space ABI but
/// is not declared by the public macOS SDK. Failure to read it disables
/// managed launch/recovery rather than falling back to PID-only authority.
nonisolated struct AntigravitySystemKernelProcessIdentityReader:
    AntigravityKernelProcessIdentityReading
{
    private struct RawUniqueIdentifierInfo {
        var executableUUIDHigh: UInt64 = 0
        var executableUUIDLow: UInt64 = 0
        var uniqueID: UInt64 = 0
        var parentUniqueID: UInt64 = 0
        var pidVersion: Int32 = 0
        var originalParentPIDVersion: Int32 = 0
        var reserved2: UInt64 = 0
        var reserved3: UInt64 = 0
    }

    private static let uniqueIdentifierFlavor: Int32 = 17
    private static let expectedSize = 56
    private let includeTerminatedProcesses: Bool

    init(
        includeTerminatedProcesses: Bool = false
    ) {
        self.includeTerminatedProcesses =
            includeTerminatedProcesses
    }

    func kernelIdentity(
        for processID: Int32
    ) -> AntigravityKernelProcessIdentity? {
        guard processID > 1,
              MemoryLayout<RawUniqueIdentifierInfo>.size
                == Self.expectedSize else {
            return nil
        }

        var info = RawUniqueIdentifierInfo()
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(
                processID,
                Self.uniqueIdentifierFlavor,
                includeTerminatedProcesses ? 1 : 0,
                $0,
                Int32(Self.expectedSize)
            )
        }
        guard result == Self.expectedSize else {
            return nil
        }
        return AntigravityKernelProcessIdentity(
            uniqueID: info.uniqueID,
            parentUniqueID: info.parentUniqueID,
            pidVersion: info.pidVersion
        )
    }
}

/// Produces a stable identity by double-reading both BSD metadata and the
/// executable image plus the kernel unique identifier. Callers still decide
/// whether that image is an allowed AGY binary or the current ClaudeUsage
/// owner executable.
nonisolated final class AntigravityManagedProcessIdentityProvider:
    AntigravityManagedProcessIdentityProviding,
    @unchecked Sendable
{
    private let libprocReader: any AntigravityLibprocReading
    private let kernelIdentityReader:
        any AntigravityKernelProcessIdentityReading

    init(
        libprocReader: any AntigravityLibprocReading =
            AntigravitySystemLibprocReader(),
        kernelIdentityReader:
            any AntigravityKernelProcessIdentityReading =
                AntigravitySystemKernelProcessIdentityReader()
    ) {
        self.libprocReader = libprocReader
        self.kernelIdentityReader = kernelIdentityReader
    }

    func identity(
        for processID: Int32
    ) -> AntigravityRecordedProcessIdentity? {
        guard let before = libprocReader.bsdInfo(for: processID),
              let kernelBefore =
                kernelIdentityReader.kernelIdentity(
                    for: processID
                ),
              let executableBefore =
                libprocReader.executableURL(for: processID)?
                    .resolvingSymlinksInPath()
                    .standardizedFileURL,
              let during = libprocReader.bsdInfo(for: processID),
              before == during,
              let kernelDuring =
                kernelIdentityReader.kernelIdentity(
                    for: processID
                ),
              kernelBefore == kernelDuring,
              let executableAfter =
                libprocReader.executableURL(for: processID)?
                    .resolvingSymlinksInPath()
                    .standardizedFileURL,
              executableBefore == executableAfter,
              let after = libprocReader.bsdInfo(for: processID),
              before == after,
              let kernelAfter =
                kernelIdentityReader.kernelIdentity(
                    for: processID
                ),
              kernelBefore == kernelAfter else {
            return nil
        }

        return AntigravityRecordedProcessIdentity(
            pid: processID,
            effectiveUserID: before.effectiveUserID.rawValue,
            realUserID: before.realUserID.rawValue,
            startedAtSeconds: before.startedAt.seconds,
            startedAtMicroseconds: before.startedAt.microseconds,
            executablePath: executableAfter.path,
            kernelIdentity: kernelAfter
        )
    }

    func processGroupID(for processID: Int32) -> Int32? {
        guard processID > 0 else { return nil }
        let groupID = getpgid(processID)
        return groupID > 0 ? groupID : nil
    }
}

nonisolated extension AntigravityRecordedProcessIdentity {
    func verifiedIdentity(
        matching executable: AntigravityCanonicalExecutable
    ) -> AntigravityVerifiedProcessIdentity? {
        guard executable.role == .agyCLI,
              executablePath
                == executable.canonicalURL.standardizedFileURL.path,
              let startedAt = AntigravityProcessStartTime(
                  seconds: startedAtSeconds,
                  microseconds: startedAtMicroseconds
              ) else {
            return nil
        }
        return AntigravityVerifiedProcessIdentity(
            processID: pid,
            effectiveUserID:
                AntigravityUserID(rawValue: effectiveUserID),
            realUserID:
                AntigravityUserID(rawValue: realUserID),
            startedAt: startedAt,
            executable: executable
        )
    }
}
