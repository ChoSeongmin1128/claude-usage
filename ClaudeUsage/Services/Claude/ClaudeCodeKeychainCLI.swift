import Foundation

/// Claude Code는 Keychain 항목을 `/usr/bin/security`로 쓰고 읽어서, 항목의 접근 목록이 `security`를 믿는다.
/// 같은 도구로 읽으면 Claude Code처럼 확인 창 없이 읽히고, 앱이 직접 읽으면 로그인 Keychain 암호를 묻는다.
nonisolated enum ClaudeCodeKeychainCLI {
    enum Outcome: Equatable, Sendable {
        case payload(String)
        case notFound
        case failed
    }

    static let executable = URL(fileURLWithPath: "/usr/bin/security")
    static let itemNotFoundStatus: Int32 = 44

    static func read(service: String, timeout: TimeInterval = 5) async -> Outcome {
        await Task.detached(priority: .utility) {
            readBlocking(service: service, timeout: timeout)
        }.value
    }

    private static func readBlocking(service: String, timeout: TimeInterval) -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["find-generic-password", "-w", "-s", service]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .failed }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            return .failed
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == itemNotFoundStatus { return .notFound }
        guard process.terminationStatus == 0,
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines),
            !text.isEmpty
        else { return .failed }
        return .payload(text)
    }
}
