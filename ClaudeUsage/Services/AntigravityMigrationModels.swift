import Foundation

nonisolated enum AntigravityLegacySourceID: String, Codable, CaseIterable, Hashable, Sendable {
    case accountFile
    case activeCredentialFile
    case metadataFile
    case bundleIdentifierKeychain
    case claudeUsageKeychain
}

nonisolated enum AntigravityLegacySourceOutcome: Equatable, Sendable {
    case notFound
    case readable
    case interactionRequired
    case invalid
    case failure(Int)
}

nonisolated enum AntigravityMigrationPhase: String, Equatable, Sendable {
    case notStarted
    case preflight
    case blockedBeforeCutover
    case awaitingImportAuthorization
    case writingCanonical
    case canonicalVerified
    case cleanupPending
    case complete
}

nonisolated enum AntigravityMigrationRequiredAction: Equatable, Sendable {
    case importCredential
    case cleanupLegacyCredential
    case removeLegacyCredential
}

nonisolated enum AntigravityMigrationBlocker: Equatable, Sendable {
    case invalidCanonicalState
    case missingCanonicalCredential
    case invalidLegacySource(AntigravityLegacySourceID)
    case legacySourceFailure(AntigravityLegacySourceID, Int)
    case missingRefreshCredential
    case tokenLineageConflict
    case externalIdentityConflict
    case activeAccountAmbiguous
    case legacySourceChanged(AntigravityLegacySourceID)
    case invalidMigrationJournal
    case invalidCompletionMarker
    case persistenceFailure
}

nonisolated enum AntigravityMigrationFlowError: Error {
    case blocked(AntigravityMigrationBlocker)
}

nonisolated struct AntigravityMigrationStatus: Equatable, Sendable {
    let phase: AntigravityMigrationPhase
    let sourceOutcomes: [AntigravityLegacySourceID: AntigravityLegacySourceOutcome]
    let plannedAccountCount: Int
    let blocker: AntigravityMigrationBlocker?
    let requiredAction: AntigravityMigrationRequiredAction?
    let authorizationCancelledThisSession: Bool
}

nonisolated enum AntigravityMigrationJournalKind: String, Codable, Sendable {
    case credentialImport
    case canonicalCleanup
    case removeAllAccounts
}

nonisolated enum AntigravityMigrationJournalPhase: String, Codable, Sendable {
    case planned
    case credentialsStaged
    case canonicalCommitted
    case cleanupPending
    case removalPending
}

nonisolated struct AntigravityMigrationJournalAccount: Codable, Equatable, Sendable {
    let accountID: AntigravityAccountID
    let credentialReference: AntigravityCredentialReference
    let refreshTokenFingerprint: String
}

/// Write-ahead migration record. It contains opaque IDs, immutable references,
/// one-way fingerprints and cleanup bookkeeping only. Legacy payloads, emails,
/// labels and OAuth client data must never be added here.
nonisolated struct AntigravityMigrationJournal: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let operationID: String
    let kind: AntigravityMigrationJournalKind
    var phase: AntigravityMigrationJournalPhase
    let expectedRevision: UInt64
    /// SHA-256 of normalized source IDs, non-secret identity metadata and
    /// refresh-token fingerprints. The raw source inventory is never persisted.
    let sourceInventoryFingerprint: String
    /// Remove-all only: SHA-256 binding of the exact canonical revision,
    /// active account, opaque account IDs and immutable credential references
    /// that the user authorized for deletion. It contains no label, external
    /// identity, timestamp or credential-derived value.
    let removalCanonicalStateFingerprint: String?
    /// Per-source raw payload/outcome fingerprints allow cleanup to prove that
    /// it is deleting the exact legacy value inventoried before cutover.
    let sourceFingerprints: [AntigravityLegacySourceID: String]
    /// SHA-256 only. Each entry binds a cleanup target to the raw payload that
    /// may be moved into the fixed v2 quarantine identity and deleted.
    var cleanupPayloadFingerprints: [AntigravityLegacySourceID: String]
    let accounts: [AntigravityMigrationJournalAccount]
    let activeAccountID: AntigravityAccountID?
    var completedCleanupTargets: Set<AntigravityLegacySourceID>

    init(
        operationID: UUID,
        kind: AntigravityMigrationJournalKind,
        phase: AntigravityMigrationJournalPhase,
        expectedRevision: UInt64,
        sourceInventoryFingerprint: String,
        removalCanonicalStateFingerprint: String? = nil,
        sourceFingerprints: [AntigravityLegacySourceID: String] = [:],
        cleanupPayloadFingerprints:
            [AntigravityLegacySourceID: String] = [:],
        accounts: [AntigravityMigrationJournalAccount],
        activeAccountID: AntigravityAccountID?,
        completedCleanupTargets: Set<AntigravityLegacySourceID> = []
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.operationID = operationID.uuidString.lowercased()
        self.kind = kind
        self.phase = phase
        self.expectedRevision = expectedRevision
        self.sourceInventoryFingerprint = sourceInventoryFingerprint
        self.removalCanonicalStateFingerprint =
            removalCanonicalStateFingerprint
        self.sourceFingerprints = sourceFingerprints
        self.cleanupPayloadFingerprints = cleanupPayloadFingerprints
        self.accounts = accounts
        self.activeAccountID = activeAccountID
        self.completedCleanupTargets = completedCleanupTargets
    }
}

nonisolated struct AntigravityMigrationCompletionMarker: Codable, Equatable, Sendable {
    static let currentVersion = 2

    let version: Int
    let completedAtMilliseconds: Double
}
