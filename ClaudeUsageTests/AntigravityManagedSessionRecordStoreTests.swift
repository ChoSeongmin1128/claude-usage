import Darwin
import XCTest
@testable import ClaudeUsage

final class AntigravityManagedSessionRecordStoreTests: XCTestCase {
    func testRoundTripAtomicallyPromotesIntentUpdatesAndRemovesRecord()
        throws
    {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let store = harness.store
        let sessionID = UUID()
        let initial = try makeRecord(sessionID: sessionID, childPID: 101)
        let intent = try makeIntent(for: initial)
        let replacement = try XCTUnwrap(
            initial.mergingObservation(
                descendants: [],
                scanWasComplete: true,
                observedAt:
                    initial.updatedAt.addingTimeInterval(1)
            )
        )

        try store.createIntent(intent)
        var snapshot = try store.loadLedger()
        XCTAssertEqual(snapshot.revision, 1)
        XCTAssertEqual(snapshot.launchIntents, [intent])
        XCTAssertEqual(snapshot.processRecords, [])

        try store.promoteIntent(intent, to: initial)
        snapshot = try store.loadLedger()
        XCTAssertEqual(snapshot.revision, 2)
        XCTAssertEqual(snapshot.launchIntents, [])
        XCTAssertEqual(snapshot.processRecords, [initial])

        try store.update(replacement)
        XCTAssertEqual(try store.load(), [replacement])
        XCTAssertEqual(try posixMode(at: harness.directoryURL), 0o700)
        XCTAssertEqual(try posixMode(at: harness.fileURL), 0o600)

        try store.remove(sessionID: sessionID)
        XCTAssertEqual(try store.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.fileURL.path))
    }

    func testSubmillisecondDatesAreCanonicalizedBeforeReadBackVerification()
        throws
    {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let inputDate = Date(
            timeIntervalSince1970: 1_785_083_173.308_400_2
        )
        let record = try makeRecord(createdAt: inputDate)
        let intent = try makeIntent(for: record)

        XCTAssertNotEqual(record.createdAt, inputDate)
        XCTAssertNoThrow(try harness.store.createIntent(intent))
        XCTAssertNoThrow(
            try harness.store.promoteIntent(intent, to: record)
        )
        XCTAssertEqual(try harness.store.load(), [record])
    }

    func testRecordValidationRejectsUnsafeIdentityAndProcessGroup() throws {
        XCTAssertNil(AntigravityRecordedProcessIdentity(
            pid: 0,
            effectiveUserID: 501,
            realUserID: 501,
            startedAtSeconds: 1,
            startedAtMicroseconds: 0,
            executablePath: "/usr/local/bin/agy",
            kernelIdentity: makeKernelIdentity(pid: 10)
        ))
        XCTAssertNil(AntigravityRecordedProcessIdentity(
            pid: 10,
            effectiveUserID: 501,
            realUserID: 501,
            startedAtSeconds: 1,
            startedAtMicroseconds: 0,
            executablePath: "/usr/local/../tmp/agy",
            kernelIdentity: makeKernelIdentity(pid: 10)
        ))

        let child = try XCTUnwrap(makeIdentity(pid: 10))
        let owner = try XCTUnwrap(makeIdentity(
            pid: 20,
            path: "/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage"
        ))
        XCTAssertNil(AntigravityManagedProcessRecord(
            sessionID: UUID(),
            bootSessionID: testBootSessionID,
            child: child,
            processGroupID: 0,
            owner: owner,
            createdAt: Date()
        ))
        XCTAssertNil(AntigravityManagedProcessRecord(
            sessionID: UUID(),
            bootSessionID: testBootSessionID,
            child: child,
            processGroupID: 10,
            owner: owner,
            createdAt: Date(timeIntervalSince1970: -1)
        ))
    }

    func testLoadRejectsSymlinkFileWithoutReadingTarget() throws {
        let harness = try StoreHarness(createDirectory: true)
        defer { harness.cleanup() }
        let target = harness.rootURL.appendingPathComponent("target.json")
        try Data("[]".utf8).write(to: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: target.path
        )
        try FileManager.default.createSymbolicLink(
            at: harness.fileURL,
            withDestinationURL: target
        )

        XCTAssertThrowsError(try harness.store.load()) { error in
            XCTAssertEqual(
                error as? AntigravityManagedProcessRecordStoreError,
                .invalidFile
            )
        }
    }

    func testLoadRejectsSymlinkDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "ClaudeUsageManagedRecordSymlinkTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let actual = root.appendingPathComponent("actual", isDirectory: true)
        let link = root.appendingPathComponent("Antigravity", isDirectory: true)
        try fileManager.createDirectory(
            at: actual,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createSymbolicLink(at: link, withDestinationURL: actual)
        let store = AntigravityManagedProcessRecordFileStore(
            fileURL: link.appendingPathComponent("managed-agy-sessions.json")
        )

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(
                error as? AntigravityManagedProcessRecordStoreError,
                .invalidDirectory
            )
        }
    }

    func testLoadRejectsInsecureFileAndDirectoryModes() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }
        let record = try makeRecord()
        let intent = try makeIntent(for: record)
        try harness.store.createIntent(intent)
        try harness.store.promoteIntent(intent, to: record)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: harness.fileURL.path
        )

        XCTAssertThrowsError(try harness.store.load()) { error in
            XCTAssertEqual(
                error as? AntigravityManagedProcessRecordStoreError,
                .invalidFilePermissions
            )
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: harness.fileURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: harness.directoryURL.path
        )
        XCTAssertThrowsError(try harness.store.load()) { error in
            XCTAssertEqual(
                error as? AntigravityManagedProcessRecordStoreError,
                .invalidDirectoryPermissions
            )
        }
    }

    func testCreateIntentHardensSameUserDirectoryBeforeWriting() throws {
        let harness = try StoreHarness(createDirectory: true)
        defer { harness.cleanup() }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: harness.directoryURL.path
        )

        try harness.store.createIntent(
            makeIntent(for: makeRecord())
        )

        XCTAssertEqual(try posixMode(at: harness.directoryURL), 0o700)
        XCTAssertEqual(try posixMode(at: harness.fileURL), 0o600)
    }

    func testScavengerSkipsActiveWriterThenRemovesAbandonedTemporaryFile()
        throws
    {
        let harness = try StoreHarness(createDirectory: true)
        defer { harness.cleanup() }
        let temporaryURL = harness.directoryURL.appendingPathComponent(
            ".managed-agy-sessions."
                + UUID().uuidString.lowercased()
                + ".tmp"
        )
        var descriptor = open(
            temporaryURL.path,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o600)
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer {
            if descriptor >= 0 {
                _ = flock(descriptor, LOCK_UN)
                close(descriptor)
            }
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        let record = try makeRecord()
        let intent = try makeIntent(for: record)
        try harness.store.createIntent(intent)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: temporaryURL.path
            ),
            "A writer-owned temporary inode must not be unlinked"
        )

        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        close(descriptor)
        descriptor = -1
        try harness.store.promoteIntent(intent, to: record)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: temporaryURL.path
            ),
            "An unlocked crash leftover must be scavenged"
        )
    }

    func testObservationMergeReplacesExecIdentityAndIncompleteIsSticky()
        throws
    {
        let record = try makeRecord()
        let childUniqueID = record.child.kernelIdentity.uniqueID
        let descendant = try XCTUnwrap(
            makeIdentity(
                pid: 201,
                path: "/usr/bin/helper",
                uniqueID: 20_001,
                parentUniqueID: childUniqueID,
                pidVersion: 301
            )
        )
        let first = try XCTUnwrap(
            record.mergingObservation(
                descendants: [descendant],
                scanWasComplete: true,
                observedAt: record.createdAt.addingTimeInterval(1)
            )
        )
        XCTAssertEqual(first.observationCompleteness, .complete)
        XCTAssertEqual(first.observedDescendants, [descendant])

        let execed = try XCTUnwrap(
            makeIdentity(
                pid: descendant.pid,
                path: "/usr/bin/other-helper",
                uniqueID: descendant.kernelIdentity.uniqueID,
                parentUniqueID:
                    descendant.kernelIdentity.parentUniqueID,
                pidVersion:
                    descendant.kernelIdentity.pidVersion + 1
            )
        )
        let replaced = try XCTUnwrap(
            first.mergingObservation(
                descendants: [execed],
                scanWasComplete: false,
                observedAt: first.updatedAt.addingTimeInterval(1)
            )
        )
        XCTAssertEqual(
            replaced.observationCompleteness,
            .incomplete
        )
        XCTAssertEqual(replaced.observedDescendants, [execed])

        let laterComplete = try XCTUnwrap(
            replaced.mergingObservation(
                descendants: [],
                scanWasComplete: true,
                observedAt:
                    replaced.updatedAt.addingTimeInterval(1)
            )
        )
        XCTAssertEqual(
            laterComplete.observationCompleteness,
            .incomplete
        )
    }

    func testLoadRejectsOversizedAndUnsupportedSchemaFiles() throws {
        let oversizedHarness = try StoreHarness(createDirectory: true)
        defer { oversizedHarness.cleanup() }
        try Data(
            repeating: 0x41,
            count: AntigravityManagedProcessRecordFileStore.maximumFileBytes + 1
        ).write(to: oversizedHarness.fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: oversizedHarness.fileURL.path
        )

        XCTAssertThrowsError(try oversizedHarness.store.load()) { error in
            XCTAssertEqual(
                error as? AntigravityManagedProcessRecordStoreError,
                .fileTooLarge
            )
        }

        let schemaHarness = try StoreHarness(createDirectory: true)
        defer { schemaHarness.cleanup() }
        let record = try makeRecord()
        try schemaHarness.store.createIntent(
            makeIntent(for: record)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: schemaHarness.fileURL
                )
            ) as? [String: Any]
        )
        object["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: object)
            .write(to: schemaHarness.fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: schemaHarness.fileURL.path
        )

        XCTAssertThrowsError(try schemaHarness.store.load()) { error in
            XCTAssertEqual(
                error as? AntigravityManagedProcessRecordStoreError,
                .unsupportedSchema(99)
            )
        }

        let legacyHarness = try StoreHarness(createDirectory: true)
        defer { legacyHarness.cleanup() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode([record]).write(
            to: legacyHarness.fileURL
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: legacyHarness.fileURL.path
        )
        XCTAssertThrowsError(
            try legacyHarness.store.loadLedger()
        ) { error in
            XCTAssertEqual(
                error as? AntigravityManagedProcessRecordStoreError,
                .unsupportedSchema(1)
            )
        }
    }

    private func makeRecord(
        sessionID: UUID = UUID(),
        childPID: Int32 = 101,
        createdAt: Date =
            Date(timeIntervalSince1970: 1_700_000_000.125)
    ) throws -> AntigravityManagedProcessRecord {
        let owner = try XCTUnwrap(makeIdentity(
            pid: 99,
            path:
                "/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage"
        ))
        return try XCTUnwrap(AntigravityManagedProcessRecord(
            sessionID: sessionID,
            bootSessionID: testBootSessionID,
            child: XCTUnwrap(makeIdentity(
                pid: childPID,
                parentUniqueID:
                    owner.kernelIdentity.uniqueID
            )),
            processGroupID: childPID,
            owner: owner,
            createdAt: createdAt
        ))
    }

    private func makeIntent(
        for record: AntigravityManagedProcessRecord
    ) throws -> AntigravityManagedLaunchIntent {
        try XCTUnwrap(AntigravityManagedLaunchIntent(
            sessionID: record.sessionID,
            bootSessionID: record.bootSessionID,
            owner: record.owner,
            executable: XCTUnwrap(
                AntigravityManagedExecutableDescriptor(
                    role: .agyCLI,
                    canonicalPath: record.child.executablePath
                )
            ),
            createdAt: record.createdAt
        ))
    }

    private var testBootSessionID: AntigravityBootSessionID {
        AntigravityBootSessionID(
            rawValue: UUID(
                uuidString:
                    "00000000-0000-0000-0000-000000000601"
            )!
        )
    }

    private func makeIdentity(
        pid: Int32,
        path: String = "/usr/local/bin/agy",
        uniqueID: UInt64? = nil,
        parentUniqueID: UInt64 = 9_999,
        pidVersion: Int32? = nil
    ) -> AntigravityRecordedProcessIdentity? {
        AntigravityRecordedProcessIdentity(
            pid: pid,
            effectiveUserID: UInt32(geteuid()),
            realUserID: UInt32(getuid()),
            startedAtSeconds: 1_700_000_000,
            startedAtMicroseconds: 125_000,
            executablePath: path,
            kernelIdentity: AntigravityKernelProcessIdentity(
                uniqueID: uniqueID ?? UInt64(pid) + 10_000,
                parentUniqueID: parentUniqueID,
                pidVersion: pidVersion ?? pid + 100
            )!
        )
    }

    private func makeKernelIdentity(
        pid: Int32
    ) -> AntigravityKernelProcessIdentity {
        AntigravityKernelProcessIdentity(
            uniqueID: UInt64(pid) + 10_000,
            parentUniqueID: 9_999,
            pidVersion: pid + 100
        )!
    }

    private func posixMode(at url: URL) throws -> Int {
        let value = try FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions]
        return try XCTUnwrap(
            (value as? NSNumber)?.intValue ?? value as? Int
        )
    }
}

private final class StoreHarness {
    let rootURL: URL
    let directoryURL: URL
    let fileURL: URL
    let store: AntigravityManagedProcessRecordFileStore

    init(createDirectory: Bool = false) throws {
        let fileManager = FileManager.default
        rootURL = fileManager.temporaryDirectory
            .appendingPathComponent(
                "ClaudeUsageManagedRecordStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        directoryURL = rootURL
            .appendingPathComponent("Antigravity", isDirectory: true)
        fileURL = directoryURL
            .appendingPathComponent("managed-agy-sessions.json")
        if createDirectory {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        store = AntigravityManagedProcessRecordFileStore(fileURL: fileURL)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
