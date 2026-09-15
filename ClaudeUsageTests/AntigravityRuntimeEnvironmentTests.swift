import Foundation
import XCTest
@testable import ClaudeUsage

final class AntigravityRuntimeEnvironmentTests: XCTestCase {
    func testBootstrapReconcilesOwnershipEvenWithoutAUsageRefresh() async throws {
        let fixture = EnvironmentFixture()
        let environment = fixture.environment()
        try await environment.recoverOrphanedProcesses()
        let events = await fixture.events
        XCTAssertEqual(events, ["recover:1"])
        let availability = await environment.managedAvailability()
        XCTAssertEqual(availability, .available(displayPath: "test-agy"))
        await environment.shutdown()
    }

    func testUnchangedFilesReuseTheGraphWithoutRevalidation() async throws {
        let fixture = EnvironmentFixture()
        let environment = fixture.environment()
        _ = try await Self.read(environment)
        _ = try await Self.read(environment)
        let builds = await fixture.builds
        XCTAssertEqual(builds, 1)
        await environment.shutdown()
    }

    func testReplacementRetiresOldSessionBeforeNewRecovery() async throws {
        let fixture = EnvironmentFixture()
        let environment = fixture.environment()
        _ = try await Self.read(environment)
        await fixture.change()
        _ = try await Self.read(environment)
        let events = await fixture.events
        XCTAssertEqual(events, ["recover:1", "shutdown:1", "recover:2"])
        await environment.shutdown()
    }

    func testInstallAfterStartupAndRemovalDoNotRequireRestart() async throws {
        let fixture = EnvironmentFixture(status: .notFound)
        let environment = fixture.environment()
        let failure_executableMissing = try await runtimeFailure(environment)
        XCTAssertEqual(failure_executableMissing, .executableMissing)
        await fixture.change(status: .verified(displayPath: "test-agy"))
        _ = try await Self.read(environment)
        let availability = await environment.managedAvailability()
        XCTAssertEqual(availability, .available(displayPath: "test-agy"))
        await fixture.change(status: .notFound)
        let removedFailure = try await runtimeFailure(environment)
        XCTAssertEqual(removedFailure, .executableMissing)
        await environment.shutdown()
    }

    func testRejectedFileIsNeverExposedAsLaunchableAndCanRecover() async throws {
        let fixture = EnvironmentFixture(status: .rejected)
        let environment = fixture.environment()
        let failure_verificationRejected = try await runtimeFailure(environment)
        XCTAssertEqual(failure_verificationRejected, .verificationRejected)
        await fixture.change(status: .verified(displayPath: "test-agy"))
        _ = try await Self.read(environment)
        let availability = await environment.managedAvailability()
        XCTAssertEqual(availability, .available(displayPath: "test-agy"))
        await environment.shutdown()
    }

    func testMutationDuringValidationDiscardsCandidate() async throws {
        let fixture = EnvironmentFixture()
        await fixture.setMutationDuringBuild(true)
        let environment = fixture.environment()
        let failure_executableChanged = try await runtimeFailure(environment)
        XCTAssertEqual(failure_executableChanged, .executableChanged)
        let events = await fixture.events
        XCTAssertEqual(events, [])
        await fixture.setMutationDuringBuild(false)
        _ = try await Self.read(environment)
        let builds = await fixture.builds
        XCTAssertEqual(builds, 2)
        await environment.shutdown()
    }

    func testUnconfirmedRecoveryBlocksOnlyManagedSourceAndRetries() async throws {
        let fixture = EnvironmentFixture()
        await fixture.setRecoveryFailure(true)
        let environment = fixture.environment()
        let failure_recoveryBlocked = try await runtimeFailure(environment)
        XCTAssertEqual(failure_recoveryBlocked, .recoveryBlocked)
        await fixture.setRecoveryFailure(false)
        _ = try await Self.read(environment)
        let builds = await fixture.builds
        XCTAssertEqual(builds, 1)
        let availability = await environment.managedAvailability()
        XCTAssertEqual(availability, .available(displayPath: "test-agy"))
        await environment.shutdown()
    }

    func testReplacementWaitsForActiveLease() async throws {
        let fixture = EnvironmentFixture()
        let environment = fixture.environment()
        let gate = EnvironmentTestGate()
        let first = Task {
            try await environment.withSources(forceDiscovery: false, deadline: .init()) { _ in
                await gate.enterAndWait()
                return 1
            }
        }
        await gate.waitForEntry()
        await fixture.change()
        let second = Task { try await Self.read(environment) }
        // The first lease owns generation 1 until its operation completes.
        let before = await fixture.events
        XCTAssertEqual(before, ["recover:1"])
        await gate.release()
        _ = try await first.value
        _ = try await second.value
        let after = await fixture.events
        XCTAssertEqual(after, ["recover:1", "shutdown:1", "recover:2"])
        await environment.shutdown()
    }

    func testCancelledWaiterDoesNotReplaceOrReleaseAnotherLease() async throws {
        let fixture = EnvironmentFixture()
        let environment = fixture.environment()
        let gate = EnvironmentTestGate()
        let first = Task {
            try await environment.withSources(forceDiscovery: false, deadline: .init()) { _ in
                await gate.enterAndWait()
                return 1
            }
        }
        await gate.waitForEntry()
        let waiter = Task { try await Self.read(environment) }
        waiter.cancel()
        do { _ = try await waiter.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let builds = await fixture.builds
        XCTAssertEqual(builds, 1)
        await gate.release()
        _ = try await first.value
        _ = try await Self.read(environment)
        await environment.shutdown()
    }

    func testSlowReadOnlyValidationTimesOutWithoutPublishingLateResult() async throws {
        let fixture = EnvironmentFixture()
        let gate = EnvironmentTestGate()
        let environment = AntigravityRuntimeEnvironment(
            fingerprint: { await fixture.fingerprint() },
            build: { await gate.enterAndWait(); return await fixture.build() }
        )
        let attempt = Task {
            try await environment.withSources(forceDiscovery: false,
                deadline: .init(totalTimeout: .milliseconds(40))) { _ in true }
        }
        await gate.waitForEntry()
        do { _ = try await attempt.value; XCTFail("Expected timeout") } catch is AntigravityRPCDeadlineError {}
        await gate.release()
        await environment.shutdown()
        let events = await fixture.events
        XCTAssertTrue(events.isEmpty)
    }

    func testForceDiscoveryInvalidatesWithoutRebuilding() async throws {
        let fixture = EnvironmentFixture()
        let environment = fixture.environment()
        _ = try await Self.read(environment)
        _ = try await environment.withSources(forceDiscovery: true, deadline: .init()) { _ in true }
        let count = fixture.discovery.invalidations
        let builds = await fixture.builds
        XCTAssertEqual(count, 1)
        XCTAssertEqual(builds, 1)
        await environment.shutdown()
    }

    private static func read(_ environment: AntigravityRuntimeEnvironment) async throws -> Int {
        try await environment.withSources(forceDiscovery: false, deadline: .init()) { $0.count }
    }

    private func runtimeFailure(_ environment: AntigravityRuntimeEnvironment) async throws -> AntigravityRuntimeFailure? {
        try await environment.withSources(forceDiscovery: false, deadline: .init()) { sources in
            guard let source = sources.first(where: { $0.id == .managedCLI }) else { return nil }
            let request = AntigravityUsageSourceRequest(generation: 1, accountTarget: .ambientLocal,
                expectedIdentity: nil, oauthAuthorization: nil, managedLaunchAuthorization: .disabled, deadline: .init())
            do { _ = try await source.fetch(request); return nil }
            catch AntigravityUsageSourceError.runtimeUnavailable(let reason) { return reason }
            catch { return nil }
        }
    }
}

private actor EnvironmentFixture {
    var revision = 1
    var builds = 0
    var events: [String] = []
    var status: AntigravityAGYExecutableDiscoveryStatus
    var mutateDuringBuild = false
    var failRecovery = false
    let discovery = EnvironmentDiscovery()

    init(status: AntigravityAGYExecutableDiscoveryStatus = .verified(displayPath: "test-agy")) { self.status = status }
    nonisolated func environment() -> AntigravityRuntimeEnvironment {
        AntigravityRuntimeEnvironment(fingerprint: { await self.fingerprint() }, build: { await self.build() })
    }
    func fingerprint() -> AntigravityInstallationFingerprint { .init(entries: [String(revision)]) }
    func change(status: AntigravityAGYExecutableDiscoveryStatus? = nil) { revision += 1; if let status { self.status = status } }
    func setMutationDuringBuild(_ value: Bool) { mutateDuringBuild = value }
    func setRecoveryFailure(_ value: Bool) { failRecovery = value }
    func event(_ value: String) { events.append(value) }
    func recovery(_ id: Int) throws {
        events.append("recover:\(id)")
        if failRecovery { throw AntigravityRuntimeFailure.recoveryBlocked }
    }
    func build() -> AntigravityLocalRuntimeGeneration {
        builds += 1
        if mutateDuringBuild { revision += 1 }
        return .init(sources: [], discovery: discovery, session: EnvironmentSession(id: builds, fixture: self), executableStatus: status)
    }
}

private struct EnvironmentSession: AntigravityManagedSessionLifecycling {
    let id: Int
    let fixture: EnvironmentFixture
    func recoverOrphanedProcesses() async throws { try await fixture.recovery(id) }
    func shutdown() async { await fixture.event("shutdown:\(id)") }
}

private nonisolated final class EnvironmentDiscovery: AntigravityManagedRuntimeDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var invalidations: Int { lock.withLock { count } }
    func invalidateCache() async { lock.withLock { count += 1 } }
    func discover(deadline: AntigravityRPCDeadline) async throws -> AntigravityRuntimeDiscoverySnapshot {
        .init(installations: [], processes: [], endpoints: [], observedAt: Date())
    }
}

private actor EnvironmentTestGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func enterAndWait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForEntry() async { while !entered { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
