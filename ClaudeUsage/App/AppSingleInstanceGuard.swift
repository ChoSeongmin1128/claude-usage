import Darwin
import Foundation

nonisolated enum AppSingleInstanceAcquireResult:
    Equatable,
    Sendable
{
    case acquired
    case alreadyRunning
    case failed(Int32)
}

/// 이동 직후 재실행은 구 프로세스가 종료 절차를 마칠 때까지 잠금을 쥐고 있다.
/// 대기는 `.alreadyRunning`에서만 하고 `.failed`는 즉시 돌려준다. 일반 중복 실행의
/// 즉시 종료 의미를 지키기 위해 호출부가 의도를 밝힐 때만 이 경로를 쓴다.
///
/// 두 시간 상수는 한 쌍이다. 후속 프로세스의 대기가 선행 프로세스의 owned runtime
/// 정리 상한보다 짧아지면 양쪽 다 사라진다. 한쪽만 고치지 않도록 여기서 유도한다.
nonisolated enum AppRelaunchHandoffPolicy {
    static let ownedRuntimeShutdownTimeout: TimeInterval = 5
    static let handoffHeadroom: TimeInterval = 5
    static let pollInterval: TimeInterval = 0.1

    static var relaunchAfterMoveTimeout: TimeInterval {
        ownedRuntimeShutdownTimeout + handoffHeadroom
    }

    /// 인자가 잘못 흘러들어와도 빈 화면으로 멈춰 있지 않도록, 실제로 살아 있는
    /// 선행 프로세스를 지목했을 때만 기다린다.
    static func predecessorIsRunning(_ processIdentifier: pid_t) -> Bool {
        guard processIdentifier > 0 else { return false }
        if kill(processIdentifier, 0) == 0 { return true }
        return errno == EPERM
    }

    static func acquire(
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        elapsed: () -> TimeInterval,
        wait: (TimeInterval) -> Void,
        attempt: () -> AppSingleInstanceAcquireResult
    ) -> AppSingleInstanceAcquireResult {
        var result = attempt()
        while result == .alreadyRunning, elapsed() < timeout {
            wait(pollInterval)
            result = attempt()
        }
        return result
    }
}

/// Holds one advisory lock for the lifetime of a ClaudeUsage process.
///
/// The lock path lives in the channel-specific application-support directory,
/// so production and staging may each run once while a second process in the
/// same channel exits before starting provider runtimes.
nonisolated final class AppSingleInstanceGuard:
    @unchecked Sendable
{
    static let shared = AppSingleInstanceGuard()
    static let lockFileName = "application-instance.lock"

    private let lock = NSLock()
    private var descriptor: Int32 = -1

    init() {}

    deinit {
        release()
    }

    func acquire(
        applicationSupportDirectoryURL: URL
    ) -> AppSingleInstanceAcquireResult {
        lock.lock()
        defer { lock.unlock() }

        if descriptor >= 0 {
            return .acquired
        }

        do {
            try FileManager.default.createDirectory(
                at: applicationSupportDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [
                    .posixPermissions: 0o700,
                ]
            )
        } catch {
            return .failed(Int32(error._code))
        }

        let lockFileURL =
            applicationSupportDirectoryURL
                .appendingPathComponent(
                    Self.lockFileName,
                    isDirectory: false
                )
        let openedDescriptor = Darwin.open(
            lockFileURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard openedDescriptor >= 0 else {
            return .failed(errno)
        }
        guard fchmod(
            openedDescriptor,
            S_IRUSR | S_IWUSR
        ) == 0 else {
            let code = errno
            Darwin.close(openedDescriptor)
            return .failed(code)
        }

        guard flock(
            openedDescriptor,
            LOCK_EX | LOCK_NB
        ) == 0 else {
            let code = errno
            Darwin.close(openedDescriptor)
            if code == EWOULDBLOCK {
                return .alreadyRunning
            }
            return .failed(code)
        }

        _ = ftruncate(openedDescriptor, 0)
        let processID =
            "\(ProcessInfo.processInfo.processIdentifier)\n"
        processID.withCString { pointer in
            _ = Darwin.write(
                openedDescriptor,
                pointer,
                strlen(pointer)
            )
        }
        descriptor = openedDescriptor
        return .acquired
    }

    func acquireWaitingForRelocatedPredecessor(
        applicationSupportDirectoryURL: URL,
        timeout: TimeInterval =
            AppRelaunchHandoffPolicy
                .relaunchAfterMoveTimeout
    ) -> AppSingleInstanceAcquireResult {
        let start = ProcessInfo.processInfo.systemUptime
        return AppRelaunchHandoffPolicy.acquire(
            timeout: timeout,
            pollInterval:
                AppRelaunchHandoffPolicy.pollInterval,
            elapsed: {
                ProcessInfo.processInfo.systemUptime - start
            },
            wait: { Thread.sleep(forTimeInterval: $0) },
            attempt: {
                self.acquire(
                    applicationSupportDirectoryURL:
                        applicationSupportDirectoryURL
                )
            }
        )
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else {
            return
        }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }
}
