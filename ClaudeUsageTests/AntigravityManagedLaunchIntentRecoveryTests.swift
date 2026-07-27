import Foundation
import XCTest
@testable import ClaudeUsage

final class AntigravityManagedLaunchIntentRecoveryTests:
    XCTestCase
{
    func testStaleBootRemovesLedgerWithoutInspectionOrRecordRecovery()
        async throws
    {
        let fixture = try makeFixture()
        let events = IntentRecoveryEventRecorder()
        let store = IntentRecoveryLedgerStore(
            snapshot: makeSnapshot(
                bootSessionID: fixture.staleBoot,
                entries: [.launchIntent(fixture.intent)]
            ),
            events: events
        )
        let inspector = ScriptedLaunchIntentInspector(
            ownerStates: [.gone],
            candidateInspections: [.none]
        )
        let recordRecovery = RecordingIntentRecordRecovery(
            events: events
        )
        let recovery = makeRecovery(
            store: store,
            boot: fixture.currentBoot,
            inspector: inspector,
            recordRecovery: recordRecovery
        )

        try await recovery.recoverOrphanedProcesses()

        XCTAssertEqual(
            store.staleBootRemovals,
            [fixture.staleBoot]
        )
        XCTAssertEqual(store.snapshot.entries, [])
        XCTAssertEqual(inspector.ownerStateCallCount, 0)
        XCTAssertEqual(inspector.candidateCallCount, 0)
        XCTAssertEqual(recordRecovery.callCount, 0)
        XCTAssertEqual(events.values, [.removeStaleBoot])
    }

    func testUnavailableBootIdentityBlocksBeforeLedgerReadOrMutation()
        async throws
    {
        let fixture = try makeFixture()
        let events = IntentRecoveryEventRecorder()
        let store = IntentRecoveryLedgerStore(
            snapshot: makeSnapshot(
                bootSessionID: fixture.currentBoot,
                entries: [.launchIntent(fixture.intent)]
            ),
            events: events
        )
        let inspector = ScriptedLaunchIntentInspector(
            ownerStates: [.gone],
            candidateInspections: [.none]
        )
        let recordRecovery = RecordingIntentRecordRecovery(
            events: events
        )
        let recovery = AntigravityManagedSessionLifecycleRecovery(
            ledgerStore: store,
            bootSessionProvider:
                ScriptedBootSessionProvider(values: [nil]),
            intentInspector: inspector,
            recordRecovery: recordRecovery
        )

        await assertRecoveryBlocked {
            try await recovery.recoverOrphanedProcesses()
        }

        XCTAssertEqual(store.loadLedgerCallCount, 0)
        XCTAssertEqual(store.mutationCount, 0)
        XCTAssertEqual(inspector.ownerStateCallCount, 0)
        XCTAssertEqual(recordRecovery.callCount, 0)
        XCTAssertEqual(events.values, [])
    }

    func testLiveOwnerBlocksWithoutCandidateInspectionOrMutation()
        async throws
    {
        let fixture = try makeFixture()
        let events = IntentRecoveryEventRecorder()
        let store = IntentRecoveryLedgerStore(
            snapshot: makeSnapshot(
                bootSessionID: fixture.currentBoot,
                entries: [.launchIntent(fixture.intent)]
            ),
            events: events
        )
        let inspector = ScriptedLaunchIntentInspector(
            ownerStates: [.live],
            candidateInspections: [.none]
        )
        let recordRecovery = RecordingIntentRecordRecovery(
            events: events
        )
        let recovery = makeRecovery(
            store: store,
            boot: fixture.currentBoot,
            inspector: inspector,
            recordRecovery: recordRecovery
        )

        await assertRecoveryBlocked {
            try await recovery.recoverOrphanedProcesses()
        }

        XCTAssertEqual(inspector.ownerStateCallCount, 1)
        XCTAssertEqual(inspector.candidateCallCount, 0)
        XCTAssertEqual(store.mutationCount, 0)
        XCTAssertEqual(recordRecovery.callCount, 0)
        XCTAssertEqual(
            store.snapshot.launchIntents,
            [fixture.intent]
        )
    }

    func testPrepareForLaunchRemovesExactCurrentOwnerIntentWhenNoChildExists()
        async throws
    {
        let fixture = try makeFixture()
        let events = IntentRecoveryEventRecorder()
        let store = IntentRecoveryLedgerStore(
            snapshot: makeSnapshot(
                bootSessionID: fixture.currentBoot,
                entries: [.launchIntent(fixture.intent)]
            ),
            events: events
        )
        let inspector = ScriptedLaunchIntentInspector(
            ownerStates: [.live],
            candidateInspections: [.none, .none]
        )
        let recordRecovery = RecordingIntentRecordRecovery(
            events: events
        )
        let recovery = makeRecovery(
            store: store,
            boot: fixture.currentBoot,
            inspector: inspector,
            recordRecovery: recordRecovery
        )

        let boot = try await recovery.prepareForLaunch(
            owner: fixture.owner,
            executable: fixture.executable
        )

        XCTAssertEqual(boot, fixture.currentBoot)
        XCTAssertEqual(store.snapshot.entries, [])
        XCTAssertEqual(store.removedIntents, [fixture.intent])
        XCTAssertEqual(inspector.ownerStateCallCount, 1)
        XCTAssertEqual(inspector.candidateCallCount, 2)
        XCTAssertEqual(recordRecovery.callCount, 1)
    }

    func testGoneOwnerWithoutCandidateRemovesIntentBeforeRecordRecovery()
        async throws
    {
        let fixture = try makeFixture()
        let events = IntentRecoveryEventRecorder()
        let store = IntentRecoveryLedgerStore(
            snapshot: makeSnapshot(
                bootSessionID: fixture.currentBoot,
                entries: [.launchIntent(fixture.intent)]
            ),
            events: events
        )
        let inspector = ScriptedLaunchIntentInspector(
            ownerStates: [.gone],
            candidateInspections: [.none]
        )
        let recordRecovery = RecordingIntentRecordRecovery(
            events: events
        )
        let recovery = makeRecovery(
            store: store,
            boot: fixture.currentBoot,
            inspector: inspector,
            recordRecovery: recordRecovery
        )

        try await recovery.recoverOrphanedProcesses()

        XCTAssertEqual(store.snapshot.entries, [])
        XCTAssertEqual(
            store.removedIntents,
            [fixture.intent]
        )
        XCTAssertEqual(store.promotions, [])
        XCTAssertEqual(recordRecovery.callCount, 1)
        XCTAssertEqual(
            events.values,
            [.removeIntent, .recordRecovery]
        )
    }

    func testGoneOwnerWithUniqueCandidatePromotesAtomicallyBeforeRecordRecovery()
        async throws
    {
        let fixture = try makeFixture()
        let events = IntentRecoveryEventRecorder()
        let store = IntentRecoveryLedgerStore(
            snapshot: makeSnapshot(
                bootSessionID: fixture.currentBoot,
                entries: [.launchIntent(fixture.intent)]
            ),
            events: events
        )
        let inspector = ScriptedLaunchIntentInspector(
            ownerStates: [.gone],
            candidateInspections: [.unique(fixture.child)]
        )
        let recordRecovery = RecordingIntentRecordRecovery(
            events: events
        )
        let recovery = makeRecovery(
            store: store,
            boot: fixture.currentBoot,
            inspector: inspector,
            recordRecovery: recordRecovery
        )

        try await recovery.recoverOrphanedProcesses()

        let promotion = try XCTUnwrap(store.promotions.first)
        XCTAssertEqual(promotion.intent, fixture.intent)
        XCTAssertEqual(promotion.record.sessionID, fixture.intent.sessionID)
        XCTAssertEqual(
            promotion.record.bootSessionID,
            fixture.currentBoot
        )
        XCTAssertEqual(promotion.record.owner, fixture.owner)
        XCTAssertEqual(promotion.record.child, fixture.child)
        XCTAssertEqual(
            promotion.record.processGroupID,
            fixture.child.pid
        )
        XCTAssertEqual(
            store.snapshot.processRecords,
            [promotion.record]
        )
        XCTAssertEqual(store.snapshot.launchIntents, [])
        XCTAssertEqual(recordRecovery.callCount, 1)
        XCTAssertEqual(
            events.values,
            [.promoteIntent, .recordRecovery]
        )
    }

    func testMultipleOrUnavailableCandidateBlocksWithoutMutation()
        async throws
    {
        let fixture = try makeFixture()

        for candidate in [
            AntigravityManagedLaunchCandidateInspection.multiple,
            .unavailable,
        ] {
            let events = IntentRecoveryEventRecorder()
            let store = IntentRecoveryLedgerStore(
                snapshot: makeSnapshot(
                    bootSessionID: fixture.currentBoot,
                    entries: [.launchIntent(fixture.intent)]
                ),
                events: events
            )
            let inspector = ScriptedLaunchIntentInspector(
                ownerStates: [.gone],
                candidateInspections: [candidate]
            )
            let recordRecovery = RecordingIntentRecordRecovery(
                events: events
            )
            let recovery = makeRecovery(
                store: store,
                boot: fixture.currentBoot,
                inspector: inspector,
                recordRecovery: recordRecovery
            )

            await assertRecoveryBlocked {
                try await recovery.recoverOrphanedProcesses()
            }

            XCTAssertEqual(store.mutationCount, 0)
            XCTAssertEqual(
                store.snapshot.launchIntents,
                [fixture.intent]
            )
            XCTAssertEqual(recordRecovery.callCount, 0)
            XCTAssertEqual(events.values, [])
        }
    }

    func testUnavailableLaterIntentBlocksWholeBatchBeforeMutation()
        async throws
    {
        let first = try makeFixture(
            sessionID: UUID(
                uuidString:
                    "00000000-0000-0000-0000-000000000701"
            )!,
            ownerPID: 4_101,
            ownerUniqueID: 74_101,
            childPID: 4_201,
            childUniqueID: 74_201
        )
        let second = try makeFixture(
            sessionID: UUID(
                uuidString:
                    "00000000-0000-0000-0000-000000000702"
            )!,
            ownerPID: 4_102,
            ownerUniqueID: 74_102,
            childPID: 4_202,
            childUniqueID: 74_202
        )
        let events = IntentRecoveryEventRecorder()
        let store = IntentRecoveryLedgerStore(
            snapshot: makeSnapshot(
                bootSessionID: first.currentBoot,
                entries: [
                    .launchIntent(first.intent),
                    .launchIntent(second.intent),
                ]
            ),
            events: events
        )
        let inspector = ScriptedLaunchIntentInspector(
            ownerStates: [.gone, .gone],
            candidateInspections: [.none, .unavailable]
        )
        let recordRecovery = RecordingIntentRecordRecovery(
            events: events
        )
        let recovery = makeRecovery(
            store: store,
            boot: first.currentBoot,
            inspector: inspector,
            recordRecovery: recordRecovery
        )

        await assertRecoveryBlocked {
            try await recovery.recoverOrphanedProcesses()
        }

        XCTAssertEqual(store.mutationCount, 0)
        XCTAssertEqual(
            store.snapshot.launchIntents,
            [first.intent, second.intent]
        )
        XCTAssertEqual(recordRecovery.callCount, 0)
        XCTAssertEqual(events.values, [])
    }

    func testPrepareForLaunchReturnsBootOnlyWhenCandidateScanIsEmpty()
        async throws
    {
        let fixture = try makeFixture()
        let events = IntentRecoveryEventRecorder()
        let store = IntentRecoveryLedgerStore(
            snapshot: .empty,
            events: events
        )
        let inspector = ScriptedLaunchIntentInspector(
            ownerStates: [],
            candidateInspections: [.none]
        )
        let recordRecovery = RecordingIntentRecordRecovery(
            events: events
        )
        let recovery = makeRecovery(
            store: store,
            boot: fixture.currentBoot,
            inspector: inspector,
            recordRecovery: recordRecovery
        )

        let boot = try await recovery.prepareForLaunch(
            owner: fixture.owner,
            executable: fixture.executable
        )

        XCTAssertEqual(boot, fixture.currentBoot)
        XCTAssertEqual(inspector.candidateCallCount, 1)
        XCTAssertEqual(recordRecovery.callCount, 1)
        XCTAssertEqual(events.values, [.recordRecovery])
    }

    func testPrepareForLaunchBlocksWhenCandidateAlreadyExists()
        async throws
    {
        let fixture = try makeFixture()
        let events = IntentRecoveryEventRecorder()
        let store = IntentRecoveryLedgerStore(
            snapshot: .empty,
            events: events
        )
        let inspector = ScriptedLaunchIntentInspector(
            ownerStates: [],
            candidateInspections: [.unique(fixture.child)]
        )
        let recordRecovery = RecordingIntentRecordRecovery(
            events: events
        )
        let recovery = makeRecovery(
            store: store,
            boot: fixture.currentBoot,
            inspector: inspector,
            recordRecovery: recordRecovery
        )

        await assertRecoveryBlocked {
            _ = try await recovery.prepareForLaunch(
                owner: fixture.owner,
                executable: fixture.executable
            )
        }

        XCTAssertEqual(store.mutationCount, 0)
        XCTAssertEqual(inspector.candidateCallCount, 1)
        XCTAssertEqual(recordRecovery.callCount, 1)
        XCTAssertEqual(events.values, [.recordRecovery])
    }

    func testSystemInspectorAcceptsOnlyExactLineageUIDPathAndPGID()
        throws
    {
        let fixture = try makeFixture()
        let inspector = makeSystemInspector(
            processIDs: [fixture.child.pid],
            kernelIdentities: [
                fixture.child.pid:
                    fixture.child.kernelIdentity,
            ],
            identities: [fixture.child.pid: fixture.child],
            processGroups: [fixture.child.pid: fixture.child.pid],
            existence: [fixture.child.pid: .present]
        )

        XCTAssertEqual(
            inspector.candidates(
                ownedBy: fixture.owner,
                executable: fixture.executable
            ),
            .unique(fixture.child)
        )

        let wrongLineage = try makeIdentity(
            pid: fixture.child.pid,
            uniqueID: fixture.child.kernelIdentity.uniqueID,
            parentUniqueID:
                fixture.owner.kernelIdentity.uniqueID + 1,
            path: fixture.child.executablePath
        )
        XCTAssertEqual(
            makeSystemInspector(
                processIDs: [wrongLineage.pid],
                kernelIdentities: [
                    wrongLineage.pid:
                        wrongLineage.kernelIdentity,
                ],
                identities: [wrongLineage.pid: wrongLineage],
                processGroups: [wrongLineage.pid: wrongLineage.pid],
                existence: [wrongLineage.pid: .present]
            ).candidates(
                ownedBy: fixture.owner,
                executable: fixture.executable
            ),
            .none
        )

        let wrongUID = try makeIdentity(
            pid: fixture.child.pid,
            uniqueID: fixture.child.kernelIdentity.uniqueID,
            parentUniqueID:
                fixture.owner.kernelIdentity.uniqueID,
            effectiveUserID: 502,
            realUserID: 502,
            path: fixture.child.executablePath
        )
        let wrongUIDInspector = makeSystemInspector(
                processIDs: [wrongUID.pid],
                kernelIdentities: [
                    wrongUID.pid: wrongUID.kernelIdentity,
                ],
                identities: [wrongUID.pid: wrongUID],
                processGroups: [wrongUID.pid: wrongUID.pid],
                existence: [wrongUID.pid: .present]
            )
        let wrongPathInspector = makeSystemInspector(
                processIDs: [fixture.child.pid],
                kernelIdentities: [
                    fixture.child.pid:
                        fixture.child.kernelIdentity,
                ],
                identities: [
                    fixture.child.pid: try makeIdentity(
                        pid: fixture.child.pid,
                        uniqueID:
                            fixture.child.kernelIdentity.uniqueID,
                        parentUniqueID:
                            fixture.owner.kernelIdentity.uniqueID,
                        path: "/Users/test/.local/bin/not-agy"
                    ),
                ],
                processGroups: [
                    fixture.child.pid: fixture.child.pid,
                ],
                existence: [fixture.child.pid: .present]
            )
        let wrongGroupInspector = makeSystemInspector(
                processIDs: [fixture.child.pid],
                kernelIdentities: [
                    fixture.child.pid:
                        fixture.child.kernelIdentity,
                ],
                identities: [fixture.child.pid: fixture.child],
                processGroups: [
                    fixture.child.pid: fixture.child.pid + 1,
                ],
                existence: [fixture.child.pid: .present]
            )
        for inspector in [
            wrongUIDInspector,
            wrongPathInspector,
        ] {
            XCTAssertEqual(
                inspector.candidates(
                    ownedBy: fixture.owner,
                    executable: fixture.executable
                ),
                .none
            )
        }
        XCTAssertEqual(
            wrongGroupInspector.candidates(
                ownedBy: fixture.owner,
                executable: fixture.executable
            ),
            .unavailable
        )
    }

    func testSystemInspectorReportsMultipleAndUnreadableScansAsAmbiguous()
        throws
    {
        let fixture = try makeFixture()
        let secondChild = try makeIdentity(
            pid: fixture.child.pid + 1,
            uniqueID:
                fixture.child.kernelIdentity.uniqueID + 1,
            parentUniqueID:
                fixture.owner.kernelIdentity.uniqueID,
            path: fixture.child.executablePath
        )
        let multiple = makeSystemInspector(
            processIDs: [fixture.child.pid, secondChild.pid],
            kernelIdentities: [
                fixture.child.pid:
                    fixture.child.kernelIdentity,
                secondChild.pid:
                    secondChild.kernelIdentity,
            ],
            identities: [
                fixture.child.pid: fixture.child,
                secondChild.pid: secondChild,
            ],
            processGroups: [
                fixture.child.pid: fixture.child.pid,
                secondChild.pid: secondChild.pid,
            ],
            existence: [
                fixture.child.pid: .present,
                secondChild.pid: .present,
            ]
        )
        XCTAssertEqual(
            multiple.candidates(
                ownedBy: fixture.owner,
                executable: fixture.executable
            ),
            .multiple
        )

        let unreadablePID = secondChild.pid + 1
        let unreadable = makeSystemInspector(
            processIDs: [fixture.child.pid, unreadablePID],
            kernelIdentities: [
                fixture.child.pid:
                    fixture.child.kernelIdentity,
            ],
            identities: [fixture.child.pid: fixture.child],
            processGroups: [fixture.child.pid: fixture.child.pid],
            existence: [
                fixture.child.pid: .present,
                unreadablePID: .present,
            ]
        )
        XCTAssertEqual(
            unreadable.candidates(
                ownedBy: fixture.owner,
                executable: fixture.executable
            ),
            .unavailable
        )

        let terminated = makeSystemInspector(
            processIDs: [unreadablePID],
            kernelIdentities: [:],
            identities: [:],
            processGroups: [:],
            existence: [unreadablePID: .terminated]
        )
        XCTAssertEqual(
            terminated.candidates(
                ownedBy: fixture.owner,
                executable: fixture.executable
            ),
            .none
        )
    }

    func testOpaqueProcessTableStateExcludesImpossibleCandidatesButFailsClosedForPossibleOne()
        throws
    {
        let fixture = try makeFixture()
        let opaquePID = fixture.child.pid + 100
        let impossibleStates = [
            try XCTUnwrap(
                AntigravityProcessTableState(
                    processID: opaquePID,
                    parentProcessID: fixture.owner.pid,
                    processGroupID: opaquePID,
                    effectiveUserID: 502,
                    realUserID: 502,
                    startedAtSeconds:
                        fixture.owner.startedAtSeconds + 1,
                    startedAtMicroseconds: 0,
                    isZombie: false
                )
            ),
            try XCTUnwrap(
                AntigravityProcessTableState(
                    processID: opaquePID,
                    parentProcessID: fixture.owner.pid,
                    processGroupID: opaquePID + 1,
                    effectiveUserID:
                        fixture.owner.effectiveUserID,
                    realUserID: fixture.owner.realUserID,
                    startedAtSeconds:
                        fixture.owner.startedAtSeconds + 1,
                    startedAtMicroseconds: 0,
                    isZombie: false
                )
            ),
            try XCTUnwrap(
                AntigravityProcessTableState(
                    processID: opaquePID,
                    parentProcessID: fixture.owner.pid,
                    processGroupID: opaquePID,
                    effectiveUserID:
                        fixture.owner.effectiveUserID,
                    realUserID: fixture.owner.realUserID,
                    startedAtSeconds:
                        fixture.owner.startedAtSeconds - 1,
                    startedAtMicroseconds: 0,
                    isZombie: false
                )
            ),
            try XCTUnwrap(
                AntigravityProcessTableState(
                    processID: opaquePID,
                    parentProcessID: fixture.owner.pid,
                    processGroupID: opaquePID,
                    effectiveUserID:
                        fixture.owner.effectiveUserID,
                    realUserID: fixture.owner.realUserID,
                    startedAtSeconds:
                        fixture.owner.startedAtSeconds + 1,
                    startedAtMicroseconds: 0,
                    isZombie: true
                )
            ),
        ]

        for state in impossibleStates {
            XCTAssertEqual(
                makeSystemInspector(
                    processIDs: [opaquePID],
                    kernelIdentities: [:],
                    identities: [:],
                    processGroups: [:],
                    existence: [opaquePID: .present],
                    processTableStates: [opaquePID: state]
                ).candidates(
                    ownedBy: fixture.owner,
                    executable: fixture.executable
                ),
                .none
            )
        }

        let possibleState = try XCTUnwrap(
            AntigravityProcessTableState(
                processID: opaquePID,
                parentProcessID: fixture.owner.pid,
                processGroupID: opaquePID,
                effectiveUserID:
                    fixture.owner.effectiveUserID,
                realUserID: fixture.owner.realUserID,
                startedAtSeconds:
                    fixture.owner.startedAtSeconds,
                startedAtMicroseconds:
                    fixture.owner.startedAtMicroseconds,
                isZombie: false
            )
        )
        XCTAssertEqual(
            makeSystemInspector(
                processIDs: [opaquePID],
                kernelIdentities: [:],
                identities: [:],
                processGroups: [:],
                existence: [opaquePID: .present],
                processTableStates: [
                    opaquePID: possibleState,
                ]
            ).candidates(
                ownedBy: fixture.owner,
                executable: fixture.executable
            ),
            .unavailable
        )
    }

    func testSystemInspectorCompletesAgainstCurrentProductionProcessTable()
        throws
    {
        let identityProvider =
            AntigravityManagedProcessIdentityProvider()
        let owner = try XCTUnwrap(
            identityProvider.identity(
                for: Int32(getpid())
            )
        )
        let executable = try XCTUnwrap(
            AntigravityManagedExecutableDescriptor(
                role: .agyCLI,
                canonicalPath: "/usr/local/bin/agy"
            )
        )
        let inspector =
            AntigravitySystemManagedLaunchIntentInspector(
                identityProvider: identityProvider
            )

        XCTAssertEqual(
            inspector.candidates(
                ownedBy: owner,
                executable: executable
            ),
            .none
        )
    }

    private func makeRecovery(
        store: IntentRecoveryLedgerStore,
        boot: AntigravityBootSessionID,
        inspector: ScriptedLaunchIntentInspector,
        recordRecovery: RecordingIntentRecordRecovery
    ) -> AntigravityManagedSessionLifecycleRecovery {
        AntigravityManagedSessionLifecycleRecovery(
            ledgerStore: store,
            bootSessionProvider:
                ScriptedBootSessionProvider(
                    values: [boot, boot]
                ),
            intentInspector: inspector,
            recordRecovery: recordRecovery
        )
    }

    private func makeSystemInspector(
        processIDs: [Int32]?,
        kernelIdentities:
            [Int32: AntigravityKernelProcessIdentity],
        identities:
            [Int32: AntigravityRecordedProcessIdentity],
        processGroups: [Int32: Int32],
        existence: [Int32: AntigravityProcessExistence],
        processTableStates:
            [Int32: AntigravityProcessTableState] = [:]
    ) -> AntigravitySystemManagedLaunchIntentInspector {
        AntigravitySystemManagedLaunchIntentInspector(
            processIDList:
                StaticIntentProcessIDList(values: processIDs),
            kernelIdentityReader:
                StaticIntentKernelIdentityReader(
                    values: kernelIdentities
                ),
            identityProvider:
                StaticIntentProcessIdentityProvider(
                    identities: identities,
                    processGroups: processGroups
                ),
            existenceChecker:
                StaticIntentProcessExistenceChecker(
                    values: existence
                ),
            processTableStateReader:
                StaticIntentProcessTableStateReader(
                    values: processTableStates
                )
        )
    }

    private func assertRecoveryBlocked(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
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

    private func makeSnapshot(
        bootSessionID: AntigravityBootSessionID,
        entries: [AntigravityManagedProcessLedgerEntry]
    ) -> AntigravityManagedProcessLedgerSnapshot {
        .init(
            bootSessionID: bootSessionID,
            revision: 1,
            entries: entries
        )
    }

    private func makeFixture(
        sessionID: UUID = UUID(
            uuidString:
                "00000000-0000-0000-0000-000000000700"
        )!,
        ownerPID: Int32 = 4_100,
        ownerUniqueID: UInt64 = 74_100,
        childPID: Int32 = 4_200,
        childUniqueID: UInt64 = 74_200
    ) throws -> IntentRecoveryFixture {
        let currentBoot = AntigravityBootSessionID(
            rawValue: UUID(
                uuidString:
                    "00000000-0000-0000-0000-000000000801"
            )!
        )
        let staleBoot = AntigravityBootSessionID(
            rawValue: UUID(
                uuidString:
                    "00000000-0000-0000-0000-000000000802"
            )!
        )
        let owner = try makeIdentity(
            pid: ownerPID,
            uniqueID: ownerUniqueID,
            parentUniqueID: ownerUniqueID - 1,
            path:
                "/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage"
        )
        let child = try makeIdentity(
            pid: childPID,
            uniqueID: childUniqueID,
            parentUniqueID: ownerUniqueID,
            path: "/Users/test/.local/bin/agy"
        )
        let executable = try XCTUnwrap(
            AntigravityManagedExecutableDescriptor(
                role: .agyCLI,
                canonicalPath: child.executablePath
            )
        )
        let intent = try XCTUnwrap(
            AntigravityManagedLaunchIntent(
                sessionID: sessionID,
                bootSessionID: currentBoot,
                owner: owner,
                executable: executable,
                createdAt: Date(
                    timeIntervalSince1970: 1_800_000_000
                )
            )
        )
        return IntentRecoveryFixture(
            currentBoot: currentBoot,
            staleBoot: staleBoot,
            owner: owner,
            child: child,
            executable: executable,
            intent: intent
        )
    }

    private func makeIdentity(
        pid: Int32,
        uniqueID: UInt64,
        parentUniqueID: UInt64,
        effectiveUserID: UInt32 = 501,
        realUserID: UInt32 = 501,
        path: String
    ) throws -> AntigravityRecordedProcessIdentity {
        let kernelIdentity = try XCTUnwrap(
            AntigravityKernelProcessIdentity(
                uniqueID: uniqueID,
                parentUniqueID: parentUniqueID,
                pidVersion: pid + 10_000
            )
        )
        return try XCTUnwrap(
            AntigravityRecordedProcessIdentity(
                pid: pid,
                effectiveUserID: effectiveUserID,
                realUserID: realUserID,
                startedAtSeconds:
                    1_800_000_000 + Int64(pid),
                startedAtMicroseconds: 123,
                executablePath: path,
                kernelIdentity: kernelIdentity
            )
        )
    }
}

private nonisolated struct IntentRecoveryFixture {
    let currentBoot: AntigravityBootSessionID
    let staleBoot: AntigravityBootSessionID
    let owner: AntigravityRecordedProcessIdentity
    let child: AntigravityRecordedProcessIdentity
    let executable: AntigravityManagedExecutableDescriptor
    let intent: AntigravityManagedLaunchIntent
}

private nonisolated enum IntentRecoveryEvent: Equatable {
    case removeStaleBoot
    case removeIntent
    case promoteIntent
    case recordRecovery
}

private nonisolated final class IntentRecoveryEventRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedValues: [IntentRecoveryEvent] = []

    var values: [IntentRecoveryEvent] {
        lock.withLock { storedValues }
    }

    func append(_ event: IntentRecoveryEvent) {
        lock.withLock {
            storedValues.append(event)
        }
    }
}

private nonisolated final class IntentRecoveryLedgerStore:
    AntigravityManagedProcessLedgerStoring,
    @unchecked Sendable
{
    struct Promotion: Equatable {
        let intent: AntigravityManagedLaunchIntent
        let record: AntigravityManagedProcessRecord
    }

    private let lock = NSLock()
    private let events: IntentRecoveryEventRecorder
    private var storedSnapshot:
        AntigravityManagedProcessLedgerSnapshot
    private var ledgerLoads = 0
    private var storedRemovedIntents:
        [AntigravityManagedLaunchIntent] = []
    private var storedPromotions: [Promotion] = []
    private var storedStaleBootRemovals:
        [AntigravityBootSessionID] = []

    init(
        snapshot: AntigravityManagedProcessLedgerSnapshot,
        events: IntentRecoveryEventRecorder
    ) {
        self.storedSnapshot = snapshot
        self.events = events
    }

    var snapshot: AntigravityManagedProcessLedgerSnapshot {
        lock.withLock { storedSnapshot }
    }

    var loadLedgerCallCount: Int {
        lock.withLock { ledgerLoads }
    }

    var removedIntents: [AntigravityManagedLaunchIntent] {
        lock.withLock { storedRemovedIntents }
    }

    var promotions: [Promotion] {
        lock.withLock { storedPromotions }
    }

    var staleBootRemovals: [AntigravityBootSessionID] {
        lock.withLock { storedStaleBootRemovals }
    }

    var mutationCount: Int {
        lock.withLock {
            storedRemovedIntents.count
                + storedPromotions.count
                + storedStaleBootRemovals.count
        }
    }

    nonisolated func load()
        throws -> [AntigravityManagedProcessRecord] {
        lock.withLock {
            storedSnapshot.processRecords
        }
    }

    nonisolated func loadLedger()
        throws -> AntigravityManagedProcessLedgerSnapshot {
        lock.withLock {
            ledgerLoads += 1
            return storedSnapshot
        }
    }

    nonisolated func createIntent(
        _ intent: AntigravityManagedLaunchIntent
    ) throws {
        try lock.withLock {
            guard storedSnapshot.entries.isEmpty else {
                throw AntigravityManagedProcessRecordStoreError
                    .entryAlreadyExists
            }
            storedSnapshot = .init(
                bootSessionID: intent.bootSessionID,
                revision: storedSnapshot.revision + 1,
                entries: [.launchIntent(intent)]
            )
        }
    }

    nonisolated func promoteIntent(
        _ intent: AntigravityManagedLaunchIntent,
        to record: AntigravityManagedProcessRecord
    ) throws {
        try lock.withLock {
            guard let index = storedSnapshot.entries.firstIndex(
                of: .launchIntent(intent)
            ) else {
                throw AntigravityManagedProcessRecordStoreError
                    .entryNotFound
            }
            var entries = storedSnapshot.entries
            entries[index] = .processRecord(record)
            storedSnapshot = .init(
                bootSessionID: storedSnapshot.bootSessionID,
                revision: storedSnapshot.revision + 1,
                entries: entries
            )
            storedPromotions.append(.init(
                intent: intent,
                record: record
            ))
            events.append(.promoteIntent)
        }
    }

    nonisolated func removeIntent(
        _ intent: AntigravityManagedLaunchIntent
    ) throws {
        try lock.withLock {
            guard storedSnapshot.entries.contains(
                .launchIntent(intent)
            ) else {
                throw AntigravityManagedProcessRecordStoreError
                    .entryNotFound
            }
            let entries = storedSnapshot.entries.filter {
                $0 != .launchIntent(intent)
            }
            storedSnapshot = .init(
                bootSessionID:
                    entries.isEmpty
                    ? nil
                    : storedSnapshot.bootSessionID,
                revision: storedSnapshot.revision + 1,
                entries: entries
            )
            storedRemovedIntents.append(intent)
            events.append(.removeIntent)
        }
    }

    nonisolated func removeEntriesFromStaleBoot(
        _ bootSessionID: AntigravityBootSessionID
    ) throws {
        lock.withLock {
            storedSnapshot = .init(
                bootSessionID: nil,
                revision: storedSnapshot.revision + 1,
                entries: []
            )
            storedStaleBootRemovals.append(bootSessionID)
            events.append(.removeStaleBoot)
        }
    }

    nonisolated func update(
        _ record: AntigravityManagedProcessRecord
    ) throws {
        try lock.withLock {
            guard let index = storedSnapshot.entries.firstIndex(
                where: { $0.sessionID == record.sessionID }
            ) else {
                throw AntigravityManagedProcessRecordStoreError
                    .entryNotFound
            }
            var entries = storedSnapshot.entries
            entries[index] = .processRecord(record)
            storedSnapshot = .init(
                bootSessionID: storedSnapshot.bootSessionID,
                revision: storedSnapshot.revision + 1,
                entries: entries
            )
        }
    }

    nonisolated func remove(sessionID: UUID) throws {
        lock.withLock {
            let entries = storedSnapshot.entries.filter {
                $0.sessionID != sessionID
            }
            storedSnapshot = .init(
                bootSessionID:
                    entries.isEmpty
                    ? nil
                    : storedSnapshot.bootSessionID,
                revision: storedSnapshot.revision + 1,
                entries: entries
            )
        }
    }
}

private nonisolated final class ScriptedBootSessionProvider:
    AntigravityBootSessionIdentityProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [AntigravityBootSessionID?]

    init(values: [AntigravityBootSessionID?]) {
        self.values = values
    }

    func currentBootSessionID() -> AntigravityBootSessionID? {
        lock.withLock {
            guard values.count > 1 else {
                return values.first ?? nil
            }
            return values.removeFirst()
        }
    }
}

private nonisolated final class ScriptedLaunchIntentInspector:
    AntigravityManagedLaunchIntentInspecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var ownerStates:
        [AntigravityManagedLaunchIntentOwnerState]
    private var candidateInspections:
        [AntigravityManagedLaunchCandidateInspection]
    private var ownerCalls = 0
    private var candidateCalls = 0

    init(
        ownerStates:
            [AntigravityManagedLaunchIntentOwnerState],
        candidateInspections:
            [AntigravityManagedLaunchCandidateInspection]
    ) {
        self.ownerStates = ownerStates
        self.candidateInspections = candidateInspections
    }

    var ownerStateCallCount: Int {
        lock.withLock { ownerCalls }
    }

    var candidateCallCount: Int {
        lock.withLock { candidateCalls }
    }

    func ownerState(
        for owner: AntigravityRecordedProcessIdentity
    ) -> AntigravityManagedLaunchIntentOwnerState {
        lock.withLock {
            ownerCalls += 1
            guard !ownerStates.isEmpty else {
                return .unavailable
            }
            return ownerStates.removeFirst()
        }
    }

    func candidates(
        ownedBy owner: AntigravityRecordedProcessIdentity,
        executable: AntigravityManagedExecutableDescriptor
    ) -> AntigravityManagedLaunchCandidateInspection {
        lock.withLock {
            candidateCalls += 1
            guard !candidateInspections.isEmpty else {
                return .unavailable
            }
            return candidateInspections.removeFirst()
        }
    }
}

private nonisolated final class RecordingIntentRecordRecovery:
    AntigravityManagedProcessRecovering,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let events: IntentRecoveryEventRecorder
    private var calls = 0

    init(events: IntentRecoveryEventRecorder) {
        self.events = events
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func recoverOrphanedProcesses() async throws {
        lock.withLock {
            calls += 1
        }
        events.append(.recordRecovery)
    }
}

private nonisolated struct StaticIntentProcessIDList:
    AntigravityProcessIDListing
{
    let values: [Int32]?

    func allProcessIDs() -> [Int32]? {
        values
    }
}

private nonisolated struct StaticIntentKernelIdentityReader:
    AntigravityKernelProcessIdentityReading
{
    let values: [Int32: AntigravityKernelProcessIdentity]

    func kernelIdentity(
        for processID: Int32
    ) -> AntigravityKernelProcessIdentity? {
        values[processID]
    }
}

private nonisolated struct StaticIntentProcessIdentityProvider:
    AntigravityManagedProcessIdentityProviding
{
    let identities:
        [Int32: AntigravityRecordedProcessIdentity]
    let processGroups: [Int32: Int32]

    func identity(
        for processID: Int32
    ) -> AntigravityRecordedProcessIdentity? {
        identities[processID]
    }

    func processGroupID(for processID: Int32) -> Int32? {
        processGroups[processID]
    }
}

private nonisolated struct StaticIntentProcessExistenceChecker:
    AntigravityProcessExistenceChecking
{
    let values: [Int32: AntigravityProcessExistence]

    func existence(
        of processID: Int32
    ) -> AntigravityProcessExistence {
        values[processID] ?? .notFound
    }
}

private nonisolated struct StaticIntentProcessTableStateReader:
    AntigravityProcessTableStateReading
{
    let values: [Int32: AntigravityProcessTableState]

    func state(
        for processID: Int32
    ) -> AntigravityProcessTableState? {
        values[processID]
    }
}
