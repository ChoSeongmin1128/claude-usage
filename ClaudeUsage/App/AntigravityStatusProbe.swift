import Foundation

struct AntigravityProcessSnapshot: Sendable, Equatable {
    let pid: Int
    let command: String
    let csrfToken: String?
    let extensionPort: Int?
}

enum AntigravityStatusProbe {
    nonisolated static func runningProcess() -> AntigravityProcessSnapshot? {
        guard let output = try? processListing() else { return nil }

        for line in output.split(separator: "\n") {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }

            let parts = raw.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2,
                  let pid = Int(parts[0]) else { continue }

            let command = String(parts[1])
            guard command.contains("language_server_macos"),
                  isAntigravityCommand(command) else { continue }

            return AntigravityProcessSnapshot(
                pid: pid,
                command: command,
                csrfToken: extractFlag("--csrf_token", from: command),
                extensionPort: extractPort("--extension_server_port", from: command)
            )
        }

        return nil
    }

    nonisolated static func appProcessRunning() -> Bool {
        guard let output = try? processListing() else { return false }

        for line in output.split(separator: "\n") {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }

            let parts = raw.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }

            let command = String(parts[1]).lowercased()
            if command.contains("/applications/antigravity.app/")
                || command.contains("user-data-dir=/users/")
                    && command.contains("/library/application support/antigravity")
            {
                return true
            }
        }

        return false
    }

    nonisolated static func isRunning() -> Bool {
        runningProcess() != nil
    }

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

    private nonisolated static func processListing() throws -> String {
        try runProcess(arguments: ["-ax", "-o", "pid=,command="])
    }

    private nonisolated static func runProcess(arguments: [String]) throws -> String {
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
