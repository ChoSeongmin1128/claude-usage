import Darwin
import Foundation
import XCTest
@testable import ClaudeUsage

final class AntigravityManagedProcessTreeTests: XCTestCase {
    func testSystemExistenceCheckerTreatsUnreapedZombieAsTerminated()
        async throws
    {
        let executablePath = "/usr/bin/true"
        var arguments = [strdup(executablePath), nil]
        defer {
            if let argument = arguments[0] {
                free(argument)
            }
        }
        var environment = [strdup("PATH=/usr/bin"), nil]
        defer {
            if let entry = environment[0] {
                free(entry)
            }
        }

        var processID: pid_t = 0
        let spawnStatus = executablePath.withCString { executable in
            posix_spawn(
                &processID,
                executable,
                nil,
                nil,
                &arguments,
                &environment
            )
        }
        XCTAssertEqual(spawnStatus, 0)
        XCTAssertGreaterThan(processID, 1)
        guard spawnStatus == 0, processID > 1 else { return }

        defer {
            _ = Darwin.kill(processID, SIGKILL)
            var status: Int32 = 0
            while waitpid(processID, &status, 0) == -1,
                  errno == EINTR {}
        }

        let checker = AntigravitySystemProcessExistenceChecker()
        let deadline = ContinuousClock.now.advanced(
            by: .seconds(1)
        )
        while ContinuousClock.now < deadline {
            if checker.existence(of: processID) == .terminated {
                XCTAssertNil(
                    AntigravitySystemKernelProcessIdentityReader()
                        .kernelIdentity(for: processID)
                )
                XCTAssertNotNil(
                    AntigravitySystemKernelProcessIdentityReader(
                        includeTerminatedProcesses: true
                    ).kernelIdentity(for: processID)
                )
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Unreaped child was not classified as terminated")
    }

    func testKernelIdentityReadFailureDistinguishesExitedFromAmbiguousProcess()
        throws
    {
        let root = try makeTreeIdentity(
            pid: 5_101,
            uniqueID: 95_101,
            parentUniqueID: 95_001
        )
        let record = try makeTreeRecord(child: root)
        let processIDs = StaticProcessIDList(
            processIDs: [root.pid, 5_999]
        )
        let kernelReader = StaticKernelIdentityReader(
            identities: [
                root.pid: root.kernelIdentity,
            ]
        )
        let identityProvider = StaticManagedIdentityProvider(
            identities: [root.pid: root]
        )

        let ambiguous = AntigravitySystemManagedProcessTreeInspector(
            processIDList: processIDs,
            kernelIdentityReader: kernelReader,
            identityProvider: identityProvider,
            existenceChecker: StaticProcessExistenceChecker(
                existences: [5_999: .present]
            ),
            bootTimeProvider: StaticBootTimeProvider(
                value: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ).snapshot(for: record)
        XCTAssertEqual(ambiguous?.rootExecution, root)
        XCTAssertEqual(ambiguous?.isComplete, false)

        let exited = AntigravitySystemManagedProcessTreeInspector(
            processIDList: processIDs,
            kernelIdentityReader: kernelReader,
            identityProvider: identityProvider,
            existenceChecker: StaticProcessExistenceChecker(
                existences: [5_999: .notFound]
            ),
            bootTimeProvider: StaticBootTimeProvider(
                value: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ).snapshot(for: record)
        XCTAssertEqual(exited?.rootExecution, root)
        XCTAssertEqual(exited?.isComplete, true)

        let terminated = AntigravitySystemManagedProcessTreeInspector(
            processIDList: processIDs,
            kernelIdentityReader: kernelReader,
            identityProvider: identityProvider,
            existenceChecker: StaticProcessExistenceChecker(
                existences: [5_999: .terminated]
            ),
            processTableStateReader:
                StaticProcessTableStateReader(
                    states: [
                        5_999: AntigravityProcessTableState(
                            processID: 5_999,
                            parentProcessID: 42,
                            processGroupID: 42,
                            effectiveUserID: 501,
                            realUserID: 501,
                            startedAtSeconds:
                                1_700_000_050,
                            startedAtMicroseconds: 123,
                            isZombie: true
                        )!,
                    ]
                ),
            bootTimeProvider: StaticBootTimeProvider(
                value: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ).snapshot(for: record)
        XCTAssertEqual(terminated?.rootExecution, root)
        XCTAssertEqual(terminated?.isComplete, true)
    }

    func testRelatedZombieMakesUnlinkedEscapedChildAmbiguous()
        throws
    {
        let root = try makeTreeIdentity(
            pid: 5_151,
            uniqueID: 95_151,
            parentUniqueID: 95_001
        )
        let liveAncestor = try makeTreeIdentity(
            pid: 5_152,
            uniqueID: 95_152,
            parentUniqueID: root.kernelIdentity.uniqueID
        )
        let zombiePID: Int32 = 5_153
        let escaped = try makeTreeIdentity(
            pid: 5_154,
            uniqueID: 95_154,
            parentUniqueID: 95_153
        )
        let record = try makeTreeRecord(child: root)
        let snapshot =
            AntigravitySystemManagedProcessTreeInspector(
                processIDList: StaticProcessIDList(
                    processIDs: [
                        root.pid,
                        liveAncestor.pid,
                        zombiePID,
                        escaped.pid,
                    ]
                ),
                kernelIdentityReader:
                    StaticKernelIdentityReader(
                        identities: [
                            root.pid: root.kernelIdentity,
                            liveAncestor.pid:
                                liveAncestor.kernelIdentity,
                            escaped.pid:
                                escaped.kernelIdentity,
                        ]
                    ),
                identityProvider:
                    StaticManagedIdentityProvider(
                        identities: [
                            root.pid: root,
                            liveAncestor.pid: liveAncestor,
                            escaped.pid: escaped,
                        ]
                    ),
                existenceChecker:
                    StaticProcessExistenceChecker(
                        existences: [
                            root.pid: .present,
                            liveAncestor.pid: .present,
                            zombiePID: .terminated,
                            escaped.pid: .present,
                        ]
                    ),
                processTableStateReader:
                    StaticProcessTableStateReader(
                        states: [
                            zombiePID:
                                AntigravityProcessTableState(
                                    processID: zombiePID,
                                    parentProcessID:
                                        liveAncestor.pid,
                                    processGroupID:
                                        zombiePID,
                                    effectiveUserID: 501,
                                    realUserID: 501,
                                    startedAtSeconds:
                                        1_700_000_050,
                                    startedAtMicroseconds: 123,
                                    isZombie: true
                                )!,
                        ]
                    ),
                bootTimeProvider: StaticBootTimeProvider(
                    value: Date(
                        timeIntervalSince1970: 1_700_000_000
                    )
                )
            ).snapshot(for: record)

        XCTAssertEqual(snapshot?.rootExecution, root)
        XCTAssertEqual(
            snapshot?.descendants,
            [liveAncestor]
        )
        XCTAssertEqual(snapshot?.isComplete, false)
    }

    func testExactZombieIdentityLinksLiveGrandchildAncestry()
        throws
    {
        let root = try makeTreeIdentity(
            pid: 5_161,
            uniqueID: 95_161,
            parentUniqueID: 95_001
        )
        let zombie = try makeTreeIdentity(
            pid: 5_162,
            uniqueID: 95_162,
            parentUniqueID: root.kernelIdentity.uniqueID
        )
        let liveGrandchild = try makeTreeIdentity(
            pid: 5_163,
            uniqueID: 95_163,
            parentUniqueID:
                zombie.kernelIdentity.uniqueID
        )
        let record = try makeTreeRecord(child: root)
        let snapshot =
            AntigravitySystemManagedProcessTreeInspector(
                processIDList: StaticProcessIDList(
                    processIDs: [
                        root.pid,
                        zombie.pid,
                        liveGrandchild.pid,
                    ]
                ),
                kernelIdentityReader:
                    StaticKernelIdentityReader(
                        identities: [
                            root.pid: root.kernelIdentity,
                            // Production obtains this edge through flavor 17
                            // with arg 1, which includes unreaped zombies.
                            zombie.pid: zombie.kernelIdentity,
                            liveGrandchild.pid:
                                liveGrandchild.kernelIdentity,
                        ]
                    ),
                identityProvider:
                    StaticManagedIdentityProvider(
                        identities: [
                            root.pid: root,
                            liveGrandchild.pid: liveGrandchild,
                        ]
                    ),
                existenceChecker:
                    StaticProcessExistenceChecker(
                        existences: [
                            root.pid: .present,
                            zombie.pid: .terminated,
                            liveGrandchild.pid: .present,
                        ]
                    ),
                bootTimeProvider: StaticBootTimeProvider(
                    value: Date(
                        timeIntervalSince1970: 1_700_000_000
                    )
                )
            ).snapshot(for: record)

        XCTAssertEqual(snapshot?.rootExecution, root)
        XCTAssertEqual(
            snapshot?.descendants,
            [liveGrandchild]
        )
        XCTAssertEqual(snapshot?.isComplete, true)
    }

    func testOpaqueRelatedExecutionThatDisappearsDuringRevalidationDoesNotBlockSnapshot()
        throws
    {
        let root = try makeTreeIdentity(
            pid: 5_181,
            uniqueID: 95_181,
            parentUniqueID: 95_001
        )
        let opaquePID: Int32 = 5_182
        let opaqueState = try XCTUnwrap(
            AntigravityProcessTableState(
                processID: opaquePID,
                parentProcessID: root.pid,
                processGroupID: root.pid,
                effectiveUserID: 501,
                realUserID: 501,
                startedAtSeconds: 1_700_000_051,
                startedAtMicroseconds: 123,
                isZombie: false
            )
        )
        let record = try makeTreeRecord(child: root)
        let snapshot =
            AntigravitySystemManagedProcessTreeInspector(
                processIDList: StaticProcessIDList(
                    processIDs: [root.pid, opaquePID]
                ),
                kernelIdentityReader:
                    StaticKernelIdentityReader(
                        identities: [
                            root.pid: root.kernelIdentity,
                        ]
                    ),
                identityProvider:
                    StaticManagedIdentityProvider(
                        identities: [root.pid: root]
                    ),
                existenceChecker:
                    ScriptedProcessExistenceChecker(
                        existences: [
                            opaquePID: [.present, .notFound],
                        ]
                    ),
                processTableStateReader:
                    ScriptedProcessTableStateReader(
                        states: [
                            opaquePID: [opaqueState, nil],
                        ]
                    ),
                bootTimeProvider: StaticBootTimeProvider(
                    value: Date(
                        timeIntervalSince1970: 1_700_000_000
                    )
                )
            ).snapshot(for: record)

        XCTAssertEqual(snapshot?.rootExecution, root)
        XCTAssertEqual(snapshot?.descendants, [])
        XCTAssertEqual(snapshot?.isComplete, true)
    }

    func testDurableExitedAncestorSeedsNewLiveDescendant()
        throws
    {
        let root = try makeTreeIdentity(
            pid: 5_201,
            uniqueID: 95_201,
            parentUniqueID: 95_001
        )
        let exitedAncestor = try makeTreeIdentity(
            pid: 5_202,
            uniqueID: 95_202,
            parentUniqueID: root.kernelIdentity.uniqueID
        )
        let newDescendant = try makeTreeIdentity(
            pid: 5_203,
            uniqueID: 95_203,
            parentUniqueID:
                exitedAncestor.kernelIdentity.uniqueID
        )
        let record = try makeTreeRecord(
            child: root,
            descendants: [exitedAncestor]
        )
        let snapshot =
            AntigravitySystemManagedProcessTreeInspector(
                processIDList: StaticProcessIDList(
                    processIDs: [newDescendant.pid]
                ),
                kernelIdentityReader:
                    StaticKernelIdentityReader(
                        identities: [
                            newDescendant.pid:
                                newDescendant.kernelIdentity,
                        ]
                    ),
                identityProvider:
                    StaticManagedIdentityProvider(
                        identities: [
                            newDescendant.pid: newDescendant,
                        ]
                    ),
                existenceChecker:
                    StaticProcessExistenceChecker(existences: [:]),
                bootTimeProvider: StaticBootTimeProvider(
                    value: Date(
                        timeIntervalSince1970: 1_700_000_000
                    )
                )
            ).snapshot(for: record)

        XCTAssertEqual(snapshot?.rootExecution, nil)
        XCTAssertEqual(snapshot?.descendants, [newDescendant])
        XCTAssertEqual(snapshot?.isComplete, true)
    }

    func testRootExecIsCapturedButStableInvariantChangeFailsClosed()
        throws
    {
        let root = try makeTreeIdentity(
            pid: 5_301,
            uniqueID: 95_301,
            parentUniqueID: 95_001,
            pidVersion: 15_301,
            executablePath: "/usr/local/bin/agy"
        )
        let execedRoot = try makeTreeIdentity(
            pid: root.pid,
            uniqueID: root.kernelIdentity.uniqueID,
            parentUniqueID:
                root.kernelIdentity.parentUniqueID,
            pidVersion: root.kernelIdentity.pidVersion + 1,
            executablePath: "/usr/bin/node"
        )
        let record = try makeTreeRecord(child: root)
        let execedSnapshot = makeSystemSnapshot(
            record: record,
            currentRoot: execedRoot
        )
        XCTAssertEqual(execedSnapshot?.rootExecution, execedRoot)
        XCTAssertEqual(execedSnapshot?.isComplete, true)
        XCTAssertEqual(
            record.mergingObservation(
                rootExecution: execedSnapshot?.rootExecution,
                descendants: [],
                scanWasComplete: true,
                observedAt:
                    record.createdAt.addingTimeInterval(1)
            )?.child,
            execedRoot
        )

        let changedStart = try makeTreeIdentity(
            pid: root.pid,
            uniqueID: root.kernelIdentity.uniqueID,
            parentUniqueID:
                root.kernelIdentity.parentUniqueID,
            pidVersion: root.kernelIdentity.pidVersion + 2,
            startedAtSeconds: root.startedAtSeconds + 1,
            executablePath: "/usr/bin/node"
        )
        let invalidSnapshot = makeSystemSnapshot(
            record: record,
            currentRoot: changedStart
        )
        XCTAssertNil(invalidSnapshot?.rootExecution)
        XCTAssertEqual(invalidSnapshot?.isComplete, false)
    }

    func testPrebootDurableAncestryFailsClosed()
        throws
    {
        let root = try makeTreeIdentity(
            pid: 5_401,
            uniqueID: 95_401,
            parentUniqueID: 95_001,
            startedAtSeconds: 1_699_999_900
        )
        let record = try makeTreeRecord(
            child: root,
            createdAt: Date(
                timeIntervalSince1970: 1_699_999_950
            )
        )
        let snapshot =
            AntigravitySystemManagedProcessTreeInspector(
                processIDList: StaticProcessIDList(
                    processIDs: [root.pid]
                ),
                kernelIdentityReader:
                    StaticKernelIdentityReader(
                        identities: [
                            root.pid: root.kernelIdentity,
                        ]
                    ),
                identityProvider:
                    StaticManagedIdentityProvider(
                        identities: [root.pid: root]
                    ),
                bootTimeProvider: StaticBootTimeProvider(
                    value: Date(
                        timeIntervalSince1970: 1_700_000_000
                    )
                )
            ).snapshot(for: record)

        XCTAssertEqual(snapshot?.descendants, [])
        XCTAssertEqual(snapshot?.isComplete, false)
    }

    func testExactSignalerRejectsWrongPIDVersionWithoutSignallingProcess()
        async throws
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; while :; do sleep 1; done"]
        try process.run()
        defer {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        let provider = AntigravityManagedProcessIdentityProvider()
        let identity = try XCTUnwrap(
            provider.identity(for: process.processIdentifier)
        )
        let wrongKernelIdentity = try XCTUnwrap(
            AntigravityKernelProcessIdentity(
                uniqueID: identity.kernelIdentity.uniqueID,
                parentUniqueID:
                    identity.kernelIdentity.parentUniqueID,
                pidVersion:
                    identity.kernelIdentity.pidVersion &+ 1
            )
        )
        let wrongIdentity = try XCTUnwrap(
            AntigravityRecordedProcessIdentity(
                pid: identity.pid,
                effectiveUserID: identity.effectiveUserID,
                realUserID: identity.realUserID,
                startedAtSeconds: identity.startedAtSeconds,
                startedAtMicroseconds:
                    identity.startedAtMicroseconds,
                executablePath: identity.executablePath,
                kernelIdentity: wrongKernelIdentity
            )
        )

        XCTAssertThrowsError(
            try AntigravitySystemExactProcessSignaler().signal(
                wrongIdentity,
                signal: SIGKILL
            )
        ) {
            XCTAssertEqual(
                $0 as? AntigravityExactProcessSignalError,
                .processNotFound
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(process.isRunning, "A mismatched identity must not be signalled")
    }

    private func makeSystemSnapshot(
        record: AntigravityManagedProcessRecord,
        currentRoot: AntigravityRecordedProcessIdentity
    ) -> AntigravityManagedProcessTreeSnapshot? {
        AntigravitySystemManagedProcessTreeInspector(
            processIDList: StaticProcessIDList(
                processIDs: [currentRoot.pid]
            ),
            kernelIdentityReader: StaticKernelIdentityReader(
                identities: [
                    currentRoot.pid: currentRoot.kernelIdentity,
                ]
            ),
            identityProvider: StaticManagedIdentityProvider(
                identities: [currentRoot.pid: currentRoot]
            ),
            bootTimeProvider: StaticBootTimeProvider(
                value: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ).snapshot(for: record)
    }

    private func makeTreeRecord(
        child: AntigravityRecordedProcessIdentity,
        descendants: [AntigravityRecordedProcessIdentity] = [],
        createdAt: Date =
            Date(timeIntervalSince1970: 1_700_000_100)
    ) throws -> AntigravityManagedProcessRecord {
        let owner = try makeTreeIdentity(
            pid: 5_001,
            uniqueID: 95_001,
            parentUniqueID: 94_999,
            executablePath:
                "/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage"
        )
        return try XCTUnwrap(
            AntigravityManagedProcessRecord(
                sessionID: UUID(),
                bootSessionID: AntigravityBootSessionID(
                    rawValue: UUID(
                        uuidString:
                            "00000000-0000-0000-0000-000000000601"
                    )!
                ),
                child: child,
                processGroupID: child.pid,
                owner: owner,
                observedDescendants: descendants,
                observationCompleteness: .complete,
                createdAt: createdAt
            )
        )
    }

    private func makeTreeIdentity(
        pid: Int32,
        uniqueID: UInt64,
        parentUniqueID: UInt64,
        pidVersion: Int32? = nil,
        startedAtSeconds: Int64 = 1_700_000_050,
        executablePath: String = "/usr/local/bin/agy"
    ) throws -> AntigravityRecordedProcessIdentity {
        try XCTUnwrap(
            AntigravityRecordedProcessIdentity(
                pid: pid,
                effectiveUserID: 501,
                realUserID: 501,
                startedAtSeconds: startedAtSeconds,
                startedAtMicroseconds: 123,
                executablePath: executablePath,
                kernelIdentity: try XCTUnwrap(
                    AntigravityKernelProcessIdentity(
                        uniqueID: uniqueID,
                        parentUniqueID: parentUniqueID,
                        pidVersion: pidVersion ?? pid + 10_000
                    )
                )
            )
        )
    }
}

private nonisolated struct StaticProcessIDList:
    AntigravityProcessIDListing
{
    let processIDs: [Int32]

    func allProcessIDs() -> [Int32]? {
        processIDs
    }
}

private nonisolated struct StaticKernelIdentityReader:
    AntigravityKernelProcessIdentityReading
{
    let identities: [Int32: AntigravityKernelProcessIdentity]

    func kernelIdentity(
        for processID: Int32
    ) -> AntigravityKernelProcessIdentity? {
        identities[processID]
    }
}

private nonisolated struct StaticManagedIdentityProvider:
    AntigravityManagedProcessIdentityProviding
{
    let identities: [Int32: AntigravityRecordedProcessIdentity]

    func identity(
        for processID: Int32
    ) -> AntigravityRecordedProcessIdentity? {
        identities[processID]
    }

    func processGroupID(for processID: Int32) -> Int32? {
        identities[processID] == nil ? nil : processID
    }
}

private nonisolated struct StaticProcessExistenceChecker:
    AntigravityProcessExistenceChecking
{
    let existences: [Int32: AntigravityProcessExistence]

    func existence(
        of processID: Int32
    ) -> AntigravityProcessExistence {
        existences[processID] ?? .notFound
    }
}

private nonisolated struct StaticProcessTableStateReader:
    AntigravityProcessTableStateReading
{
    let states: [Int32: AntigravityProcessTableState]

    func state(
        for processID: Int32
    ) -> AntigravityProcessTableState? {
        states[processID]
    }
}

private nonisolated final class ScriptedProcessExistenceChecker:
    AntigravityProcessExistenceChecking,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var existences:
        [Int32: [AntigravityProcessExistence]]

    init(
        existences:
            [Int32: [AntigravityProcessExistence]]
    ) {
        self.existences = existences
    }

    func existence(
        of processID: Int32
    ) -> AntigravityProcessExistence {
        lock.withLock {
            guard var values = existences[processID],
                  !values.isEmpty else {
                return .notFound
            }
            let value = values.removeFirst()
            existences[processID] = values
            return value
        }
    }
}

private nonisolated final class ScriptedProcessTableStateReader:
    AntigravityProcessTableStateReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var states:
        [Int32: [AntigravityProcessTableState?]]

    init(
        states:
            [Int32: [AntigravityProcessTableState?]]
    ) {
        self.states = states
    }

    func state(
        for processID: Int32
    ) -> AntigravityProcessTableState? {
        lock.withLock {
            guard var values = states[processID],
                  !values.isEmpty else {
                return nil
            }
            let value = values.removeFirst()
            states[processID] = values
            return value
        }
    }
}

private nonisolated struct StaticBootTimeProvider:
    AntigravitySystemBootTimeProviding
{
    let value: Date?

    func bootTime() -> Date? {
        value
    }
}
