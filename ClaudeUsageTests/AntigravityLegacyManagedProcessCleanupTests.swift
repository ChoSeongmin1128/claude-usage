import Darwin
import XCTest
@testable import ClaudeUsage

final class AntigravityLegacyManagedProcessCleanupTests: XCTestCase {
    private var stateDirectory: URL!

    override func setUpWithError() throws {
        stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyManagedCleanupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDirectory)
    }

    // MARK: - Policy

    func testMissingLedgerNeverStartsRecovery() async {
        let recovery = RecordingRecovery()
        let cleanup = AntigravityLegacyManagedProcessCleanup(
            ledgerStore: FixedLedgerStore(snapshot: .empty), recovery: recovery, ledgerExists: { false })

        let result = await cleanup.cleanUp()

        XCTAssertEqual(result, .nothingRecorded)
        let calls = await recovery.calls
        XCTAssertEqual(calls, 0)
    }

    func testEmptyLedgerNeverStartsRecovery() async {
        let recovery = RecordingRecovery()
        let cleanup = AntigravityLegacyManagedProcessCleanup(
            ledgerStore: FixedLedgerStore(snapshot: .empty), recovery: recovery, ledgerExists: { true })

        let result = await cleanup.cleanUp()

        XCTAssertEqual(result, .nothingRecorded)
        let calls = await recovery.calls
        XCTAssertEqual(calls, 0)
    }

    func testRecordedEntriesAreRecovered() async throws {
        let recovery = RecordingRecovery()
        let snapshot = AntigravityManagedProcessLedgerSnapshot(
            bootSessionID: nil, revision: 1, entries: [.launchIntent(try intent(boot: .init(rawValue: UUID())))])
        let cleanup = AntigravityLegacyManagedProcessCleanup(
            ledgerStore: FixedLedgerStore(snapshot: snapshot), recovery: recovery, ledgerExists: { true })

        let result = await cleanup.cleanUp()

        XCTAssertEqual(result, .cleaned)
        let calls = await recovery.calls
        XCTAssertEqual(calls, 1)
    }

    func testBlockedRecoveryIsDeferredWithoutThrowing() async throws {
        let snapshot = AntigravityManagedProcessLedgerSnapshot(
            bootSessionID: nil, revision: 1, entries: [.launchIntent(try intent(boot: .init(rawValue: UUID())))])
        let cleanup = AntigravityLegacyManagedProcessCleanup(
            ledgerStore: FixedLedgerStore(snapshot: snapshot),
            recovery: RecordingRecovery(error: AntigravityManagedSessionError.recordRecoveryBlocked),
            ledgerExists: { true })

        let result = await cleanup.cleanUp()

        XCTAssertEqual(result, .deferred)
    }

    func testUnreadableLedgerIsDeferred() async {
        let recovery = RecordingRecovery()
        let cleanup = AntigravityLegacyManagedProcessCleanup(
            ledgerStore: FixedLedgerStore(snapshot: nil), recovery: recovery, ledgerExists: { true })

        let result = await cleanup.cleanUp()

        XCTAssertEqual(result, .deferred)
        let calls = await recovery.calls
        XCTAssertEqual(calls, 0)
    }

    // MARK: - Production composition against a real ledger file

    func testProductionCleanupDropsEntriesFromAPreviousBoot() async throws {
        let store = ledgerFileStore()
        try store.createIntent(try intent(boot: .init(rawValue: UUID())))

        let result = await AntigravityLegacyManagedProcessCleanup.production(
            stateDirectory: stateDirectory, homeDirectoryURL: stateDirectory
        ).cleanUp()

        XCTAssertEqual(result, .cleaned)
        XCTAssertTrue(try store.loadLedger().entries.isEmpty)
    }

    func testProductionCleanupRemovesAnIntentWhoseOwnerIsGone() async throws {
        let currentBoot = try XCTUnwrap(AntigravitySystemBootSessionIdentityProvider().currentBootSessionID())
        let store = ledgerFileStore()
        try store.createIntent(try intent(boot: currentBoot))

        let result = await AntigravityLegacyManagedProcessCleanup.production(
            stateDirectory: stateDirectory, homeDirectoryURL: stateDirectory
        ).cleanUp()

        XCTAssertEqual(result, .cleaned)
        XCTAssertTrue(try store.loadLedger().entries.isEmpty)
    }

    func testProductionCleanupWithoutLedgerCreatesNothing() async {
        let result = await AntigravityLegacyManagedProcessCleanup.production(
            stateDirectory: stateDirectory, homeDirectoryURL: stateDirectory
        ).cleanUp()

        XCTAssertEqual(result, .nothingRecorded)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: stateDirectory.appendingPathComponent("managed-agy-sessions.json").path))
    }

    func testProductionCleanupRemovesTheOldSharedLaunchLock() async throws {
        let lockDirectory = AntigravityLegacyManagedProcessCleanup.launchLockDirectory(
            homeDirectoryURL: stateDirectory)
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: lockDirectory.appendingPathComponent(
                AntigravityLegacyManagedProcessCleanup.launchLockFileName
            ).path,
            contents: Data())

        _ = await AntigravityLegacyManagedProcessCleanup.production(
            stateDirectory: stateDirectory, homeDirectoryURL: stateDirectory
        ).cleanUp()

        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDirectory.deletingLastPathComponent().path))
    }

    func testLaunchLockRemovalKeepsUnknownFiles() throws {
        let lockDirectory = AntigravityLegacyManagedProcessCleanup.launchLockDirectory(
            homeDirectoryURL: stateDirectory)
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let lockURL = lockDirectory.appendingPathComponent(AntigravityLegacyManagedProcessCleanup.launchLockFileName)
        let unknownURL = lockDirectory.appendingPathComponent("other")
        FileManager.default.createFile(atPath: lockURL.path, contents: Data())
        FileManager.default.createFile(atPath: unknownURL.path, contents: Data())

        AntigravityLegacyManagedProcessCleanup.removeLaunchLock(in: lockDirectory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknownURL.path))
    }

    // MARK: - Helpers

    private func ledgerFileStore() -> AntigravityManagedProcessRecordFileStore {
        AntigravityManagedProcessRecordFileStore(
            fileURL: stateDirectory.appendingPathComponent("managed-agy-sessions.json"))
    }

    /// An intent owned by this test process's PID but a different kernel
    /// execution that starts in the future: its owner is provably gone and no
    /// running process can be its launch candidate.
    private func intent(boot: AntigravityBootSessionID) throws -> AntigravityManagedLaunchIntent {
        let future = Int64(Date().timeIntervalSince1970) + 86_400
        let owner = try XCTUnwrap(
            AntigravityRecordedProcessIdentity(
                pid: getpid(),
                effectiveUserID: geteuid(),
                realUserID: getuid(),
                startedAtSeconds: future,
                startedAtMicroseconds: 0,
                executablePath: "/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage",
                kernelIdentity: try XCTUnwrap(
                    AntigravityKernelProcessIdentity(uniqueID: UInt64.max - 1, parentUniqueID: 1, pidVersion: 1))
            ))
        let executable = try XCTUnwrap(
            AntigravityManagedExecutableDescriptor(role: .agyCLI, canonicalPath: "/Users/test/.local/bin/agy"))
        return try XCTUnwrap(
            AntigravityManagedLaunchIntent(
                sessionID: UUID(), bootSessionID: boot, owner: owner, executable: executable,
                createdAt: Date(timeIntervalSince1970: 1_900_000_000)))
    }
}

private actor RecordingRecovery: AntigravityManagedProcessRecovering {
    private let error: Error?
    private(set) var calls = 0

    init(error: Error? = nil) {
        self.error = error
    }

    func recoverOrphanedProcesses() async throws {
        calls += 1
        if let error { throw error }
    }
}

private struct FixedLedgerStore: AntigravityManagedProcessLedgerStoring {
    let snapshot: AntigravityManagedProcessLedgerSnapshot?

    func loadLedger() throws -> AntigravityManagedProcessLedgerSnapshot {
        guard let snapshot else { throw AntigravityManagedProcessRecordStoreError.invalidFile }
        return snapshot
    }

    func load() throws -> [AntigravityManagedProcessRecord] { try loadLedger().processRecords }
    func update(_ record: AntigravityManagedProcessRecord) throws { throw Unexpected.mutation }
    func remove(sessionID: UUID) throws { throw Unexpected.mutation }
    func createIntent(_ intent: AntigravityManagedLaunchIntent) throws { throw Unexpected.mutation }
    func promoteIntent(_ intent: AntigravityManagedLaunchIntent, to record: AntigravityManagedProcessRecord) throws {
        throw Unexpected.mutation
    }
    func removeIntent(_ intent: AntigravityManagedLaunchIntent) throws { throw Unexpected.mutation }
    func removeEntriesFromStaleBoot(_ bootSessionID: AntigravityBootSessionID) throws { throw Unexpected.mutation }

    private enum Unexpected: Error { case mutation }
}
