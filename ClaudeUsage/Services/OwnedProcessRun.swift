import Darwin
import Foundation
import os

/// 막히는 작업(poll, 잠금 대기, 자식 회수)을 Swift 협력 스레드 대신 전용 스레드에서 돌린다.
/// 협력 스레드는 코어 수만큼이라 여러 조회가 겹치면 앱 전체 작업이 멈출 수 있다. 취소는 작업이 스스로 확인한다.
nonisolated enum BlockingWork {
    static func run<T: Sendable>(
        qos: DispatchQoS.QoSClass = .utility, _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    static func run<T: Sendable>(qos: DispatchQoS.QoSClass = .utility, _ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async { continuation.resume(returning: body()) }
        }
    }
}

/// 자체 프로세스 그룹으로 띄운 자식의 종료. 루트를 회수하기 전까지 PID와 그룹 ID가 재사용되지 않으므로
/// 그룹 전체에 신호를 다 보낸 뒤에 회수한다. 막히는 호출이라 전용 스레드에서만 부른다.
nonisolated enum OwnedProcessGroup {
    static func terminate(processID: pid_t, grace: TimeInterval) {
        guard processID > 0 else { return }
        if grace > 0 {
            _ = Darwin.kill(-processID, SIGTERM)
            let deadline = Date().addingTimeInterval(grace)
            while Date() < deadline, !hasExited(processID) { usleep(10_000) }
        }
        _ = Darwin.kill(-processID, SIGKILL)
        _ = Darwin.kill(processID, SIGKILL)
        reap(processID, waitingUpTo: 1)
    }

    /// 루트가 끝났는지 회수하지 않고 본다.
    static func hasExited(_ processID: pid_t) -> Bool {
        var information = siginfo_t()
        return waitid(P_PID, id_t(processID), &information, WEXITED | WNOHANG | WNOWAIT) == 0
            && information.si_pid == processID
    }

    /// 정해진 시간 안에 회수하지 못하면 다른 스레드에서 끝까지 기다린다. 신호는 더 보내지 않는다.
    @discardableResult
    static func reap(_ processID: pid_t, waitingUpTo seconds: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        var status: Int32 = 0
        repeat {
            let result = waitpid(processID, &status, WNOHANG)
            if result == processID { return status }
            if result < 0, errno != EINTR { return nil }
            usleep(5_000)
        } while Date() < deadline
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(processID, &status, 0) < 0, errno == EINTR {}
        }
        return nil
    }
}

/// 짧게 끝나는 외부 명령 한 번. 출력을 계속 읽어 파이프가 차서 멈추지 않게 하고, 시간 초과나 취소에는
/// 프로세스 그룹 전체를 끝낸다. 루트가 끝난 뒤 남은 자손도 함께 정리한다.
nonisolated final class OwnedProcessRun: @unchecked Sendable {
    struct Request: Sendable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        var currentDirectory: URL?
        var input: Data?
        var timeout: TimeInterval
        var maximumOutputBytes = 16 * 1_048_576
        var terminationGrace: TimeInterval = 2
        var mergesStandardError = false
        var onOutput: (@Sendable (Data) -> Void)?
    }

    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    func cancel() { cancelled.withLock { $0 = true } }

    /// 전용 스레드에서 부른다. 시간 초과, 취소, 실행 실패, 출력 상한 초과면 nil이다.
    func run(_ request: Request) -> ExternalCommand.Output? {
        guard !cancelled.withLock({ $0 }) else { return nil }
        var options = OwnedSubprocessSpawn.Options(
            workingDirectoryPath: request.currentDirectory?.path, ownProcessGroup: true, qosClass: QOS_CLASS_UTILITY)
        options.standardInput = request.input == nil ? .devNull : .pipe
        options.standardError = request.mergesStandardError ? .mergeWithOutput : .devNull
        guard
            let child = OwnedSubprocessSpawn.spawn(
                executablePath: request.executable.path, arguments: request.arguments,
                environment: request.environment, options: options)
        else { return nil }

        let output = child.standardOutputFileDescriptor
        var input = child.standardInputFileDescriptor
        defer {
            Darwin.close(output)
            if input >= 0 { Darwin.close(input) }
        }
        guard Self.setNonBlocking(output), input < 0 || Self.setNonBlocking(input) else {
            OwnedProcessGroup.terminate(processID: child.processID, grace: 0)
            return nil
        }
        if input >= 0 { _ = fcntl(input, F_SETNOSIGPIPE, 1) }

        let deadline = Date().addingTimeInterval(request.timeout)
        let pendingInput = request.input ?? Data()
        var written = 0
        var collected = Data()
        var outputClosed = false
        var exitedAt: Date?

        while true {
            if cancelled.withLock({ $0 }) || Date() >= deadline {
                OwnedProcessGroup.terminate(processID: child.processID, grace: request.terminationGrace)
                return nil
            }
            if input >= 0, written >= pendingInput.count {
                Darwin.close(input)
                input = -1
            }
            var descriptors = [pollfd(fd: output, events: Int16(POLLIN), revents: 0)]
            if input >= 0 { descriptors.append(pollfd(fd: input, events: Int16(POLLOUT), revents: 0)) }
            if !outputClosed { _ = poll(&descriptors, nfds_t(descriptors.count), 50) } else { usleep(10_000) }

            if !outputClosed {
                switch Self.drain(
                    output, into: &collected, limit: request.maximumOutputBytes, onOutput: request.onOutput)
                {
                case .open: break
                case .closed: outputClosed = true
                case .overflow:
                    OwnedProcessGroup.terminate(processID: child.processID, grace: 0)
                    return nil
                }
            }
            if input >= 0, written < pendingInput.count {
                // Serialize cancellation with each nonblocking input chunk.
                // Once cancel() returns, no later chunk can be submitted.
                let inputDescriptor = input
                let inputOffset = written
                let submitted = cancelled.withLock { isCancelled -> Int? in
                    guard !isCancelled else { return nil }
                    return pendingInput.withUnsafeBytes {
                        Darwin.write(inputDescriptor, $0.baseAddress!.advanced(by: inputOffset), $0.count - inputOffset)
                    }
                }
                guard let count = submitted else {
                    OwnedProcessGroup.terminate(processID: child.processID, grace: request.terminationGrace)
                    return nil
                }
                if count > 0 {
                    written += count
                } else if count < 0, errno != EAGAIN, errno != EINTR {
                    // 자식이 입력을 다 읽지 않고 끝냈다. 남은 입력은 버린다.
                    written = pendingInput.count
                }
            }

            if exitedAt == nil, OwnedProcessGroup.hasExited(child.processID) { exitedAt = Date() }
            // 루트가 끝난 뒤 출력을 물려받은 자손이 EOF를 늦출 수 있어 잠깐만 기다린다.
            if let exitedAt, outputClosed || Date().timeIntervalSince(exitedAt) >= 1 {
                _ = Darwin.kill(-child.processID, SIGKILL)
                guard let status = OwnedProcessGroup.reap(child.processID, waitingUpTo: 1) else { return nil }
                let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
                return ExternalCommand.Output(status: code, data: collected)
            }
        }
    }

    private enum DrainResult { case open, closed, overflow }

    private static func drain(
        _ descriptor: Int32, into data: inout Data, limit: Int, onOutput: (@Sendable (Data) -> Void)?
    ) -> DrainResult {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                guard data.count + count <= limit else { return .overflow }
                let chunk = Data(buffer.prefix(count))
                data.append(chunk)
                onOutput?(chunk)
            } else if count == 0 {
                return .closed
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return .open
            } else if errno != EINTR {
                return .closed
            }
        }
    }

    private static func setNonBlocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }
}
