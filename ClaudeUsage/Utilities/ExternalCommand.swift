import Darwin
import Foundation

/// 짧게 끝나는 외부 명령(공식 CLI, `/usr/bin/security`)을 찾고 실행한다.
nonisolated enum ExternalCommand {
    struct Output: Sendable {
        let status: Int32
        let data: Data

        var succeeded: Bool { status == 0 }
    }

    /// 앱은 로그인 셸 환경을 물려받지 않으므로 CLI가 설치되는 위치를 직접 넣는다.
    /// npm으로 설치한 CLI는 `#!/usr/bin/env node`라 node가 있는 위치도 PATH에 있어야 한다.
    static func searchDirectories(home: URL = FileManager.default.realHomeDirectory) -> [String] {
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map(String.init).filter { $0.hasPrefix("/") }
        let preferred = ["/opt/homebrew/bin", "/usr/local/bin"]
        let userLocal = [".local/bin", ".npm-global/bin", ".npm/bin", ".bun/bin", "bin"].map {
            home.appendingPathComponent($0).path
        }
        var seen: Set<String> = []
        return (preferred + inherited + userLocal + ["/usr/bin", "/bin"]).filter { seen.insert($0).inserted }
    }

    static func searchPath(home: URL = FileManager.default.realHomeDirectory) -> String {
        searchDirectories(home: home).joined(separator: ":")
    }

    /// 다른 사용자가 바꿔 둘 수 없는 일반 실행 파일만 실행한다.
    static func isTrustedExecutable(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o022 == 0
            && (info.st_uid == getuid() || info.st_uid == 0) && access(url.path, X_OK) == 0
    }

    static func firstTrustedExecutable(in candidates: [URL]) -> URL? {
        candidates.lazy.map { $0.resolvingSymlinksInPath() }.first(where: isTrustedExecutable)
    }

    /// 출력은 실행 중에 계속 읽어 파이프가 가득 차 멈추지 않게 한다. 시간이 지나거나 작업이 취소되면
    /// 종료하고 nil을 돌려준다. 종료 요청에 응하지 않으면 잠시 뒤 강제로 끝낸다. 실행하지 못해도 nil이다.
    static func run(
        _ executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL? = nil,
        input: Data? = nil, timeout: TimeInterval
    ) async -> Output? {
        let running = RunningCommand()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                running.start(
                    executable: executable, arguments: arguments, environment: environment,
                    currentDirectory: currentDirectory, input: input, timeout: timeout
                ) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            running.cancel()
        }
    }
}

/// Process는 Sendable이 아니어서 시작, 시간 초과, 취소가 같은 잠금 안에서만 건드린다.
private nonisolated final class RunningCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false
    private var didTimeOut = false
    private var hasExited = false
    private static let killGracePeriod: TimeInterval = 2

    func start(
        executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?,
        input: Data?, timeout: TimeInterval, completion: @escaping @Sendable (ExternalCommand.Output?) -> Void
    ) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice

        let reader = OutputReader(handle: output.fileHandleForReading)
        process.terminationHandler = { [self] finished in
            lock.withLock { hasExited = true }
            let data = reader.finish()
            let failed = lock.withLock { isCancelled || didTimeOut }
            completion(failed ? nil : ExternalCommand.Output(status: finished.terminationStatus, data: data))
        }

        let launched: Bool = lock.withLock {
            guard !isCancelled else { return false }
            do {
                try process.run()
            } catch {
                return false
            }
            self.process = process
            return true
        }
        guard launched else {
            completion(nil)
            return
        }
        reader.start()
        if let inputPipe, let input {
            let writer = inputPipe.fileHandleForWriting
            // 자식이 입력을 다 읽기 전에 끝나도 SIGPIPE로 앱이 죽지 않게 한다. 쓰기는 호출한 스레드를 막지 않게 따로 한다.
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .utility).async {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [self] in
            lock.withLock {
                guard let process = self.process, process.isRunning else { return }
                didTimeOut = true
                stop(process)
            }
        }
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
            if let process, process.isRunning { stop(process) }
        }
    }

    /// 잠금 안에서만 부른다.
    private func stop(_ process: Process) {
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.killGracePeriod) { [self] in
            lock.withLock {
                if !hasExited { kill(pid, SIGKILL) }
            }
        }
    }
}

/// 출력 끝(EOF)까지 다른 스레드에서 읽는다. 자식이 출력을 물려받은 하위 프로세스를 남기면 EOF가 늦을 수 있어
/// 종료 뒤에는 잠깐만 기다린다.
private nonisolated final class OutputReader: @unchecked Sendable {
    private let handle: FileHandle
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let read = handle.readDataToEndOfFile()
            lock.withLock { data = read }
            done.signal()
        }
    }

    func finish() -> Data {
        _ = done.wait(timeout: .now() + 1)
        return lock.withLock { data }
    }
}
