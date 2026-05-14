import Darwin
import Foundation

/// `codex` CLI 를 PTY 안에서 띄우고 `/status` 슬래시 명령을 전송한 뒤 텍스트를 캡처한다.
///
/// 왜 PTY 가 필요한가:
/// - `echo "/status" | codex` 는 `Error: stdin is not a terminal` 로 거부됨.
/// - codex 는 인터랙티브 TUI 만 제공하고 비-interactive 사용량 명령(`codex usage` 등)이 없음.
/// - 그래서 의사 터미널을 열어 자식 프로세스에 stdin/stdout/stderr 로 연결하고,
///   슬래시 명령을 전송한 뒤 터미널 출력을 그대로 읽어 텍스트 파싱한다.
///
/// MVP 정책:
/// - 단순 one-shot 실행 (재사용 세션 X)
/// - update prompt 같은 복잡한 dialog 자동 dismiss 처리 X (실패 시 사용자에게 안내)
/// - timeout 후 자식 프로세스 강제 종료
/// - 응답 markers ("Credits:", "5h limit", "Weekly limit") 발견 시 일정 settle 후 종료
///
/// 차용: CodexBar (MIT License) Sources/CodexBarCore/Host/PTY/TTYCommandRunner.swift 의
/// 골격을 단순화. Copyright (c) 2026 Peter Steinberger.
actor CodexPTYRunner {
    struct Result: Sendable {
        let text: String
        let durationSeconds: Double
    }

    enum PTYError: Error, LocalizedError {
        case openptyFailed(Int32)
        case spawnFailed(String)
        case timedOut(partialText: String)

        var errorDescription: String? {
            switch self {
            case .openptyFailed(let errno):
                return "PTY 열기 실패 (errno \(errno))"
            case .spawnFailed(let detail):
                return "codex 프로세스 실행 실패: \(detail)"
            case .timedOut:
                return "codex 응답 대기 시간 초과"
            }
        }
    }

    /// codex 바이너리를 PTY 로 띄우고 슬래시 명령 응답을 캡처.
    /// - Parameters:
    ///   - binary: 실행 가능한 codex 바이너리 절대 경로
    ///   - slashCommand: codex 안에서 보낼 슬래시 명령. 보통 "/status"
    ///   - markers: 응답 본문에 이 중 하나라도 보이면 캡처 완료로 간주
    ///   - timeout: 전체 타임아웃 (초)
    ///   - rows/cols: PTY winsize. 좁으면 codex 가 wrap 으로 layout 깨질 수 있어 넉넉히.
    func capture(
        binary: String,
        slashCommand: String,
        markers: [String],
        timeout: TimeInterval = 8.0,
        rows: UInt16 = 60,
        cols: UInt16 = 200
    ) async throws -> Result {
        let started = Date()

        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var windowSize = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        let openResult = openpty(&primaryFD, &secondaryFD, nil, nil, &windowSize)
        guard openResult == 0 else {
            throw PTYError.openptyFailed(errno)
        }

        // FD_CLOEXEC 으로 primary 가 자식에 leak 되지 않게.
        _ = fcntl(primaryFD, F_SETFD, FD_CLOEXEC)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-s", "read-only", "-a", "untrusted"]

        // PTY secondary 를 자식의 stdin/stdout/stderr 로 연결.
        let secondaryHandle = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: false)
        process.standardInput = secondaryHandle
        process.standardOutput = secondaryHandle
        process.standardError = secondaryHandle

        // 환경: 색상 비활성화 + locale 명시 → 파싱 안정성 향상
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["NO_COLOR"] = "1"
        environment["CI"] = "1"
        process.environment = environment

        do {
            try process.run()
        } catch {
            close(primaryFD)
            close(secondaryFD)
            throw PTYError.spawnFailed(error.localizedDescription)
        }

        // 자식 프로세스가 secondary 를 들고 있으므로 우리(parent)는 닫는다.
        close(secondaryFD)

        defer {
            if process.isRunning {
                process.terminate()
            }
            close(primaryFD)
        }

        // 슬래시 명령 전송 (잠시 후 — codex 가 prompt 띄우는 시간 확보)
        try? await Task.sleep(nanoseconds: 600_000_000)
        let commandBytes = (slashCommand + "\r").data(using: .utf8) ?? Data()
        let writeResult = commandBytes.withUnsafeBytes { buffer -> ssize_t in
            guard let base = buffer.baseAddress else { return -1 }
            return Darwin.write(primaryFD, base, buffer.count)
        }
        if writeResult < 0 {
            throw PTYError.spawnFailed("write to PTY failed (errno \(errno))")
        }

        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var sawMarker = false

        while Date() < deadline {
            // non-blocking read 한 청크
            if let chunk = Self.readAvailable(fd: primaryFD), !chunk.isEmpty {
                buffer.append(chunk)
                if !sawMarker, let text = String(data: buffer, encoding: .utf8) {
                    if markers.contains(where: { text.contains($0) }) {
                        sawMarker = true
                        // settle: marker 본 후에도 0.6 초 동안 추가 출력 모음
                        let settleDeadline = Date().addingTimeInterval(0.6)
                        while Date() < settleDeadline {
                            if let more = Self.readAvailable(fd: primaryFD), !more.isEmpty {
                                buffer.append(more)
                            }
                            try? await Task.sleep(nanoseconds: 100_000_000)
                        }
                        break
                    }
                }
            }
            if !process.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let captured = String(data: buffer, encoding: .utf8) ?? ""
        let elapsed = Date().timeIntervalSince(started)

        if !sawMarker {
            throw PTYError.timedOut(partialText: captured)
        }

        return Result(text: captured, durationSeconds: elapsed)
    }

    /// fd 에서 사용 가능한 만큼 한 번 read. blocking 안 되도록 select 로 짧게 대기.
    private static func readAvailable(fd: Int32) -> Data? {
        var fdSet = fd_set()
        fd_zero(&fdSet)
        fd_set_at(fd: fd, in: &fdSet)
        var timeout = timeval(tv_sec: 0, tv_usec: 50_000)  // 50ms
        let result = select(fd + 1, &fdSet, nil, nil, &timeout)
        guard result > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = buffer.withUnsafeMutableBytes { ptr -> ssize_t in
            guard let base = ptr.baseAddress else { return 0 }
            return Darwin.read(fd, base, ptr.count)
        }
        guard n > 0 else { return nil }
        return Data(buffer.prefix(Int(n)))
    }
}

// MARK: - C macro 회피 (Swift 에서 fd_zero / fd_set 매크로 직접 호출 불가)

@inline(__always)
private func fd_zero(_ set: inout fd_set) {
    set = fd_set()
}

@inline(__always)
private func fd_set_at(fd: Int32, in set: inout fd_set) {
    // fd_set 는 32 개의 Int32 배열 (fds_bits). bit 단위 set.
    let mask = Int32(1 << (Int(fd) % 32))
    let index = Int(fd) / 32
    withUnsafeMutablePointer(to: &set.fds_bits) { pointer in
        pointer.withMemoryRebound(to: Int32.self, capacity: 32) { array in
            array[index] |= mask
        }
    }
}
