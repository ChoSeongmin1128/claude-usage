import Darwin
import Foundation
import XCTest
@testable import ClaudeUsage

final class AntigravityDiscoverySecurityTests: XCTestCase {
    func testPSCommandSpoofCannotBecomeCandidateWithoutCatalogExecutable() async throws {
        let setup = makeAppCatalog()
        let subprocess = DiscoverySubprocessStub(output: """
        4242 /tmp/language_server --https_server_port 54321 --csrf_token secret
        """)
        let info = makeBSDInfo(processID: 4_242)
        let libproc = DiscoveryLibprocStub(
            bsdInfo: [4_242: [info, info, info]],
            executableURLs: [
                4_242: [
                    URL(fileURLWithPath: "/tmp/language_server"),
                    URL(fileURLWithPath: "/tmp/language_server"),
                ],
            ]
        )
        let inspector = AntigravityProcessInspector(
            catalog: setup.catalog,
            subprocessRunner: subprocess,
            libprocReader: libproc,
            kernelIdentityReader:
                DiscoveryKernelIdentityReaderStub(),
            runningExecutableImageValidator:
                DiscoveryRunningImageValidatorStub(),
            runningCodeTrustValidator:
                DiscoveryRunningCodeTrustValidatorStub(),
            effectiveUserID: AntigravityUserID(rawValue: 501),
            realUserID: AntigravityUserID(rawValue: 501)
        )

        let candidates = try await inspector.discoverProcesses(timeout: 1)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testWrongEffectiveOrRealUIDIsRejected() async throws {
        let setup = makeAppCatalog()
        let subprocess = DiscoverySubprocessStub(
            output: "4242 \(setup.executable.path) --csrf_token secret"
        )
        let wrongUID = AntigravityBSDProcessInfo(
            processID: 4_242,
            effectiveUserID: AntigravityUserID(rawValue: 502),
            realUserID: AntigravityUserID(rawValue: 501),
            startedAt: makeStartTime()
        )
        let libproc = DiscoveryLibprocStub(
            bsdInfo: [4_242: [wrongUID]],
            executableURLs: [4_242: [setup.executable]]
        )
        let inspector = AntigravityProcessInspector(
            catalog: setup.catalog,
            subprocessRunner: subprocess,
            libprocReader: libproc,
            kernelIdentityReader:
                DiscoveryKernelIdentityReaderStub(),
            runningExecutableImageValidator:
                DiscoveryRunningImageValidatorStub(),
            runningCodeTrustValidator:
                DiscoveryRunningCodeTrustValidatorStub(),
            effectiveUserID: AntigravityUserID(rawValue: 501),
            realUserID: AntigravityUserID(rawValue: 501)
        )

        let candidates = try await inspector.discoverProcesses(timeout: 1)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testPIDStartTimeReuseIsRejected() async throws {
        let setup = makeAppCatalog()
        let subprocess = DiscoverySubprocessStub(
            output: "4242 \(setup.executable.path) --csrf_token secret"
        )
        let before = makeBSDInfo(processID: 4_242)
        let reused = AntigravityBSDProcessInfo(
            processID: 4_242,
            effectiveUserID: before.effectiveUserID,
            realUserID: before.realUserID,
            startedAt: AntigravityProcessStartTime(
                seconds: before.startedAt.seconds + 1,
                microseconds: 0
            )!
        )
        let libproc = DiscoveryLibprocStub(
            bsdInfo: [4_242: [before, reused]],
            executableURLs: [4_242: [setup.executable]]
        )
        let inspector = makeProcessInspector(
            setup: setup,
            subprocess: subprocess,
            libproc: libproc
        )

        let candidates = try await inspector.discoverProcesses(timeout: 1)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testExecutableImageChangeDuringVerificationIsRejected() async throws {
        let setup = makeAppCatalog()
        let subprocess = DiscoverySubprocessStub(
            output: "4242 \(setup.executable.path) --csrf_token secret"
        )
        let info = makeBSDInfo(processID: 4_242)
        let libproc = DiscoveryLibprocStub(
            bsdInfo: [4_242: [info, info, info]],
            executableURLs: [
                4_242: [
                    setup.executable,
                    URL(fileURLWithPath: "/tmp/replaced-image"),
                ],
            ]
        )
        let inspector = makeProcessInspector(
            setup: setup,
            subprocess: subprocess,
            libproc: libproc
        )

        let candidates = try await inspector.discoverProcesses(timeout: 1)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testExecDuringRunningCodeVerificationIsRejected() async throws {
        let setup = makeAppCatalog()
        let processID: Int32 = 4_242
        let subprocess = DiscoverySubprocessStub(
            output:
                "\(processID) \(setup.executable.path) --https_server_port=54321"
        )
        let info = makeBSDInfo(processID: processID)
        let libproc = DiscoveryLibprocStub(
            bsdInfo: [processID: [info, info, info]],
            executableURLs: [
                processID: [setup.executable, setup.executable],
            ]
        )
        let inspector = AntigravityProcessInspector(
            catalog: setup.catalog,
            subprocessRunner: subprocess,
            libprocReader: libproc,
            kernelIdentityReader:
                DiscoveryKernelIdentityReaderStub(
                    pidVersions: [1, 2]
                ),
            runningExecutableImageValidator:
                DiscoveryRunningImageValidatorStub(),
            runningCodeTrustValidator:
                DiscoveryRunningCodeTrustValidatorStub(),
            effectiveUserID: info.effectiveUserID,
            realUserID: info.realUserID
        )

        let candidates = try await inspector.discoverProcesses(timeout: 1)

        XCTAssertTrue(candidates.isEmpty)
    }

    func testVerifiedAppCandidateUsesOnlyHintsFromVerifiedProcess() async throws {
        let setup = makeAppCatalog()
        let subprocess = DiscoverySubprocessStub(
            output: """
            4242 \(setup.executable.path) --https_server_port=54321 \
            --csrf_token app-secret
            """
        )
        let info = makeBSDInfo(processID: 4_242)
        let libproc = DiscoveryLibprocStub(
            bsdInfo: [4_242: [info, info, info]],
            executableURLs: [
                4_242: [setup.executable, setup.executable],
            ]
        )
        let inspector = makeProcessInspector(
            setup: setup,
            subprocess: subprocess,
            libproc: libproc
        )

        let candidates = try await inspector.discoverProcesses(timeout: 1)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.ownership, .external)
        XCTAssertEqual(
            candidate.connectionHints.requestedPort,
            AntigravityTCPPort(54_321)
        )
        XCTAssertEqual(
            candidate.connectionHints.csrfToken?.value,
            "app-secret"
        )
        XCTAssertFalse(String(describing: candidate.connectionHints).contains(
            "app-secret"
        ))
    }

    func testLsofNULParserHandlesChunksAndStrictListeningState() throws {
        let payload = lsofPayload([
            "p42",
            "f7",
            "n127.0.0.1:54321",
            "PTCP",
            "TST=ESTABLISHED",
            "f8",
            "n[::1]:54322",
            "PTCP",
            "TST=LISTEN",
        ])
        var parser = AntigravityLsofNULParser()
        parser.consume(payload.prefix(5))
        parser.consume(payload.dropFirst(5).prefix(11))
        parser.consume(payload.dropFirst(16))

        let records = try parser.finish()
        XCTAssertEqual(records, [
            AntigravityLsofListeningRecord(
                processID: 42,
                fileDescriptor: "8",
                endpoint: AntigravityOwnedListeningEndpoint(
                    host: .ipv6,
                    port: AntigravityTCPPort(54_322)!
                )
            ),
        ])
    }

    func testLsofParserRejectsWildcardAndNonLoopbackListeners() throws {
        let payload = lsofPayload([
            "p42",
            "f1", "n*:54321", "PTCP", "TST=LISTEN",
            "f2", "n0.0.0.0:54322", "PTCP", "TST=LISTEN",
            "f3", "n192.0.2.10:54323", "PTCP", "TST=LISTEN",
            "f4", "n127.0.0.1:54324", "PTCP", "TST=LISTEN",
        ])
        var parser = AntigravityLsofNULParser()
        parser.consume(payload)

        XCTAssertEqual(
            try parser.finish().map(\.endpoint),
            [
                AntigravityOwnedListeningEndpoint(
                    host: .ipv4,
                    port: AntigravityTCPPort(54_324)!
                ),
            ]
        )
    }

    func testLsofInspectorUsesExactArgumentsAndPIDOwnershipFilter() async throws {
        let output = lsofPayload([
            "p42",
            "f1", "n127.0.0.1:54321", "PTCP", "TST=LISTEN",
            "p99",
            "f2", "n127.0.0.1:54322", "PTCP", "TST=LISTEN",
        ])
        let runner = DiscoverySubprocessStub(
            result: AntigravityOwnedSubprocessResult(
                standardOutput: output,
                standardError: Data(),
                terminationStatus: 0
            )
        )
        let inspector = AntigravityPortOwnershipInspector(
            subprocessRunner: runner,
            lsofExecutableURL: URL(fileURLWithPath: "/fake/lsof")
        )

        let result = try await inspector.listeningEndpoints(
            ownedBy: [42],
            timeout: 1
        )
        XCTAssertEqual(
            result,
            [
                42: [
                    AntigravityOwnedListeningEndpoint(
                        host: .ipv4,
                        port: AntigravityTCPPort(54_321)!
                    ),
                ],
            ]
        )
        XCTAssertEqual(runner.requests().single?.arguments, [
            "-nP",
            "-a",
            "-p", "42",
            "-iTCP",
            "-sTCP:LISTEN",
            "-F0pfnPT",
        ])
    }

    func testPortResolutionRequiresHintOwnershipAndRejectsAmbiguity() {
        let first = AntigravityOwnedListeningEndpoint(
            host: .ipv4,
            port: AntigravityTCPPort(54_321)!
        )
        let second = AntigravityOwnedListeningEndpoint(
            host: .ipv4,
            port: AntigravityTCPPort(54_322)!
        )
        let ipv6SamePort = AntigravityOwnedListeningEndpoint(
            host: .ipv6,
            port: first.port
        )

        XCTAssertEqual(
            AntigravityPortOwnershipInspector.resolvePort(
                requestedPort: first.port,
                ownedEndpoints: [first, second]
            ),
            .selected(first)
        )
        XCTAssertEqual(
            AntigravityPortOwnershipInspector.resolvePort(
                requestedPort: AntigravityTCPPort(60_000)!,
                ownedEndpoints: [first]
            ),
            .requestedPortNotOwned
        )
        XCTAssertEqual(
            AntigravityPortOwnershipInspector.resolvePort(
                requestedPort: nil,
                ownedEndpoints: [first, second]
            ),
            .ambiguous([first, second])
        )
        XCTAssertEqual(
            AntigravityPortOwnershipInspector.resolvePort(
                requestedPort: first.port,
                ownedEndpoints: [first, ipv6SamePort]
            ),
            .selected(first)
        )
        XCTAssertEqual(
            AntigravityPortOwnershipInspector.resolvePort(
                requestedPort: nil,
                ownedEndpoints: [ipv6SamePort]
            ),
            .noListeningPort
        )
    }

    func testPositiveCacheRevalidatesProcessAndPortEveryHit() async throws {
        let candidate = makeRuntimeCandidate()
        let processInspector = DiscoveryProcessInspectorStub(
            discoveries: [[candidate]]
        )
        let portInspector = DiscoveryPortInspectorStub(
            observations: [ownedEndpointMap(for: candidate)]
        )
        let discovery = AntigravityRuntimeDiscovery(
            processInspector: processInspector,
            portInspector: portInspector,
            installations: [candidate.processIdentity.executable]
        )

        let first = try await discovery.discover()
        let second = try await discovery.discover()

        XCTAssertEqual(first.endpoints.count, 1)
        XCTAssertEqual(second, first)
        XCTAssertEqual(processInspector.discoverCallCount(), 1)
        // Fresh discovery verifies after lsof; a cache hit verifies both before
        // and after the ownership observation.
        XCTAssertEqual(processInspector.revalidateCallCount(), 3)
        XCTAssertEqual(portInspector.callCount(), 2)
    }

    func testAGYDiscoveryRetainsEveryOwnedIPv4PortWithoutHint()
        async throws
    {
        let candidate = makeRuntimeCandidate()
        let first = AntigravityOwnedListeningEndpoint(
            host: .ipv4,
            port: AntigravityTCPPort(54_321)!
        )
        let second = AntigravityOwnedListeningEndpoint(
            host: .ipv4,
            port: AntigravityTCPPort(54_322)!
        )
        let ignoredIPv6 = AntigravityOwnedListeningEndpoint(
            host: .ipv6,
            port: AntigravityTCPPort(54_323)!
        )
        let discovery = AntigravityRuntimeDiscovery(
            processInspector: DiscoveryProcessInspectorStub(
                discoveries: [[candidate]]
            ),
            portInspector: DiscoveryPortInspectorStub(
                observations: [[
                    candidate.processIdentity.processID: [
                        second,
                        ignoredIPv6,
                        first,
                    ],
                ]]
            ),
            installations: [
                candidate.processIdentity.executable,
            ]
        )

        let snapshot = try await discovery.discover()

        XCTAssertEqual(
            snapshot.endpoints.map(\.port),
            [first.port, second.port]
        )
        XCTAssertTrue(
            snapshot.endpoints.allSatisfy {
                $0.processIdentity
                    == candidate.processIdentity
                    && $0.authentication == .cliTokenless
            }
        )
    }

    func testPositiveCacheRevalidatesMutableManagedOwnership() async throws {
        let fileSystem = DiscoveryCatalogFileSystemStub()
        let executableURL = URL(
            fileURLWithPath: "/opt/homebrew/bin/agy"
        )
        fileSystem.executablePaths = [executableURL.path]
        let catalog = AntigravityExecutableCatalog(
            appBundleRoots: [],
            agyExecutableURLs: [executableURL],
            fileSystem: fileSystem
        )
        let executable = try XCTUnwrap(catalog.executables.single)
        let processID: Int32 = 7_778
        let processInfo = makeBSDInfo(processID: processID)
        let subprocess = DiscoverySubprocessStub(
            output:
                "\(processID) \(executableURL.path) --https_server_port=54321"
        )
        let libproc = DiscoveryLibprocStub(
            bsdInfo: [processID: [processInfo]],
            executableURLs: [processID: [executableURL]]
        )
        let registry = AntigravityManagedRuntimeRegistry()
        let identity = AntigravityVerifiedProcessIdentity(
            processID: processID,
            effectiveUserID: processInfo.effectiveUserID,
            realUserID: processInfo.realUserID,
            startedAt: processInfo.startedAt,
            executable: executable
        )!
        await registry.register(identity)

        let processInspector = AntigravityProcessInspector(
            catalog: catalog,
            subprocessRunner: subprocess,
            libprocReader: libproc,
            kernelIdentityReader:
                DiscoveryKernelIdentityReaderStub(),
            runningExecutableImageValidator:
                DiscoveryRunningImageValidatorStub(),
            runningCodeTrustValidator:
                DiscoveryRunningCodeTrustValidatorStub(),
            effectiveUserID: processInfo.effectiveUserID,
            realUserID: processInfo.realUserID,
            ownershipResolver: registry
        )
        let portInspector = DiscoveryPortInspectorStub(
            observations: [[
                processID: [
                    AntigravityOwnedListeningEndpoint(
                        host: .ipv4,
                        port: AntigravityTCPPort(54_321)!
                    ),
                ],
            ]]
        )
        let discovery = AntigravityRuntimeDiscovery(
            processInspector: processInspector,
            portInspector: portInspector,
            installations: [executable]
        )

        let managed = try await discovery.discover()
        XCTAssertEqual(managed.endpoints.single?.ownership, .managed)

        await registry.unregister(identity)
        let borrowed = try await discovery.discover()

        XCTAssertEqual(borrowed.processes.single?.ownership, .borrowed)
        XCTAssertEqual(borrowed.endpoints.single?.ownership, .borrowed)
        XCTAssertFalse(
            borrowed.endpoints.contains { $0.ownership == .managed }
        )
        XCTAssertEqual(subprocess.requests().count, 2)
    }

    func testInvalidatedCacheNeverReturnsStaleSnapshot() async throws {
        let candidate = makeRuntimeCandidate()
        let processInspector = DiscoveryProcessInspectorStub(
            discoveries: [[candidate], []],
            revalidations: [true, false]
        )
        let portInspector = DiscoveryPortInspectorStub(
            observations: [ownedEndpointMap(for: candidate)]
        )
        let discovery = AntigravityRuntimeDiscovery(
            processInspector: processInspector,
            portInspector: portInspector,
            installations: [candidate.processIdentity.executable]
        )

        let first = try await discovery.discover()
        XCTAssertEqual(first.endpoints.count, 1)
        let refreshed = try await discovery.discover()

        XCTAssertTrue(refreshed.processes.isEmpty)
        XCTAssertTrue(refreshed.endpoints.isEmpty)
        XCTAssertEqual(processInspector.discoverCallCount(), 2)
    }

    func testConcurrentDiscoveryIsSingleFlight() async throws {
        let candidate = makeRuntimeCandidate()
        let processInspector = DiscoveryProcessInspectorStub(
            discoveries: [[candidate]],
            discoveryDelayNanoseconds: 120_000_000
        )
        let portInspector = DiscoveryPortInspectorStub(
            observations: [ownedEndpointMap(for: candidate)]
        )
        let discovery = AntigravityRuntimeDiscovery(
            processInspector: processInspector,
            portInspector: portInspector,
            installations: [candidate.processIdentity.executable]
        )

        async let first = discovery.discover()
        async let second = discovery.discover()
        let snapshots = try await [first, second]

        XCTAssertEqual(snapshots[0], snapshots[1])
        XCTAssertEqual(processInspector.discoverCallCount(), 1)
        XCTAssertEqual(portInspector.callCount(), 1)
    }

    func testCancelledWaiterDoesNotCancelSharedDiscoveryForOtherWaiter() async throws {
        let candidate = makeRuntimeCandidate()
        let processInspector = DiscoveryProcessInspectorStub(
            discoveries: [[candidate]],
            discoveryDelayNanoseconds: 180_000_000
        )
        let portInspector = DiscoveryPortInspectorStub(
            observations: [ownedEndpointMap(for: candidate)]
        )
        let discovery = AntigravityRuntimeDiscovery(
            processInspector: processInspector,
            portInspector: portInspector,
            installations: [candidate.processIdentity.executable]
        )

        let retained = Task { try await discovery.discover() }
        try await Task.sleep(for: .milliseconds(20))
        let cancelled = Task { try await discovery.discover() }
        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()

        do {
            _ = try await cancelled.value
            XCTFail("Cancelled waiter unexpectedly received the shared value")
        } catch is CancellationError {
            // Expected: only this waiter is released.
        }

        let retainedSnapshot = try await retained.value
        XCTAssertEqual(retainedSnapshot.endpoints.count, 1)
        XCTAssertEqual(processInspector.discoverCallCount(), 1)
    }

    func testJoiningWaiterHonorsItsOwnShorterDiscoveryDeadline() async throws {
        let candidate = makeRuntimeCandidate()
        let processInspector = DiscoveryProcessInspectorStub(
            discoveries: [[candidate]],
            discoveryDelayNanoseconds: 180_000_000
        )
        let portInspector = DiscoveryPortInspectorStub(
            observations: [ownedEndpointMap(for: candidate)]
        )
        let discovery = AntigravityRuntimeDiscovery(
            processInspector: processInspector,
            portInspector: portInspector,
            installations: [candidate.processIdentity.executable]
        )

        let retained = Task {
            try await discovery.discover(deadline: AntigravityRPCDeadline(
                totalTimeout: .seconds(1),
                discoveryTimeout: .seconds(1)
            ))
        }
        try await Task.sleep(for: .milliseconds(20))

        do {
            _ = try await discovery.discover(deadline: AntigravityRPCDeadline(
                totalTimeout: .milliseconds(30),
                discoveryTimeout: .milliseconds(30)
            ))
            XCTFail("Short-deadline waiter unexpectedly received shared value")
        } catch let error as AntigravityRPCDeadlineError {
            XCTAssertEqual(error, .timedOut(.discovery))
        }

        let snapshot = try await retained.value
        XCTAssertEqual(snapshot.endpoints.count, 1)
        XCTAssertEqual(processInspector.discoverCallCount(), 1)
    }

    func testLongWaiterIsNotBoundToFirstShortWaiterDeadline() async throws {
        let candidate = makeRuntimeCandidate()
        let processInspector = DiscoveryProcessInspectorStub(
            discoveries: [[candidate]],
            discoveryDelayNanoseconds: 180_000_000
        )
        let portInspector = DiscoveryPortInspectorStub(
            observations: [ownedEndpointMap(for: candidate)]
        )
        let discovery = AntigravityRuntimeDiscovery(
            processInspector: processInspector,
            portInspector: portInspector,
            installations: [candidate.processIdentity.executable]
        )

        let short = Task {
            try await discovery.discover(deadline: AntigravityRPCDeadline(
                totalTimeout: .milliseconds(40),
                discoveryTimeout: .milliseconds(40)
            ))
        }
        try await Task.sleep(for: .milliseconds(10))
        let retained = Task {
            try await discovery.discover(deadline: AntigravityRPCDeadline(
                totalTimeout: .seconds(1),
                discoveryTimeout: .seconds(1)
            ))
        }

        do {
            _ = try await short.value
            XCTFail("Short first waiter unexpectedly completed")
        } catch let error as AntigravityRPCDeadlineError {
            XCTAssertEqual(error, .timedOut(.discovery))
        }

        let snapshot = try await retained.value
        XCTAssertEqual(snapshot.endpoints.count, 1)
        XCTAssertEqual(processInspector.discoverCallCount(), 1)
    }

    func testOwnedHelperCancellationEscalatesWithoutWaitingForSIGTERM() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let scriptURL = directory.appendingPathComponent("stubborn-helper")
        let pidURL = directory.appendingPathComponent("pid")
        try """
        #!/bin/sh
        echo $$ > "$1"
        trap '' TERM
        while :; do :; done
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        let runner = AntigravityOwnedSubprocessRunner(
            allowedExecutableURLs: [URL(fileURLWithPath: "/bin/sh")]
        )
        let task = Task {
            try await runner.run(
                AntigravityOwnedSubprocessRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [scriptURL.path, pidURL.path],
                    timeout: 5
                )
            )
        }
        for _ in 0..<50
        where !FileManager.default.fileExists(atPath: pidURL.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidURL.path))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled owned helper unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }

        let processID = try XCTUnwrap(
            Int32(
                String(contentsOf: pidURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        errno = 0
        XCTAssertEqual(kill(processID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testOwnedHelperTimeoutIsBoundedAndReapsBeforeReturning() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let scriptURL = directory.appendingPathComponent("stubborn-helper")
        let pidURL = directory.appendingPathComponent("pid")
        try """
        #!/bin/sh
        echo $$ > "$1"
        trap '' TERM
        while :; do :; done
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        let runner = AntigravityOwnedSubprocessRunner(
            allowedExecutableURLs: [URL(fileURLWithPath: "/bin/sh")]
        )
        let startedAt = ContinuousClock.now

        do {
            _ = try await runner.run(
                AntigravityOwnedSubprocessRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [scriptURL.path, pidURL.path],
                    timeout: 0.05
                )
            )
            XCTFail("Timed-out owned helper unexpectedly completed")
        } catch let error as AntigravityOwnedSubprocessError {
            XCTAssertEqual(error, .timedOut)
        }

        XCTAssertLessThan(
            startedAt.duration(to: .now),
            .seconds(2)
        )
        let processID = try XCTUnwrap(
            Int32(
                String(contentsOf: pidURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        errno = 0
        XCTAssertEqual(kill(processID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testOwnedHelperDrainsBothPipesAndPreservesExitStatus() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let scriptURL = directory.appendingPathComponent("finite-helper")
        try """
        #!/bin/sh
        printf 'stdout-complete'
        printf 'stderr-complete' >&2
        exit 7
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        let runner = AntigravityOwnedSubprocessRunner(
            allowedExecutableURLs: [URL(fileURLWithPath: "/bin/sh")]
        )

        let result = try await runner.run(
            AntigravityOwnedSubprocessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [scriptURL.path],
                timeout: 1,
                maximumOutputBytes: 1_024
            )
        )

        XCTAssertEqual(
            String(decoding: result.standardOutput, as: UTF8.self),
            "stdout-complete"
        )
        XCTAssertEqual(
            String(decoding: result.standardError, as: UTF8.self),
            "stderr-complete"
        )
        XCTAssertEqual(result.terminationStatus, 7)
    }

    func testOwnedHelperOutputCapStopsAndReapsProducer() async throws {
        let runner = AntigravityOwnedSubprocessRunner(
            allowedExecutableURLs: [URL(fileURLWithPath: "/bin/sh")]
        )

        do {
            _ = try await runner.run(
                AntigravityOwnedSubprocessRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        "while :; do printf '0123456789'; done",
                    ],
                    timeout: 2,
                    maximumOutputBytes: 128
                )
            )
            XCTFail("Unbounded producer unexpectedly completed")
        } catch let error as AntigravityOwnedSubprocessError {
            XCTAssertEqual(error, .outputLimitExceeded)
        }
    }
}

private struct AppCatalogSetup {
    let catalog: AntigravityExecutableCatalog
    let executable: URL
}

private func makeAppCatalog() -> AppCatalogSetup {
    let fileSystem = DiscoveryCatalogFileSystemStub()
    let root = URL(fileURLWithPath: "/Applications/Antigravity.app")
    let executable = root.appendingPathComponent(
        "Contents/Resources/bin/language_server"
    )
    fileSystem.bundleIdentifiers[root.path] =
        AntigravityAppBundleIdentity.requiredBundleIdentifier
    fileSystem.executablePaths = [executable.path]
    return AppCatalogSetup(
        catalog: AntigravityExecutableCatalog(
            appBundleRoots: [root],
            agyExecutableURLs: [],
            fileSystem: fileSystem
        ),
        executable: executable
    )
}

private func makeProcessInspector(
    setup: AppCatalogSetup,
    subprocess: DiscoverySubprocessStub,
    libproc: DiscoveryLibprocStub
) -> AntigravityProcessInspector {
    AntigravityProcessInspector(
        catalog: setup.catalog,
        subprocessRunner: subprocess,
        libprocReader: libproc,
        kernelIdentityReader:
            DiscoveryKernelIdentityReaderStub(),
        runningExecutableImageValidator:
            DiscoveryRunningImageValidatorStub(),
        runningCodeTrustValidator:
            DiscoveryRunningCodeTrustValidatorStub(),
        effectiveUserID: AntigravityUserID(rawValue: 501),
        realUserID: AntigravityUserID(rawValue: 501)
    )
}

private func makeBSDInfo(processID: Int32) -> AntigravityBSDProcessInfo {
    AntigravityBSDProcessInfo(
        processID: processID,
        effectiveUserID: AntigravityUserID(rawValue: 501),
        realUserID: AntigravityUserID(rawValue: 501),
        startedAt: makeStartTime()
    )
}

private func makeStartTime() -> AntigravityProcessStartTime {
    AntigravityProcessStartTime(
        seconds: 1_700_000_000,
        microseconds: 123
    )!
}

private func lsofPayload(_ fields: [String]) -> Data {
    var data = Data()
    for field in fields {
        data.append(contentsOf: field.utf8)
        data.append(0)
        if field.first == "p" {
            data.append(0x0A)
        }
    }
    return data
}

private func makeRuntimeCandidate() -> AntigravityRuntimeProcessCandidate {
    let executable = AntigravityCanonicalExecutable(
        canonicalURL: URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
        role: .agyCLI
    )
    let identity = AntigravityVerifiedProcessIdentity(
        processID: 7_777,
        effectiveUserID: AntigravityUserID(rawValue: 501),
        realUserID: AntigravityUserID(rawValue: 501),
        startedAt: makeStartTime(),
        executable: executable
    )!
    return AntigravityRuntimeProcessCandidate(
        processIdentity: identity,
        ownership: .borrowed
    )!
}

private func ownedEndpointMap(
    for candidate: AntigravityRuntimeProcessCandidate
) -> [Int32: Set<AntigravityOwnedListeningEndpoint>] {
    [
        candidate.processIdentity.processID: [
            AntigravityOwnedListeningEndpoint(
                host: .ipv4,
                port: AntigravityTCPPort(54_321)!
            ),
        ],
    ]
}

private final class DiscoveryCatalogFileSystemStub:
    AntigravityExecutableCatalogFileSystem,
    @unchecked Sendable
{
    var bundleIdentifiers: [String: String] = [:]
    var executablePaths: Set<String> = []

    func canonicalURL(for url: URL) -> URL {
        url.standardizedFileURL
    }

    func isExecutableRegularFile(at url: URL) -> Bool {
        executablePaths.contains(url.path)
    }

    func bundleIdentifier(at appBundleRoot: URL) -> String? {
        bundleIdentifiers[appBundleRoot.path]
    }
}

private struct DiscoveryRunningImageValidatorStub:
    AntigravityRunningExecutableImageValidating
{
    let result: Bool

    init(result: Bool = true) {
        self.result = result
    }

    func validatesRunningImage(
        processID: Int32,
        executable: AntigravityCanonicalExecutable
    ) -> Bool {
        result
    }
}

private struct DiscoveryRunningCodeTrustValidatorStub:
    AntigravityRunningCodeTrustValidating
{
    let result: Bool

    init(result: Bool = true) {
        self.result = result
    }

    func validatesRunningCode(
        processID: Int32,
        executable: AntigravityCanonicalExecutable
    ) -> Bool {
        result
    }
}

private final class DiscoveryKernelIdentityReaderStub:
    AntigravityKernelProcessIdentityReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let pidVersions: [Int32]
    private var index = 0

    init(pidVersions: [Int32] = [1]) {
        precondition(!pidVersions.isEmpty)
        self.pidVersions = pidVersions
    }

    func kernelIdentity(
        for processID: Int32
    ) -> AntigravityKernelProcessIdentity? {
        lock.lock()
        defer { lock.unlock() }
        let pidVersion =
            pidVersions[min(index, pidVersions.count - 1)]
        index += 1
        return AntigravityKernelProcessIdentity(
            uniqueID: UInt64(processID),
            parentUniqueID: 1,
            pidVersion: pidVersion
        )
    }
}

private final class DiscoverySubprocessStub:
    AntigravityOwnedSubprocessRunning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let result: AntigravityOwnedSubprocessResult
    private var recordedRequests: [AntigravityOwnedSubprocessRequest] = []

    init(output: String) {
        self.result = AntigravityOwnedSubprocessResult(
            standardOutput: Data(output.utf8),
            standardError: Data(),
            terminationStatus: 0
        )
    }

    init(result: AntigravityOwnedSubprocessResult) {
        self.result = result
    }

    func run(
        _ request: AntigravityOwnedSubprocessRequest
    ) async throws -> AntigravityOwnedSubprocessResult {
        lock.withLock {
            recordedRequests.append(request)
        }
        return result
    }

    func requests() -> [AntigravityOwnedSubprocessRequest] {
        lock.withLock { recordedRequests }
    }
}

private final class DiscoveryLibprocStub:
    AntigravityLibprocReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var bsdInfoValues: [Int32: [AntigravityBSDProcessInfo]]
    private var executableURLValues: [Int32: [URL]]

    init(
        bsdInfo: [Int32: [AntigravityBSDProcessInfo]],
        executableURLs: [Int32: [URL]]
    ) {
        self.bsdInfoValues = bsdInfo
        self.executableURLValues = executableURLs
    }

    func bsdInfo(for processID: Int32) -> AntigravityBSDProcessInfo? {
        lock.withLock {
            nextValue(in: &bsdInfoValues, for: processID)
        }
    }

    func executableURL(for processID: Int32) -> URL? {
        lock.withLock {
            nextValue(in: &executableURLValues, for: processID)
        }
    }

    private func nextValue<Value>(
        in values: inout [Int32: [Value]],
        for processID: Int32
    ) -> Value? {
        guard var sequence = values[processID],
              let first = sequence.first else {
            return nil
        }
        if sequence.count > 1 {
            sequence.removeFirst()
            values[processID] = sequence
        }
        return first
    }
}

private final class DiscoveryProcessInspectorStub:
    AntigravityRuntimeProcessInspecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var discoveries:
        [[AntigravityRuntimeProcessCandidate]]
    private var revalidations: [Bool]
    private let discoveryDelayNanoseconds: UInt64
    private var discoveryCalls = 0
    private var revalidationCalls = 0

    init(
        discoveries: [[AntigravityRuntimeProcessCandidate]],
        revalidations: [Bool] = [],
        discoveryDelayNanoseconds: UInt64 = 0
    ) {
        self.discoveries = discoveries
        self.revalidations = revalidations
        self.discoveryDelayNanoseconds = discoveryDelayNanoseconds
    }

    func discoverProcesses(
        timeout: TimeInterval
    ) async throws -> [AntigravityRuntimeProcessCandidate] {
        if discoveryDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: discoveryDelayNanoseconds)
        }
        return lock.withLock {
            discoveryCalls += 1
            guard discoveries.count > 1 else {
                return discoveries.first ?? []
            }
            return discoveries.removeFirst()
        }
    }

    func revalidate(
        _ identity: AntigravityVerifiedProcessIdentity
    ) async -> Bool {
        lock.withLock {
            revalidationCalls += 1
            guard revalidations.count > 1 else {
                return revalidations.first ?? true
            }
            return revalidations.removeFirst()
        }
    }

    func discoverCallCount() -> Int {
        lock.withLock { discoveryCalls }
    }

    func revalidateCallCount() -> Int {
        lock.withLock { revalidationCalls }
    }
}

private final class DiscoveryPortInspectorStub:
    AntigravityPortOwnershipInspecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var observations:
        [[Int32: Set<AntigravityOwnedListeningEndpoint>]]
    private var calls = 0

    init(
        observations:
            [[Int32: Set<AntigravityOwnedListeningEndpoint>]]
    ) {
        self.observations = observations
    }

    func listeningEndpoints(
        ownedBy processIDs: Set<Int32>,
        timeout: TimeInterval
    ) async throws -> [Int32: Set<AntigravityOwnedListeningEndpoint>] {
        lock.withLock {
            calls += 1
            guard observations.count > 1 else {
                return observations.first ?? [:]
            }
            return observations.removeFirst()
        }
    }

    func callCount() -> Int {
        lock.withLock { calls }
    }
}

private extension Collection {
    var single: Element? {
        count == 1 ? first : nil
    }
}
