import Darwin
import Foundation

nonisolated struct AntigravityCappedSubprocessOutput: Sendable {
    let data: Data
    let exceededLimit: Bool
}

nonisolated protocol AntigravityBoundedPipeOwning: AnyObject, Sendable {
    var hasReleasedOwnership: Bool { get }
    func cancelOwnedProcess()
}

nonisolated final class AntigravityBoundedPipeCollector:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let fileDescriptor: Int32
    private let maximumBytes: Int
    private let owner: any AntigravityBoundedPipeOwning
    private var cancelled = false

    init(
        fileDescriptor: Int32,
        maximumBytes: Int,
        owner: any AntigravityBoundedPipeOwning
    ) {
        self.fileDescriptor = fileDescriptor
        self.maximumBytes = maximumBytes
        self.owner = owner
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

    // Collection blocks in poll(2) until EOF or release, so it runs on a
    // dispatch thread instead of a Swift concurrency thread.
    func collect() async -> AntigravityCappedSubprocessOutput {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: self.collectBlocking())
            }
        }
    }

    private func collectBlocking() -> AntigravityCappedSubprocessOutput {
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
                )
            {
                return AntigravityCappedSubprocessOutput(
                    data: data,
                    exceededLimit: exceededLimit
                )
            }

            if owner.hasReleasedOwnership {
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
                    owner.cancelOwnedProcess()
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
