import AppKit
import Foundation

struct AntigravityProcessSnapshot: Sendable, Equatable {
    let pid: Int
    let command: String
    let csrfToken: String?
    let extensionPort: Int?
    let extensionCsrfToken: String?
    let httpsServerPort: Int?
}

enum AntigravityStatusProbe {

    // MARK: - Cache

    private static let cacheLock = NSLock()
    private static var cachedProcess: AntigravityProcessSnapshot??  // nil = not cached, .some(nil) = cached as "not running"
    private static var cachedProcessAt: Date?
    private static var cachedAppRunning: Bool?
    private static var cachedAppRunningAt: Date?
    // 이전 5s → 2s. Antigravity language server는 재시작 시 csrf/port가 바뀌는데
    // 5초 캐시 동안 stale 토큰으로 연속 실패하는 문제가 있었음.
    private static let cacheTTL: TimeInterval = 2.0

    nonisolated static func invalidateCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedProcess = nil
        cachedProcessAt = nil
        cachedAppRunning = nil
        cachedAppRunningAt = nil
    }

    // MARK: - Public

    nonisolated static func runningProcess() -> AntigravityProcessSnapshot? {
        cacheLock.lock()
        if let cachedAt = cachedProcessAt,
           Date().timeIntervalSince(cachedAt) < cacheTTL {
            let value = cachedProcess
            cacheLock.unlock()
            return value ?? nil
        }
        cacheLock.unlock()

        var result: AntigravityProcessSnapshot?
        for entry in listProcesses() {
            guard entry.command.contains("language_server_macos"),
                  isAntigravityCommand(entry.command) else { continue }

            result = AntigravityProcessSnapshot(
                pid: entry.pid,
                command: entry.command,
                csrfToken: extractFlag("--csrf_token", from: entry.command),
                extensionPort: extractPort("--extension_server_port", from: entry.command),
                extensionCsrfToken: extractFlag("--extension_server_csrf_token", from: entry.command),
                httpsServerPort: extractPort("--https_server_port", from: entry.command)
            )
            break
        }

        cacheLock.lock()
        cachedProcess = .some(result)
        cachedProcessAt = Date()
        cacheLock.unlock()

        return result
    }

    nonisolated static func appProcessRunning() -> Bool {
        cacheLock.lock()
        if let cachedAt = cachedAppRunningAt,
           Date().timeIntervalSince(cachedAt) < cacheTTL,
           let cached = cachedAppRunning {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let apps = NSWorkspace.shared.runningApplications
        let result = apps.contains(where: {
            $0.bundleIdentifier == "com.google.antigravity"
                || $0.bundleURL?.path.contains("Antigravity.app") == true
        })

        cacheLock.lock()
        cachedAppRunning = result
        cachedAppRunningAt = Date()
        cacheLock.unlock()

        return result
    }

    nonisolated static func isRunning() -> Bool {
        runningProcess() != nil
    }

    // MARK: - /bin/ps 기반 프로세스 탐색

    private struct ProcessEntry {
        let pid: Int
        let command: String
    }

    /// /bin/ps를 사용해 language_server 프로세스를 찾습니다.
    /// App Sandbox 제거 후 /bin/ps로 전환 (기존 sysctl 방식 대체).
    /// hang 방지를 위해 3초 타임아웃을 강제합니다.
    private nonisolated static func listProcesses() -> [ProcessEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ax", "-o", "pid=,command="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")

        do {
            try process.run()
        } catch {
            Logger.warning("[Antigravity] /bin/ps 실행 실패: \(error.localizedDescription)")
            return []
        }

        // 3초 타임아웃 (ps는 보통 수십ms)
        let deadline = Date().addingTimeInterval(3.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            Logger.warning("[Antigravity] /bin/ps 타임아웃 — 강제 종료")
            process.terminate()
            // 종료 대기 500ms
            let killDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let spaceIndex = trimmed.firstIndex(of: " ") else { return nil }
            let pidStr = String(trimmed[trimmed.startIndex..<spaceIndex])
            let command = String(trimmed[trimmed.index(after: spaceIndex)...])
                .trimmingCharacters(in: .whitespaces)
            guard let pid = Int(pidStr),
                  // "language_server_macos"를 좀 더 관대하게 매칭 (prefix)
                  command.contains("language_server") else { return nil }
            return ProcessEntry(pid: pid, command: command)
        }
    }

    // MARK: - Command parsing

    private nonisolated static func isAntigravityCommand(_ command: String) -> Bool {
        if command.contains("--app_data_dir") && command.localizedCaseInsensitiveContains("antigravity") {
            return true
        }

        if command.localizedCaseInsensitiveContains("/antigravity/")
            || command.localizedCaseInsensitiveContains("\\antigravity\\")
        {
            return true
        }

        return false
    }

    private nonisolated static func extractFlag(_ flag: String, from command: String) -> String? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: flag))[=\\s]+([^\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = regex.firstMatch(in: command, options: [], range: range),
              let tokenRange = Range(match.range(at: 1), in: command) else { return nil }
        return String(command[tokenRange])
    }

    private nonisolated static func extractPort(_ flag: String, from command: String) -> Int? {
        guard let raw = extractFlag(flag, from: command) else { return nil }
        return Int(raw)
    }
}
