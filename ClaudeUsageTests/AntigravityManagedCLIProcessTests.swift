import Darwin
import Foundation
import XCTest
@testable import ClaudeUsage

final class AntigravityManagedCLIProcessTests:
    XCTestCase
{
    func testEnvironmentIsAnExplicitAllowlistAndDisablesAutoUpdate() {
        let environment = AntigravityManagedCLIEnvironment(
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            userName: "tester"
        )

        XCTAssertEqual(
            Set(environment.values.keys),
            [
                "AGY_CLI_DISABLE_AUTO_UPDATE",
                "HOME",
                "LANG",
                "LC_ALL",
                "PATH",
                "TERM",
                "USER",
            ]
        )
        XCTAssertEqual(
            environment.values["AGY_CLI_DISABLE_AUTO_UPDATE"],
            "true"
        )
        XCTAssertEqual(environment.values["HOME"], "/Users/test")
        XCTAssertEqual(environment.values["USER"], "tester")
        XCTAssertNil(environment.values["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment.values["GOOGLE_APPLICATION_CREDENTIALS"])
    }

    func testSpawnSucceedingOnFirstAttemptNeverSleepsOrRetries() {
        var spawnCalls = 0
        var sleepCalls = 0

        let status = AntigravityManagedCLIProcessLauncher
            .spawnRetryingTextFileBusy(
                sleepBetweenAttempts: { sleepCalls += 1 },
                spawn: {
                    spawnCalls += 1
                    return 0
                }
            )

        XCTAssertEqual(status, 0)
        XCTAssertEqual(spawnCalls, 1)
        XCTAssertEqual(sleepCalls, 0)
    }

    func testSpawnRetriesTextFileBusyUntilSuccess() {
        var outcomes: [Int32] = [ETXTBSY, ETXTBSY, 0]
        var sleepCalls = 0

        let status = AntigravityManagedCLIProcessLauncher
            .spawnRetryingTextFileBusy(
                sleepBetweenAttempts: { sleepCalls += 1 },
                spawn: { outcomes.removeFirst() }
            )

        XCTAssertEqual(status, 0)
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertEqual(sleepCalls, 2)
    }

    func testSpawnStopsRetryingTextFileBusyAtAttemptLimit() {
        var spawnCalls = 0

        let status = AntigravityManagedCLIProcessLauncher
            .spawnRetryingTextFileBusy(
                sleepBetweenAttempts: {},
                spawn: {
                    spawnCalls += 1
                    return ETXTBSY
                }
            )

        XCTAssertEqual(status, ETXTBSY)
        XCTAssertEqual(spawnCalls, 3)
    }

    func testSpawnNeverRetriesOtherFailures() {
        var spawnCalls = 0
        var sleepCalls = 0

        let status = AntigravityManagedCLIProcessLauncher
            .spawnRetryingTextFileBusy(
                sleepBetweenAttempts: { sleepCalls += 1 },
                spawn: {
                    spawnCalls += 1
                    return EPERM
                }
            )

        XCTAssertEqual(status, EPERM)
        XCTAssertEqual(spawnCalls, 1)
        XCTAssertEqual(sleepCalls, 0)
    }

    func testLaunchRequestRejectsNonCLIExecutable() {
        let bundle = AntigravityAppBundleIdentity(
            canonicalRootURL: URL(
                fileURLWithPath: "/Applications/Antigravity.app"
            ),
            bundleIdentifier:
                AntigravityAppBundleIdentity
                    .requiredBundleIdentifier
        )
        let executable = AntigravityCanonicalExecutable(
            canonicalURL: URL(
                fileURLWithPath:
                    "/Applications/Antigravity.app/Contents/Resources/bin/language_server"
            ),
            role: .appLanguageServer,
            appBundle: bundle
        )

        XCTAssertNil(AntigravityManagedCLIProcessLaunchRequest(
            executable: executable,
            environment: AntigravityManagedCLIEnvironment(),
            currentDirectoryURL:
                FileManager.default.temporaryDirectory
        ))
    }

    func testProductionLauncherRejectsArbitraryLocalCLI()
        throws
    {
        let harness = try ManagedProcessScriptHarness(
            body: """
            #!/bin/sh
            exit 0
            """
        )
        defer { harness.cleanup() }

        XCTAssertThrowsError(
            try AntigravityManagedCLIProcessLauncher()
                .launchSuspended(harness.request)
        ) {
            XCTAssertEqual(
                $0 as? AntigravityManagedSessionError,
                .executableNotAllowed
            )
        }
    }

    func testInstalledPinnedAGYCanBeSuspendedByProductionLauncher()
        async throws
    {
        let home = FileManager.default.realHomeDirectory
        let resolution =
            AntigravityProductionExecutableCatalogResolver(
                homeDirectoryURL: home
            ).resolve()
        guard let executable =
            resolution.managedLaunchExecutable else {
            throw XCTSkip(
                "검증된 공식 AGY가 설치되지 않았습니다"
            )
        }
        let request = try XCTUnwrap(
            AntigravityManagedCLIProcessLaunchRequest(
                executable: executable,
                environment: AntigravityManagedCLIEnvironment(
                    homeDirectory: home,
                    userName: NSUserName()
                ),
                currentDirectoryURL: home
            )
        )

        let handle = try AntigravityManagedCLIProcessLauncher()
            .launchSuspended(request)
        let recordedIdentity =
            AntigravityManagedProcessIdentityProvider()
                .identity(for: handle.processID)
        let termination = await handle.terminateTree(
            gracePeriod: .zero
        )

        XCTAssertEqual(
            recordedIdentity?.executablePath,
            executable.canonicalURL.path
        )
        XCTAssertEqual(termination, .confirmed)
    }

    func testManagedLaunchRejectsSwappedImageEvenAfterPathIsRestored()
        throws
    {
        let harness = try ManagedMachOReplacementHarness()
        defer { harness.cleanup() }
        let revalidator = ManagedSwapBeforeSpawnRevalidator(
            catalogPath: harness.catalogURL.path,
            trustedBackupPath: harness.trustedBackupURL.path,
            replacementPath: harness.replacementURL.path
        )
        let imageValidator =
            ManagedRestoreBeforeImageValidationValidator(
                catalogPath: harness.catalogURL.path,
                trustedBackupPath:
                    harness.trustedBackupURL.path,
                replacementPath: harness.replacementURL.path
            )

        XCTAssertThrowsError(
            try AntigravityManagedCLIProcessLauncher(
                executableRevalidator: revalidator,
                runningExecutableImageValidator:
                    imageValidator
            ).launchSuspended(harness.request)
        ) {
            XCTAssertEqual(
                $0 as? AntigravityManagedSessionError,
                .executableNotAllowed
            )
        }

        let processID = try XCTUnwrap(
            imageValidator.validatedProcessID()
        )
        errno = 0
        XCTAssertEqual(Darwin.kill(processID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testExitedRootRemainsReapableWhileOwnedDescendantIsCleaned()
        async throws
    {
        let harness = try ManagedProcessScriptHarness(
            body: """
            #!/bin/sh
            (
              trap '' TERM
              while :; do sleep 1; done
            ) &
            printf 'child=%s\\n' "$!"
            exit 7
            """
        )
        defer { harness.cleanup() }

        let handle = try AntigravityManagedCLIProcessLauncher(
            executableRevalidator:
                ManagedProcessExecutableRevalidatorStub(),
            runningExecutableImageValidator:
                ManagedProcessRunningImageValidatorStub()
        )
            .launchSuspended(harness.request)
        try handle.resume()
        let childPID = try await readChildPID(from: handle)
        let exitStatus = try await waitForTerminationStatus(
            from: handle
        )

        XCTAssertEqual(exitStatus, 7)
        var information = siginfo_t()
        XCTAssertEqual(
            waitid(
                P_PID,
                id_t(handle.processID),
                &information,
                WEXITED | WNOHANG | WNOWAIT
            ),
            0
        )
        XCTAssertEqual(information.si_pid, handle.processID)
        XCTAssertEqual(information.si_status, 7)

        let termination = await handle.terminateTree(
            gracePeriod: .milliseconds(10)
        )
        XCTAssertEqual(termination, .confirmed)

        try await assertProcessDisappears(handle.processID)
        try await assertProcessDisappears(childPID)
    }

    func testTerminateTreeEscalatesAndReapsRunningRoot()
        async throws
    {
        let harness = try ManagedProcessScriptHarness(
            body: """
            #!/bin/sh
            trap '' TERM
            while :; do sleep 1; done
            """
        )
        defer { harness.cleanup() }

        let handle = try AntigravityManagedCLIProcessLauncher(
            executableRevalidator:
                ManagedProcessExecutableRevalidatorStub(),
            runningExecutableImageValidator:
                ManagedProcessRunningImageValidatorStub()
        )
            .launchSuspended(harness.request)
        try handle.resume()
        XCTAssertNil(handle.terminationStatus())

        let termination = await handle.terminateTree(
            gracePeriod: .milliseconds(10)
        )
        XCTAssertEqual(termination, .confirmed)

        try await assertProcessDisappears(handle.processID)
        XCTAssertNotNil(handle.terminationStatus())
    }

    func testTerminateTreeReapsRootThatMovedToAnotherProcessGroup()
        async throws
    {
        let parentProcessGroup = getpgrp()
        XCTAssertGreaterThan(parentProcessGroup, 1)
        let harness = try ManagedProcessScriptHarness(
            body: """
            #!/bin/sh
            exec /usr/bin/perl -MPOSIX -e 'POSIX::setpgid(0, \(parentProcessGroup)); $|=1; $SIG{TERM}=sub{}; print "group=".POSIX::getpgrp()."\\n"; while (1) { select undef, undef, undef, 1; }'
            """
        )
        defer { harness.cleanup() }

        let handle = try AntigravityManagedCLIProcessLauncher(
            executableRevalidator:
                ManagedProcessExecutableRevalidatorStub(),
            runningExecutableImageValidator:
                ManagedProcessRunningImageValidatorStub()
        )
            .launchSuspended(harness.request)
        try handle.resume()
        let output = try await waitForOutput(from: handle)
        XCTAssertTrue(
            String(decoding: output, as: UTF8.self)
                .contains("group=\(parentProcessGroup)")
        )
        XCTAssertEqual(
            getpgid(handle.processID),
            parentProcessGroup
        )

        let termination = await handle.terminateTree(
            gracePeriod: .milliseconds(10)
        )
        XCTAssertEqual(termination, .confirmed)
        try await assertProcessDisappears(handle.processID)
    }

    func testSuspendedLaunchDoesNotRunUserCodeBeforeResume()
        async throws
    {
        let harness = try ManagedProcessScriptHarness(
            body: """
            #!/bin/sh
            printf 'started\\n'
            while :; do sleep 1; done
            """
        )
        defer { harness.cleanup() }

        let handle = try AntigravityManagedCLIProcessLauncher(
            executableRevalidator:
                ManagedProcessExecutableRevalidatorStub(),
            runningExecutableImageValidator:
                ManagedProcessRunningImageValidatorStub()
        )
            .launchSuspended(harness.request)
        XCTAssertEqual(
            handle.drainOutput(maximumBytes: 1_024),
            Data()
        )
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(
            handle.drainOutput(maximumBytes: 1_024),
            Data(),
            "AGY user code ran before durable state could be committed"
        )

        try handle.resume()
        try handle.resume()
        let output = try await waitForOutput(from: handle)
        XCTAssertTrue(
            String(decoding: output, as: UTF8.self)
                .contains("started")
        )

        let termination = await handle.terminateTree(
            gracePeriod: .milliseconds(10)
        )
        XCTAssertEqual(termination, .confirmed)
        try await assertProcessDisappears(handle.processID)
    }

    func testSuspendedLaunchCanBeTerminatedWithoutResume()
        async throws
    {
        let harness = try ManagedProcessScriptHarness(
            body: """
            #!/bin/sh
            printf 'must-not-run\\n'
            while :; do sleep 1; done
            """
        )
        defer { harness.cleanup() }

        let handle = try AntigravityManagedCLIProcessLauncher(
            executableRevalidator:
                ManagedProcessExecutableRevalidatorStub(),
            runningExecutableImageValidator:
                ManagedProcessRunningImageValidatorStub()
        )
            .launchSuspended(harness.request)
        let termination = await handle.terminateTree(
            gracePeriod: .seconds(1)
        )
        XCTAssertEqual(termination, .confirmed)

        XCTAssertEqual(
            handle.drainOutput(maximumBytes: 1_024),
            Data()
        )
        try await assertProcessDisappears(handle.processID)
    }

    private func waitForOutput(
        from handle: any AntigravityManagedCLIProcessHandling
    ) async throws -> Data {
        let deadline = ContinuousClock.now.advanced(
            by: .seconds(2)
        )
        var output = Data()
        while ContinuousClock.now < deadline {
            output.append(
                handle.drainOutput(maximumBytes: 1_024)
            )
            if !output.isEmpty {
                return output
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Resumed process produced no output")
        throw CocoaError(.fileReadUnknown)
    }

    private func readChildPID(
        from handle: any AntigravityManagedCLIProcessHandling
    ) async throws -> Int32 {
        let deadline = ContinuousClock.now.advanced(
            by: .seconds(2)
        )
        var output = Data()
        while ContinuousClock.now < deadline {
            output.append(
                handle.drainOutput(maximumBytes: 1_024)
            )
            let text = String(decoding: output, as: UTF8.self)
            if let range = text.range(
                of: #"child=(\d+)"#,
                options: .regularExpression
            ) {
                let value = text[range]
                    .dropFirst("child=".count)
                if let processID = Int32(value) {
                    return processID
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Child PID was not emitted")
        throw CocoaError(.fileReadUnknown)
    }

    private func waitForTerminationStatus(
        from handle: any AntigravityManagedCLIProcessHandling
    ) async throws -> Int32 {
        let deadline = ContinuousClock.now.advanced(
            by: .seconds(2)
        )
        while ContinuousClock.now < deadline {
            if let status = handle.terminationStatus() {
                return status
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Root process did not exit")
        throw CocoaError(.fileReadUnknown)
    }

    private func assertProcessDisappears(
        _ processID: Int32
    ) async throws {
        let deadline = ContinuousClock.now.advanced(
            by: .seconds(2)
        )
        while ContinuousClock.now < deadline {
            errno = 0
            if Darwin.kill(processID, 0) == -1,
               errno == ESRCH {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Process \(processID) was not cleaned up")
    }
}

private struct ManagedProcessExecutableRevalidatorStub:
    AntigravityExecutableRevalidating
{
    func isCurrent(
        _ executable: AntigravityCanonicalExecutable
    ) -> Bool {
        true
    }
}

private struct ManagedProcessRunningImageValidatorStub:
    AntigravityRunningExecutableImageValidating
{
    func validatesRunningImage(
        processID: Int32,
        executable: AntigravityCanonicalExecutable
    ) -> Bool {
        true
    }
}

private final class ManagedSwapBeforeSpawnRevalidator:
    AntigravityExecutableRevalidating,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let catalogPath: String
    private let trustedBackupPath: String
    private let replacementPath: String
    private var didSwap = false

    init(
        catalogPath: String,
        trustedBackupPath: String,
        replacementPath: String
    ) {
        self.catalogPath = catalogPath
        self.trustedBackupPath = trustedBackupPath
        self.replacementPath = replacementPath
    }

    func isCurrent(
        _ executable: AntigravityCanonicalExecutable
    ) -> Bool {
        lock.withLock {
            guard !didSwap,
                  atomicRename(
                      from: catalogPath,
                      to: trustedBackupPath
                  ),
                  atomicRename(
                      from: replacementPath,
                      to: catalogPath
                  ) else {
                return false
            }
            didSwap = true
            return true
        }
    }
}

private final class
    ManagedRestoreBeforeImageValidationValidator:
    AntigravityRunningExecutableImageValidating,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let catalogPath: String
    private let trustedBackupPath: String
    private let replacementPath: String
    private var processID: Int32?

    init(
        catalogPath: String,
        trustedBackupPath: String,
        replacementPath: String
    ) {
        self.catalogPath = catalogPath
        self.trustedBackupPath = trustedBackupPath
        self.replacementPath = replacementPath
    }

    func validatesRunningImage(
        processID: Int32,
        executable: AntigravityCanonicalExecutable
    ) -> Bool {
        lock.withLock {
            self.processID = processID
            guard atomicRename(
                from: catalogPath,
                to: replacementPath
            ),
            atomicRename(
                from: trustedBackupPath,
                to: catalogPath
            ) else {
                return false
            }
            return AntigravitySystemRunningExecutableImageValidator()
                .validatesRunningImage(
                    processID: processID,
                    executable: executable
                )
        }
    }

    func validatedProcessID() -> Int32? {
        lock.withLock { processID }
    }
}

private func atomicRename(
    from sourcePath: String,
    to destinationPath: String
) -> Bool {
    sourcePath.withCString { source in
        destinationPath.withCString { destination in
            Darwin.rename(source, destination) == 0
        }
    }
}

private final class ManagedMachOReplacementHarness {
    let directoryURL: URL
    let catalogURL: URL
    let trustedBackupURL: URL
    let replacementURL: URL
    let request: AntigravityManagedCLIProcessLaunchRequest

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ClaudeUsage-ManagedImage-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        catalogURL = directoryURL.appendingPathComponent("agy")
        trustedBackupURL = directoryURL
            .appendingPathComponent("agy-trusted")
        replacementURL = directoryURL
            .appendingPathComponent("agy-replacement")

        let source = URL(fileURLWithPath: "/bin/sleep")
        try FileManager.default.copyItem(
            at: source,
            to: catalogURL
        )
        try FileManager.default.copyItem(
            at: source,
            to: replacementURL
        )
        guard chmod(catalogURL.path, mode_t(0o700)) == 0,
              chmod(replacementURL.path, mode_t(0o700)) == 0,
              let fileIdentity =
                AntigravitySystemExecutableFileIdentityInspector()
                    .identity(at: catalogURL) else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }

        let executable = AntigravityCanonicalExecutable(
            canonicalURL: catalogURL,
            role: .agyCLI,
            fileIdentity: fileIdentity
        )
        request = AntigravityManagedCLIProcessLaunchRequest(
            executable: executable,
            environment: AntigravityManagedCLIEnvironment(
                homeDirectory: directoryURL,
                userName: "test"
            ),
            currentDirectoryURL: directoryURL
        )!
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private final class ManagedProcessScriptHarness {
    let directoryURL: URL
    let request: AntigravityManagedCLIProcessLaunchRequest

    init(body: String) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ClaudeUsage-ManagedProcess-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let scriptURL = directoryURL.appendingPathComponent(
            "agy-test",
            isDirectory: false
        )
        try body.write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )
        guard chmod(scriptURL.path, mode_t(0o700)) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        let executable = AntigravityCanonicalExecutable(
            canonicalURL: scriptURL,
            role: .agyCLI
        )
        request = AntigravityManagedCLIProcessLaunchRequest(
            executable: executable,
            environment: AntigravityManagedCLIEnvironment(
                homeDirectory: directoryURL,
                userName: "test"
            ),
            currentDirectoryURL: directoryURL
        )!
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
