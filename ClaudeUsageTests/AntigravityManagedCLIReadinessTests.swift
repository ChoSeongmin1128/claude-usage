import Foundation
import XCTest
@testable import ClaudeUsage

final class AntigravityManagedCLIReadinessTests:
    XCTestCase
{
    func testExactManagedEndpointAndValidatedRPCBecomeReady()
        async throws
    {
        let identity = makeIdentity(processID: 4_101)
        let endpoint = makeEndpoint(identity: identity)
        let discovery = ManagedReadinessDiscoveryStub(
            snapshots: [makeSnapshot(
                identity: identity,
                endpoints: [endpoint]
            )]
        )
        let processInspector =
            ManagedReadinessProcessInspectorStub()
        let handle = ManagedReadinessProcessHandleStub(
            processID: identity.processID
        )
        let checker = makeChecker(
            discovery: discovery,
            processInspector: processInspector
        )

        let result = try await checker.waitUntilReady(
            handle: handle,
            processIdentity: identity,
            deadline: AntigravityRPCDeadline(
                totalTimeout: .seconds(1),
                discoveryTimeout: .seconds(1)
            )
        )

        XCTAssertEqual(result.runtime.endpoint, endpoint)
        XCTAssertEqual(
            result.runtime.processIdentity,
            identity
        )
        XCTAssertTrue(result.diagnostics.interactions.isEmpty)
        XCTAssertFalse(result.diagnostics.outputWasTruncated)
        XCTAssertEqual(discovery.discoverCallCount(), 1)
        XCTAssertEqual(processInspector.revalidateCallCount(), 2)
    }

    func testBoundEndpointWaitsForValidatedRPC()
        async throws
    {
        let identity = makeIdentity(processID: 4_108)
        let endpoint = makeEndpoint(identity: identity)
        let discovery = ManagedReadinessDiscoveryStub(
            snapshots: [makeSnapshot(
                identity: identity,
                endpoints: [endpoint]
            )]
        )
        let rpcProbe = ManagedReadinessRPCProbeStub(
            failures: [.transportFailure, nil]
        )
        let checker = makeChecker(
            discovery: discovery,
            processInspector:
                ManagedReadinessProcessInspectorStub(),
            rpcProbe: rpcProbe
        )

        let result = try await checker.waitUntilReady(
            handle: ManagedReadinessProcessHandleStub(
                processID: identity.processID
            ),
            processIdentity: identity,
            deadline: AntigravityRPCDeadline(
                totalTimeout: .seconds(1),
                discoveryTimeout: .seconds(1)
            )
        )

        XCTAssertEqual(result.runtime.endpoint, endpoint)
        XCTAssertEqual(discovery.discoverCallCount(), 2)
        XCTAssertEqual(rpcProbe.callCount(), 2)
    }

    func testPromptEmittedDuringSuccessfulRPCProbePreventsReadiness()
        async throws
    {
        let identity = makeIdentity(processID: 4_109)
        let endpoint = makeEndpoint(identity: identity)
        let handle = ManagedReadinessProcessHandleStub(
            processID: identity.processID
        )
        let rpcProbe = ManagedReadinessRPCProbeStub(
            onProbe: {
                handle.appendOutput(
                    Data("How would you like to sign in?".utf8)
                )
            }
        )
        let checker = makeChecker(
            discovery: ManagedReadinessDiscoveryStub(
                snapshots: [makeSnapshot(
                    identity: identity,
                    endpoints: [endpoint]
                )]
            ),
            processInspector:
                ManagedReadinessProcessInspectorStub(),
            rpcProbe: rpcProbe
        )

        do {
            _ = try await checker.waitUntilReady(
                handle: handle,
                processIdentity: identity,
                deadline: AntigravityRPCDeadline(
                    totalTimeout: .seconds(1),
                    discoveryTimeout: .seconds(1)
                )
            )
            XCTFail("RPC 중 나타난 login prompt를 놓치면 안 됩니다")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(
                error,
                .interactionRequired(.loginRequired)
            )
        }
        XCTAssertEqual(rpcProbe.callCount(), 1)
    }

    func testBlockingPromptFailsBeforeEndpointDiscovery()
        async throws
    {
        let identity = makeIdentity(processID: 4_102)
        let discovery = ManagedReadinessDiscoveryStub(
            snapshots: [makeSnapshot(identity: identity)]
        )
        let handle = ManagedReadinessProcessHandleStub(
            processID: identity.processID,
            output: Data(
                "How would you like to sign in?".utf8
            )
        )
        let checker = makeChecker(
            discovery: discovery,
            processInspector:
                ManagedReadinessProcessInspectorStub()
        )

        do {
            _ = try await checker.waitUntilReady(
                handle: handle,
                processIdentity: identity,
                deadline: AntigravityRPCDeadline(
                    totalTimeout: .seconds(1),
                    discoveryTimeout: .seconds(1)
                )
            )
            XCTFail("Blocking login prompt was accepted")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(
                error,
                .interactionRequired(.loginRequired)
            )
        }
        XCTAssertEqual(discovery.discoverCallCount(), 0)
    }

    func testLatePromptAfterMoreThanRollingWindowIsStillDetected()
        async throws
    {
        let identity = makeIdentity(processID: 4_103)
        let discovery = ManagedReadinessDiscoveryStub(
            snapshots: Array(
                repeating: makeSnapshot(identity: identity),
                count: 8
            )
        )
        var output = Data(
            repeating: Character("x").asciiValue!,
            count: 20 * 1_024
        )
        output.append(
            Data(" Do you trust this project?".utf8)
        )
        let handle = ManagedReadinessProcessHandleStub(
            processID: identity.processID,
            output: output
        )
        let checker = makeChecker(
            discovery: discovery,
            processInspector:
                ManagedReadinessProcessInspectorStub()
        )

        do {
            _ = try await checker.waitUntilReady(
                handle: handle,
                processIdentity: identity,
                deadline: AntigravityRPCDeadline(
                    totalTimeout: .seconds(1),
                    discoveryTimeout: .seconds(1)
                )
            )
            XCTFail("Late project trust prompt was discarded")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(
                error,
                .interactionRequired(.projectTrustRequired)
            )
        }
        XCTAssertGreaterThan(discovery.discoverCallCount(), 1)
    }

    func testTransientSignedOutTextAndOrdinaryURLAreNotPrompts()
        async throws
    {
        let identity = makeIdentity(processID: 4_104)
        let endpoint = makeEndpoint(identity: identity)
        let discovery = ManagedReadinessDiscoveryStub(
            snapshots: [makeSnapshot(
                identity: identity,
                endpoints: [endpoint]
            )]
        )
        let handle = ManagedReadinessProcessHandleStub(
            processID: identity.processID,
            output: Data(
                "You are currently not signed in. Docs: https://example.com"
                    .utf8
            )
        )
        let checker = makeChecker(
            discovery: discovery,
            processInspector:
                ManagedReadinessProcessInspectorStub()
        )

        let result = try await checker.waitUntilReady(
            handle: handle,
            processIdentity: identity,
            deadline: AntigravityRPCDeadline(
                totalTimeout: .seconds(1),
                discoveryTimeout: .seconds(1)
            )
        )

        XCTAssertEqual(result.runtime.endpoint, endpoint)
        XCTAssertTrue(result.diagnostics.interactions.isEmpty)
    }

    func testEndpointForDifferentIdentityIsIgnored()
        async throws
    {
        let identity = makeIdentity(processID: 4_105)
        let other = makeIdentity(processID: 4_106)
        let exactEndpoint = makeEndpoint(identity: identity)
        let discovery = ManagedReadinessDiscoveryStub(
            snapshots: [
                makeSnapshot(
                    identity: other,
                    endpoints: [makeEndpoint(identity: other)]
                ),
                makeSnapshot(
                    identity: identity,
                    endpoints: [exactEndpoint]
                ),
            ]
        )
        let checker = makeChecker(
            discovery: discovery,
            processInspector:
                ManagedReadinessProcessInspectorStub()
        )

        let result = try await checker.waitUntilReady(
            handle: ManagedReadinessProcessHandleStub(
                processID: identity.processID
            ),
            processIdentity: identity,
            deadline: AntigravityRPCDeadline(
                totalTimeout: .seconds(1),
                discoveryTimeout: .seconds(1)
            )
        )

        XCTAssertEqual(result.runtime.endpoint, exactEndpoint)
        XCTAssertEqual(discovery.discoverCallCount(), 2)
    }

    func testEarlyExitNeverBecomesReady() async throws {
        let identity = makeIdentity(processID: 4_107)
        let discovery = ManagedReadinessDiscoveryStub(
            snapshots: [makeSnapshot(identity: identity)]
        )
        let checker = makeChecker(
            discovery: discovery,
            processInspector:
                ManagedReadinessProcessInspectorStub()
        )

        do {
            _ = try await checker.waitUntilReady(
                handle: ManagedReadinessProcessHandleStub(
                    processID: identity.processID,
                    terminationStatus: 17
                ),
                processIdentity: identity,
                deadline: AntigravityRPCDeadline(
                    totalTimeout: .seconds(1),
                    discoveryTimeout: .seconds(1)
                )
            )
            XCTFail("Exited process was accepted")
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(error, .processExited(17))
        }
        XCTAssertEqual(discovery.discoverCallCount(), 0)
    }

    private func makeChecker(
        discovery: ManagedReadinessDiscoveryStub,
        processInspector: ManagedReadinessProcessInspectorStub,
        rpcProbe: ManagedReadinessRPCProbeStub =
            ManagedReadinessRPCProbeStub()
    ) -> AntigravityManagedCLIReadinessChecker {
        AntigravityManagedCLIReadinessChecker(
            discovery: discovery,
            processInspector: processInspector,
            rpcProbe: rpcProbe,
            pollInterval: .zero,
            maximumDrainBytes: 4 * 1_024,
            sleep: { _ in await Task.yield() }
        )
    }

    private func makeSnapshot(
        identity: AntigravityVerifiedProcessIdentity,
        endpoints: [AntigravityVerifiedRuntimeEndpoint] = []
    ) -> AntigravityRuntimeDiscoverySnapshot {
        AntigravityRuntimeDiscoverySnapshot(
            installations: [identity.executable],
            processes: [
                AntigravityRuntimeProcessCandidate(
                    processIdentity: identity,
                    ownership: .managed
                )!
            ],
            endpoints: endpoints,
            observedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeEndpoint(
        identity: AntigravityVerifiedProcessIdentity
    ) -> AntigravityVerifiedRuntimeEndpoint {
        AntigravityVerifiedRuntimeEndpoint(
            processIdentity: identity,
            host: .ipv4,
            port: AntigravityTCPPort(45_321)!,
            transport: .agyCLI,
            ownership: .managed,
            authentication: .cliTokenless
        )!
    }

    private func makeIdentity(
        processID: Int32
    ) -> AntigravityVerifiedProcessIdentity {
        AntigravityVerifiedProcessIdentity(
            processID: processID,
            effectiveUserID: AntigravityUserID(rawValue: 501),
            realUserID: AntigravityUserID(rawValue: 501),
            startedAt: AntigravityProcessStartTime(
                seconds: Int64(processID),
                microseconds: 7
            )!,
            executable: AntigravityCanonicalExecutable(
                canonicalURL: URL(
                    fileURLWithPath: "/usr/local/bin/agy"
                ),
                role: .agyCLI
            )
        )!
    }
}

private final class ManagedReadinessRPCProbeStub:
    AntigravityManagedCLIRPCReadinessProbing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var failures: [AntigravityLocalRPCError?]
    private let onProbe: @Sendable () -> Void
    private var calls = 0

    init(
        failures: [AntigravityLocalRPCError?] = [nil],
        onProbe: @escaping @Sendable () -> Void = {}
    ) {
        precondition(!failures.isEmpty)
        self.failures = failures
        self.onProbe = onProbe
    }

    func probe(
        _ runtime: AntigravityManagedRuntime,
        deadline: AntigravityRPCDeadline
    ) async throws {
        let failure = lock.withLock {
            calls += 1
            guard failures.count > 1 else {
                return failures[0]
            }
            return failures.removeFirst()
        }
        onProbe()
        if let failure {
            throw failure
        }
    }

    func callCount() -> Int {
        lock.withLock { calls }
    }
}

private final class ManagedReadinessDiscoveryStub:
    AntigravityManagedRuntimeDiscovering,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var snapshots:
        [AntigravityRuntimeDiscoverySnapshot]
    private var discoverCalls = 0

    init(
        snapshots: [AntigravityRuntimeDiscoverySnapshot]
    ) {
        self.snapshots = snapshots
    }

    func discover(
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityRuntimeDiscoverySnapshot {
        lock.withLock {
            discoverCalls += 1
            guard snapshots.count > 1 else {
                return snapshots[0]
            }
            return snapshots.removeFirst()
        }
    }

    func invalidateCache() async {}

    func discoverCallCount() -> Int {
        lock.withLock { discoverCalls }
    }
}

private final class ManagedReadinessProcessInspectorStub:
    AntigravityRuntimeProcessInspecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var revalidateCalls = 0

    func discoverProcesses(
        timeout: TimeInterval
    ) async throws -> [AntigravityRuntimeProcessCandidate] {
        XCTFail("Readiness must use shared discovery")
        return []
    }

    func revalidate(
        _ identity: AntigravityVerifiedProcessIdentity
    ) async -> Bool {
        lock.withLock {
            revalidateCalls += 1
            return true
        }
    }

    func revalidateCallCount() -> Int {
        lock.withLock { revalidateCalls }
    }
}

private final class ManagedReadinessProcessHandleStub:
    AntigravityManagedCLIProcessHandling,
    @unchecked Sendable
{
    let processID: Int32
    let processGroupID: Int32

    private let lock = NSLock()
    private var output: Data
    private let recordedTerminationStatus: Int32?

    init(
        processID: Int32,
        output: Data = Data(),
        terminationStatus: Int32? = nil
    ) {
        self.processID = processID
        self.processGroupID = processID
        self.output = output
        self.recordedTerminationStatus = terminationStatus
    }

    func resume() throws {}

    func drainOutput(maximumBytes: Int) -> Data {
        lock.withLock {
            let count = min(maximumBytes, output.count)
            let drained = output.prefix(count)
            output.removeFirst(count)
            return Data(drained)
        }
    }

    func appendOutput(_ data: Data) {
        lock.withLock {
            output.append(data)
        }
    }

    func terminationStatus() -> Int32? {
        recordedTerminationStatus
    }

    func terminateTree(
        gracePeriod: Duration
    ) async -> AntigravityManagedCLIProcessTerminationEvidence {
        .confirmed
    }
}
