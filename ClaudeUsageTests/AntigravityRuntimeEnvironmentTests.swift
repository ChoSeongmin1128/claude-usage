import Foundation
import XCTest
@testable import ClaudeUsage

final class AntigravityRuntimeEnvironmentTests: XCTestCase {
    func testLegacyCleanupRunsWithoutBuildingTheGraph() async throws {
        let fixture = EnvironmentFixture()
        let environment = fixture.environment()

        await environment.cleanUpLegacyManagedProcesses()

        let cleanups = await fixture.cleanups
        let builds = await fixture.builds
        XCTAssertEqual(cleanups, 1)
        XCTAssertEqual(builds, 0)
        await environment.shutdown()
    }

    func testLegacyCleanupDoesNotRunAfterShutdown() async throws {
        let fixture = EnvironmentFixture()
        let environment = fixture.environment()
        await environment.shutdown()

        await environment.cleanUpLegacyManagedProcesses()

        let cleanups = await fixture.cleanups
        XCTAssertEqual(cleanups, 0)
    }

    func testUnchangedFilesReuseTheGraphWithoutRevalidation() async throws {
        let fixture = EnvironmentFixture()
        let environment = fixture.environment()
        let first = try await Self.sourceGeneration(environment)
        let second = try await Self.sourceGeneration(environment)
        let builds = await fixture.builds
        XCTAssertEqual(builds, 1)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1)
        await environment.shutdown()
    }

    func testChangedFilesPublishSourcesFromTheNewGraph() async throws {
        let fixture = EnvironmentFixture()
        let environment = fixture.environment()
        let before = try await Self.sourceGeneration(environment)
        await fixture.change()
        let after = try await Self.sourceGeneration(environment)
        XCTAssertEqual(before, 1)
        XCTAssertEqual(after, 2)
        await environment.shutdown()
    }

    func testInstallAfterStartupAndRemovalDoNotRequireRestart() async throws {
        let fixture = EnvironmentFixture(status: .notFound)
        let environment = fixture.environment()
        let failure_executableMissing = try await runtimeFailure(environment)
        XCTAssertEqual(failure_executableMissing, .executableMissing)
        await fixture.change(status: .verified(displayPath: "test-agy"))
        let installed = try await runtimeFailure(environment)
        XCTAssertNil(installed)
        let availability = await environment.managedAvailability()
        XCTAssertEqual(availability, .available(displayPath: "test-agy"))
        await fixture.change(status: .notFound)
        let removedFailure = try await runtimeFailure(environment)
        XCTAssertEqual(removedFailure, .executableMissing)
        await environment.shutdown()
    }

    func testRejectedFileIsNeverExposedAsRunnableAndCanRecover() async throws {
        let fixture = EnvironmentFixture(status: .rejected)
        let environment = fixture.environment()
        let failure_verificationRejected = try await runtimeFailure(environment)
        XCTAssertEqual(failure_verificationRejected, .verificationRejected)
        await fixture.change(status: .verified(displayPath: "test-agy"))
        let verified = try await runtimeFailure(environment)
        XCTAssertNil(verified)
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
        let discarded = await environment.managedAvailability()
        XCTAssertEqual(discarded, .unavailable(reason: .executableNotFound))
        await fixture.setMutationDuringBuild(false)
        let generation = try await Self.sourceGeneration(environment)
        let builds = await fixture.builds
        XCTAssertEqual(builds, 2)
        XCTAssertEqual(generation, 2)
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
        let second = Task { try await Self.sourceGeneration(environment) }
        // The first lease owns generation 1 until its operation completes.
        let before = await fixture.builds
        XCTAssertEqual(before, 1)
        await gate.release()
        _ = try await first.value
        let generation = try await second.value
        let after = await fixture.builds
        XCTAssertEqual(after, 2)
        XCTAssertEqual(generation, 2)
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
        let waiter = Task { try await Self.sourceGeneration(environment) }
        waiter.cancel()
        do { _ = try await waiter.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let builds = await fixture.builds
        XCTAssertEqual(builds, 1)
        await gate.release()
        _ = try await first.value
        _ = try await Self.sourceGeneration(environment)
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
        let availability = await environment.managedAvailability()
        XCTAssertEqual(availability, .unavailable(reason: .executableNotFound))
    }

    func testForceDiscoveryInvalidatesWithoutRebuilding() async throws {
        let fixture = EnvironmentFixture()
        let environment = fixture.environment()
        _ = try await Self.sourceGeneration(environment)
        _ = try await environment.withSources(forceDiscovery: true, deadline: .init()) { _ in true }
        let count = fixture.discovery.invalidations
        let builds = await fixture.builds
        XCTAssertEqual(count, 1)
        XCTAssertEqual(builds, 1)
        await environment.shutdown()
    }

    func testShutdownWaitsForTheActiveLease() async throws {
        let fixture = EnvironmentFixture()
        let environment = fixture.environment()
        let gate = EnvironmentTestGate()
        let lease = Task {
            try await environment.withSources(forceDiscovery: false, deadline: .init()) { _ in
                await gate.enterAndWait()
                return 1
            }
        }
        await gate.waitForEntry()
        let shutdownFinished = EnvironmentFlag()
        let shutdown = Task {
            await environment.shutdown()
            await shutdownFinished.set()
        }
        try await Task.sleep(for: .milliseconds(50))
        let finishedEarly = await shutdownFinished.value
        XCTAssertFalse(finishedEarly, "Shutdown must wait for the report in flight")

        await gate.release()
        _ = try await lease.value
        await shutdown.value
        let finished = await shutdownFinished.value
        XCTAssertTrue(finished)
    }

    private static func sourceGeneration(_ environment: AntigravityRuntimeEnvironment) async throws -> Int? {
        try await environment.withSources(forceDiscovery: false, deadline: .init()) { sources in
            (sources.first { $0.id == .cliReport } as? EnvironmentReportSource)?.generation
        }
    }

    private func runtimeFailure(_ environment: AntigravityRuntimeEnvironment) async throws -> AntigravityRuntimeFailure? {
        try await environment.withSources(forceDiscovery: false, deadline: .init()) { sources in
            guard let source = sources.first(where: { $0.id == .cliReport }) else { return nil }
            let request = AntigravityUsageSourceRequest(generation: 1, deadline: .init())
            do { _ = try await source.fetch(request); return nil }
            catch AntigravityUsageSourceError.runtimeUnavailable(let reason) { return reason }
            catch { return nil }
        }
    }
}

private actor EnvironmentFixture {
    var revision = 1
    var builds = 0
    var cleanups = 0
    var status: AntigravityAGYExecutableDiscoveryStatus
    var mutateDuringBuild = false
    let discovery = EnvironmentDiscovery()

    init(status: AntigravityAGYExecutableDiscoveryStatus = .verified(displayPath: "test-agy")) { self.status = status }
    nonisolated func environment() -> AntigravityRuntimeEnvironment {
        AntigravityRuntimeEnvironment(
            fingerprint: { await self.fingerprint() },
            build: { await self.build() },
            legacyCleanup: { await self.recordCleanup() }
        )
    }
    func fingerprint() -> AntigravityInstallationFingerprint { .init(entries: [String(revision)]) }
    func change(status: AntigravityAGYExecutableDiscoveryStatus? = nil) { revision += 1; if let status { self.status = status } }
    func setMutationDuringBuild(_ value: Bool) { mutateDuringBuild = value }
    func recordCleanup() { cleanups += 1 }
    func build() -> AntigravityLocalRuntimeGeneration {
        builds += 1
        if mutateDuringBuild { revision += 1 }
        let sources: [any AntigravityUsageSource] =
            if case .verified = status { [EnvironmentReportSource(generation: builds)] } else { [] }
        return .init(sources: sources, discovery: discovery, executableStatus: status)
    }
}

private struct EnvironmentReportSource: AntigravityUsageSource {
    let id = AntigravityUsageSourceID.cliReport
    let generation: Int

    func fetch(_ request: AntigravityUsageSourceRequest) async throws -> AntigravityUsageSourceResponse {
        throw AntigravityUsageSourceError.unavailable
    }
}

private nonisolated final class EnvironmentDiscovery: AntigravityRuntimeDiscovering, @unchecked Sendable {
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

private actor EnvironmentFlag {
    private(set) var value = false
    func set() { value = true }
}
