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
