import Darwin
import XCTest
@testable import ClaudeUsage

/// Exercises the runner against real child processes. Shell scripts stand in
/// for AGY; trust decisions are stubbed because the scripts are unsigned.
final class AntigravityCLIReportProcessRunnerTests: XCTestCase {
    private var directory: URL!
    private var workingDirectory: URL!
    private var strayProcessIDs: [pid_t] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIReportProcessRunnerTests-\(UUID().uuidString)", isDirectory: true)
        workingDirectory = directory.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for processID in strayProcessIDs {
            _ = kill(processID, SIGKILL)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func testCapturesStreamsExitStatusAndOnlyTheRequestedEnvironment() async throws {
        let executable = try script(
            """
            printf '%s\\n' "$PWD" "$PATH" "$REPORT_VALUE" "${HOME-unset}"
            cat
            printf 'stdin-closed\\n'
            printf 'diagnostic' >&2
            exit 3
            """)

        let result = try await runner().run(
            request(
                executable,
                environment: [
                    "PATH": "/bin",
                    "REPORT_VALUE": "value",
                ]))

        XCTAssertEqual(
            String(decoding: result.standardOutput, as: UTF8.self),
            "\(try realPath(workingDirectory))\n/bin\nvalue\nunset\nstdin-closed\n"
        )
        XCTAssertEqual(String(decoding: result.standardError, as: UTF8.self), "diagnostic")
        XCTAssertEqual(result.exitStatus, 3)
    }

    func testPassesArgumentsVerbatim() async throws {
        let executable = try script(#"for argument in "$@"; do printf '[%s]' "$argument"; done"#)

        let result = try await runner().run(
            request(
                executable,
                arguments: ["-p", "/usage", "--output-format", "json", "two words"]
            ))

        XCTAssertEqual(
            String(decoding: result.standardOutput, as: UTF8.self),
            "[-p][/usage][--output-format][json][two words]"
        )
        XCTAssertEqual(result.exitStatus, 0)
    }

    func testKillsGroupMembersLeftBehindAfterTheRootExits() async throws {
        let pidFile = directory.appendingPathComponent("leftover.pid")
        let executable = try script(
            """
            /bin/sleep 30 &
            echo $! > "$PID_FILE"
            echo done
            """)

        let result = try await runner().run(
            request(
                executable,
                environment: ["PATH": "/bin", "PID_FILE": pidFile.path]
            ))

        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), "done\n")
        let leftover = try processID(in: pidFile)
        XCTAssertTrue(waitUntilGone(leftover), "A group member outlived the report")
    }

    func testTimeoutTerminatesTheWholeGroup() async throws {
        let rootFile = directory.appendingPathComponent("root.pid")
        let childFile = directory.appendingPathComponent("child.pid")
        let executable = try script(
            """
            echo $$ > "$ROOT_FILE"
            /bin/sleep 30 &
            echo $! > "$CHILD_FILE"
            /bin/sleep 30
            """)
        let started = ContinuousClock.now

        do {
            _ = try await runner().run(
                request(
                    executable,
                    environment: [
                        "PATH": "/bin",
                        "ROOT_FILE": rootFile.path,
                        "CHILD_FILE": childFile.path,
                    ],
                    timeout: .milliseconds(500)
                ))
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? AntigravityCLIReportProcessError, .timedOut)
        }

        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
        XCTAssertTrue(waitUntilGone(try processID(in: rootFile)))
        XCTAssertTrue(waitUntilGone(try processID(in: childFile)))
    }

    func testCancellationTerminatesTheWholeGroup() async throws {
        let childFile = directory.appendingPathComponent("child.pid")
        let executable = try script(
            """
            /bin/sleep 30 &
            echo $! > "$CHILD_FILE"
            /bin/sleep 30
            """)
        let runner = runner()
        let request = request(
            executable,
            environment: ["PATH": "/bin", "CHILD_FILE": childFile.path],
            timeout: .seconds(30)
        )
        let task = Task { try await runner.run(request) }

        XCTAssertTrue(waitUntilExists(childFile))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        XCTAssertTrue(waitUntilGone(try processID(in: childFile)))
    }

    func testOutputLimitStopsTheProcess() async throws {
        let rootFile = directory.appendingPathComponent("root.pid")
        let executable = try script(
            """
            echo $$ > "$ROOT_FILE"
            while :; do echo 0123456789abcdef; done
            """)

        do {
            _ = try await runner().run(
                request(
                    executable,
                    environment: ["PATH": "/bin", "ROOT_FILE": rootFile.path],
                    timeout: .seconds(10),
                    maximumOutputBytes: 1_024
                ))
            XCTFail("Expected output limit")
        } catch {
            XCTAssertEqual(error as? AntigravityCLIReportProcessError, .outputLimitExceeded)
        }

        XCTAssertTrue(waitUntilGone(try processID(in: rootFile)))
    }

    func testSignalledExitIsNormalized() async throws {
        let executable = try script("kill -9 $$")

        let result = try await runner().run(request(executable))

        XCTAssertEqual(result.exitStatus, 128 + SIGKILL)
    }

    func testRevalidationFailureNeverSpawns() async throws {
        let marker = directory.appendingPathComponent("ran")
        let executable = try script(#"/usr/bin/touch "$MARKER""#)
        let imageValidator = RecordingImageValidator(result: true)

        do {
            _ = try await AntigravityCLIReportProcessRunner(
                executableRevalidator: StubRevalidator(result: false),
                runningExecutableImageValidator: imageValidator
            ).run(request(executable, environment: ["MARKER": marker.path]))
            XCTFail("Expected rejection")
        } catch {
            XCTAssertEqual(error as? AntigravityCLIReportProcessError, .executableNotAllowed)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(imageValidator.processIDs.isEmpty)
    }

    func testImageValidationFailureDiscardsTheSuspendedChild() async throws {
        let marker = directory.appendingPathComponent("ran")
        let executable = try script(#"/usr/bin/touch "$MARKER""#)
        let imageValidator = RecordingImageValidator(result: false)

        do {
            _ = try await AntigravityCLIReportProcessRunner(
                executableRevalidator: StubRevalidator(result: true),
                runningExecutableImageValidator: imageValidator
            ).run(request(executable, environment: ["MARKER": marker.path]))
            XCTFail("Expected rejection")
        } catch {
            XCTAssertEqual(error as? AntigravityCLIReportProcessError, .executableNotAllowed)
        }

        let checked = try XCTUnwrap(imageValidator.processIDs.first)
        XCTAssertTrue(waitUntilGone(checked))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "The child ran before its image was validated"
        )
    }

    func testChildThatLeavesTheGroupCannotHoldTheRunOpen() async throws {
        let pidFile = directory.appendingPathComponent("escaped.pid")
        let readyFile = directory.appendingPathComponent("escaped.ready")
        let executable = try script(
            """
            /usr/bin/perl -e 'use POSIX; POSIX::setsid(); open(my $f, ">", $ENV{"READY_FILE"}); close($f); sleep 30' &
            echo $! > "$PID_FILE"
            while [ ! -e "$READY_FILE" ]; do /bin/sleep 0.05; done
            echo done
            """)
        let started = ContinuousClock.now

        let result = try await runner().run(
            request(
                executable,
                environment: ["PATH": "/bin", "PID_FILE": pidFile.path, "READY_FILE": readyFile.path]
            ))
        let escaped = try processID(in: pidFile)
        strayProcessIDs.append(escaped)

        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), "done\n")
        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
        XCTAssertNotEqual(getpgid(escaped), -1, "Only the report's own group may be signalled")
    }

    func testRejectsMalformedRequestsBeforeSpawning() async throws {
        let executable = try script("exit 0")
        let malformed = [
            request(executable, timeout: .zero),
            request(executable, maximumOutputBytes: 0),
            request(executable, arguments: ["bad\0argument"]),
            request(executable, environment: ["KEY=VALUE": "x"]),
            request(executable, environment: ["": "x"]),
            request(executable, environment: ["KEY": "bad\0value"]),
        ]

        for request in malformed {
            do {
                _ = try await runner().run(request)
                XCTFail("Expected invalid request")
            } catch {
                XCTAssertEqual(error as? AntigravityCLIReportProcessError, .invalidRequest)
            }
        }
    }

    func testOnlyAGYCLIExecutablesAreRun() async throws {
        let bundle = AntigravityAppBundleIdentity(
            canonicalRootURL: directory.appendingPathComponent("Antigravity.app"),
            bundleIdentifier: AntigravityAppBundleIdentity.requiredBundleIdentifier
        )
        let languageServer = AntigravityCanonicalExecutable(
            canonicalURL: try script("exit 0").canonicalURL,
            role: .appLanguageServer,
            appBundle: bundle
        )

        do {
            _ = try await runner().run(request(languageServer))
            XCTFail("Expected rejection")
        } catch {
            XCTAssertEqual(error as? AntigravityCLIReportProcessError, .executableNotAllowed)
        }
    }

    func testRetriesOnlyTextFileBusySpawnFailures() {
        var statuses: [Int32] = [ETXTBSY, 0]
        var calls = 0
        XCTAssertEqual(
            AntigravityCLIReportProcessRunner.spawnRetryingTextFileBusy(sleepBetweenAttempts: {}) {
                calls += 1
                return statuses.removeFirst()
            },
            0
        )
        XCTAssertEqual(calls, 2)

        calls = 0
        XCTAssertEqual(
            AntigravityCLIReportProcessRunner.spawnRetryingTextFileBusy(sleepBetweenAttempts: {}) {
                calls += 1
                return EACCES
            },
            EACCES
        )
        XCTAssertEqual(calls, 1)

        calls = 0
        XCTAssertEqual(
            AntigravityCLIReportProcessRunner.spawnRetryingTextFileBusy(sleepBetweenAttempts: {}) {
                calls += 1
                return ETXTBSY
            },
            ETXTBSY
        )
        XCTAssertEqual(calls, 3)
    }

    // MARK: - Production trust checks

    func testProductionRunnerRejectsAnUnsignedExecutable() async throws {
        let marker = directory.appendingPathComponent("ran")
        let executable = try script(#"/usr/bin/touch "$MARKER""#)

        do {
            _ = try await AntigravityCLIReportProcessRunner().run(
                request(executable, environment: ["MARKER": marker.path]))
            XCTFail("An arbitrary local executable must not run")
        } catch {
            XCTAssertEqual(error as? AntigravityCLIReportProcessError, .executableNotAllowed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testSwappedImageIsRejectedEvenAfterThePathIsRestored() async throws {
        let catalogURL = directory.appendingPathComponent("agy")
        let trustedBackupURL = directory.appendingPathComponent("agy-trusted")
        let replacementURL = directory.appendingPathComponent("agy-replacement")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: catalogURL)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: replacementURL)
        XCTAssertEqual(chmod(catalogURL.path, 0o700), 0)
        XCTAssertEqual(chmod(replacementURL.path, 0o700), 0)
        let fileIdentity = try XCTUnwrap(
            AntigravitySystemExecutableFileIdentityInspector().identity(at: catalogURL))
        let executable = AntigravityCanonicalExecutable(
            canonicalURL: catalogURL, role: .agyCLI, fileIdentity: fileIdentity)
        let imageValidator = RestoreBeforeImageValidation(
            catalogPath: catalogURL.path,
            trustedBackupPath: trustedBackupURL.path,
            replacementPath: replacementURL.path)

        do {
            _ = try await AntigravityCLIReportProcessRunner(
                executableRevalidator: SwapBeforeSpawn(
                    catalogPath: catalogURL.path,
                    trustedBackupPath: trustedBackupURL.path,
                    replacementPath: replacementURL.path),
                runningExecutableImageValidator: imageValidator
            ).run(request(executable, arguments: ["30"]))
            XCTFail("A swapped image must not be resumed")
        } catch {
            XCTAssertEqual(error as? AntigravityCLIReportProcessError, .executableNotAllowed)
        }

        let processID = try XCTUnwrap(imageValidator.validatedProcessID)
        XCTAssertTrue(waitUntilGone(processID))
    }

    func testInstalledOfficialAGYPassesProductionTrustChecks() async throws {
        let home = FileManager.default.realHomeDirectory
        guard
            let executable = AntigravityProductionExecutableCatalogResolver(homeDirectoryURL: home)
                .resolve().reportExecutable
        else {
            throw XCTSkip("검증된 공식 AGY가 설치되지 않았습니다")
        }

        let result = try await AntigravityCLIReportProcessRunner().run(
            AntigravityCLIReportProcessRequest(
                executable: executable,
                arguments: ["--version"],
                environment: AntigravityCLIReportEnvironment.values(homeDirectory: home),
                workingDirectoryURL: workingDirectory,
                timeout: .seconds(10)
            ))

        XCTAssertEqual(result.exitStatus, 0)
        let version = try XCTUnwrap(
            AntigravityCLIVersion(versionOutput: String(decoding: result.standardOutput, as: UTF8.self)))
        XCTAssertTrue(version.supportsUsageReport, "Installed AGY \(version) predates usage reports")
    }

    // MARK: - Helpers

    private func runner() -> AntigravityCLIReportProcessRunner {
        AntigravityCLIReportProcessRunner(
            executableRevalidator: StubRevalidator(result: true),
            runningExecutableImageValidator: RecordingImageValidator(result: true),
            terminationGracePeriod: .milliseconds(100)
        )
    }

    private func request(
        _ executable: AntigravityCanonicalExecutable,
        arguments: [String] = [],
        environment: [String: String] = ["PATH": "/bin"],
        timeout: Duration = .seconds(10),
        maximumOutputBytes: Int = 64 * 1_024
    ) -> AntigravityCLIReportProcessRequest {
        AntigravityCLIReportProcessRequest(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectoryURL: workingDirectory,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )
    }

    private func script(_ body: String) throws -> AntigravityCanonicalExecutable {
        let url = directory.appendingPathComponent("agy-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(url.path, 0o700), 0)
        return AntigravityCanonicalExecutable(canonicalURL: url, role: .agyCLI)
    }

    private func processID(in file: URL) throws -> pid_t {
        XCTAssertTrue(waitUntilExists(file))
        let text = try String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(pid_t(text), "No PID in \(file.lastPathComponent)")
    }

    private func realPath(_ url: URL) throws -> String {
        let resolved = try XCTUnwrap(realpath(url.path, nil))
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func waitUntilExists(_ file: URL, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: file.path) { return true }
            usleep(20_000)
        }
        return FileManager.default.fileExists(atPath: file.path)
    }

    private func waitUntilGone(_ processID: pid_t, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(processID, 0) == -1, errno == ESRCH { return true }
            usleep(20_000)
        }
        let gone = kill(processID, 0) == -1 && errno == ESRCH
        if !gone { strayProcessIDs.append(processID) }
        return gone
    }
}

private struct StubRevalidator: AntigravityExecutableRevalidating {
    let result: Bool

    func isCurrent(_ executable: AntigravityCanonicalExecutable) -> Bool {
        result
    }
}

private final class RecordingImageValidator:
    AntigravityRunningExecutableImageValidating,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let result: Bool
    private var recorded: [Int32] = []

    init(result: Bool) {
        self.result = result
    }

    var processIDs: [Int32] {
        lock.withLock { recorded }
    }

    func validatesRunningImage(
        processID: Int32,
        executable: AntigravityCanonicalExecutable
    ) -> Bool {
        lock.withLock { recorded.append(processID) }
        return result
    }
}

private final class SwapBeforeSpawn: AntigravityExecutableRevalidating, @unchecked Sendable {
    private let lock = NSLock()
    private let catalogPath: String
    private let trustedBackupPath: String
    private let replacementPath: String
    private var didSwap = false

    init(catalogPath: String, trustedBackupPath: String, replacementPath: String) {
        self.catalogPath = catalogPath
        self.trustedBackupPath = trustedBackupPath
        self.replacementPath = replacementPath
    }

    func isCurrent(_ executable: AntigravityCanonicalExecutable) -> Bool {
        lock.withLock {
            guard !didSwap,
                rename(catalogPath, trustedBackupPath) == 0,
                rename(replacementPath, catalogPath) == 0
            else { return false }
            didSwap = true
            return true
        }
    }
}

/// Puts the trusted file back at the catalog path before validating, so only
/// the kernel-mapped image can reveal that the spawned bytes were swapped.
private final class RestoreBeforeImageValidation:
    AntigravityRunningExecutableImageValidating,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let catalogPath: String
    private let trustedBackupPath: String
    private let replacementPath: String
    private var processID: Int32?

    init(catalogPath: String, trustedBackupPath: String, replacementPath: String) {
        self.catalogPath = catalogPath
        self.trustedBackupPath = trustedBackupPath
        self.replacementPath = replacementPath
    }

    var validatedProcessID: Int32? {
        lock.withLock { processID }
    }

    func validatesRunningImage(processID: Int32, executable: AntigravityCanonicalExecutable) -> Bool {
        lock.withLock {
            self.processID = processID
            guard rename(catalogPath, replacementPath) == 0,
                rename(trustedBackupPath, catalogPath) == 0
            else { return false }
            return AntigravitySystemRunningExecutableImageValidator()
                .validatesRunningImage(processID: processID, executable: executable)
        }
    }
}
