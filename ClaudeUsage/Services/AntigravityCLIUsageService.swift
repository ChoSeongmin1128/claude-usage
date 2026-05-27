import Darwin
import Foundation

nonisolated protocol AntigravityCLIUsageCommandRunning: Sendable {
    func runUsageCommand(executableURL: URL, timeout: TimeInterval) async throws -> String
}

actor AntigravityCLIUsageService {
    private let runner: any AntigravityCLIUsageCommandRunning
    private let executableURLProvider: @Sendable () -> URL?
    private let timeout: TimeInterval

    init(
        runner: any AntigravityCLIUsageCommandRunning = AntigravityCLIPTYUsageCommandRunner(),
        executableURLProvider: @escaping @Sendable () -> URL? = {
            AntigravityCLIExecutableResolver.resolvedExecutableURL()
        },
        timeout: TimeInterval = 15
    ) {
        self.runner = runner
        self.executableURLProvider = executableURLProvider
        self.timeout = timeout
    }

    func fetchUsage() async throws -> AntigravityUsageResponse {
        guard let executableURL = executableURLProvider() else {
            throw APIError.invalidSessionKey
        }
        let output = try await runner.runUsageCommand(
            executableURL: executableURL,
            timeout: timeout
        )
        return try AntigravityCLIUsageParsing.response(from: output, now: Date())
    }
}

extension AntigravityCLIUsageService: AntigravityUsageFetching {
    func fetchUsageForRuntime() async throws -> AntigravityUsageResponse {
        try await fetchUsage()
    }
}

nonisolated enum AntigravityCLIExecutableResolver {
    static func resolvedExecutableURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let home = fileManager.realHomeDirectory.path
        let candidates = candidatePaths(environment: environment, home: home)
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            let status = ProviderEnvironmentDetector.antigravityCLIStatus(
                for: url,
                fileManager: fileManager
            )
            if status.isRunnable {
                return url
            }
        }
        return nil
    }

    private static func candidatePaths(environment: [String: String], home: String) -> [String] {
        var paths: [String] = []
        if let override = environment["CLAUDEUSAGE_AGY_PATH"]?.trimmedNonEmpty {
            paths.append(override)
        }

        let pathDirectories = environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let fallbackDirectories = [
            "\(home)/.local/bin",
            "\(home)/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        for directory in pathDirectories + fallbackDirectories {
            paths.append(URL(fileURLWithPath: directory).appendingPathComponent("agy").path)
        }
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }
}

nonisolated enum AntigravityCLIUsageParsing {
    static func response(
        from output: String,
        now: Date,
        source: AntigravityUsageDataSource = .agyCLI
    ) throws -> AntigravityUsageResponse {
        let cleaned = cleanedTerminalText(output)
        guard let quotaRange = cleaned.range(of: "Model Quota") else {
            throw APIError.parseError
        }

        let quotaText = String(cleaned[quotaRange.lowerBound...])
        let lines = quotaText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var quotas: [AntigravityModelQuota] = []
        var pendingLabel: String?

        for line in lines {
            guard !line.isEmpty else { continue }
            if shouldIgnore(line) {
                continue
            }
            if let remaining = remainingQuota(from: line, now: now), let label = pendingLabel {
                quotas.append(
                    AntigravityModelQuota(
                        label: label,
                        modelID: normalizedModelID(from: label),
                        remainingFraction: remaining.fraction,
                        resetAtISO: remaining.resetAtISO
                    )
                )
                pendingLabel = nil
                continue
            }
            if line.localizedCaseInsensitiveContains("Quota available"), let label = pendingLabel {
                quotas.append(
                    AntigravityModelQuota(
                        label: label,
                        modelID: normalizedModelID(from: label),
                        remainingFraction: 1,
                        resetAtISO: nil
                    )
                )
                pendingLabel = nil
                continue
            }
            if isModelLabel(line) {
                pendingLabel = line
            }
        }

        guard !quotas.isEmpty else {
            throw APIError.parseError
        }

        return AntigravityUsageMapper.buildResponse(
            quotas: quotas,
            accountEmail: firstEmail(in: cleaned),
            accountPlan: nil,
            source: source
        )
    }

    private static func remainingQuota(
        from line: String,
        now: Date
    ) -> (fraction: Double, resetAtISO: String?)? {
        guard let percentRange = line.range(of: #"^\d+(?:\.\d+)?(?=%\s+remaining)"#, options: .regularExpression),
              let percent = Double(line[percentRange])
        else {
            return nil
        }

        let resetAtISO: String?
        if let refreshRange = line.range(of: #"Refreshes in\s+(.+)$"#, options: .regularExpression) {
            let refreshText = String(line[refreshRange])
                .replacingOccurrences(of: "Refreshes in", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            resetAtISO = resetTime(from: refreshText, now: now)
        } else {
            resetAtISO = nil
        }

        return (max(0, min(1, percent / 100)), resetAtISO)
    }

    private static func resetTime(from text: String, now: Date) -> String? {
        let days = firstInteger(in: text, pattern: #"(\d+)\s*d"#) ?? 0
        let hours = firstInteger(in: text, pattern: #"(\d+)\s*h"#) ?? 0
        let minutes = firstInteger(in: text, pattern: #"(\d+)\s*m"#) ?? 0
        let seconds = (days * 24 * 60 * 60) + (hours * 60 * 60) + (minutes * 60)
        guard seconds > 0 else { return nil }
        return ISO8601DateFormatter().string(from: now.addingTimeInterval(TimeInterval(seconds)))
    }

    private static func firstInteger(in text: String, pattern: String) -> Int? {
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let match = String(text[range])
        let digits = match.prefix { $0.isNumber }
        return Int(digits)
    }

    private static func isModelLabel(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        return lowercased.contains("gemini")
            || lowercased.contains("claude")
            || lowercased.contains("gpt")
    }

    private static func shouldIgnore(_ line: String) -> Bool {
        if line.contains("█") || line.contains("░") {
            return true
        }
        let lowercased = line.lowercased()
        return line.contains("↑/↓")
            || line.contains("pgup")
            || line.contains("esc ")
            || line.contains("Model Quota")
            || lowercased.contains("for shortcuts")
            || lowercased.contains("antigravity cli")
            || lowercased.contains("view model quota")
            || lowercased.contains("select · tab")
    }

    private static func normalizedModelID(from label: String) -> String {
        let scalars = label.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
        return collapsed.isEmpty ? label : collapsed
    }

    private static func firstEmail(in text: String) -> String? {
        guard let range = text.range(
            of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }
        return String(text[range])
    }

    private static func cleanedTerminalText(_ output: String) -> String {
        let escape = "\u{001B}"
        let withoutANSI = output
            .replacingOccurrences(
                of: "\(escape)\\[[0-?]*[ -/]*[@-~]",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "\(escape)\\][^\u{0007}]*(?:\u{0007}|\(escape)\\\\)",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "\(escape)[@-Z\\\\-_]",
                with: "",
                options: .regularExpression
            )

        var result = ""
        for scalar in withoutANSI.unicodeScalars {
            switch scalar {
            case "\u{0008}":
                if !result.isEmpty {
                    result.removeLast()
                }
            case "\r":
                result.append("\n")
            case "\n", "\t":
                result.unicodeScalars.append(scalar)
            default:
                if scalar.value >= 32 {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}

struct AntigravityCLIPTYUsageCommandRunner: AntigravityCLIUsageCommandRunning {
    private let rows: UInt16 = 80
    private let columns: UInt16 = 160

    func runUsageCommand(executableURL: URL, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(
                        returning: try runUsageCommandSync(
                            executableURL: executableURL,
                            timeout: timeout
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runUsageCommandSync(executableURL: URL, timeout: TimeInterval) throws -> String {
        let masterFD = posix_openpt(O_RDWR | O_NOCTTY)
        guard masterFD >= 0 else {
            throw APIError.networkError("AGY CLI PTY를 열 수 없습니다")
        }
        defer { Darwin.close(masterFD) }

        guard grantpt(masterFD) == 0, unlockpt(masterFD) == 0, let slaveName = ptsname(masterFD) else {
            throw APIError.networkError("AGY CLI PTY 초기화에 실패했습니다")
        }

        let slaveFD = open(String(cString: slaveName), O_RDWR | O_NOCTTY)
        guard slaveFD >= 0 else {
            throw APIError.networkError("AGY CLI PTY slave를 열 수 없습니다")
        }
        defer { Darwin.close(slaveFD) }

        var windowSize = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(slaveFD, TIOCSWINSZ, &windowSize)

        let flags = fcntl(masterFD, F_GETFL)
        if flags >= 0 {
            _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
        }

        let slaveInput = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        let slaveOutput = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        let slaveError = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)

        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = FileManager.default.realHomeDirectory
        process.standardInput = slaveInput
        process.standardOutput = slaveOutput
        process.standardError = slaveError
        process.environment = environment()

        try process.run()

        let output = collectOutput(
            masterFD: masterFD,
            process: process,
            timeout: timeout
        )

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }

        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.parseError
        }
        return output
    }

    private func collectOutput(masterFD: Int32, process: Process, timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        var sentUsageCommand = false
        var sentExitCommand = false
        var sawQuota = false
        var quotaSeenAt: Date?

        while Date() < deadline {
            readAvailableData(from: masterFD, into: &data)
            let output = String(decoding: data, as: UTF8.self)

            if !sentUsageCommand, shouldSendUsageCommand(output) {
                write("/usage\r", to: masterFD)
                sentUsageCommand = true
            }

            if output.contains("Model Quota") {
                if !sawQuota {
                    sawQuota = true
                    quotaSeenAt = Date()
                }
                if !sentExitCommand, Date().timeIntervalSince(quotaSeenAt ?? Date()) > 1.25 {
                    write("\u{0004}\u{0004}", to: masterFD)
                    sentExitCommand = true
                }
            }

            if sentExitCommand, !process.isRunning {
                break
            }

            Thread.sleep(forTimeInterval: 0.05)
        }

        readAvailableData(from: masterFD, into: &data)
        return String(decoding: data, as: UTF8.self)
    }

    private func shouldSendUsageCommand(_ output: String) -> Bool {
        if output.contains("Do you trust the contents of this project?") {
            return false
        }
        return output.contains("for shortcuts")
    }

    private func readAvailableData(from fd: Int32, into data: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bufferCount = buffer.count
            let count = buffer.withUnsafeMutableBytes { pointer in
                Darwin.read(fd, pointer.baseAddress, bufferCount)
            }
            if count > 0 {
                data.append(buffer, count: count)
                continue
            }
            break
        }
    }

    private func write(_ string: String, to fd: Int32) {
        let bytes = Array(string.utf8)
        bytes.withUnsafeBytes { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            _ = Darwin.write(fd, baseAddress, bytes.count)
        }
    }

    private func environment() -> [String: String] {
        let home = FileManager.default.realHomeDirectory.path
        var env: [String: String] = [
            "HOME": home,
            "PATH": "\(home)/.local/bin:\(home)/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "LANG": "en_US.UTF-8",
        ]
        if let user = ProcessInfo.processInfo.environment["USER"] {
            env["USER"] = user
        }
        return env
    }
}

private extension String {
    nonisolated var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
