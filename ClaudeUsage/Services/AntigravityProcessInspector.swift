import Darwin
import Foundation

nonisolated struct AntigravityBSDProcessInfo: Sendable, Equatable {
    let processID: Int32
    let effectiveUserID: AntigravityUserID
    let realUserID: AntigravityUserID
    let startedAt: AntigravityProcessStartTime
}

nonisolated protocol AntigravityLibprocReading: Sendable {
    func bsdInfo(for processID: Int32) -> AntigravityBSDProcessInfo?
    func executableURL(for processID: Int32) -> URL?
}

nonisolated struct AntigravitySystemLibprocReader: AntigravityLibprocReading {
    func bsdInfo(for processID: Int32) -> AntigravityBSDProcessInfo? {
        guard processID > 0 else {
            return nil
        }

        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                processID,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(expectedSize)
            )
        }
        guard result == expectedSize,
              info.pbi_pid == UInt32(processID),
              let seconds = Int64(exactly: info.pbi_start_tvsec),
              let microseconds = Int32(exactly: info.pbi_start_tvusec),
              let startedAt = AntigravityProcessStartTime(
                  seconds: seconds,
                  microseconds: microseconds
              ) else {
            return nil
        }

        return AntigravityBSDProcessInfo(
            processID: processID,
            effectiveUserID: AntigravityUserID(rawValue: info.pbi_uid),
            realUserID: AntigravityUserID(rawValue: info.pbi_ruid),
            startedAt: startedAt
        )
    }

    func executableURL(for processID: Int32) -> URL? {
        guard processID > 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(
                processID,
                pointer.baseAddress,
                UInt32(pointer.count)
            )
        }
        guard result > 0 else {
            return nil
        }

        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
    }
}

nonisolated protocol AntigravityRuntimeProcessInspecting: Sendable {
    func discoverProcesses(
        timeout: TimeInterval
    ) async throws -> [AntigravityRuntimeProcessCandidate]

    func revalidate(
        _ identity: AntigravityVerifiedProcessIdentity
    ) async -> Bool

    func revalidate(
        _ candidate: AntigravityRuntimeProcessCandidate
    ) async -> AntigravityRuntimeProcessCandidate?
}

nonisolated extension AntigravityRuntimeProcessInspecting {
    func revalidate(
        _ candidate: AntigravityRuntimeProcessCandidate
    ) async -> AntigravityRuntimeProcessCandidate? {
        guard await revalidate(candidate.processIdentity) else {
            return nil
        }
        return candidate
    }
}

nonisolated enum AntigravityProcessInspectionError: Error, Equatable {
    case helperFailed(Int32)
    case malformedProcessList
}

nonisolated struct AntigravityProcessListHint: Sendable, Equatable {
    let processID: Int32
    let command: String
}

/// Verifies every `ps` hint with libproc before it becomes a runtime process.
///
/// The command line is used only to recover non-authoritative connection
/// hints. UID, start time, executable path, executable role, and bundle
/// identity all come from the double-read libproc verification.
nonisolated final class AntigravityProcessInspector:
    AntigravityRuntimeProcessInspecting,
    @unchecked Sendable
{
    private let catalog: AntigravityExecutableCatalog
    private let subprocessRunner: any AntigravityOwnedSubprocessRunning
    private let libprocReader: any AntigravityLibprocReading
    private let kernelIdentityReader:
        any AntigravityKernelProcessIdentityReading
    private let runningExecutableImageValidator:
        any AntigravityRunningExecutableImageValidating
    private let runningCodeTrustValidator:
        any AntigravityRunningCodeTrustValidating
    private let effectiveUserID: AntigravityUserID
    private let realUserID: AntigravityUserID
    private let psExecutableURL: URL

    init(
        catalog: AntigravityExecutableCatalog,
        subprocessRunner: any AntigravityOwnedSubprocessRunning =
            AntigravityOwnedSubprocessRunner(),
        libprocReader: any AntigravityLibprocReading =
            AntigravitySystemLibprocReader(),
        kernelIdentityReader:
            any AntigravityKernelProcessIdentityReading =
                AntigravitySystemKernelProcessIdentityReader(),
        runningExecutableImageValidator:
            any AntigravityRunningExecutableImageValidating =
                AntigravitySystemRunningExecutableImageValidator(),
        runningCodeTrustValidator:
            any AntigravityRunningCodeTrustValidating =
                AntigravityOfficialRunningCodeTrustValidator(),
        effectiveUserID: AntigravityUserID =
            AntigravityUserID(rawValue: geteuid()),
        realUserID: AntigravityUserID =
            AntigravityUserID(rawValue: getuid()),
        psExecutableURL: URL = URL(fileURLWithPath: "/bin/ps")
    ) {
        self.catalog = catalog
        self.subprocessRunner = subprocessRunner
        self.libprocReader = libprocReader
        self.kernelIdentityReader = kernelIdentityReader
        self.runningExecutableImageValidator =
            runningExecutableImageValidator
        self.runningCodeTrustValidator =
            runningCodeTrustValidator
        self.effectiveUserID = effectiveUserID
        self.realUserID = realUserID
        self.psExecutableURL = psExecutableURL
    }

    func discoverProcesses(
        timeout: TimeInterval
    ) async throws -> [AntigravityRuntimeProcessCandidate] {
        let result = try await subprocessRunner.run(
            AntigravityOwnedSubprocessRequest(
                executableURL: psExecutableURL,
                arguments: ["-ax", "-o", "pid=,command="],
                timeout: timeout
            )
        )
        guard result.terminationStatus == 0 else {
            throw AntigravityProcessInspectionError.helperFailed(result.terminationStatus)
        }
        guard let output = String(data: result.standardOutput, encoding: .utf8) else {
            throw AntigravityProcessInspectionError.malformedProcessList
        }

        var seenProcessIDs = Set<Int32>()
        var candidates: [AntigravityRuntimeProcessCandidate] = []
        for hint in Self.parseProcessList(output)
        where seenProcessIDs.insert(hint.processID).inserted {
            guard let identity = verifiedIdentity(for: hint.processID),
                let candidate = candidate(for: identity, command: hint.command)
            else {
                continue
            }
            candidates.append(candidate)
        }

        return candidates.sorted {
            if $0.processIdentity.executable.role != $1.processIdentity.executable.role {
                return $0.processIdentity.executable.role.rawValue
                    < $1.processIdentity.executable.role.rawValue
            }
            return $0.processIdentity.processID < $1.processIdentity.processID
        }
    }

    func revalidate(
        _ identity: AntigravityVerifiedProcessIdentity
    ) async -> Bool {
        verifiedIdentity(for: identity.processID) == identity
    }

    func revalidate(
        _ candidate: AntigravityRuntimeProcessCandidate
    ) async -> AntigravityRuntimeProcessCandidate? {
        guard await revalidate(candidate.processIdentity) else {
            return nil
        }
        return candidate
    }

    static func parseProcessList(_ output: String) -> [AntigravityProcessListHint] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.drop(while: \.isWhitespace)
            guard let separator = trimmed.firstIndex(where: \.isWhitespace) else {
                return nil
            }

            let rawProcessID = trimmed[..<separator]
            let rawCommand = trimmed[separator...].drop(while: \.isWhitespace)
            guard let processID = Int32(rawProcessID),
                  processID > 0,
                  !rawCommand.isEmpty else {
                return nil
            }

            return AntigravityProcessListHint(
                processID: processID,
                command: String(rawCommand)
            )
        }
    }

    private func verifiedIdentity(
        for processID: Int32
    ) -> AntigravityVerifiedProcessIdentity? {
        guard let before = libprocReader.bsdInfo(for: processID),
              before.processID == processID,
              before.effectiveUserID == effectiveUserID,
              before.realUserID == realUserID,
              let executableURLBefore =
                libprocReader.executableURL(for: processID),
              let executableBefore =
                catalog.executable(matching: executableURLBefore),
            // The CLI is read through its own usage report. Running AGY
            // processes are never trust-checked or queried.
            executableBefore.role == .appLanguageServer,
              let during = libprocReader.bsdInfo(for: processID),
              before == during,
              catalog.isCurrent(executableBefore),
              let kernelIdentityBefore =
                kernelIdentityReader.kernelIdentity(
                    for: processID
                ),
              runningExecutableImageValidator
                .validatesRunningImage(
                    processID: processID,
                    executable: executableBefore
                ),
              runningCodeTrustValidator.validatesRunningCode(
                  processID: processID,
                  executable: executableBefore
              ),
              let executableURLAfter =
                libprocReader.executableURL(for: processID),
              let executableAfter =
                catalog.executable(matching: executableURLAfter),
              executableBefore == executableAfter,
              let after = libprocReader.bsdInfo(for: processID),
              before == after,
              let kernelIdentityAfter =
                kernelIdentityReader.kernelIdentity(
                    for: processID
                ),
              kernelIdentityBefore == kernelIdentityAfter else {
            return nil
        }

        return AntigravityVerifiedProcessIdentity(
            processID: processID,
            effectiveUserID: before.effectiveUserID,
            realUserID: before.realUserID,
            startedAt: before.startedAt,
            executable: executableAfter
        )
    }

    private func candidate(
        for identity: AntigravityVerifiedProcessIdentity,
        command: String
    ) -> AntigravityRuntimeProcessCandidate? {
        AntigravityRuntimeProcessCandidate(
            processIdentity: identity,
            ownership: .external,
            connectionHints: AntigravityRuntimeConnectionHints(
                requestedPort: Self.extractPort(
                    flag: "--https_server_port",
                    command: command
                ),
                csrfToken: Self.extractFlag(
                    flag: "--csrf_token",
                    command: command
                ).flatMap(AntigravityCSRFToken.init)
            )
        )
    }

    static func extractFlag(flag: String, command: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: flag)
        let pattern = "(?:^|\\s)\(escaped)(?:=|\\s+)([^\\s]+)"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: command,
                  range: NSRange(command.startIndex..., in: command)
              ),
              let range = Range(match.range(at: 1), in: command) else {
            return nil
        }

        let value = command[range].trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return value.isEmpty ? nil : value
    }

    static func extractPort(
        flag: String,
        command: String
    ) -> AntigravityTCPPort? {
        guard let value = extractFlag(flag: flag, command: command),
              let integer = Int(value) else {
            return nil
        }
        return AntigravityTCPPort(integer)
    }
}
