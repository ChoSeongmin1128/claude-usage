import Darwin
import Foundation

nonisolated struct ClaudeCodeExecutableSelection: Equatable, Sendable {
    let originalURL: URL
    let executableURL: URL
    let searchDirectories: [String]

    var isCurrent: Bool {
        ExternalCommand.firstTrustedExecutable(in: [originalURL]) == executableURL
    }

    static func known(home: URL) -> Self? {
        let directories = ExternalCommand.searchDirectories(home: home)
        let candidates =
            [
                home.appendingPathComponent(".local/bin/claude"),
                home.appendingPathComponent(".claude/local/claude"),
            ] + directories.map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }
        for candidate in candidates {
            if let executable = ExternalCommand.firstTrustedExecutable(in: [candidate]) {
                return Self(
                    originalURL: candidate, executableURL: executable,
                    searchDirectories: [candidate.deletingLastPathComponent().path] + directories)
            }
        }
        return nil
    }
}

nonisolated final class ClaudeCodeExecutableResolver: @unchecked Sendable {
    typealias Lookup = @Sendable () async -> ClaudeCodeExecutableSelection?
    private let known: @Sendable () -> ClaudeCodeExecutableSelection?
    private let lookup: Lookup
    private let lock = NSLock()
    private var flight: Task<ClaudeCodeExecutableSelection?, Never>?
    private var cached: ClaudeCodeExecutableSelection?

    init(
        known: @escaping @Sendable () -> ClaudeCodeExecutableSelection?,
        lookup: @escaping Lookup
    ) {
        self.known = known
        self.lookup = lookup
    }

    func cachedSelection() -> ClaudeCodeExecutableSelection? {
        if let selection = known(), selection.isCurrent { return selection }
        return lock.withLock { cached }.flatMap { $0.isCurrent ? $0 : nil }
    }

    func resolve() async -> ClaudeCodeExecutableSelection? {
        guard !Task.isCancelled else { return nil }
        if let selection = cachedSelection() { return selection }
        let task = lock.withLock {
            if let flight { return flight }
            let task = Task.detached(priority: .utility) { [self] in
                let selection = await lookup()
                lock.withLock { cached = selection }
                return selection
            }
            flight = task
            return task
        }
        let race = OwnedSubprocessOneShotRace<ClaudeCodeExecutableSelection?>()
        Task.detached(priority: .utility) { race.finish(await task.value) }
        let selection = await withTaskCancellationHandler {
            await race.wait(timeout: ClaudeCodeLoginShellLookup.timeoutSeconds, orElse: nil)
        } onCancel: {
            race.finish(nil)
        }
        return selection.flatMap { $0.isCurrent ? $0 : nil }
    }
}

nonisolated enum ClaudeCodeLoginShellLookup {
    static let timeoutSeconds: TimeInterval = 2
    static let timeout: Duration = .seconds(timeoutSeconds)
    static let maximumOutputBytes = 16_384
    static let command = "command -v claude; printf '\\0'; /usr/bin/printenv PATH"

    static func lookup(home: URL) async -> ClaudeCodeExecutableSelection? {
        guard AppRuntimeEnvironment.mayRunInstalledClaudeCode else { return nil }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let race = OwnedSubprocessOneShotRace<ClaudeCodeExecutableSelection?>()
        let task = Task.detached(priority: .utility) {
            race.finish(await probe(home: home, deadline: deadline))
        }
        return await withTaskCancellationHandler {
            await race.wait(timeout: timeoutSeconds, orElse: nil)
        } onCancel: {
            task.cancel()
            race.finish(nil)
        }
    }

    private static func probe(home: URL, deadline: ContinuousClock.Instant) async -> ClaudeCodeExecutableSelection? {
        var record = passwd()
        var recordPointer: UnsafeMutablePointer<passwd>?
        let size = max(1_024, Int(sysconf(_SC_GETPW_R_SIZE_MAX)))
        var buffer = [CChar](repeating: 0, count: size)
        let shellPath: String? = buffer.withUnsafeMutableBufferPointer { bytes in
            guard getpwuid_r(getuid(), &record, bytes.baseAddress, bytes.count, &recordPointer) == 0,
                recordPointer != nil, let shell = record.pw_shell
            else { return nil }
            return String(cString: shell)
        }
        guard let shellPath, !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
        let shell = URL(fileURLWithPath: shellPath)
        guard ExternalCommand.isTrustedExecutable(shell) else { return nil }
        return await run(
            shell: shell, arguments: ["-ilc", command],
            environment: ClaudeCodeCLI.environment(configDirectory: nil, home: home), home: home,
            timeout: ContinuousClock.now.duration(to: deadline))
    }

    static func run(
        shell: URL, arguments: [String], environment: [String: String], home: URL,
        timeout: Duration = timeout
    ) async -> ClaudeCodeExecutableSelection? {
        guard timeout > .zero, !Task.isCancelled else { return nil }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let task: Task<ClaudeCodeExecutableSelection?, Never> = Task.detached(priority: .utility) {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            guard
                let child = OwnedSubprocessSpawn.spawn(
                    executablePath: shell.path, arguments: arguments, environment: environment,
                    options: .init(workingDirectoryPath: home.path, ownProcessGroup: true, qosClass: QOS_CLASS_UTILITY)
                )
            else { return nil }
            defer {
                // The unreaped root reserves its PID/group until every signal has been sent.
                _ = Darwin.kill(-child.processID, SIGKILL)
                _ = Darwin.kill(child.processID, SIGKILL)
                Darwin.close(child.standardOutputFileDescriptor)
                Darwin.close(child.standardErrorFileDescriptor)
                var status: Int32 = 0
                if waitpid(child.processID, &status, WNOHANG) != child.processID {
                    DispatchQueue.global(qos: .utility).async {
                        var status: Int32 = 0
                        while waitpid(child.processID, &status, 0) == -1, errno == EINTR {}
                    }
                }
            }
            for descriptor in [child.standardOutputFileDescriptor, child.standardErrorFileDescriptor] {
                let flags = fcntl(descriptor, F_GETFL)
                guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
            }
            var output = Data()
            var discardedError = Data()
            while !Task.isCancelled, ContinuousClock.now < deadline {
                guard drain(child.standardOutputFileDescriptor, into: &output),
                    drain(child.standardErrorFileDescriptor, into: &discardedError)
                else { return nil }
                var information = siginfo_t()
                if waitid(P_PID, id_t(child.processID), &information, WEXITED | WNOHANG | WNOWAIT) == 0,
                    information.si_pid == child.processID
                {
                    guard information.si_code == CLD_EXITED, information.si_status == 0,
                        drain(child.standardOutputFileDescriptor, into: &output)
                    else { return nil }
                    return selection(from: output, home: home)
                }
                usleep(5_000)
            }
            return nil
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func drain(_ descriptor: Int32, into data: inout Data) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                guard data.count + count <= maximumOutputBytes else { return false }
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                return true
            } else if errno != EINTR {
                return false
            }
        }
    }

    static func selection(from output: Data, home: URL) -> ClaudeCodeExecutableSelection? {
        let fields = output.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count == 2,
            let rawPath = String(data: Data(fields[0]), encoding: .utf8),
            let rawDirectories = String(data: Data(fields[1]), encoding: .utf8)
        else { return nil }
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginPath = rawDirectories.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r"),
            !loginPath.contains("\n"), !loginPath.contains("\r")
        else { return nil }
        let original = URL(fileURLWithPath: path)
        guard let executable = ExternalCommand.firstTrustedExecutable(in: [original]) else { return nil }
        let directories = loginPath.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        return ClaudeCodeExecutableSelection(
            originalURL: original, executableURL: executable,
            searchDirectories: [original.deletingLastPathComponent().path] + directories
                + ExternalCommand.searchDirectories(home: home))
    }
}
