import Darwin
import Foundation
import XCTest
@testable import ClaudeUsage

final class AntigravityManagedRuntimeCompositionTests:
    XCTestCase
{
    func testManagedSessionAndDiscoveryShareLiveOwnershipGraph()
        async throws
    {
        let processID: Int32 = 8_125
        let executableURL = URL(
            fileURLWithPath: "/opt/homebrew/bin/agy"
        )
        let fileSystem = ManagedCompositionCatalogFileSystemStub(
            executableURL: executableURL
        )
        let catalog = AntigravityExecutableCatalog(
            appBundleRoots: [],
            agyExecutableURLs: [executableURL],
            fileSystem: fileSystem
        )
        let executable = try XCTUnwrap(
            catalog.executables.first
        )
        let processInfo = AntigravityBSDProcessInfo(
            processID: processID,
            effectiveUserID:
                AntigravityUserID(rawValue: geteuid()),
            realUserID:
                AntigravityUserID(rawValue: getuid()),
            startedAt: AntigravityProcessStartTime(
                seconds: 1_700_000_000,
                microseconds: 125
            )!
        )
        let processIdentity = try XCTUnwrap(
            AntigravityVerifiedProcessIdentity(
                processID: processID,
                effectiveUserID: processInfo.effectiveUserID,
                realUserID: processInfo.realUserID,
                startedAt: processInfo.startedAt,
                executable: executable
            )
        )
        let libprocReader =
            ManagedCompositionLibprocReaderStub(
                processInfos: [
                    processID: processInfo,
                ],
                executableURLs: [
                    processID: executableURL,
                ]
            )
        let subprocessRunner =
            ManagedCompositionSubprocessRunnerStub(
                output:
                    "\(processID) \(executableURL.path) --https_server_port=54321"
            )
        let portInspector =
            ManagedCompositionPortInspectorStub(
                processID: processID,
                port: AntigravityTCPPort(54_321)!
            )
        let processHandle =
            ManagedCompositionProcessHandleStub(
                processID: processID
            )
        let launcher =
            ManagedCompositionLauncherStub(
                handle: processHandle
            )
        let identityProvider =
            ManagedCompositionIdentityProviderStub(
                child: try XCTUnwrap(
                    AntigravityRecordedProcessIdentity(
                        pid: processIdentity.processID,
                        effectiveUserID:
                            processIdentity
                                .effectiveUserID.rawValue,
                        realUserID:
                            processIdentity.realUserID.rawValue,
                        startedAtSeconds:
                            processIdentity.startedAt.seconds,
                        startedAtMicroseconds:
                            processIdentity.startedAt.microseconds,
                        executablePath:
                            processIdentity.executable
                                .canonicalURL.path,
                        kernelIdentity:
                            AntigravityKernelProcessIdentity(
                                uniqueID:
                                    UInt64(processID) + 10_000,
                                parentUniqueID:
                                    UInt64(Int32(getpid()))
                                    + 10_000,
                                pidVersion: processID + 100
                            )!
                    )
                ),
                owner: try XCTUnwrap(
                    AntigravityRecordedProcessIdentity(
                        pid: Int32(getpid()),
                        effectiveUserID: geteuid(),
                        realUserID: getuid(),
                        startedAtSeconds: 1_600_000_000,
                        startedAtMicroseconds: 1,
                        executablePath:
                            "/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage",
                        kernelIdentity:
                            ManagedCompositionKernelIdentity
                                .make(
                                    processID: Int32(getpid())
                                )
                    )
                )
            )
        let recordStore =
            ManagedCompositionRecordStoreStub()
        let launchCoordinator =
            ManagedCompositionLaunchCoordinatorStub()
        let readinessProbe =
            ManagedCompositionReadinessProbeStub()
        let processTreeTerminator =
            ManagedCompositionProcessTreeTerminatorStub(
                recordStore: recordStore
            )

        let composition =
            AntigravityManagedRuntimeCompositionFactory.make(
                catalog: catalog,
                dependencies:
                    AntigravityManagedRuntimeCompositionDependencies(
                        subprocessRunner: subprocessRunner,
                        libprocReader: libprocReader,
                        kernelIdentityReader:
                            ManagedCompositionKernelIdentityReaderStub(),
                        runningExecutableImageValidator:
                            ManagedCompositionRunningImageValidatorStub(),
                        runningCodeTrustValidator:
                            ManagedCompositionRunningCodeTrustValidatorStub(),
                        portInspector: portInspector,
                        launcher: launcher,
                        identityProviderOverride:
                            identityProvider,
                        recordStore: recordStore,
                        launchCoordinator: launchCoordinator,
                        recoverySignaler:
                            ManagedCompositionRecoverySignalerStub(),
                        bootSessionProvider:
                            ManagedCompositionBootSessionProviderStub(),
                        launchIntentInspectorOverride:
                            ManagedCompositionLaunchIntentInspectorStub(),
                        processTreeControllerOverride:
                            processTreeTerminator,
                        readinessProbe: readinessProbe
                    ),
                environment: AntigravityManagedCLIEnvironment(
                    homeDirectory: URL(
                        fileURLWithPath: "/Users/test"
                    ),
                    userName: "test"
                ),
                currentDirectoryURL: URL(
                    fileURLWithPath: "/tmp"
                )
            )

        let managedSnapshot = try await
            composition.managedSession.withRuntime(
                authorization: .automatic(
                    idleTimeout: .seconds(5)
                ),
                executable: executable,
                deadline: AntigravityRPCDeadline()
            ) { runtime in
                XCTAssertEqual(
                    runtime.endpoint.ownership,
                    .managed
                )
                return try await composition.discovery.discover()
            }

        XCTAssertEqual(
            managedSnapshot.processes.first?.ownership,
            .managed
        )
        XCTAssertEqual(
            managedSnapshot.endpoints.first?.ownership,
            .managed
        )
        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertEqual(readinessProbe.callCount, 1)
        XCTAssertEqual(recordStore.saveCount, 1)
        XCTAssertGreaterThanOrEqual(recordStore.loadCount, 1)

        await composition.managedSession.shutdown()
        await composition.discovery.invalidateCache()
        let borrowedSnapshot =
            try await composition.discovery.discover()

        XCTAssertEqual(
            borrowedSnapshot.processes.first?.ownership,
            .borrowed
        )
        XCTAssertEqual(
            borrowedSnapshot.endpoints.first?.ownership,
            .borrowed
        )
        XCTAssertFalse(
            borrowedSnapshot.endpoints.contains {
                $0.ownership == .managed
            }
        )
        XCTAssertEqual(processHandle.terminationCount, 1)
        XCTAssertEqual(processTreeTerminator.callCount, 1)
        XCTAssertEqual(recordStore.removeCount, 1)
        let finalOwnership =
            await composition.ownershipRegistry.ownership(
                for: processIdentity
            )
        XCTAssertEqual(
            finalOwnership,
            .borrowed
        )
    }
}

private enum ManagedCompositionKernelIdentity {
    static func make(
        processID: Int32
    ) -> AntigravityKernelProcessIdentity {
        AntigravityKernelProcessIdentity(
            uniqueID: UInt64(processID) + 10_000,
            parentUniqueID: 9_999,
            pidVersion: processID + 100
        )!
    }
}

private struct ManagedCompositionKernelIdentityReaderStub:
    AntigravityKernelProcessIdentityReading
{
    func kernelIdentity(
        for processID: Int32
    ) -> AntigravityKernelProcessIdentity? {
        ManagedCompositionKernelIdentity.make(
            processID: processID
        )
    }
}

private struct ManagedCompositionRunningImageValidatorStub:
    AntigravityRunningExecutableImageValidating
{
    func validatesRunningImage(
        processID: Int32,
        executable: AntigravityCanonicalExecutable
    ) -> Bool {
        true
    }
}

private struct ManagedCompositionRunningCodeTrustValidatorStub:
    AntigravityRunningCodeTrustValidating
{
    func validatesRunningCode(
        processID: Int32,
        executable: AntigravityCanonicalExecutable
    ) -> Bool {
        true
    }
}

private final class ManagedCompositionCatalogFileSystemStub:
    AntigravityExecutableCatalogFileSystem,
    @unchecked Sendable
{
    private let executableURL: URL

    init(executableURL: URL) {
        self.executableURL = executableURL.standardizedFileURL
    }

    func canonicalURL(for url: URL) -> URL {
        url.standardizedFileURL
    }

    func isExecutableRegularFile(at url: URL) -> Bool {
        url.standardizedFileURL == executableURL
    }

    func bundleIdentifier(at appBundleRoot: URL) -> String? {
        nil
    }
}

private final class ManagedCompositionLibprocReaderStub:
    AntigravityLibprocReading,
    @unchecked Sendable
{
    private let processInfos:
        [Int32: AntigravityBSDProcessInfo]
    private let executableURLs: [Int32: URL]

    init(
        processInfos: [Int32: AntigravityBSDProcessInfo],
        executableURLs: [Int32: URL]
    ) {
        self.processInfos = processInfos
        self.executableURLs = executableURLs
    }

    func bsdInfo(
        for processID: Int32
    ) -> AntigravityBSDProcessInfo? {
        processInfos[processID]
    }

    func executableURL(for processID: Int32) -> URL? {
        executableURLs[processID]
    }
}

private final class ManagedCompositionSubprocessRunnerStub:
    AntigravityOwnedSubprocessRunning,
    @unchecked Sendable
{
    private let output: Data

    init(output: String) {
        self.output = Data(output.utf8)
    }

    func run(
        _ request: AntigravityOwnedSubprocessRequest
    ) async throws -> AntigravityOwnedSubprocessResult {
        AntigravityOwnedSubprocessResult(
            standardOutput: output,
            standardError: Data(),
            terminationStatus: 0
        )
    }
}

private final class ManagedCompositionPortInspectorStub:
    AntigravityPortOwnershipInspecting,
    @unchecked Sendable
{
    private let processID: Int32
    private let endpoint: AntigravityOwnedListeningEndpoint

    init(processID: Int32, port: AntigravityTCPPort) {
        self.processID = processID
        self.endpoint = AntigravityOwnedListeningEndpoint(
            host: .ipv4,
            port: port
        )
    }

    func listeningEndpoints(
        ownedBy processIDs: Set<Int32>,
        timeout: TimeInterval
    ) async throws
        -> [Int32: Set<AntigravityOwnedListeningEndpoint>]
    {
        guard processIDs.contains(processID) else {
            return [:]
        }
        return [processID: [endpoint]]
    }
}

private final class ManagedCompositionProcessHandleStub:
    AntigravityManagedCLIProcessHandling,
    @unchecked Sendable
{
    let processID: Int32
    let processGroupID: Int32

    private let lock = NSLock()
    private var recordedTerminationCount = 0

    init(processID: Int32) {
        self.processID = processID
        self.processGroupID = processID
    }

    var terminationCount: Int {
        lock.withLock { recordedTerminationCount }
    }

    func resume() throws {}

    func drainOutput(maximumBytes: Int) -> Data {
        Data()
    }

    func terminationStatus() -> Int32? {
        nil
    }

    func terminateTree(
        gracePeriod: Duration
    ) async -> AntigravityManagedCLIProcessTerminationEvidence {
        lock.withLock {
            recordedTerminationCount += 1
        }
        return .confirmed
    }
}

private final class ManagedCompositionLauncherStub:
    AntigravityManagedCLIProcessLaunching,
    @unchecked Sendable
{
    private let handle: ManagedCompositionProcessHandleStub
    private let lock = NSLock()
    private var recordedLaunchCount = 0

    init(handle: ManagedCompositionProcessHandleStub) {
        self.handle = handle
    }

    var launchCount: Int {
        lock.withLock { recordedLaunchCount }
    }

    func launchSuspended(
        _ request: AntigravityManagedCLIProcessLaunchRequest
    ) throws -> any AntigravityManagedCLIProcessHandling {
        lock.withLock {
            recordedLaunchCount += 1
        }
        return handle
    }
}

private final class ManagedCompositionIdentityProviderStub:
    AntigravityManagedProcessIdentityProviding,
    @unchecked Sendable
{
    private let child: AntigravityRecordedProcessIdentity
    private let owner: AntigravityRecordedProcessIdentity

    init(
        child: AntigravityRecordedProcessIdentity,
        owner: AntigravityRecordedProcessIdentity
    ) {
        self.child = child
        self.owner = owner
    }

    func identity(
        for processID: Int32
    ) -> AntigravityRecordedProcessIdentity? {
        switch processID {
        case child.pid:
            child
        case owner.pid:
            owner
        default:
            nil
        }
    }

    func processGroupID(for processID: Int32) -> Int32? {
        processID == child.pid ? child.pid : nil
    }
}

private final class ManagedCompositionRecordStoreStub:
    AntigravityManagedProcessLedgerStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var records:
        [UUID: AntigravityManagedProcessRecord] = [:]
    private var intents:
        [UUID: AntigravityManagedLaunchIntent] = [:]
    private var recordedLoadCount = 0
    private var recordedSaveCount = 0
    private var recordedRemoveCount = 0

    var loadCount: Int {
        lock.withLock { recordedLoadCount }
    }

    var saveCount: Int {
        lock.withLock { recordedSaveCount }
    }

    var removeCount: Int {
        lock.withLock { recordedRemoveCount }
    }

    func load() throws -> [AntigravityManagedProcessRecord] {
        lock.withLock {
            recordedLoadCount += 1
            return Array(records.values)
        }
    }

    func loadLedger() throws
        -> AntigravityManagedProcessLedgerSnapshot
    {
        lock.withLock {
            recordedLoadCount += 1
            let entries =
                intents.values.map {
                    AntigravityManagedProcessLedgerEntry
                        .launchIntent($0)
                }
                + records.values.map {
                    AntigravityManagedProcessLedgerEntry
                        .processRecord($0)
                }
            return AntigravityManagedProcessLedgerSnapshot(
                bootSessionID: entries.first?.bootSessionID,
                revision: UInt64(recordedSaveCount),
                entries: entries
            )
        }
    }

    func createIntent(
        _ intent: AntigravityManagedLaunchIntent
    ) throws {
        lock.withLock {
            intents[intent.sessionID] = intent
        }
    }

    func promoteIntent(
        _ intent: AntigravityManagedLaunchIntent,
        to record: AntigravityManagedProcessRecord
    ) throws {
        lock.withLock {
            intents.removeValue(forKey: intent.sessionID)
            recordedSaveCount += 1
            records[record.sessionID] = record
        }
    }

    func update(
        _ record: AntigravityManagedProcessRecord
    ) throws {
        lock.withLock {
            recordedSaveCount += 1
            records[record.sessionID] = record
        }
    }

    func remove(sessionID: UUID) throws {
        lock.withLock {
            recordedRemoveCount += 1
            records.removeValue(forKey: sessionID)
        }
    }

    func removeIntent(
        _ intent: AntigravityManagedLaunchIntent
    ) throws {
        lock.withLock {
            _ = intents.removeValue(forKey: intent.sessionID)
        }
    }

    func removeEntriesFromStaleBoot(
        _ bootSessionID: AntigravityBootSessionID
    ) throws {
        lock.withLock {
            intents.removeAll()
            records.removeAll()
        }
    }
}

private struct ManagedCompositionBootSessionProviderStub:
    AntigravityBootSessionIdentityProviding
{
    func currentBootSessionID() -> AntigravityBootSessionID? {
        AntigravityBootSessionID(
            rawValue: UUID(
                uuidString:
                    "00000000-0000-0000-0000-000000000601"
            )!
        )
    }
}

private struct ManagedCompositionLaunchIntentInspectorStub:
    AntigravityManagedLaunchIntentInspecting
{
    func ownerState(
        for owner: AntigravityRecordedProcessIdentity
    ) -> AntigravityManagedLaunchIntentOwnerState {
        .gone
    }

    func candidates(
        ownedBy owner: AntigravityRecordedProcessIdentity,
        executable: AntigravityManagedExecutableDescriptor
    ) -> AntigravityManagedLaunchCandidateInspection {
        .none
    }
}

private final class ManagedCompositionLaunchCoordinatorStub:
    AntigravityManagedLaunchCoordinating,
    @unchecked Sendable
{
    nonisolated func withExclusiveLaunch<T: Sendable>(
        _ operation:
            nonisolated(nonsending)
            @Sendable () async throws -> T
    ) async throws -> T {
        try await operation()
    }
}

private final class ManagedCompositionRecoverySignalerStub:
    AntigravityExactProcessSignaling,
    @unchecked Sendable
{
    func signal(
        _ identity: AntigravityRecordedProcessIdentity,
        signal: Int32
    ) throws {
        XCTFail("Empty recovery store must not signal a process")
    }
}

private final class ManagedCompositionProcessTreeTerminatorStub:
    AntigravityManagedProcessTreeControlling,
    @unchecked Sendable
{
    private let recordStore:
        ManagedCompositionRecordStoreStub
    private let lock = NSLock()
    private var recordedCallCount = 0

    init(
        recordStore: ManagedCompositionRecordStoreStub
    ) {
        self.recordStore = recordStore
    }

    var callCount: Int {
        lock.withLock { recordedCallCount }
    }

    func observe(
        sessionID: UUID
    ) async -> AntigravityManagedProcessObservationResult {
        .complete
    }

    func terminate(
        sessionID: UUID,
        handle: any AntigravityManagedCLIProcessHandling,
        gracePeriod: Duration
    ) async -> AntigravityManagedProcessCleanupResult {
        lock.withLock {
            recordedCallCount += 1
        }
        _ = await handle.terminateTree(
            gracePeriod: gracePeriod
        )
        do {
            try recordStore.remove(
                sessionID: sessionID
            )
            return .complete
        } catch {
            return .recordRemovalFailed
        }
    }
}

private final class ManagedCompositionReadinessProbeStub:
    AntigravityManagedCLIRPCReadinessProbing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedCallCount = 0

    var callCount: Int {
        lock.withLock { recordedCallCount }
    }

    func probe(
        _ runtime: AntigravityManagedRuntime,
        deadline: AntigravityRPCDeadline
    ) async throws {
        lock.withLock {
            recordedCallCount += 1
        }
    }
}
