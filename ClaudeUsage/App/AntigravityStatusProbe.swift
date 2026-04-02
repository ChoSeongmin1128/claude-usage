import Foundation

struct AntigravityProcessSnapshot: Sendable, Equatable {
    let pid: Int
    let command: String
}

enum AntigravityStatusProbe {
    static func runningProcess() -> AntigravityProcessSnapshot? {
        guard let output = try? runProcess(arguments: ["-ax", "-o", "pid=,command="]) else { return nil }

        for line in output.split(separator: "\n") {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }

            let parts = raw.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2,
                  let pid = Int(parts[0]) else { continue }

            let command = String(parts[1])
            guard command.contains("language_server_macos"),
                  isAntigravityCommand(command) else { continue }

            return AntigravityProcessSnapshot(pid: pid, command: command)
        }

        return nil
    }

    static func isRunning() -> Bool {
        runningProcess() != nil
    }

    private static func isAntigravityCommand(_ command: String) -> Bool {
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

    private static func runProcess(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
