import Darwin
import Foundation

/// Kernel-issued process identity used to close PID-reuse races.
///
/// `uniqueID` and `parentUniqueID` come from
/// `PROC_PIDUNIQIDENTIFIERINFO`. `pidVersion` is the value validated by
/// `proc_signal_with_audittoken` inside the kernel before a signal is sent.
nonisolated struct AntigravityKernelProcessIdentity:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let uniqueID: UInt64
    let parentUniqueID: UInt64
    let pidVersion: Int32

    init?(
        uniqueID: UInt64,
        parentUniqueID: UInt64,
        pidVersion: Int32
    ) {
        guard uniqueID > 0,
              parentUniqueID > 0,
              pidVersion != 0 else {
            return nil
        }
        self.uniqueID = uniqueID
        self.parentUniqueID = parentUniqueID
        self.pidVersion = pidVersion
    }
}

nonisolated struct AntigravityRecordedProcessIdentity:
    Codable,
    Equatable,
    Sendable
{
    let pid: Int32
    let effectiveUserID: UInt32
    let realUserID: UInt32
    let startedAtSeconds: Int64
    let startedAtMicroseconds: Int32
    let executablePath: String
    let kernelIdentity: AntigravityKernelProcessIdentity

    init?(
        pid: Int32,
        effectiveUserID: UInt32,
        realUserID: UInt32,
        startedAtSeconds: Int64,
        startedAtMicroseconds: Int32,
        executablePath: String,
        kernelIdentity: AntigravityKernelProcessIdentity
    ) {
        guard pid > 1,
              startedAtSeconds >= 0,
              (0..<1_000_000).contains(startedAtMicroseconds),
              Self.isCanonicalAbsolutePath(executablePath)
        else {
            return nil
        }
        self.pid = pid
        self.effectiveUserID = effectiveUserID
        self.realUserID = realUserID
        self.startedAtSeconds = startedAtSeconds
        self.startedAtMicroseconds = startedAtMicroseconds
        self.executablePath = executablePath
        self.kernelIdentity = kernelIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case pid
        case effectiveUserID
        case realUserID
        case startedAtSeconds
        case startedAtMicroseconds
        case executablePath
        case kernelIdentity
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let identity = Self(
            pid: try container.decode(Int32.self, forKey: .pid),
            effectiveUserID: try container.decode(
                UInt32.self,
                forKey: .effectiveUserID
            ),
            realUserID: try container.decode(
                UInt32.self,
                forKey: .realUserID
            ),
            startedAtSeconds: try container.decode(
                Int64.self,
                forKey: .startedAtSeconds
            ),
            startedAtMicroseconds: try container.decode(
                Int32.self,
                forKey: .startedAtMicroseconds
            ),
            executablePath: try container.decode(
                String.self,
                forKey: .executablePath
            ),
            kernelIdentity: try container.decode(
                AntigravityKernelProcessIdentity.self,
                forKey: .kernelIdentity
            )
        ) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid recorded process identity"
                )
            )
        }
        self = identity
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              !path.contains("\0"),
              path.utf8.count <= Int(PATH_MAX)
        else {
            return false
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path == path
    }
}

nonisolated extension AntigravityRecordedProcessIdentity {
    /// Invariants that survive `exec(2)`. The executable path and pidversion
    /// may change across exec; changing any field below means this is not
    /// safely the same process lineage.
    func hasStableExecutionInvariants(
        as other: AntigravityRecordedProcessIdentity
    ) -> Bool {
        pid == other.pid
            && effectiveUserID == other.effectiveUserID
            && realUserID == other.realUserID
            && startedAtSeconds == other.startedAtSeconds
            && startedAtMicroseconds
                == other.startedAtMicroseconds
            && kernelIdentity.uniqueID
                == other.kernelIdentity.uniqueID
            && kernelIdentity.parentUniqueID
                == other.kernelIdentity.parentUniqueID
    }
}

nonisolated enum AntigravityManagedProcessObservationCompleteness:
    String,
    Codable,
    Equatable,
    Sendable
{
    /// The root record was written before the first descendant snapshot.
    case rootOnly

    /// Every process visible in the bounded snapshot was classified.
    case complete

    /// At least one scan was unavailable, ambiguous, or exceeded the bound.
    /// This is sticky because an unobserved process may already have escaped.
    case incomplete
}

nonisolated struct AntigravityManagedProcessRecord:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion = 2
    static let maximumObservedDescendantCount = 64

    let schemaVersion: Int
    let sessionID: UUID
    let bootSessionID: AntigravityBootSessionID
    let child: AntigravityRecordedProcessIdentity
    let processGroupID: Int32
    let owner: AntigravityRecordedProcessIdentity
    let observedDescendants: [AntigravityRecordedProcessIdentity]
    let observationCompleteness:
        AntigravityManagedProcessObservationCompleteness
    let createdAt: Date
    let updatedAt: Date

    init?(
        schemaVersion: Int = Self.currentSchemaVersion,
        sessionID: UUID,
        bootSessionID: AntigravityBootSessionID,
        child: AntigravityRecordedProcessIdentity,
        processGroupID: Int32,
        owner: AntigravityRecordedProcessIdentity,
        observedDescendants:
            [AntigravityRecordedProcessIdentity] = [],
        observationCompleteness:
            AntigravityManagedProcessObservationCompleteness =
                .rootOnly,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        let resolvedUpdatedAt = updatedAt ?? createdAt
        let descendantUniqueIDs = Set(
            observedDescendants.map(\.kernelIdentity.uniqueID)
        )
        guard schemaVersion == Self.currentSchemaVersion,
              processGroupID > 1,
              child.pid == processGroupID,
              observedDescendants.count
                <= Self.maximumObservedDescendantCount,
              descendantUniqueIDs.count == observedDescendants.count,
              !descendantUniqueIDs.contains(
                  child.kernelIdentity.uniqueID
              ),
              createdAt.timeIntervalSince1970.isFinite,
              createdAt.timeIntervalSince1970 >= 0,
              resolvedUpdatedAt.timeIntervalSince1970.isFinite,
              resolvedUpdatedAt >= createdAt,
              let persistedCreatedAt =
                  Self.persistedDate(createdAt),
              let persistedUpdatedAt =
                  Self.persistedDate(resolvedUpdatedAt)
        else {
            return nil
        }
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.bootSessionID = bootSessionID
        self.child = child
        self.processGroupID = processGroupID
        self.owner = owner
        self.observedDescendants = observedDescendants.sorted {
            if $0.kernelIdentity.uniqueID
                != $1.kernelIdentity.uniqueID {
                return $0.kernelIdentity.uniqueID
                    < $1.kernelIdentity.uniqueID
            }
            return $0.pid < $1.pid
        }
        self.observationCompleteness = observationCompleteness
        self.createdAt = persistedCreatedAt
        self.updatedAt = persistedUpdatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sessionID
        case bootSessionID
        case child
        case processGroupID
        case owner
        case observedDescendants
        case observationCompleteness
        case createdAt
        case updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AntigravityManagedProcessRecordStoreError.unsupportedSchema(
                schemaVersion
            )
        }
        guard let record = Self(
            schemaVersion: schemaVersion,
            sessionID: try container.decode(UUID.self, forKey: .sessionID),
            bootSessionID: try container.decode(
                AntigravityBootSessionID.self,
                forKey: .bootSessionID
            ),
            child: try container.decode(
                AntigravityRecordedProcessIdentity.self,
                forKey: .child
            ),
            processGroupID: try container.decode(
                Int32.self,
                forKey: .processGroupID
            ),
            owner: try container.decode(
                AntigravityRecordedProcessIdentity.self,
                forKey: .owner
            ),
            observedDescendants:
                try container.decodeIfPresent(
                    [AntigravityRecordedProcessIdentity].self,
                    forKey: .observedDescendants
                ) ?? [],
            observationCompleteness:
                try container.decodeIfPresent(
                    AntigravityManagedProcessObservationCompleteness.self,
                    forKey: .observationCompleteness
                ) ?? .rootOnly,
            createdAt: try container.decode(
                Date.self,
                forKey: .createdAt
            ),
            updatedAt: try container.decodeIfPresent(
                Date.self,
                forKey: .updatedAt
            )
        ) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid managed process record"
                )
            )
        }
        self = record
    }

    func mergingObservation(
        rootExecution:
            AntigravityRecordedProcessIdentity? = nil,
        descendants: [AntigravityRecordedProcessIdentity],
        scanWasComplete: Bool,
        observedAt: Date
    ) -> AntigravityManagedProcessRecord? {
        let nextChild: AntigravityRecordedProcessIdentity
        if let rootExecution {
            guard rootExecution.hasStableExecutionInvariants(
                as: child
            ) else {
                return nil
            }
            nextChild = rootExecution
        } else {
            nextChild = child
        }

        var identitiesByUniqueID = Dictionary(
            uniqueKeysWithValues: observedDescendants.map {
                ($0.kernelIdentity.uniqueID, $0)
            }
        )
        for descendant in descendants
        where descendant.kernelIdentity.uniqueID
            != nextChild.kernelIdentity.uniqueID {
            if let persisted = identitiesByUniqueID[
                descendant.kernelIdentity.uniqueID
            ],
            !descendant.hasStableExecutionInvariants(as: persisted) {
                return nil
            }
            identitiesByUniqueID[
                descendant.kernelIdentity.uniqueID
            ] = descendant
        }

        let sorted = identitiesByUniqueID.values.sorted {
            if $0.kernelIdentity.uniqueID
                != $1.kernelIdentity.uniqueID {
                return $0.kernelIdentity.uniqueID
                    < $1.kernelIdentity.uniqueID
            }
            return $0.pid < $1.pid
        }
        let exceededBound =
            sorted.count > Self.maximumObservedDescendantCount
        let nextCompleteness:
            AntigravityManagedProcessObservationCompleteness
        if observationCompleteness == .incomplete
            || !scanWasComplete
            || exceededBound {
            nextCompleteness = .incomplete
        } else {
            nextCompleteness = .complete
        }

        let boundedDescendants = Array(
            sorted.prefix(Self.maximumObservedDescendantCount)
        )
        if nextChild == child,
           boundedDescendants == observedDescendants,
           nextCompleteness == observationCompleteness {
            return self
        }

        return Self(
            schemaVersion: schemaVersion,
            sessionID: sessionID,
            bootSessionID: bootSessionID,
            child: nextChild,
            processGroupID: processGroupID,
            owner: owner,
            observedDescendants: boundedDescendants,
            observationCompleteness: nextCompleteness,
            createdAt: createdAt,
            updatedAt: max(updatedAt, observedAt)
        )
    }

    /// Disk records use millisecond timestamps. `Date()` normally carries
    /// finer precision, which otherwise makes a successful JSON round trip
    /// fail the store's exact read-back verification.
    private static func persistedDate(_ date: Date) -> Date? {
        let milliseconds = (
            date.timeIntervalSince1970 * 1_000
        ).rounded(.towardZero)
        guard milliseconds.isFinite else { return nil }
        return Date(
            timeIntervalSince1970: milliseconds / 1_000
        )
    }
}

nonisolated enum AntigravityManagedProcessLedgerEntry:
    Codable,
    Equatable,
    Sendable
{
    case launchIntent(AntigravityManagedLaunchIntent)
    case processRecord(AntigravityManagedProcessRecord)

    private enum Kind: String, Codable {
        case launchIntent
        case processRecord
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case launchIntent
        case processRecord
    }

    var sessionID: UUID {
        switch self {
        case .launchIntent(let intent):
            intent.sessionID
        case .processRecord(let record):
            record.sessionID
        }
    }

    var bootSessionID: AntigravityBootSessionID {
        switch self {
        case .launchIntent(let intent):
            intent.bootSessionID
        case .processRecord(let record):
            record.bootSessionID
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        switch try container.decode(Kind.self, forKey: .kind) {
        case .launchIntent:
            self = .launchIntent(try container.decode(
                AntigravityManagedLaunchIntent.self,
                forKey: .launchIntent
            ))
        case .processRecord:
            self = .processRecord(try container.decode(
                AntigravityManagedProcessRecord.self,
                forKey: .processRecord
            ))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(
            keyedBy: CodingKeys.self
        )
        switch self {
        case .launchIntent(let intent):
            try container.encode(
                Kind.launchIntent,
                forKey: .kind
            )
            try container.encode(
                intent,
                forKey: .launchIntent
            )
        case .processRecord(let record):
            try container.encode(
                Kind.processRecord,
                forKey: .kind
            )
            try container.encode(
                record,
                forKey: .processRecord
            )
        }
    }
}

nonisolated struct AntigravityManagedProcessLedgerSnapshot:
    Equatable,
    Sendable
{
    let bootSessionID: AntigravityBootSessionID?
    let revision: UInt64
    let entries: [AntigravityManagedProcessLedgerEntry]

    static let empty = Self(
        bootSessionID: nil,
        revision: 0,
        entries: []
    )

    var launchIntents: [AntigravityManagedLaunchIntent] {
        entries.compactMap {
            guard case .launchIntent(let intent) = $0 else {
                return nil
            }
            return intent
        }
    }

    var processRecords: [AntigravityManagedProcessRecord] {
        entries.compactMap {
            guard case .processRecord(let record) = $0 else {
                return nil
            }
            return record
        }
    }
}

private nonisolated struct AntigravityManagedProcessLedgerEnvelope:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let bootSessionID: AntigravityBootSessionID
    let revision: UInt64
    let entries: [AntigravityManagedProcessLedgerEntry]

    init?(
        schemaVersion: Int = Self.currentSchemaVersion,
        bootSessionID: AntigravityBootSessionID,
        revision: UInt64,
        entries: [AntigravityManagedProcessLedgerEntry]
    ) {
        let sorted = entries.sorted {
            $0.sessionID.uuidString < $1.sessionID.uuidString
        }
        let sessionIDs = Set(sorted.map(\.sessionID))
        guard schemaVersion == Self.currentSchemaVersion,
              revision > 0,
              sorted.count <=
                AntigravityManagedProcessRecordFileStore.maximumEntryCount,
              sessionIDs.count == sorted.count,
              sorted.allSatisfy({
                  $0.bootSessionID == bootSessionID
              }) else {
            return nil
        }
        self.schemaVersion = schemaVersion
        self.bootSessionID = bootSessionID
        self.revision = revision
        self.entries = sorted
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case bootSessionID
        case revision
        case entries
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        let schemaVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AntigravityManagedProcessRecordStoreError
                .unsupportedSchema(schemaVersion)
        }
        guard let envelope = Self(
            schemaVersion: schemaVersion,
            bootSessionID: try container.decode(
                AntigravityBootSessionID.self,
                forKey: .bootSessionID
            ),
            revision: try container.decode(
                UInt64.self,
                forKey: .revision
            ),
            entries: try container.decode(
                [AntigravityManagedProcessLedgerEntry].self,
                forKey: .entries
            )
        ) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Invalid managed process ledger envelope"
                )
            )
        }
        self = envelope
    }
}

protocol AntigravityManagedProcessRecordStoring: Sendable {
    nonisolated func load() throws -> [AntigravityManagedProcessRecord]
    nonisolated func update(
        _ record: AntigravityManagedProcessRecord
    ) throws
    nonisolated func remove(sessionID: UUID) throws
}

protocol AntigravityManagedProcessLedgerStoring:
    AntigravityManagedProcessRecordStoring
{
    nonisolated func loadLedger()
        throws -> AntigravityManagedProcessLedgerSnapshot
    nonisolated func createIntent(
        _ intent: AntigravityManagedLaunchIntent
    ) throws
    nonisolated func promoteIntent(
        _ intent: AntigravityManagedLaunchIntent,
        to record: AntigravityManagedProcessRecord
    ) throws
    nonisolated func removeIntent(
        _ intent: AntigravityManagedLaunchIntent
    ) throws
    nonisolated func removeEntriesFromStaleBoot(
        _ bootSessionID: AntigravityBootSessionID
    ) throws
}

nonisolated enum AntigravityManagedProcessRecordStoreError:
    Error,
    Equatable
{
    case invalidDirectory
    case invalidDirectoryOwner
    case invalidDirectoryPermissions
    case invalidFile
    case invalidFileOwner
    case invalidFilePermissions
    case fileTooLarge
    case tooManyRecords
    case duplicateSessionID
    case bootSessionMismatch
    case revisionOverflow
    case entryNotFound
    case entryAlreadyExists
    case invalidTransition
    case unsupportedSchema(Int)
    case verificationFailed
    case posix(Int32)
}

/// Persists only ClaudeUsage-owned AGY process identities.
///
/// Reads and writes are anchored to an opened private directory descriptor.
/// Symlinks and non-regular files are rejected, and replacement happens with a
/// same-directory `renameat` so readers see either the old or new full JSON.
nonisolated final class AntigravityManagedProcessRecordFileStore:
    AntigravityManagedProcessLedgerStoring,
    @unchecked Sendable
{
    static let maximumFileBytes = 256 * 1_024
    static let maximumEntryCount = 64

    let fileURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()
    private let expectedUserID: uid_t

    init(
        fileURL: URL = AntigravityStoragePaths
            .canonicalStateDirectoryURL()
            .appendingPathComponent("managed-agy-sessions.json"),
        fileManager: FileManager = .default,
        expectedUserID: uid_t = geteuid()
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.expectedUserID = expectedUserID
    }

    nonisolated func load() throws -> [AntigravityManagedProcessRecord] {
        try loadLedger().processRecords
    }

    nonisolated func loadLedger()
        throws -> AntigravityManagedProcessLedgerSnapshot
    {
        try lock.withLock {
            try loadLedgerLocked()
        }
    }

    nonisolated func createIntent(
        _ intent: AntigravityManagedLaunchIntent
    ) throws {
        try lock.withLock {
            try prepareDirectoryForMutation()
            let snapshot = try loadLedgerLocked()
            guard snapshot.entries.isEmpty else {
                throw AntigravityManagedProcessRecordStoreError
                    .entryAlreadyExists
            }
            guard snapshot.bootSessionID == nil
                    || snapshot.bootSessionID
                        == intent.bootSessionID else {
                throw AntigravityManagedProcessRecordStoreError
                    .bootSessionMismatch
            }
            try writeLocked(try makeEnvelope(
                bootSessionID: intent.bootSessionID,
                previousRevision: snapshot.revision,
                entries: [.launchIntent(intent)]
            ))
        }
    }

    nonisolated func promoteIntent(
        _ intent: AntigravityManagedLaunchIntent,
        to record: AntigravityManagedProcessRecord
    ) throws {
        try lock.withLock {
            let snapshot = try loadLedgerLocked()
            guard snapshot.bootSessionID
                    == intent.bootSessionID,
                  record.bootSessionID
                    == intent.bootSessionID,
                  record.sessionID == intent.sessionID,
                  record.owner == intent.owner,
                  record.child.effectiveUserID
                    == intent.owner.effectiveUserID,
                  record.child.realUserID
                    == intent.owner.realUserID,
                  record.child.kernelIdentity.parentUniqueID
                    == intent.owner.kernelIdentity.uniqueID,
                  record.child.executablePath
                    == intent.executable.canonicalPath,
                  record.child.pid == record.processGroupID else {
                throw AntigravityManagedProcessRecordStoreError
                    .invalidTransition
            }
            guard let entryIndex = snapshot.entries.firstIndex(
                of: .launchIntent(intent)
            ) else {
                throw AntigravityManagedProcessRecordStoreError
                    .entryNotFound
            }
            var entries = snapshot.entries
            entries[entryIndex] = .processRecord(record)
            try writeLocked(try makeEnvelope(
                bootSessionID: intent.bootSessionID,
                previousRevision: snapshot.revision,
                entries: entries
            ))
        }
    }

    nonisolated func update(
        _ record: AntigravityManagedProcessRecord
    ) throws {
        try lock.withLock {
            let snapshot = try loadLedgerLocked()
            guard snapshot.bootSessionID
                    == record.bootSessionID,
                  let entryIndex = snapshot.entries.firstIndex(
                      where: {
                          guard case .processRecord(let existing) = $0
                          else {
                              return false
                          }
                          return existing.sessionID == record.sessionID
                      }
                  ),
                  case .processRecord(let existing) =
                    snapshot.entries[entryIndex],
                  existing.bootSessionID == record.bootSessionID,
                  existing.owner == record.owner,
                  record.child.hasStableExecutionInvariants(
                      as: existing.child
                  ) else {
                throw AntigravityManagedProcessRecordStoreError
                    .invalidTransition
            }
            var entries = snapshot.entries
            entries[entryIndex] = .processRecord(record)
            try writeLocked(try makeEnvelope(
                bootSessionID: record.bootSessionID,
                previousRevision: snapshot.revision,
                entries: entries
            ))
        }
    }

    nonisolated func remove(sessionID: UUID) throws {
        try lock.withLock {
            let snapshot = try loadLedgerLocked()
            let entries = snapshot.entries.filter {
                guard case .processRecord(let record) = $0 else {
                    return true
                }
                return record.sessionID != sessionID
            }
            guard entries.count != snapshot.entries.count else {
                return
            }
            try writeOrRemoveLocked(
                bootSessionID: snapshot.bootSessionID,
                previousRevision: snapshot.revision,
                entries: entries
            )
        }
    }

    nonisolated func removeIntent(
        _ intent: AntigravityManagedLaunchIntent
    ) throws {
        try lock.withLock {
            let snapshot = try loadLedgerLocked()
            guard snapshot.bootSessionID == intent.bootSessionID else {
                throw AntigravityManagedProcessRecordStoreError
                    .bootSessionMismatch
            }
            let entries = snapshot.entries.filter {
                $0 != .launchIntent(intent)
            }
            guard entries.count != snapshot.entries.count else {
                throw AntigravityManagedProcessRecordStoreError
                    .entryNotFound
            }
            try writeOrRemoveLocked(
                bootSessionID: snapshot.bootSessionID,
                previousRevision: snapshot.revision,
                entries: entries
            )
        }
    }

    nonisolated func removeEntriesFromStaleBoot(
        _ bootSessionID: AntigravityBootSessionID
    ) throws {
        try lock.withLock {
            let snapshot = try loadLedgerLocked()
            guard let persisted = snapshot.bootSessionID else {
                return
            }
            guard persisted == bootSessionID else {
                throw AntigravityManagedProcessRecordStoreError
                    .bootSessionMismatch
            }
            try removeLedgerFileLocked()
        }
    }

    private func prepareDirectoryForMutation() throws {
        // A same-user directory from an older build may be too permissive.
        // Validate its identity before tightening it, then read any state.
        let directoryFD = try ensurePrivateDirectory()
        close(directoryFD)
    }

    private func loadLedgerLocked()
        throws -> AntigravityManagedProcessLedgerSnapshot
    {
        guard let directoryFD = try openDirectoryForLoad() else {
            return .empty
        }
        defer { close(directoryFD) }

        let descriptor = openat(
            directoryFD,
            fileURL.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return .empty }
            if errno == ELOOP {
                throw AntigravityManagedProcessRecordStoreError
                    .invalidFile
            }
            throw Self.posixError()
        }
        defer { close(descriptor) }

        let data = try readAndValidateFile(descriptor)
        if data.drop(while: Self.isJSONWhitespace).first == 0x5B {
            // Stage 5 record arrays never shipped and carry no exact boot
            // identity. Never upgrade their signal authority heuristically.
            throw AntigravityManagedProcessRecordStoreError
                .unsupportedSchema(1)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope = try decoder.decode(
            AntigravityManagedProcessLedgerEnvelope.self,
            from: data
        )
        try validateEnvelope(envelope)
        return AntigravityManagedProcessLedgerSnapshot(
            bootSessionID: envelope.bootSessionID,
            revision: envelope.revision,
            entries: envelope.entries
        )
    }

    private func makeEnvelope(
        bootSessionID: AntigravityBootSessionID,
        previousRevision: UInt64,
        entries: [AntigravityManagedProcessLedgerEntry]
    ) throws -> AntigravityManagedProcessLedgerEnvelope {
        guard previousRevision < UInt64.max else {
            throw AntigravityManagedProcessRecordStoreError
                .revisionOverflow
        }
        guard let envelope =
                AntigravityManagedProcessLedgerEnvelope(
                    bootSessionID: bootSessionID,
                    revision: previousRevision + 1,
                    entries: entries
                ) else {
            throw AntigravityManagedProcessRecordStoreError
                .verificationFailed
        }
        return envelope
    }

    private func writeOrRemoveLocked(
        bootSessionID: AntigravityBootSessionID?,
        previousRevision: UInt64,
        entries: [AntigravityManagedProcessLedgerEntry]
    ) throws {
        guard !entries.isEmpty else {
            try removeLedgerFileLocked()
            return
        }
        guard let bootSessionID else {
            throw AntigravityManagedProcessRecordStoreError
                .bootSessionMismatch
        }
        try writeLocked(try makeEnvelope(
            bootSessionID: bootSessionID,
            previousRevision: previousRevision,
            entries: entries
        ))
    }

    private func removeLedgerFileLocked() throws {
        guard let directoryFD = try openDirectoryForLoad() else {
            return
        }
        defer { close(directoryFD) }
        try removeAbandonedTemporaryFiles(
            in: directoryFD
        )
        try validateExistingFile(in: directoryFD)
        guard unlinkat(
            directoryFD,
            fileURL.lastPathComponent,
            0
        ) == 0 else {
            if errno == ENOENT { return }
            throw Self.posixError()
        }
        try Self.sync(directoryFD)
    }

    private func writeLocked(
        _ envelope: AntigravityManagedProcessLedgerEnvelope
    ) throws {
        try validateEnvelope(envelope)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maximumFileBytes else {
            throw AntigravityManagedProcessRecordStoreError.fileTooLarge
        }

        let directoryFD = try ensurePrivateDirectory()
        defer { close(directoryFD) }
        try validateExistingFileIfPresent(in: directoryFD)
        try removeAbandonedTemporaryFiles(
            in: directoryFD
        )

        let temporaryName =
            ".managed-agy-sessions.\(UUID().uuidString.lowercased()).tmp"
        let temporaryFD = openat(
            directoryFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard temporaryFD >= 0 else { throw Self.posixError() }
        guard flock(
            temporaryFD,
            LOCK_EX | LOCK_NB
        ) == 0 else {
            let code = errno
            close(temporaryFD)
            _ = unlinkat(directoryFD, temporaryName, 0)
            throw AntigravityManagedProcessRecordStoreError
                .posix(code)
        }

        var shouldRemoveTemporary = true
        defer {
            close(temporaryFD)
            if shouldRemoveTemporary {
                _ = unlinkat(directoryFD, temporaryName, 0)
            }
        }

        try writeAll(data, to: temporaryFD)
        guard fchmod(temporaryFD, mode_t(0o600)) == 0 else {
            throw Self.posixError()
        }
        try Self.sync(temporaryFD)
        try validateMetadata(
            descriptor: temporaryFD,
            expectedKind: S_IFREG,
            expectedPermissions: 0o600,
            requireSingleLink: true
        )

        guard renameat(
            directoryFD,
            temporaryName,
            directoryFD,
            fileURL.lastPathComponent
        ) == 0 else {
            throw Self.posixError()
        }
        shouldRemoveTemporary = false
        try Self.sync(directoryFD)

        let persisted = try loadLedgerLocked()
        guard persisted.bootSessionID == envelope.bootSessionID,
              persisted.revision == envelope.revision,
              persisted.entries == envelope.entries else {
            throw AntigravityManagedProcessRecordStoreError
                .verificationFailed
        }
    }

    private func validateEnvelope(
        _ envelope: AntigravityManagedProcessLedgerEnvelope
    ) throws {
        guard envelope.entries.count <= Self.maximumEntryCount else {
            throw AntigravityManagedProcessRecordStoreError.tooManyRecords
        }
        let sessionIDs = Set(envelope.entries.map(\.sessionID))
        guard sessionIDs.count == envelope.entries.count else {
            throw AntigravityManagedProcessRecordStoreError
                .duplicateSessionID
        }
        guard envelope.entries.allSatisfy({
            $0.bootSessionID == envelope.bootSessionID
        }) else {
            throw AntigravityManagedProcessRecordStoreError
                .bootSessionMismatch
        }
        guard envelope.entries.allSatisfy({
            guard case .processRecord(let record) = $0 else {
                return true
            }
            return record.schemaVersion
                == AntigravityManagedProcessRecord.currentSchemaVersion
        }) else {
            throw AntigravityManagedProcessRecordStoreError
                .verificationFailed
        }
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09
            || byte == 0x0A || byte == 0x0D
    }

    private func openDirectoryForLoad() throws -> Int32? {
        let descriptor = open(
            fileURL.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP || errno == ENOTDIR {
                throw AntigravityManagedProcessRecordStoreError.invalidDirectory
            }
            throw Self.posixError()
        }
        do {
            try validateMetadata(
                descriptor: descriptor,
                expectedKind: S_IFDIR,
                expectedPermissions: 0o700,
                requireSingleLink: false
            )
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func ensurePrivateDirectory() throws -> Int32 {
        let directory = fileURL.deletingLastPathComponent()
        var metadata = stat()
        if lstat(directory.path, &metadata) != 0 {
            guard errno == ENOENT else { throw Self.posixError() }
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                // A concurrent creator is acceptable only if the descriptor
                // validation below proves the resulting node is private.
                guard (error as NSError).code == NSFileWriteFileExistsError
                else {
                    throw error
                }
            }
        }

        let descriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw AntigravityManagedProcessRecordStoreError.invalidDirectory
            }
            throw Self.posixError()
        }
        do {
            var openedMetadata = stat()
            guard fstat(descriptor, &openedMetadata) == 0 else {
                throw Self.posixError()
            }
            guard (openedMetadata.st_mode & S_IFMT) == S_IFDIR else {
                throw AntigravityManagedProcessRecordStoreError.invalidDirectory
            }
            guard openedMetadata.st_uid == expectedUserID else {
                throw AntigravityManagedProcessRecordStoreError.invalidDirectoryOwner
            }
            guard fchmod(descriptor, mode_t(0o700)) == 0 else {
                throw Self.posixError()
            }
            try validateMetadata(
                descriptor: descriptor,
                expectedKind: S_IFDIR,
                expectedPermissions: 0o700,
                requireSingleLink: false
            )
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func validateExistingFileIfPresent(in directoryFD: Int32) throws {
        let descriptor = openat(
            directoryFD,
            fileURL.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            if errno == ELOOP {
                throw AntigravityManagedProcessRecordStoreError.invalidFile
            }
            throw Self.posixError()
        }
        defer { close(descriptor) }
        try validateFileMetadata(descriptor)
    }

    private func validateExistingFile(in directoryFD: Int32) throws {
        let descriptor = openat(
            directoryFD,
            fileURL.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            if errno == ELOOP {
                throw AntigravityManagedProcessRecordStoreError.invalidFile
            }
            throw Self.posixError()
        }
        defer { close(descriptor) }
        try validateFileMetadata(descriptor)
    }

    /// Removes only abandoned temporary files from this store's exact
    /// namespace. Every active writer holds an advisory lock on its temp
    /// inode, so concurrent mutations are skipped rather than unlinked.
    private func removeAbandonedTemporaryFiles(
        in directoryFD: Int32
    ) throws {
        let scanDescriptor = dup(directoryFD)
        guard scanDescriptor >= 0 else {
            throw Self.posixError()
        }
        guard let directory = fdopendir(scanDescriptor) else {
            let code = errno
            close(scanDescriptor)
            throw AntigravityManagedProcessRecordStoreError
                .posix(code)
        }
        defer { closedir(directory) }

        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(
                to: &entry.pointee.d_name
            ) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) {
                    String(cString: $0)
                }
            }
            if Self.isTemporaryLedgerName(name) {
                names.append(name)
            }
        }

        var removedAny = false
        for name in names {
            removedAny = try removeAbandonedTemporaryFile(
                named: name,
                in: directoryFD
            ) || removedAny
        }
        if removedAny {
            try Self.sync(directoryFD)
        }
    }

    /// Opens and closes one candidate within a dedicated scope so a directory
    /// containing many crash leftovers never retains one descriptor per
    /// scanned entry.
    private func removeAbandonedTemporaryFile(
        named name: String,
        in directoryFD: Int32
    ) throws -> Bool {
        let descriptor = openat(
            directoryFD,
            name,
            O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return false }
            if errno == ELOOP {
                throw AntigravityManagedProcessRecordStoreError
                    .invalidFile
            }
            throw Self.posixError()
        }
        var ownsLock = false
        defer {
            if ownsLock {
                _ = flock(descriptor, LOCK_UN)
            }
            close(descriptor)
        }
        try validateFileMetadata(descriptor)

        var lockResult: Int32
        repeat {
            lockResult = flock(
                descriptor,
                LOCK_EX | LOCK_NB
            )
        } while lockResult == -1 && errno == EINTR
        if lockResult == -1,
           errno == EWOULDBLOCK || errno == EAGAIN {
            return false
        }
        guard lockResult == 0 else {
            throw Self.posixError()
        }
        ownsLock = true

        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0 else {
            throw Self.posixError()
        }
        var pathMetadata = stat()
        guard fstatat(
            directoryFD,
            name,
            &pathMetadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT { return false }
            throw Self.posixError()
        }
        guard openedMetadata.st_dev == pathMetadata.st_dev,
              openedMetadata.st_ino == pathMetadata.st_ino,
              (pathMetadata.st_mode & S_IFMT) == S_IFREG else {
            throw AntigravityManagedProcessRecordStoreError
                .invalidFile
        }
        guard unlinkat(directoryFD, name, 0) == 0 else {
            if errno == ENOENT { return false }
            throw Self.posixError()
        }
        return true
    }

    private static func isTemporaryLedgerName(
        _ name: String
    ) -> Bool {
        let prefix = ".managed-agy-sessions."
        let suffix = ".tmp"
        guard name.hasPrefix(prefix),
              name.hasSuffix(suffix) else {
            return false
        }
        let rawUUID = String(
            name.dropFirst(prefix.count)
                .dropLast(suffix.count)
        )
        guard let uuid = UUID(uuidString: rawUUID) else {
            return false
        }
        return uuid.uuidString.lowercased()
            == rawUUID
    }

    private func readAndValidateFile(_ descriptor: Int32) throws -> Data {
        try validateFileMetadata(descriptor)

        var result = Data()
        result.reserveCapacity(4_096)
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard result.count + count <= Self.maximumFileBytes else {
                    throw AntigravityManagedProcessRecordStoreError.fileTooLarge
                }
                result.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 { return result }
            if errno == EINTR { continue }
            throw Self.posixError()
        }
    }

    private func validateFileMetadata(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw Self.posixError()
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1
        else {
            throw AntigravityManagedProcessRecordStoreError.invalidFile
        }
        guard metadata.st_uid == expectedUserID else {
            throw AntigravityManagedProcessRecordStoreError.invalidFileOwner
        }
        guard Self.permissions(metadata.st_mode) == 0o600 else {
            throw AntigravityManagedProcessRecordStoreError.invalidFilePermissions
        }
        guard metadata.st_size >= 0,
              metadata.st_size <= off_t(Self.maximumFileBytes)
        else {
            throw AntigravityManagedProcessRecordStoreError.fileTooLarge
        }
    }

    private func validateMetadata(
        descriptor: Int32,
        expectedKind: mode_t,
        expectedPermissions: Int,
        requireSingleLink: Bool
    ) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw Self.posixError()
        }
        guard (metadata.st_mode & S_IFMT) == expectedKind else {
            throw expectedKind == S_IFDIR
                ? AntigravityManagedProcessRecordStoreError.invalidDirectory
                : AntigravityManagedProcessRecordStoreError.invalidFile
        }
        guard metadata.st_uid == expectedUserID else {
            throw expectedKind == S_IFDIR
                ? AntigravityManagedProcessRecordStoreError.invalidDirectoryOwner
                : AntigravityManagedProcessRecordStoreError.invalidFileOwner
        }
        guard Self.permissions(metadata.st_mode) == expectedPermissions else {
            throw expectedKind == S_IFDIR
                ? AntigravityManagedProcessRecordStoreError.invalidDirectoryPermissions
                : AntigravityManagedProcessRecordStoreError.invalidFilePermissions
        }
        if requireSingleLink, metadata.st_nlink != 1 {
            throw AntigravityManagedProcessRecordStoreError.invalidFile
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                throw Self.posixError()
            }
        }
    }

    private static func permissions(_ mode: mode_t) -> Int {
        Int(mode & mode_t(0o7777))
    }

    private static func sync(_ descriptor: Int32) throws {
        while fsync(descriptor) == -1 {
            if errno == EINTR { continue }
            throw posixError()
        }
    }

    private static func posixError() -> AntigravityManagedProcessRecordStoreError {
        .posix(errno)
    }
}
