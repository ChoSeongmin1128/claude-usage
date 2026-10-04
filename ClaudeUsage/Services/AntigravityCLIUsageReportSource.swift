import Darwin
import Foundation

// PATH is /bin only: AGY reads its keychain entry through the absolute
// /usr/bin/security, while `open` and MCP servers configured by command name
// cannot be found, so a report can neither open a browser sign-in nor start
// the user's MCP servers.
nonisolated enum AntigravityCLIReportEnvironment {
    static func values(
        homeDirectory: URL = FileManager.default.realHomeDirectory,
        userName: String? = NSUserName()
    ) -> [String: String] {
        var values = [
            "AGY_CLI_DISABLE_AUTO_UPDATE": "true",
            "HOME": homeDirectory.standardizedFileURL.path,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PATH": "/bin",
        ]
        if let userName = userName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !userName.isEmpty
        {
            values["USER"] = userName
        }
        return values
    }
}

nonisolated enum AntigravityCLIReportWorkspaceError: Error, Equatable {
    case notAPrivateDirectory
    case unavailable
}

nonisolated enum AntigravityCLIReportWorkspace {
    static func url(in stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("cli-report", isDirectory: true)
    }

    static func prepare(
        at url: URL,
        fileManager: FileManager = .default,
        expectedUserID: uid_t = geteuid()
    ) throws -> URL {
        let path = url.standardizedFileURL.path
        var metadata = stat()
        if lstat(path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw AntigravityCLIReportWorkspaceError.unavailable
            }
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw AntigravityCLIReportWorkspaceError.unavailable
            }
            guard lstat(path, &metadata) == 0 else {
                throw AntigravityCLIReportWorkspaceError.unavailable
            }
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == expectedUserID,
            metadata.st_mode & 0o077 == 0
        else {
            throw AntigravityCLIReportWorkspaceError.notAPrivateDirectory
        }
        return url.standardizedFileURL
    }
}

actor AntigravityCLIUsageReportSource: AntigravityUsageSource {
    static let reportArguments = ["-p", "/usage", "--output-format", "json"]
    static let versionTimeout: Duration = .seconds(10)
    // Reports measured 5-8 seconds. Below this budget --print-timeout would be
    // shorter than a normal report, and a report cut short by our own timeout
    // would read as a signed-out AGY, so the refresh is left as a timeout.
    static let minimumReportBudget: Duration = .seconds(10)
    private static let printTimeoutMargin: Duration = .seconds(2)

    nonisolated let id = AntigravityUsageSourceID.cliReport

    private enum VersionState {
        case unknown
        case supported
        case unsupported
    }

    private let executable: AntigravityCanonicalExecutable
    private let executableRevalidator: any AntigravityExecutableRevalidating
    private let runner: any AntigravityCLIReportProcessRunning
    private let environment: [String: String]
    private let prepareWorkingDirectory: @Sendable () throws -> URL
    private let now: @Sendable () -> Date
    private var versionState = VersionState.unknown
    private var reportsDisabled = false

    init(
        executable: AntigravityCanonicalExecutable,
        executableRevalidator: any AntigravityExecutableRevalidating,
        runner: any AntigravityCLIReportProcessRunning = AntigravityCLIReportProcessRunner(),
        environment: [String: String] = AntigravityCLIReportEnvironment.values(),
        prepareWorkingDirectory: @escaping @Sendable () throws -> URL,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(executable.role == .agyCLI)
        self.executable = executable
        self.executableRevalidator = executableRevalidator
        self.runner = runner
        self.environment = environment
        self.prepareWorkingDirectory = prepareWorkingDirectory
        self.now = now
    }

    func fetch(
        _ request: AntigravityUsageSourceRequest
    ) async throws -> AntigravityUsageSourceResponse {
        try check(request.deadline)
        guard !reportsDisabled else {
            throw AntigravityUsageSourceError.runtimeUnavailable(.reportDisabled)
        }
        guard executableRevalidator.isCurrent(executable) else {
            throw AntigravityUsageSourceError.runtimeUnavailable(.executableChanged)
        }
        let workingDirectory: URL
        do {
            workingDirectory = try prepareWorkingDirectory()
        } catch {
            throw AntigravityUsageSourceError.transportFailure
        }

        try await requireSupportedVersion(
            workingDirectory: workingDirectory,
            deadline: request.deadline
        )

        let budget = request.deadline.remaining
        guard budget >= Self.minimumReportBudget else {
            throw AntigravityUsageSourceError.deadlineExceeded
        }
        let printSeconds = max(1, (budget - Self.printTimeoutMargin).components.seconds)
        let result: AntigravityCLIReportProcessResult
        do {
            result = try await run(
                Self.reportArguments + ["--print-timeout", "\(printSeconds)s"],
                workingDirectory: workingDirectory,
                timeout: budget
            )
        } catch AntigravityUsageSourceError.deadlineExceeded {
            // Signed-out AGY waits for browser sign-in past --print-timeout
            // (measured with 1.2.12), so an unanswered report is a failed one.
            throw AntigravityUsageSourceError.reportFailed
        }

        let summary: AntigravityDecodedQuotaSummary
        do {
            summary = try AntigravityCLIUsageReportDecoder.decode(result.standardOutput)
        } catch let error as AntigravityCLIUsageReportError {
            throw map(error, exitStatus: result.exitStatus)
        }

        return AntigravityUsageSourceResponse(
            payload: .grouped(
                AntigravityQuotaSnapshot(
                    identity: nil,
                    plan: nil,
                    lanes: summary.lanes,
                    decodeIssues: summary.decodeIssues,
                    provenance: AntigravityQuotaProvenance(
                        transport: .cliUsageReport,
                        endpointOwner: .managed,
                        accountIdentity: nil,
                        capability: .groupedQuotaSummary,
                        processIdentity: nil
                    ),
                    fetchedAt: now()
                )
            )
        )
    }

    private func requireSupportedVersion(
        workingDirectory: URL,
        deadline: AntigravityRPCDeadline
    ) async throws {
        switch versionState {
        case .supported:
            return
        case .unsupported:
            throw AntigravityUsageSourceError.runtimeUnavailable(.unsupportedVersion)
        case .unknown:
            break
        }
        let timeout = min(Self.versionTimeout, deadline.remaining)
        guard timeout > .zero else {
            throw AntigravityUsageSourceError.deadlineExceeded
        }
        let result = try await run(
            ["--version"],
            workingDirectory: workingDirectory,
            timeout: timeout
        )
        guard result.exitStatus == 0 else {
            throw AntigravityUsageSourceError.transportFailure
        }
        // Unreadable output cannot prove that `/usage` is answered without a
        // model turn, so it is treated like an old release.
        let version = AntigravityCLIVersion(
            versionOutput: String(decoding: result.standardOutput, as: UTF8.self)
        )
        guard let version, version.supportsUsageReport else {
            versionState = .unsupported
            throw AntigravityUsageSourceError.runtimeUnavailable(.unsupportedVersion)
        }
        versionState = .supported
    }

    private func run(
        _ arguments: [String],
        workingDirectory: URL,
        timeout: Duration
    ) async throws -> AntigravityCLIReportProcessResult {
        do {
            return try await runner.run(
                AntigravityCLIReportProcessRequest(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    workingDirectoryURL: workingDirectory,
                    timeout: timeout
                )
            )
        } catch is CancellationError {
            throw AntigravityUsageSourceError.cancelled
        } catch let error as AntigravityCLIReportProcessError {
            switch error {
            case .timedOut:
                throw AntigravityUsageSourceError.deadlineExceeded
            case .executableNotAllowed:
                throw AntigravityUsageSourceError.runtimeUnavailable(.executableChanged)
            case .invalidRequest, .launchFailed, .processGroupInvalid, .outputLimitExceeded:
                throw AntigravityUsageSourceError.transportFailure
            }
        }
    }

    private func map(
        _ error: AntigravityCLIUsageReportError,
        exitStatus: Int32
    ) -> AntigravityUsageSourceError {
        switch error {
        case .agentTurnStarted:
            // Quota may already have been spent. Stop until a changed
            // executable produces a new source.
            reportsDisabled = true
            return .runtimeUnavailable(.reportDisabled)
        case .reportFailed:
            return .reportFailed
        case .invalidJSON:
            return exitStatus == 0 ? .malformedResponse : .transportFailure
        case .unexpectedCommand, .quotaUnavailable:
            return .malformedResponse
        }
    }

    private func check(_ deadline: AntigravityRPCDeadline) throws {
        do {
            try deadline.check(.request)
        } catch is CancellationError {
            throw AntigravityUsageSourceError.cancelled
        } catch {
            throw AntigravityUsageSourceError.deadlineExceeded
        }
    }
}
