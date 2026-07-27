import Foundation
import CryptoKit

nonisolated struct AntigravityAccountID: Codable, Hashable, Sendable, RawRepresentable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(uuid: UUID) {
        self.rawValue = uuid.uuidString.lowercased()
    }

    var isOpaqueUUID: Bool {
        guard let uuid = UUID(uuidString: rawValue) else { return false }
        return uuid.uuidString.lowercased() == rawValue
    }
}

nonisolated struct AntigravityCredentialReference: Codable, Hashable, Sendable, RawRepresentable {
    static let namespacePrefix = "oauth.antigravity.v2."

    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(uuid: UUID) {
        self.rawValue = Self.namespacePrefix + uuid.uuidString.lowercased()
    }

    var isCanonical: Bool {
        guard rawValue.hasPrefix(Self.namespacePrefix) else { return false }
        let suffix = String(rawValue.dropFirst(Self.namespacePrefix.count))
        guard let uuid = UUID(uuidString: suffix) else { return false }
        return uuid.uuidString.lowercased() == suffix
    }
}

nonisolated struct AntigravityExternalAccountIdentity: Codable, Equatable, Sendable {
    var googleSubject: String?
    var email: String?

    init(googleSubject: String? = nil, email: String? = nil) {
        self.googleSubject = googleSubject?.trimmedNonEmpty
        self.email = email?.trimmedNonEmpty
    }
}

nonisolated enum AntigravityAccountLifecycle: String, Codable, Sendable {
    case active
    case pendingDeletion
}

nonisolated struct AntigravityStoredAccount: Codable, Identifiable, Equatable, Sendable {
    let id: AntigravityAccountID
    var label: String
    var externalIdentity: AntigravityExternalAccountIdentity
    var migrationAliases: [String]
    var lifecycle: AntigravityAccountLifecycle
    var credentialReference: AntigravityCredentialReference
    let createdAtMilliseconds: Double
    var updatedAtMilliseconds: Double
}

nonisolated struct AntigravityAccountRepositoryState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var revision: UInt64
    var activeAccountID: AntigravityAccountID?
    var accounts: [AntigravityStoredAccount]

    init(
        schemaVersion: Int = currentSchemaVersion,
        revision: UInt64 = 0,
        activeAccountID: AntigravityAccountID? = nil,
        accounts: [AntigravityStoredAccount] = []
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.activeAccountID = activeAccountID
        self.accounts = accounts
    }

    var usableAccounts: [AntigravityStoredAccount] {
        accounts.filter { $0.lifecycle == .active }
    }

    var activeAccount: AntigravityStoredAccount? {
        guard let activeAccountID else { return nil }
        return usableAccounts.first { $0.id == activeAccountID }
    }
}

nonisolated struct AntigravityCredentialSnapshot: Sendable, Equatable {
    let repositoryRevision: UInt64
    let account: AntigravityStoredAccount
    let credentials: AntigravityOAuthCredentials
}

nonisolated enum AntigravityAccountRepositoryError: Error, Equatable, Sendable {
    case revisionConflict(expected: UInt64, actual: UInt64)
    case accountNotFound
    case accountPendingDeletion
    case invalidMetadata
    case invalidCredential
    case credentialVerificationFailed
    case credentialDeletionVerificationFailed
    case metadataPersistenceVerificationFailed
    case journalPersistenceVerificationFailed
    case namespaceCleanupVerificationFailed
    case canonicalFilePermissionsVerificationFailed
    case interruptedOperationRequiresRecovery
    case canonicalStateAlreadyExists
    case credentialReferenceCollision
    case credentialReferenceIsCanonical
}

/// Migration-only, secret-free description of the canonical repository.
/// `metadataExists` deliberately distinguishes an absent v2 store from a
/// persisted but empty v2 store.
nonisolated struct AntigravityMigrationCanonicalInspection: Equatable, Sendable {
    let metadataExists: Bool
    let state: AntigravityAccountRepositoryState
    let missingOrInvalidCredentialAccountIDs: Set<AntigravityAccountID>

    var hasValidCanonicalState: Bool {
        metadataExists && missingOrInvalidCredentialAccountIDs.isEmpty
    }
}

nonisolated struct AntigravityMigrationPlannedAccount: Equatable, Sendable {
    let id: AntigravityAccountID
    let label: String
    let externalIdentity: AntigravityExternalAccountIdentity
    let migrationAliases: [String]
    let credentialReference: AntigravityCredentialReference
    let createdAtMilliseconds: Double
    let updatedAtMilliseconds: Double
}

/// The coordinator persists this plan without credential payloads before it
/// stages any secret. The repository commits the complete plan in one metadata
/// revision instead of exposing a partially migrated account list.
nonisolated struct AntigravityMigrationRepositoryPlan: Equatable, Sendable {
    let expectedRevision: UInt64
    let activeAccountID: AntigravityAccountID
    let accounts: [AntigravityMigrationPlannedAccount]
}

protocol AntigravityAccountMetadataStoring: Sendable {
    nonisolated func load() throws -> AntigravityAccountRepositoryState?
    nonisolated func save(_ state: AntigravityAccountRepositoryState) throws
    nonisolated func delete() throws
}

nonisolated enum AntigravityAccountOperationKind: String, Codable, Sendable {
    case createAccount
    case replaceCredential
    case deleteAccount
    case deleteAll
}

nonisolated enum AntigravityAccountOperationPhase: String, Codable, Sendable {
    case planned
    case secretStaged
    case metadataCommitted
    case vaultCleanupCompleted
}

/// Deliberately contains references and revisions only; credential payloads and
/// credential-derived fingerprints are forbidden from this file.
nonisolated struct AntigravityAccountOperationJournal: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let operationID: String
    let kind: AntigravityAccountOperationKind
    var phase: AntigravityAccountOperationPhase
    let expectedRevision: UInt64
    let accountID: AntigravityAccountID?
    let oldReferences: Set<AntigravityCredentialReference>
    let newReferences: Set<AntigravityCredentialReference>

    init(
        operationID: UUID,
        kind: AntigravityAccountOperationKind,
        phase: AntigravityAccountOperationPhase = .planned,
        expectedRevision: UInt64,
        accountID: AntigravityAccountID?,
        oldReferences: Set<AntigravityCredentialReference>,
        newReferences: Set<AntigravityCredentialReference>
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.operationID = operationID.uuidString.lowercased()
        self.kind = kind
        self.phase = phase
        self.expectedRevision = expectedRevision
        self.accountID = accountID
        self.oldReferences = oldReferences
        self.newReferences = newReferences
    }

    var allReferences: Set<AntigravityCredentialReference> {
        oldReferences.union(newReferences)
    }
}

protocol AntigravityAccountOperationJournalStoring: Sendable {
    nonisolated func load() throws -> AntigravityAccountOperationJournal?
    nonisolated func save(_ journal: AntigravityAccountOperationJournal) throws
    nonisolated func delete() throws
}

private nonisolated enum AntigravityCanonicalFilePermissions {
    static let directoryMode = 0o700
    static let fileMode = 0o600

    static func ensureDirectory(at directory: URL, fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: directoryMode]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: directoryMode],
            ofItemAtPath: directory.path
        )
        guard try mode(at: directory, fileManager: fileManager) == directoryMode else {
            throw AntigravityAccountRepositoryError.canonicalFilePermissionsVerificationFailed
        }
    }

    static func enforceFileMode(at fileURL: URL, fileManager: FileManager) throws {
        try fileManager.setAttributes(
            [.posixPermissions: fileMode],
            ofItemAtPath: fileURL.path
        )
        guard try mode(at: fileURL, fileManager: fileManager) == fileMode else {
            throw AntigravityAccountRepositoryError.canonicalFilePermissionsVerificationFailed
        }
    }

    private static func mode(at url: URL, fileManager: FileManager) throws -> Int? {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
            ?? attributes[.posixPermissions] as? Int
    }
}

nonisolated final class AntigravityAccountMetadataFileStore:
    AntigravityAccountMetadataStoring,
    @unchecked Sendable
{
    let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = AntigravityStoragePaths
            .canonicalStateDirectoryURL()
            .appendingPathComponent("accounts.json"),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    nonisolated func load() throws -> AntigravityAccountRepositoryState? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(
            AntigravityAccountRepositoryState.self,
            from: Data(contentsOf: fileURL)
        )
    }

    nonisolated func save(_ state: AntigravityAccountRepositoryState) throws {
        let directory = fileURL.deletingLastPathComponent()
        try AntigravityCanonicalFilePermissions.ensureDirectory(at: directory, fileManager: fileManager)
        let data = try Self.encoder.encode(state)
        try data.write(to: fileURL, options: [.atomic])
        try AntigravityCanonicalFilePermissions.enforceFileMode(at: fileURL, fileManager: fileManager)
    }

    nonisolated func delete() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private nonisolated static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

nonisolated final class AntigravityAccountOperationJournalFileStore:
    AntigravityAccountOperationJournalStoring,
    @unchecked Sendable
{
    let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = AntigravityStoragePaths
            .canonicalStateDirectoryURL()
            .appendingPathComponent("account-operation.json"),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    nonisolated func load() throws -> AntigravityAccountOperationJournal? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(
            AntigravityAccountOperationJournal.self,
            from: Data(contentsOf: fileURL)
        )
    }

    nonisolated func save(_ journal: AntigravityAccountOperationJournal) throws {
        let directory = fileURL.deletingLastPathComponent()
        try AntigravityCanonicalFilePermissions.ensureDirectory(at: directory, fileManager: fileManager)
        let data = try Self.encoder.encode(journal)
        try data.write(to: fileURL, options: [.atomic])
        try AntigravityCanonicalFilePermissions.enforceFileMode(at: fileURL, fileManager: fileManager)
    }

    nonisolated func delete() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private nonisolated static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private nonisolated struct AntigravityVaultCredentialEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let credentials: AntigravityOAuthCredentials

    init(credentials: AntigravityOAuthCredentials) {
        self.schemaVersion = Self.currentSchemaVersion
        self.credentials = credentials
    }
}

/// Dormant v2 account repository. It is intentionally not wired into the current
/// Antigravity runtime until migration and source cutover land together.
actor AntigravityAccountRepository {
    nonisolated static let credentialNamespace: OAuthCredentialVaultNamespace = {
        // The prefix is compile-time fixed and covered by tests.
        try! OAuthCredentialVaultNamespace(prefix: AntigravityCredentialReference.namespacePrefix)
    }()

    private let metadataStore: any AntigravityAccountMetadataStoring
    private let journalStore: any AntigravityAccountOperationJournalStoring
    private let vault: any OAuthCredentialVault
    private let uuidGenerator: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    init(
        metadataStore: any AntigravityAccountMetadataStoring = AntigravityAccountMetadataFileStore(),
        journalStore: any AntigravityAccountOperationJournalStoring = AntigravityAccountOperationJournalFileStore(),
        // Canonical AGY credentials are new app-owned items in the shared app
        // vault, kept apart from legacy items by their `oauth.antigravity.v2.`
        // reference namespace rather than by a separate Keychain domain.
        vault: any OAuthCredentialVault = SecurityFrameworkOAuthCredentialVault.shared,
        uuidGenerator: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.metadataStore = metadataStore
        self.journalStore = journalStore
        self.vault = vault
        self.uuidGenerator = uuidGenerator
        self.now = now
    }

    func state() throws -> AntigravityAccountRepositoryState {
        try recoverInterruptedOperation()
        return try loadValidatedState()
    }

    /// Dormant migration boundary. This never mutates canonical state.
    func inspectCanonicalForMigration() throws -> AntigravityMigrationCanonicalInspection {
        try recoverInterruptedOperation()
        let persisted = try metadataStore.load()
        let state = persisted ?? AntigravityAccountRepositoryState()
        try validate(state)

        var invalidAccountIDs: Set<AntigravityAccountID> = []
        for account in state.accounts {
            guard let payload = try vault.loadPayload(
                reference: account.credentialReference.rawValue
            ), (try? decodeCredential(payload)) != nil else {
                invalidAccountIDs.insert(account.id)
                continue
            }
        }
        return AntigravityMigrationCanonicalInspection(
            metadataExists: persisted != nil,
            state: state,
            missingOrInvalidCredentialAccountIDs: invalidAccountIDs
        )
    }

    /// Stages one immutable secret after the migration coordinator has durably
    /// written its own secret-free plan. A restart may repeat this exact write,
    /// but can never replace a different payload at the same reference.
    func stageMigrationCredential(
        _ credentials: AntigravityOAuthCredentials,
        reference: AntigravityCredentialReference
    ) throws {
        try recoverInterruptedOperation()
        guard reference.isCanonical,
              credentials.refreshToken?.trimmedNonEmpty != nil
        else {
            throw AntigravityAccountRepositoryError.invalidCredential
        }
        let payload = try JSONEncoder().encode(
            AntigravityVaultCredentialEnvelope(credentials: credentials)
        )
        if let existing = try vault.loadPayload(reference: reference.rawValue) {
            guard let existingEnvelope = try? decodeCredential(existing),
                  existingEnvelope.credentials == credentials,
                  refreshTokenFingerprint(existingEnvelope.credentials)
                    == refreshTokenFingerprint(credentials)
            else {
                throw AntigravityAccountRepositoryError.credentialReferenceCollision
            }
            return
        }

        try vault.savePayload(payload, reference: reference.rawValue)
        guard let readback = try vault.loadPayload(reference: reference.rawValue),
              let readbackEnvelope = try? decodeCredential(readback),
              readbackEnvelope.credentials == credentials,
              refreshTokenFingerprint(readbackEnvelope.credentials)
                == refreshTokenFingerprint(credentials)
        else {
            throw AntigravityAccountRepositoryError.credentialVerificationFailed
        }
    }

    /// Reads only a caller-selected immutable reference. The migration
    /// coordinator uses this for fingerprint verification after vault staging.
    func migrationCredential(
        reference: AntigravityCredentialReference
    ) throws -> AntigravityOAuthCredentials? {
        try recoverInterruptedOperation()
        guard reference.isCanonical else {
            throw AntigravityAccountRepositoryError.invalidMetadata
        }
        guard let payload = try vault.loadPayload(reference: reference.rawValue) else {
            return nil
        }
        return try decodeCredential(payload).credentials
    }

    /// Commits all migrated accounts in one CAS revision. Existing canonical
    /// metadata is accepted only when it is byte-for-model identical to the
    /// already committed plan, which makes restart recovery idempotent.
    @discardableResult
    func commitMigration(
        _ plan: AntigravityMigrationRepositoryPlan
    ) throws -> AntigravityAccountRepositoryState {
        try recoverInterruptedOperation()
        let desired = try migrationState(for: plan)
        if let persisted = try metadataStore.load() {
            try validate(persisted)
            guard persisted == desired else {
                throw AntigravityAccountRepositoryError.canonicalStateAlreadyExists
            }
            try verifyCredentialReferences(in: desired)
            return persisted
        }
        guard plan.expectedRevision == 0 else {
            throw AntigravityAccountRepositoryError.revisionConflict(
                expected: plan.expectedRevision,
                actual: 0
            )
        }
        try verifyCredentialReferences(in: desired)
        try saveMetadataAndVerify(desired)
        return desired
    }

    /// Rollback is restricted to a reference that canonical metadata does not
    /// own. This prevents an old migration journal from deleting live v2 data.
    func discardStagedMigrationCredential(
        reference: AntigravityCredentialReference
    ) throws {
        try recoverInterruptedOperation()
        guard reference.isCanonical else {
            throw AntigravityAccountRepositoryError.invalidMetadata
        }
        if let persisted = try metadataStore.load() {
            try validate(persisted)
            guard !persisted.accounts.contains(where: {
                $0.credentialReference == reference
            }) else {
                throw AntigravityAccountRepositoryError.credentialReferenceIsCanonical
            }
        }
        try deleteVaultReferenceAndVerify(reference)
    }

    func credentialSnapshot(for accountID: AntigravityAccountID) throws -> AntigravityCredentialSnapshot? {
        try recoverInterruptedOperation()
        let state = try loadValidatedState()
        guard let account = state.accounts.first(where: { $0.id == accountID }) else {
            return nil
        }
        guard account.lifecycle == .active else {
            throw AntigravityAccountRepositoryError.accountPendingDeletion
        }
        guard let payload = try vault.loadPayload(reference: account.credentialReference.rawValue) else {
            throw AntigravityAccountRepositoryError.invalidCredential
        }
        let envelope = try decodeCredential(payload)
        return AntigravityCredentialSnapshot(
            repositoryRevision: state.revision,
            account: account,
            credentials: envelope.credentials
        )
    }

    @discardableResult
    func createAccount(
        credentials: AntigravityOAuthCredentials,
        label: String,
        externalIdentity: AntigravityExternalAccountIdentity,
        migrationAliases: [String] = [],
        makeActive: Bool,
        expectedRevision: UInt64
    ) throws -> AntigravityAccountRepositoryState {
        try recoverInterruptedOperation()
        let original = try loadValidatedState(expectedRevision: expectedRevision)
        let accountID = AntigravityAccountID(uuid: uuidGenerator())
        let reference = AntigravityCredentialReference(uuid: uuidGenerator())
        let timestamp = now().timeIntervalSince1970 * 1_000
        let account = AntigravityStoredAccount(
            id: accountID,
            label: label.trimmedNonEmpty ?? "Google 계정",
            externalIdentity: externalIdentity,
            migrationAliases: normalizedAliases(migrationAliases),
            lifecycle: .active,
            credentialReference: reference,
            createdAtMilliseconds: timestamp,
            updatedAtMilliseconds: timestamp
        )

        var updated = original
        updated.revision = try nextRevision(after: original.revision)
        updated.accounts.append(account)
        if makeActive || original.usableAccounts.isEmpty {
            updated.activeAccountID = accountID
        }

        try performCredentialMutation(
            kind: .createAccount,
            accountID: accountID,
            credentials: credentials,
            oldReferences: [],
            newReference: reference,
            original: original,
            updated: updated
        )
        return updated
    }

    @discardableResult
    func replaceCredential(
        for accountID: AntigravityAccountID,
        with credentials: AntigravityOAuthCredentials,
        externalIdentity: AntigravityExternalAccountIdentity? = nil,
        expectedRevision: UInt64
    ) throws -> AntigravityAccountRepositoryState {
        try recoverInterruptedOperation()
        let original = try loadValidatedState(expectedRevision: expectedRevision)
        guard let index = original.accounts.firstIndex(where: { $0.id == accountID }) else {
            throw AntigravityAccountRepositoryError.accountNotFound
        }
        guard original.accounts[index].lifecycle == .active else {
            throw AntigravityAccountRepositoryError.accountPendingDeletion
        }

        let oldReference = original.accounts[index].credentialReference
        let newReference = AntigravityCredentialReference(uuid: uuidGenerator())
        var updated = original
        updated.revision = try nextRevision(after: original.revision)
        updated.accounts[index].credentialReference = newReference
        updated.accounts[index].updatedAtMilliseconds = now().timeIntervalSince1970 * 1_000
        if let externalIdentity {
            updated.accounts[index].externalIdentity = externalIdentity
        }

        try performCredentialMutation(
            kind: .replaceCredential,
            accountID: accountID,
            credentials: credentials,
            oldReferences: [oldReference],
            newReference: newReference,
            original: original,
            updated: updated
        )
        return updated
    }

    @discardableResult
    func setActiveAccountID(
        _ accountID: AntigravityAccountID?,
        expectedRevision: UInt64
    ) throws -> AntigravityAccountRepositoryState {
        try recoverInterruptedOperation()
        let original = try loadValidatedState(expectedRevision: expectedRevision)
        if let accountID {
            guard let account = original.accounts.first(where: { $0.id == accountID }) else {
                throw AntigravityAccountRepositoryError.accountNotFound
            }
            guard account.lifecycle == .active else {
                throw AntigravityAccountRepositoryError.accountPendingDeletion
            }
        }
        var updated = original
        updated.revision = try nextRevision(after: original.revision)
        updated.activeAccountID = accountID
        try validate(updated)
        try saveMetadataAndVerify(updated)
        return updated
    }

    @discardableResult
    func deleteAccount(
        id accountID: AntigravityAccountID,
        expectedRevision: UInt64
    ) throws -> AntigravityAccountRepositoryState {
        try recoverInterruptedOperation()
        let original = try loadValidatedState(expectedRevision: expectedRevision)
        guard let index = original.accounts.firstIndex(where: { $0.id == accountID }) else {
            throw AntigravityAccountRepositoryError.accountNotFound
        }
        guard original.accounts[index].lifecycle == .active else {
            throw AntigravityAccountRepositoryError.accountPendingDeletion
        }
        let pendingRevision = try nextRevision(after: original.revision)
        let completedRevision = try nextRevision(after: pendingRevision)

        let reference = original.accounts[index].credentialReference
        var journal = AntigravityAccountOperationJournal(
            operationID: uuidGenerator(),
            kind: .deleteAccount,
            expectedRevision: original.revision,
            accountID: accountID,
            oldReferences: [reference],
            newReferences: []
        )
        try saveJournalAndVerify(journal)

        var pending = original
        pending.revision = pendingRevision
        pending.accounts[index].lifecycle = .pendingDeletion
        pending.activeAccountID = replacementActiveAccountID(
            afterExcluding: accountID,
            from: original
        )
        try validate(pending)
        try saveMetadataAndVerify(pending)
        journal.phase = .metadataCommitted
        try saveJournalAndVerify(journal)

        try deleteVaultReferenceAndVerify(reference)
        var completed = pending
        completed.revision = completedRevision
        completed.accounts.removeAll { $0.id == accountID }
        try validate(completed)
        try saveMetadataAndVerify(completed)
        try deleteJournalAndVerify()
        return completed
    }

    /// Removes every canonical v2 account and every item discoverable inside the
    /// Antigravity v2 namespace. Legacy sources are intentionally outside this
    /// dormant repository and remain a cutover/migration responsibility.
    func deleteAll(expectedRevision: UInt64) throws {
        try recoverInterruptedOperation()
        let original = try loadValidatedState(expectedRevision: expectedRevision)
        let pendingRevision = try nextRevision(after: original.revision)
        let references = Set(original.accounts.map(\.credentialReference))
        var journal = AntigravityAccountOperationJournal(
            operationID: uuidGenerator(),
            kind: .deleteAll,
            expectedRevision: original.revision,
            accountID: nil,
            oldReferences: references,
            newReferences: []
        )
        try saveJournalAndVerify(journal)

        var pending = original
        pending.revision = pendingRevision
        pending.activeAccountID = nil
        for index in pending.accounts.indices {
            pending.accounts[index].lifecycle = .pendingDeletion
        }
        try validate(pending)
        try saveMetadataAndVerify(pending)
        journal.phase = .metadataCommitted
        try saveJournalAndVerify(journal)

        try deleteAllCanonicalReferences(journal: journal)
        journal.phase = .vaultCleanupCompleted
        try saveJournalAndVerify(journal)
        try deleteMetadataAndVerify()
        try deleteJournalAndVerify()
    }

    @discardableResult
    func cleanupOrphanedCredentials() throws -> OAuthCredentialVaultCleanupResult {
        try recoverInterruptedOperation()
        let state = try loadValidatedState()
        let preserved = Set(state.accounts.map { $0.credentialReference.rawValue })
        return try vault.deleteOrphans(
            in: Self.credentialNamespace,
            preserving: preserved
        )
    }

    func recoverInterruptedOperation() throws {
        guard let journal = try journalStore.load() else { return }
        try validate(journal)
        let persistedState = try metadataStore.load()
        let state = persistedState ?? AntigravityAccountRepositoryState()
        try validate(state)

        switch journal.kind {
        case .createAccount, .replaceCredential:
            try recoverCredentialMutation(
                journal,
                state: state,
                metadataWasPresent: persistedState != nil
            )
        case .deleteAccount:
            try recoverAccountDeletion(
                journal,
                state: state,
                metadataWasPresent: persistedState != nil
            )
        case .deleteAll:
            try recoverDeleteAll(
                journal,
                state: state,
                metadataWasPresent: persistedState != nil
            )
        }
    }

    private func performCredentialMutation(
        kind: AntigravityAccountOperationKind,
        accountID: AntigravityAccountID,
        credentials: AntigravityOAuthCredentials,
        oldReferences: Set<AntigravityCredentialReference>,
        newReference: AntigravityCredentialReference,
        original: AntigravityAccountRepositoryState,
        updated: AntigravityAccountRepositoryState
    ) throws {
        guard credentials.hasTokenMaterial else {
            throw AntigravityAccountRepositoryError.invalidCredential
        }
        try validate(updated)
        let payload = try JSONEncoder().encode(
            AntigravityVaultCredentialEnvelope(credentials: credentials)
        )
        var journal = AntigravityAccountOperationJournal(
            operationID: uuidGenerator(),
            kind: kind,
            expectedRevision: original.revision,
            accountID: accountID,
            oldReferences: oldReferences,
            newReferences: [newReference]
        )
        try saveJournalAndVerify(journal)
        try vault.savePayload(payload, reference: newReference.rawValue)
        guard try vault.loadPayload(reference: newReference.rawValue) == payload else {
            throw AntigravityAccountRepositoryError.credentialVerificationFailed
        }
        journal.phase = .secretStaged
        try saveJournalAndVerify(journal)
        try saveMetadataAndVerify(updated)
        journal.phase = .metadataCommitted
        try saveJournalAndVerify(journal)
        for reference in oldReferences.sorted(by: { $0.rawValue < $1.rawValue }) {
            try deleteVaultReferenceAndVerify(reference)
        }
        try deleteJournalAndVerify()
    }

    private func recoverCredentialMutation(
        _ journal: AntigravityAccountOperationJournal,
        state: AntigravityAccountRepositoryState,
        metadataWasPresent: Bool
    ) throws {
        guard let accountID = journal.accountID,
              let newReference = journal.newReferences.first
        else {
            throw AntigravityAccountRepositoryError.invalidMetadata
        }
        let stateReferences = Set(state.accounts.map(\.credentialReference))
        let committedRevision = try nextRevision(after: journal.expectedRevision)
        let uncommittedPhase = journal.phase == .planned || journal.phase == .secretStaged
        let committedPhase = journal.phase == .secretStaged || journal.phase == .metadataCommitted

        let isUncommitted: Bool
        let isCommitted: Bool
        switch journal.kind {
        case .createAccount:
            isUncommitted = uncommittedPhase
                && state.revision == journal.expectedRevision
                && !state.accounts.contains(where: { $0.id == accountID })
                && stateReferences.isDisjoint(with: journal.newReferences)
            isCommitted = metadataWasPresent
                && committedPhase
                && state.revision == committedRevision
                && state.accounts.contains(where: {
                    $0.id == accountID
                        && $0.lifecycle == .active
                        && $0.credentialReference == newReference
                })
                && stateReferences.intersection(journal.newReferences) == journal.newReferences
        case .replaceCredential:
            guard let oldReference = journal.oldReferences.first else {
                throw AntigravityAccountRepositoryError.invalidMetadata
            }
            isUncommitted = metadataWasPresent
                && uncommittedPhase
                && state.revision == journal.expectedRevision
                && state.accounts.contains(where: {
                    $0.id == accountID
                        && $0.lifecycle == .active
                        && $0.credentialReference == oldReference
                })
                && stateReferences.isDisjoint(with: journal.newReferences)
            isCommitted = metadataWasPresent
                && committedPhase
                && state.revision == committedRevision
                && state.accounts.contains(where: {
                    $0.id == accountID
                        && $0.lifecycle == .active
                        && $0.credentialReference == newReference
                })
                && stateReferences.isDisjoint(with: journal.oldReferences)
        case .deleteAccount, .deleteAll:
            throw AntigravityAccountRepositoryError.invalidMetadata
        }

        if isCommitted {
            for reference in journal.oldReferences.sorted(by: { $0.rawValue < $1.rawValue }) {
                try deleteVaultReferenceAndVerify(reference)
            }
            try deleteJournalAndVerify()
            return
        }

        guard isUncommitted else {
            throw AntigravityAccountRepositoryError.interruptedOperationRequiresRecovery
        }
        for reference in journal.newReferences.sorted(by: { $0.rawValue < $1.rawValue }) {
            try deleteVaultReferenceAndVerify(reference)
        }
        try deleteJournalAndVerify()
    }

    private func recoverAccountDeletion(
        _ journal: AntigravityAccountOperationJournal,
        state: AntigravityAccountRepositoryState,
        metadataWasPresent: Bool
    ) throws {
        guard metadataWasPresent,
              let accountID = journal.accountID,
              let oldReference = journal.oldReferences.first
        else {
            throw AntigravityAccountRepositoryError.invalidMetadata
        }
        let pendingRevision = try nextRevision(after: journal.expectedRevision)
        let completedRevision = try nextRevision(after: pendingRevision)
        let account = state.accounts.first(where: { $0.id == accountID })
        let stateReferences = Set(state.accounts.map(\.credentialReference))

        let isOriginal = journal.phase == .planned
            && state.revision == journal.expectedRevision
            && account?.lifecycle == .active
            && account?.credentialReference == oldReference
        if isOriginal {
            try deleteJournalAndVerify()
            return
        }

        let isPending = (journal.phase == .planned || journal.phase == .metadataCommitted)
            && state.revision == pendingRevision
            && account?.lifecycle == .pendingDeletion
            && account?.credentialReference == oldReference
        if isPending {
            try deleteVaultReferenceAndVerify(oldReference)
            var completed = state
            completed.revision = completedRevision
            completed.accounts.removeAll { $0.id == accountID }
            if completed.activeAccountID == accountID {
                completed.activeAccountID = nil
            }
            try validate(completed)
            try saveMetadataAndVerify(completed)
            try deleteJournalAndVerify()
            return
        }

        let isCompleted = journal.phase == .metadataCommitted
            && state.revision == completedRevision
            && account == nil
            && !stateReferences.contains(oldReference)
        guard isCompleted else {
            throw AntigravityAccountRepositoryError.interruptedOperationRequiresRecovery
        }
        try deleteVaultReferenceAndVerify(oldReference)
        try deleteJournalAndVerify()
    }

    private func recoverDeleteAll(
        _ sourceJournal: AntigravityAccountOperationJournal,
        state: AntigravityAccountRepositoryState,
        metadataWasPresent: Bool
    ) throws {
        if !metadataWasPresent {
            let isUncommittedEmptyStore = sourceJournal.phase == .planned
                && sourceJournal.expectedRevision == 0
                && sourceJournal.oldReferences.isEmpty
            if isUncommittedEmptyStore || sourceJournal.phase == .vaultCleanupCompleted {
                try deleteJournalAndVerify()
                return
            }
            throw AntigravityAccountRepositoryError.interruptedOperationRequiresRecovery
        }

        let stateReferences = Set(state.accounts.map(\.credentialReference))
        let referencesMatch = stateReferences == sourceJournal.oldReferences
        let isOriginal = sourceJournal.phase == .planned
            && state.revision == sourceJournal.expectedRevision
            && state.accounts.allSatisfy { $0.lifecycle == .active }
            && referencesMatch
        if isOriginal {
            try deleteJournalAndVerify()
            return
        }

        let pendingRevision = try nextRevision(after: sourceJournal.expectedRevision)
        let isPending = state.revision == pendingRevision
            && state.activeAccountID == nil
            && state.accounts.allSatisfy { $0.lifecycle == .pendingDeletion }
            && referencesMatch
            && (
                sourceJournal.phase == .planned
                    || sourceJournal.phase == .metadataCommitted
                    || sourceJournal.phase == .vaultCleanupCompleted
            )
        guard isPending else {
            throw AntigravityAccountRepositoryError.interruptedOperationRequiresRecovery
        }

        if sourceJournal.phase == .vaultCleanupCompleted {
            try deleteMetadataAndVerify()
            try deleteJournalAndVerify()
            return
        }

        var journal = sourceJournal
        if journal.phase == .planned {
            journal.phase = .metadataCommitted
            try saveJournalAndVerify(journal)
        }
        try deleteAllCanonicalReferences(journal: journal)
        journal.phase = .vaultCleanupCompleted
        try saveJournalAndVerify(journal)
        try deleteMetadataAndVerify()
        try deleteJournalAndVerify()
    }

    private func deleteAllCanonicalReferences(
        journal: AntigravityAccountOperationJournal
    ) throws {
        let discovered = try vault.references(in: Self.credentialNamespace)
        let recorded = Set(journal.allReferences.map(\.rawValue))
        let references = discovered.union(recorded)
        guard references.allSatisfy(Self.credentialNamespace.contains) else {
            throw AntigravityAccountRepositoryError.invalidMetadata
        }
        for reference in references.sorted() {
            try deleteVaultReferenceAndVerify(
                AntigravityCredentialReference(rawValue: reference)
            )
        }
        guard try vault.references(in: Self.credentialNamespace).isEmpty else {
            throw AntigravityAccountRepositoryError.namespaceCleanupVerificationFailed
        }
    }

    private func migrationState(
        for plan: AntigravityMigrationRepositoryPlan
    ) throws -> AntigravityAccountRepositoryState {
        guard !plan.accounts.isEmpty,
              plan.accounts.contains(where: { $0.id == plan.activeAccountID }),
              plan.expectedRevision < UInt64.max,
              plan.accounts.allSatisfy({
                  $0.createdAtMilliseconds.isFinite
                      && $0.createdAtMilliseconds >= 0
                      && $0.updatedAtMilliseconds.isFinite
                      && $0.updatedAtMilliseconds >= 0
                      && $0.updatedAtMilliseconds >= $0.createdAtMilliseconds
              })
        else {
            throw AntigravityAccountRepositoryError.invalidMetadata
        }
        let state = AntigravityAccountRepositoryState(
            revision: plan.expectedRevision + 1,
            activeAccountID: plan.activeAccountID,
            accounts: plan.accounts.map { planned in
                AntigravityStoredAccount(
                    id: planned.id,
                    label: planned.label.trimmedNonEmpty ?? "Google 계정",
                    externalIdentity: planned.externalIdentity,
                    migrationAliases: normalizedAliases(planned.migrationAliases),
                    lifecycle: .active,
                    credentialReference: planned.credentialReference,
                    createdAtMilliseconds: planned.createdAtMilliseconds,
                    updatedAtMilliseconds: planned.updatedAtMilliseconds
                )
            }
        )
        try validate(state)
        return state
    }

    private func verifyCredentialReferences(
        in state: AntigravityAccountRepositoryState
    ) throws {
        for account in state.accounts {
            guard let payload = try vault.loadPayload(
                reference: account.credentialReference.rawValue
            ), (try? decodeCredential(payload)) != nil else {
                throw AntigravityAccountRepositoryError.invalidCredential
            }
        }
    }

    private func refreshTokenFingerprint(
        _ credentials: AntigravityOAuthCredentials
    ) -> String? {
        guard let refreshToken = credentials.refreshToken,
              refreshToken.trimmedNonEmpty != nil
        else {
            return nil
        }
        return SHA256.hash(data: Data(refreshToken.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func saveMetadataAndVerify(_ state: AntigravityAccountRepositoryState) throws {
        try validate(state)
        try metadataStore.save(state)
        guard try metadataStore.load() == state else {
            throw AntigravityAccountRepositoryError.metadataPersistenceVerificationFailed
        }
    }

    private func deleteMetadataAndVerify() throws {
        try metadataStore.delete()
        guard try metadataStore.load() == nil else {
            throw AntigravityAccountRepositoryError.metadataPersistenceVerificationFailed
        }
    }

    private func saveJournalAndVerify(_ journal: AntigravityAccountOperationJournal) throws {
        try validate(journal)
        try journalStore.save(journal)
        guard try journalStore.load() == journal else {
            throw AntigravityAccountRepositoryError.journalPersistenceVerificationFailed
        }
    }

    private func deleteJournalAndVerify() throws {
        try journalStore.delete()
        guard try journalStore.load() == nil else {
            throw AntigravityAccountRepositoryError.journalPersistenceVerificationFailed
        }
    }

    private func deleteVaultReferenceAndVerify(
        _ reference: AntigravityCredentialReference
    ) throws {
        guard reference.isCanonical else {
            throw AntigravityAccountRepositoryError.invalidMetadata
        }
        try vault.deletePayload(reference: reference.rawValue)
        guard try vault.loadPayload(reference: reference.rawValue) == nil else {
            throw AntigravityAccountRepositoryError.credentialDeletionVerificationFailed
        }
    }

    private func loadValidatedState(
        expectedRevision: UInt64? = nil
    ) throws -> AntigravityAccountRepositoryState {
        let state = try metadataStore.load() ?? AntigravityAccountRepositoryState()
        try validate(state)
        if let expectedRevision, state.revision != expectedRevision {
            throw AntigravityAccountRepositoryError.revisionConflict(
                expected: expectedRevision,
                actual: state.revision
            )
        }
        return state
    }

    private func decodeCredential(_ payload: Data) throws -> AntigravityVaultCredentialEnvelope {
        guard let envelope = try? JSONDecoder().decode(
            AntigravityVaultCredentialEnvelope.self,
            from: payload
        ), envelope.schemaVersion == AntigravityVaultCredentialEnvelope.currentSchemaVersion,
            envelope.credentials.hasTokenMaterial
        else {
            throw AntigravityAccountRepositoryError.invalidCredential
        }
        return envelope
    }

    private func validate(_ state: AntigravityAccountRepositoryState) throws {
        guard state.schemaVersion == AntigravityAccountRepositoryState.currentSchemaVersion else {
            throw AntigravityAccountRepositoryError.invalidMetadata
        }
        guard Set(state.accounts.map(\.id)).count == state.accounts.count,
              Set(state.accounts.map(\.credentialReference)).count == state.accounts.count,
              state.accounts.allSatisfy({ account in
                  account.id.isOpaqueUUID
                      && account.credentialReference.isCanonical
                      && account.label.trimmedNonEmpty != nil
                      && account.migrationAliases.allSatisfy { $0.trimmedNonEmpty != nil }
              })
        else {
            throw AntigravityAccountRepositoryError.invalidMetadata
        }
        if let activeAccountID = state.activeAccountID,
           !state.accounts.contains(where: {
               $0.id == activeAccountID && $0.lifecycle == .active
           })
        {
            throw AntigravityAccountRepositoryError.invalidMetadata
        }
    }

    private func validate(_ journal: AntigravityAccountOperationJournal) throws {
        let hasValidShape: Bool
        let hasValidPhase: Bool
        switch journal.kind {
        case .createAccount:
            hasValidShape = journal.accountID != nil
                && journal.oldReferences.isEmpty
                && journal.newReferences.count == 1
            hasValidPhase = journal.phase == .planned
                || journal.phase == .secretStaged
                || journal.phase == .metadataCommitted
        case .replaceCredential:
            hasValidShape = journal.accountID != nil
                && journal.oldReferences.count == 1
                && journal.newReferences.count == 1
                && journal.oldReferences.isDisjoint(with: journal.newReferences)
            hasValidPhase = journal.phase == .planned
                || journal.phase == .secretStaged
                || journal.phase == .metadataCommitted
        case .deleteAccount:
            hasValidShape = journal.accountID != nil
                && journal.oldReferences.count == 1
                && journal.newReferences.isEmpty
            hasValidPhase = journal.phase == .planned
                || journal.phase == .metadataCommitted
        case .deleteAll:
            hasValidShape = journal.accountID == nil
                && journal.newReferences.isEmpty
            hasValidPhase = journal.phase == .planned
                || journal.phase == .metadataCommitted
                || journal.phase == .vaultCleanupCompleted
        }

        guard journal.schemaVersion == AntigravityAccountOperationJournal.currentSchemaVersion,
              UUID(uuidString: journal.operationID)?.uuidString.lowercased() == journal.operationID,
              journal.accountID?.isOpaqueUUID != false,
              journal.allReferences.allSatisfy(\.isCanonical),
              hasValidShape,
              hasValidPhase
        else {
            throw AntigravityAccountRepositoryError.invalidMetadata
        }
    }

    private func replacementActiveAccountID(
        afterExcluding accountID: AntigravityAccountID,
        from state: AntigravityAccountRepositoryState
    ) -> AntigravityAccountID? {
        guard state.activeAccountID == accountID else { return state.activeAccountID }
        let remaining = state.usableAccounts.filter { $0.id != accountID }
        return remaining.count == 1 ? remaining[0].id : nil
    }

    private func nextRevision(after revision: UInt64) throws -> UInt64 {
        guard revision < UInt64.max else {
            throw AntigravityAccountRepositoryError.invalidMetadata
        }
        return revision + 1
    }

    private func normalizedAliases(_ aliases: [String]) -> [String] {
        var result: [String] = []
        for alias in aliases {
            guard let value = alias.trimmedNonEmpty, !result.contains(value) else { continue }
            result.append(value)
        }
        return result
    }
}

private extension String {
    nonisolated var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
