import AppKit
import Foundation

struct AntigravityProcessSnapshot: Sendable, Equatable {
    let pid: Int
    let command: String
    let csrfToken: String?
    let extensionPort: Int?
}

enum AntigravityStatusProbe {
    nonisolated static func runningProcess() -> AntigravityProcessSnapshot? {
        for entry in listProcesses() {
            guard entry.command.contains("language_server_macos"),
                  isAntigravityCommand(entry.command) else { continue }

            return AntigravityProcessSnapshot(
                pid: Int(entry.pid),
                command: entry.command,
                csrfToken: extractFlag("--csrf_token", from: entry.command),
                extensionPort: extractPort("--extension_server_port", from: entry.command)
            )
        }
        return nil
    }

    nonisolated static func appProcessRunning() -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        return apps.contains(where: {
            $0.bundleIdentifier == "com.google.antigravity"
                || $0.bundleURL?.path.contains("Antigravity.app") == true
        })
    }

    nonisolated static func isRunning() -> Bool {
        runningProcess() != nil
    }

    // MARK: - sysctl 기반 프로세스 탐색

    private struct ProcessEntry {
        let pid: pid_t
        let command: String
    }

    /// sysctl을 사용해 language_server 프로세스를 찾습니다.
    /// App Sandbox에서 /bin/ps는 다른 프로세스를 볼 수 없지만 sysctl은 가능합니다.
    private nonisolated static func listProcesses() -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        var results: [ProcessEntry] = []

        for i in 0..<actualCount {
            let proc = procs[i]
            let name = withUnsafePointer(to: proc.kp_proc.p_comm) { ptr in
                String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
            }

            // p_comm은 16바이트로 잘리므로 "language_se"까지만 보임
            guard name.hasPrefix("language_se") else { continue }

            let pid = proc.kp_proc.p_pid
            guard let commandLine = commandLine(forPid: pid) else { continue }
            results.append(ProcessEntry(pid: pid, command: commandLine))
        }

        return results
    }

    /// KERN_PROCARGS2를 사용해 프로세스의 전체 command line을 가져옵니다.
    private nonisolated static func commandLine(forPid pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }

        // argc(4바이트) 뒤의 exec path를 건너뜀
        var offset = 4
        while offset < size && buffer[offset] != 0 { offset += 1 }
        while offset < size && buffer[offset] == 0 { offset += 1 }

        // argc개의 인자를 수집
        var args: [String] = []
        var argCount: Int32 = 0
        var current = ""
        while offset < size && argCount < argc {
            if buffer[offset] == 0 {
                args.append(current)
                current = ""
                argCount += 1
            } else {
                current += String(UnicodeScalar(buffer[offset]))
            }
            offset += 1
        }

        return args.joined(separator: " ")
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
