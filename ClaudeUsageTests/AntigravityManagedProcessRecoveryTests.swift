import Darwin
import Foundation
import XCTest
@testable import ClaudeUsage

final class AntigravityManagedProcessRecoveryTests:
    XCTestCase
{
    func testExactOrphanReceivesIdentityBoundTermAndKillWithoutGroupSignal()
        async throws
    {
        let record = try makeRecord()
        let store = RecoveryRecordStore(records: [record])
        let processInspector = ScriptedRecoveryProcessInspector(
            processes: [
                record.owner.pid: [.notFound],
                record.child.pid: [
                    .running(record.child),
                    .running(record.child),
                    .notFound,
                ],
            ]
        )
        let treeInspector = ScriptedRecoveryProcessTreeInspector(
            snapshots: [
                completeSnapshot(),
                completeSnapshot(),
                completeSnapshot(),
            ]
        )
        let signaler = RecordingExactProcessSignaler()
        let recovery = makeRecovery(
            store: store,
            processInspector: processInspector,
            treeInspector: treeInspector,
            signaler: signaler
        )

        try await recovery.recoverOrphanedProcesses()

        XCTAssertEqual(
            signaler.signals,
            [
                .init(identity: record.child, signal: SIGTERM),
                .init(identity: record.child, signal: SIGKILL),
            ]
        )
        XCTAssertEqual(
            signaler.signals.map(\.identity),
            [record.child, record.child]
        )
        XCTAssertEqual(
            processInspector.processLookupCount(
                for: record.child.pid
            ),
            3
        )
        XCTAssertEqual(treeInspector.lookupCount, 3)
        XCTAssertEqual(store.records, [])
        XCTAssertEqual(
            store.removedSessionIDs,
            [record.sessionID]
        )
    }

    func testReusedRootPIDIsRemovedAsStaleWithoutAnySignal()
        async throws
    {
        let record = try makeRecord()
        let reusedRoot = try makeIdentity(
            pid: record.child.pid,
            uniqueID:
                record.child.kernelIdentity.uniqueID + 10_000,
            parentUniqueID:
                record.child.kernelIdentity.parentUniqueID,
            pidVersion:
                record.child.kernelIdentity.pidVersion + 1,
            startSeconds:
                record.child.startedAtSeconds + 1,
            executablePath: record.child.executablePath
        )
        let store = RecoveryRecordStore(records: [record])
        let processInspector = ScriptedRecoveryProcessInspector(
            processes: [
                record.child.pid: [.running(reusedRoot)],
            ]
        )
        let treeInspector = ScriptedRecoveryProcessTreeInspector(
            snapshots: [completeSnapshot()]
        )
        let signaler = RecordingExactProcessSignaler()
        let recovery = makeRecovery(
            store: store,
            processInspector: processInspector,
            treeInspector: treeInspector,
            signaler: signaler
        )

        try await recovery.recoverOrphanedProcesses()

        XCTAssertEqual(signaler.signals, [])
        XCTAssertEqual(
            processInspector.processLookupCount(
                for: record.owner.pid
            ),
            0
        )
        XCTAssertEqual(store.records, [])
        XCTAssertEqual(
            store.removedSessionIDs,
            [record.sessionID]
        )
    }

    func testBlockedPreflightDoesNotRemoveOtherStaleRecord()
        async throws
    {
        let staleRecord = try makeRecord()
        let blockedChild = try makeIdentity(
            pid: 4_202,
            uniqueID: 74_202,
            parentUniqueID: 74_101
        )
        let blockedRecord = try makeRecord(
            sessionID: UUID(
                uuidString:
                    "00000000-0000-0000-0000-000000000502"
            )!,
            child: blockedChild
        )
        let reusedRoot = try makeIdentity(
            pid: staleRecord.child.pid,
            uniqueID:
                staleRecord.child.kernelIdentity.uniqueID + 10_000,
            parentUniqueID:
                staleRecord.child.kernelIdentity.parentUniqueID,
            pidVersion:
                staleRecord.child.kernelIdentity.pidVersion + 1,
            startSeconds:
                staleRecord.child.startedAtSeconds + 1,
            executablePath:
                staleRecord.child.executablePath
        )
        let store = RecoveryRecordStore(
            records: [staleRecord, blockedRecord]
        )
        let processInspector = ScriptedRecoveryProcessInspector(
            processes: [
                staleRecord.child.pid: [.running(reusedRoot)],
            ]
        )
        let treeInspector = ScriptedRecoveryProcessTreeInspector(
            snapshots: [
                completeSnapshot(),
                nil,
            ]
        )
        let signaler = RecordingExactProcessSignaler()
        let recovery = makeRecovery(
            store: store,
            processInspector: processInspector,
            treeInspector: treeInspector,
            signaler: signaler
        )

        await assertRecoveryBlocked(recovery)

        XCTAssertEqual(
            Set(store.records.map(\.sessionID)),
            Set([staleRecord.sessionID, blockedRecord.sessionID])
        )
        XCTAssertEqual(store.removedSessionIDs, [])
        XCTAssertEqual(signaler.signals, [])
    }

    func testPersistedDescendantIsRecoveredWhenRootAlreadyExited()
        async throws
    {
        let root = try makeIdentity(
            pid: 4_201,
            uniqueID: 84_201,
            parentUniqueID: 84_101
        )
        let persistedDescendant = try makeIdentity(
            pid: 4_301,
            uniqueID: 84_301,
            parentUniqueID: root.kernelIdentity.uniqueID,
            executablePath: "/usr/bin/ssh"
        )
        let record = try makeRecord(
            child: root,
            observedDescendants: [persistedDescendant],
            observationCompleteness: .complete
        )
        let store = RecoveryRecordStore(records: [record])
        let processInspector = ScriptedRecoveryProcessInspector(
            processes: [
                record.owner.pid: [.notFound],
                root.pid: [.notFound, .notFound, .notFound],
                persistedDescendant.pid: [
                    .running(persistedDescendant),
                    .running(persistedDescendant),
                    .notFound,
                ],
            ]
        )
        let treeInspector = ScriptedRecoveryProcessTreeInspector(
            snapshots: [
                completeSnapshot(),
                completeSnapshot(),
                completeSnapshot(),
            ]
        )
        let signaler = RecordingExactProcessSignaler()
        let recovery = makeRecovery(
            store: store,
            processInspector: processInspector,
            treeInspector: treeInspector,
            signaler: signaler
        )

        try await recovery.recoverOrphanedProcesses()

        XCTAssertEqual(
            signaler.signals,
            [
                .init(
                    identity: persistedDescendant,
                    signal: SIGTERM
                ),
                .init(
                    identity: persistedDescendant,
                    signal: SIGKILL
                ),
            ]
        )
        XCTAssertFalse(
            signaler.signals.contains {
                $0.identity == root
            }
        )
        XCTAssertEqual(store.records, [])
    }

    func testNewlyObservedDescendantIsPersistedAndRecoveredWhenRootIsGone()
        async throws
    {
        let root = try makeIdentity(
            pid: 4_201,
            uniqueID: 94_201,
            parentUniqueID: 94_101
        )
        let newDescendant = try makeIdentity(
            pid: 4_302,
            uniqueID: 94_302,
            parentUniqueID: root.kernelIdentity.uniqueID,
            executablePath: "/bin/sleep"
        )
        let record = try makeRecord(child: root)
        let store = RecoveryRecordStore(records: [record])
        let processInspector = ScriptedRecoveryProcessInspector(
            processes: [
                record.owner.pid: [.notFound],
                root.pid: [.notFound, .notFound, .notFound],
                newDescendant.pid: [
                    .running(newDescendant),
                    .running(newDescendant),
                    .notFound,
                ],
            ]
        )
        let treeInspector = ScriptedRecoveryProcessTreeInspector(
            snapshots: [
                completeSnapshot([newDescendant]),
                completeSnapshot([newDescendant]),
                completeSnapshot([newDescendant]),
            ]
        )
        let signaler = RecordingExactProcessSignaler()
        let recovery = makeRecovery(
            store: store,
            processInspector: processInspector,
            treeInspector: treeInspector,
            signaler: signaler
        )

        try await recovery.recoverOrphanedProcesses()

        let firstSaved = try XCTUnwrap(store.savedRecords.first)
        XCTAssertEqual(
            firstSaved.observedDescendants,
            [newDescendant]
        )
        XCTAssertEqual(
            firstSaved.observationCompleteness,
            .complete
        )
        XCTAssertEqual(
            signaler.signals,
            [
                .init(
                    identity: newDescendant,
                    signal: SIGTERM
                ),
                .init(
                    identity: newDescendant,
                    signal: SIGKILL
                ),
            ]
        )
        XCTAssertEqual(store.records, [])
    }

    func testUnavailableTreeFailsClosedWithoutInspectingOrSignalling()
        async throws
    {
        let record = try makeRecord()
        let store = RecoveryRecordStore(records: [record])
        let processInspector = ScriptedRecoveryProcessInspector(
            processes: [:]
        )
        let treeInspector = ScriptedRecoveryProcessTreeInspector(
            snapshots: [nil]
        )
        let signaler = RecordingExactProcessSignaler()
        let recovery = makeRecovery(
            store: store,
            processInspector: processInspector,
            treeInspector: treeInspector,
            signaler: signaler
        )

        await assertRecoveryBlocked(recovery)

        XCTAssertEqual(signaler.signals, [])
        XCTAssertEqual(processInspector.totalLookupCount, 0)
        XCTAssertEqual(store.records, [record])
        XCTAssertEqual(store.savedRecords, [])
        XCTAssertEqual(store.removedSessionIDs, [])
    }

    func testIncompleteTreeIsPersistedAsStickyAndFailsClosed()
        async throws
    {
        let record = try makeRecord()
        let observedDescendant = try makeIdentity(
            pid: 4_303,
            uniqueID: 104_303,
            parentUniqueID:
                record.child.kernelIdentity.uniqueID
        )
        let store = RecoveryRecordStore(records: [record])
        let processInspector = ScriptedRecoveryProcessInspector(
            processes: [:]
        )
        let treeInspector = ScriptedRecoveryProcessTreeInspector(
            snapshots: [
                .init(
                    descendants: [observedDescendant],
                    isComplete: false
                ),
            ]
        )
        let signaler = RecordingExactProcessSignaler()
        let recovery = makeRecovery(
            store: store,
            processInspector: processInspector,
            treeInspector: treeInspector,
            signaler: signaler
        )

        await assertRecoveryBlocked(recovery)

        XCTAssertEqual(signaler.signals, [])
        XCTAssertEqual(processInspector.totalLookupCount, 0)
        let retained = try XCTUnwrap(store.records.first)
        XCTAssertEqual(
            retained.observedDescendants,
            [observedDescendant]
        )
        XCTAssertEqual(
            retained.observationCompleteness,
            .incomplete
        )
        XCTAssertEqual(store.removedSessionIDs, [])
    }

    func testExactLiveOwnerBlocksRecoveryAfterTargetPreflight()
        async throws
    {
        let record = try makeRecord()
        let store = RecoveryRecordStore(records: [record])
        let processInspector = ScriptedRecoveryProcessInspector(
            processes: [
                record.owner.pid: [.running(record.owner)],
                record.child.pid: [.running(record.child)],
            ]
        )
        let treeInspector = ScriptedRecoveryProcessTreeInspector(
            snapshots: [completeSnapshot()]
        )
        let signaler = RecordingExactProcessSignaler()
        let recovery = makeRecovery(
            store: store,
            processInspector: processInspector,
            treeInspector: treeInspector,
            signaler: signaler
        )

        await assertRecoveryBlocked(recovery)

        XCTAssertEqual(signaler.signals, [])
        XCTAssertEqual(
            processInspector.processLookupCount(
                for: record.child.pid
            ),
            1
        )
        XCTAssertEqual(
            processInspector.processLookupCount(
                for: record.owner.pid
            ),
            1
        )
        XCTAssertEqual(store.removedSessionIDs, [])
    }

    func testUnavailableExactIdentityFailsClosedWithoutSignal()
        async throws
    {
        let record = try makeRecord()
        let store = RecoveryRecordStore(records: [record])
        let processInspector = ScriptedRecoveryProcessInspector(
            processes: [
                record.child.pid: [.unavailable],
            ]
        )
        let treeInspector = ScriptedRecoveryProcessTreeInspector(
            snapshots: [completeSnapshot()]
        )
        let signaler = RecordingExactProcessSignaler()
        let recovery = makeRecovery(
            store: store,
            processInspector: processInspector,
            treeInspector: treeInspector,
            signaler: signaler
        )

        await assertRecoveryBlocked(recovery)

        XCTAssertEqual(signaler.signals, [])
        XCTAssertEqual(
            processInspector.processLookupCount(
                for: record.owner.pid
            ),
            0
        )
        XCTAssertEqual(store.removedSessionIDs, [])
    }

    func testESRCHAtTermSignalIsSafeAndRecoveryCanComplete()
        async throws
    {
        let record = try makeRecord()
        let store = RecoveryRecordStore(records: [record])
        let processInspector = ScriptedRecoveryProcessInspector(
            processes: [
                record.owner.pid: [.notFound],
                record.child.pid: [
                    .running(record.child),
                    .notFound,
                    .notFound,
                ],
            ]
        )
        let treeInspector = ScriptedRecoveryProcessTreeInspector(
            snapshots: [
                completeSnapshot(),
                completeSnapshot(),
                completeSnapshot(),
            ]
        )
        let signaler = RecordingExactProcessSignaler(
            outcomes: [.processNotFound]
        )
        let recovery = makeRecovery(
            store: store,
            processInspector: processInspector,
            treeInspector: treeInspector,
            signaler: signaler
        )

        try await recovery.recoverOrphanedProcesses()

        XCTAssertEqual(
            signaler.signals,
            [
                .init(identity: record.child, signal: SIGTERM),
            ]
        )
        XCTAssertEqual(store.records, [])
        XCTAssertEqual(
            store.removedSessionIDs,
            [record.sessionID]
        )
    }

    func testESRCHAtKillSignalIsSafeAndRecoveryCanComplete()
        async throws
    {
        let record = try makeRecord()
        let store = RecoveryRecordStore(records: [record])
        let processInspector = ScriptedRecoveryProcessInspector(
            processes: [
                record.owner.pid: [.notFound],
                record.child.pid: [
                    .running(record.child),
                    .running(record.child),
                    .notFound,
                ],
            ]
        )
        let treeInspector = ScriptedRecoveryProcessTreeInspector(
            snapshots: [
                completeSnapshot(),
                completeSnapshot(),
                completeSnapshot(),
            ]
        )
        let signaler = RecordingExactProcessSignaler(
            outcomes: [.success, .processNotFound]
        )
        let recovery = makeRecovery(
            store: store,
            processInspector: processInspector,
            treeInspector: treeInspector,
            signaler: signaler
        )

        try await recovery.recoverOrphanedProcesses()

        XCTAssertEqual(
            signaler.signals,
            [
                .init(identity: record.child, signal: SIGTERM),
                .init(identity: record.child, signal: SIGKILL),
            ]
        )
        XCTAssertEqual(store.records, [])
    }

    func testTreeBecomingUnavailableAfterTermKeepsRecordAndSkipsKill()
        async throws
    {
        let record = try makeRecord()
        let store = RecoveryRecordStore(records: [record])
        let processInspector = ScriptedRecoveryProcessInspector(
            processes: [
                record.owner.pid: [.notFound],
                record.child.pid: [.running(record.child)],
            ]
        )
        let treeInspector = ScriptedRecoveryProcessTreeInspector(
            snapshots: [
                completeSnapshot(),
                nil,
            ]
        )
        let signaler = RecordingExactProcessSignaler()
        let recovery = makeRecovery(
            store: store,
            processInspector: processInspector,
            treeInspector: treeInspector,
            signaler: signaler
        )

        await assertRecoveryBlocked(recovery)

        XCTAssertEqual(
            signaler.signals,
            [
                .init(identity: record.child, signal: SIGTERM),
            ]
        )
        XCTAssertEqual(store.removedSessionIDs, [])
        XCTAssertEqual(store.records.count, 1)
    }

    func testRootExecIdentityIsPersistedAndSignalledExactly()
        async throws
    {
        let record = try makeRecord()
        let execedRoot = try makeIdentity(
            pid: record.child.pid,
            uniqueID: record.child.kernelIdentity.uniqueID,
            parentUniqueID:
                record.child.kernelIdentity.parentUniqueID,
            pidVersion:
                record.child.kernelIdentity.pidVersion + 1,
            startSeconds: record.child.startedAtSeconds,
            executablePath: "/usr/bin/node"
        )
        let store = RecoveryRecordStore(records: [record])
        let processInspector = ScriptedRecoveryProcessInspector(
            processes: [
                record.owner.pid: [.notFound],
                record.child.pid: [
                    .running(execedRoot),
                    .running(execedRoot),
                    .notFound,
                ],
            ]
        )
        let treeInspector = ScriptedRecoveryProcessTreeInspector(
            snapshots: [
                completeSnapshot(rootExecution: execedRoot),
                completeSnapshot(rootExecution: execedRoot),
                completeSnapshot(rootExecution: execedRoot),
            ]
        )
        let signaler = RecordingExactProcessSignaler()
        let recovery = makeRecovery(
            store: store,
            processInspector: processInspector,
            treeInspector: treeInspector,
            signaler: signaler
        )

        try await recovery.recoverOrphanedProcesses()

        XCTAssertEqual(
            store.savedRecords.first?.child,
            execedRoot
        )
        XCTAssertEqual(
            signaler.signals,
            [
                .init(identity: execedRoot, signal: SIGTERM),
                .init(identity: execedRoot, signal: SIGKILL),
            ]
        )
        XCTAssertEqual(store.records, [])
    }

    func testRecoverySignalsPersistedTreeDeepestFirst()
        async throws
    {
        let root = try makeIdentity(
            pid: 4_501,
            uniqueID: 84_501,
            parentUniqueID: 84_401
        )
        let parent = try makeIdentity(
            pid: 4_502,
            uniqueID: 84_502,
            parentUniqueID: root.kernelIdentity.uniqueID
        )
        let leaf = try makeIdentity(
            pid: 4_503,
            uniqueID: 84_503,
            parentUniqueID: parent.kernelIdentity.uniqueID
        )
        let record = try makeRecord(
            child: root,
            observedDescendants: [parent, leaf],
            observationCompleteness: .complete
        )
        let store = RecoveryRecordStore(records: [record])
        let processInspector = ScriptedRecoveryProcessInspector(
            processes: [
                record.owner.pid: [.notFound],
                root.pid: [
                    .running(root),
                    .running(root),
                    .notFound,
                ],
                parent.pid: [
                    .running(parent),
                    .running(parent),
                    .notFound,
                ],
                leaf.pid: [
                    .running(leaf),
                    .running(leaf),
                    .notFound,
                ],
            ]
        )
        let treeInspector = ScriptedRecoveryProcessTreeInspector(
            snapshots: [
                completeSnapshot(),
                completeSnapshot(),
                completeSnapshot(),
            ]
        )
        let signaler = RecordingExactProcessSignaler()
        let recovery = makeRecovery(
            store: store,
            processInspector: processInspector,
            treeInspector: treeInspector,
            signaler: signaler
        )

        try await recovery.recoverOrphanedProcesses()

        XCTAssertEqual(
            signaler.signals,
            [
                .init(identity: leaf, signal: SIGTERM),
                .init(identity: parent, signal: SIGTERM),
                .init(identity: root, signal: SIGTERM),
                .init(identity: leaf, signal: SIGKILL),
                .init(identity: parent, signal: SIGKILL),
                .init(identity: root, signal: SIGKILL),
            ]
        )
        XCTAssertEqual(store.records, [])
    }

    private func makeRecovery(
        store: RecoveryRecordStore,
        processInspector: ScriptedRecoveryProcessInspector,
        treeInspector: ScriptedRecoveryProcessTreeInspector,
        signaler: RecordingExactProcessSignaler
    ) -> AntigravityManagedProcessRecovery {
        AntigravityManagedProcessRecovery(
            recordStore: store,
            processInspector: processInspector,
            processTreeInspector: treeInspector,
            signaler: signaler,
            terminationGracePeriod: .zero,
            killObservationDelay: .zero,
            now: {
                Date(timeIntervalSince1970: 1_800_000_300)
            },
            sleep: { _ in }
        )
    }

    private func assertRecoveryBlocked(
        _ recovery: AntigravityManagedProcessRecovery,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await recovery.recoverOrphanedProcesses()
            XCTFail(
                "Expected recovery to fail closed",
                file: file,
                line: line
            )
        } catch let error as AntigravityManagedSessionError {
            XCTAssertEqual(
                error,
                .recordRecoveryBlocked,
                file: file,
                line: line
            )
        } catch {
            XCTFail(
                "Unexpected error: \(error)",
                file: file,
                line: line
            )
        }
    }

    private func completeSnapshot(
        rootExecution:
            AntigravityRecordedProcessIdentity? = nil,
        _ descendants: [AntigravityRecordedProcessIdentity] = []
    ) -> AntigravityManagedProcessTreeSnapshot {
        .init(
            rootExecution: rootExecution,
            descendants: descendants,
            isComplete: true
        )
    }

    private func makeRecord(
        sessionID: UUID = UUID(
            uuidString:
                "00000000-0000-0000-0000-000000000501"
        )!,
        child: AntigravityRecordedProcessIdentity? = nil,
        observedDescendants:
            [AntigravityRecordedProcessIdentity] = [],
        observationCompleteness:
            AntigravityManagedProcessObservationCompleteness =
                .rootOnly
    ) throws -> AntigravityManagedProcessRecord {
        let resolvedChild = try child ?? makeIdentity(
            pid: 4_201,
            uniqueID: 74_201,
            parentUniqueID: 74_101,
            executablePath: "/Users/test/.local/bin/agy"
        )
        let owner = try makeIdentity(
            pid: 4_101,
            uniqueID: 74_101,
            parentUniqueID: 74_001,
            executablePath:
                "/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage"
        )
        return try XCTUnwrap(
            AntigravityManagedProcessRecord(
                sessionID: sessionID,
                bootSessionID: AntigravityBootSessionID(
                    rawValue: UUID(
                        uuidString:
                            "00000000-0000-0000-0000-000000000601"
                    )!
                ),
                child: resolvedChild,
                processGroupID: resolvedChild.pid,
                owner: owner,
                observedDescendants: observedDescendants,
                observationCompleteness:
                    observationCompleteness,
                createdAt: Date(
                    timeIntervalSince1970: 1_800_000_200
                )
            )
        )
    }

    private func makeIdentity(
        pid: Int32,
        uniqueID: UInt64,
        parentUniqueID: UInt64,
        pidVersion: Int32? = nil,
        startSeconds: Int64? = nil,
        executablePath: String =
            "/Users/test/.local/bin/agy"
    ) throws -> AntigravityRecordedProcessIdentity {
        let kernelIdentity = try XCTUnwrap(
            AntigravityKernelProcessIdentity(
                uniqueID: uniqueID,
                parentUniqueID: parentUniqueID,
                pidVersion: pidVersion ?? pid + 10_000
            )
        )
        return try XCTUnwrap(
            AntigravityRecordedProcessIdentity(
                pid: pid,
                effectiveUserID: 501,
                realUserID: 501,
                startedAtSeconds:
                    startSeconds
                    ?? (1_800_000_000 + Int64(pid)),
                startedAtMicroseconds: 123,
                executablePath: executablePath,
                kernelIdentity: kernelIdentity
            )
        )
    }
}

private nonisolated final class RecoveryRecordStore:
    AntigravityManagedProcessRecordStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedRecords: [AntigravityManagedProcessRecord]
    private var saves: [AntigravityManagedProcessRecord] = []
    private var removals: [UUID] = []

    init(records: [AntigravityManagedProcessRecord]) {
        self.storedRecords = records
    }

    var records: [AntigravityManagedProcessRecord] {
        lock.withLock { storedRecords }
    }

    var savedRecords: [AntigravityManagedProcessRecord] {
        lock.withLock { saves }
    }

    var removedSessionIDs: [UUID] {
        lock.withLock { removals }
    }

    nonisolated func load()
        throws -> [AntigravityManagedProcessRecord] {
        lock.withLock { storedRecords }
    }

    nonisolated func update(
        _ record: AntigravityManagedProcessRecord
    ) throws {
        lock.withLock {
            storedRecords.removeAll {
                $0.sessionID == record.sessionID
            }
            storedRecords.append(record)
            saves.append(record)
        }
    }

    nonisolated func remove(sessionID: UUID) throws {
        lock.withLock {
            storedRecords.removeAll {
                $0.sessionID == sessionID
            }
            removals.append(sessionID)
        }
    }
}

private nonisolated final class ScriptedRecoveryProcessInspector:
    AntigravityRecordedProcessInspecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var processScripts:
        [Int32: [AntigravityRecordedProcessLookup]]
    private var processCounts: [Int32: Int] = [:]

    init(
        processes:
            [Int32: [AntigravityRecordedProcessLookup]]
    ) {
        self.processScripts = processes
    }

    var totalLookupCount: Int {
        lock.withLock {
            processCounts.values.reduce(0, +)
        }
    }

    nonisolated func process(
        for processID: Int32
    ) -> AntigravityRecordedProcessLookup {
        lock.withLock {
            processCounts[processID, default: 0] += 1
            guard var values = processScripts[processID],
                  !values.isEmpty else {
                return .unavailable
            }
            let value = values.removeFirst()
            processScripts[processID] = values
            return value
        }
    }

    func processLookupCount(for processID: Int32) -> Int {
        lock.withLock {
            processCounts[processID, default: 0]
        }
    }
}

private nonisolated final class ScriptedRecoveryProcessTreeInspector:
    AntigravityManagedProcessTreeInspecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var scriptedSnapshots:
        [AntigravityManagedProcessTreeSnapshot?]
    private var count = 0

    init(
        snapshots: [AntigravityManagedProcessTreeSnapshot?]
    ) {
        self.scriptedSnapshots = snapshots
    }

    var lookupCount: Int {
        lock.withLock { count }
    }

    nonisolated func snapshot(
        for record: AntigravityManagedProcessRecord
    ) -> AntigravityManagedProcessTreeSnapshot? {
        lock.withLock {
            count += 1
            guard !scriptedSnapshots.isEmpty else {
                return nil
            }
            return scriptedSnapshots.removeFirst()
        }
    }
}

private nonisolated final class RecordingExactProcessSignaler:
    AntigravityExactProcessSignaling,
    @unchecked Sendable
{
    nonisolated struct Signal: Sendable, Equatable {
        let identity: AntigravityRecordedProcessIdentity
        let signal: Int32
    }

    nonisolated enum Outcome: Sendable {
        case success
        case processNotFound
        case posix(Int32)
    }

    private let lock = NSLock()
    private var recordedSignals: [Signal] = []
    private var scriptedOutcomes: [Outcome]

    init(outcomes: [Outcome] = []) {
        self.scriptedOutcomes = outcomes
    }

    var signals: [Signal] {
        lock.withLock { recordedSignals }
    }

    nonisolated func signal(
        _ identity: AntigravityRecordedProcessIdentity,
        signal: Int32
    ) throws {
        let outcome = lock.withLock {
            recordedSignals.append(
                Signal(
                    identity: identity,
                    signal: signal
                )
            )
            guard !scriptedOutcomes.isEmpty else {
                return Outcome.success
            }
            return scriptedOutcomes.removeFirst()
        }

        switch outcome {
        case .success:
            return
        case .processNotFound:
            throw AntigravityExactProcessSignalError
                .processNotFound
        case .posix(let status):
            throw AntigravityExactProcessSignalError
                .posix(status)
        }
    }
}
