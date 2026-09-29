import Foundation

nonisolated enum AntigravityLegacyManagedProcessCleanupResult: Sendable, Equatable {
    case nothingRecorded
    case cleaned
    /// The ledger could not be reconciled safely; it is kept for the next launch.
    case deferred
}

nonisolated protocol AntigravityLegacyManagedProcessCleaning: Sendable {
    func cleanUp() async -> AntigravityLegacyManagedProcessCleanupResult
}

/// Retires AGY processes that earlier releases launched and recorded.
///
/// Releases before the usage-report source kept a long-lived AGY process and a
/// ledger of it. After an update the previous app instance is gone, so the
/// ledger owner is provably dead and the existing fail-closed recovery can
/// finish. The result never gates refreshes: nothing current reads the ledger.
nonisolated struct AntigravityLegacyManagedProcessCleanup: AntigravityLegacyManagedProcessCleaning {
    private let ledgerStore: any AntigravityManagedProcessLedgerStoring
    private let recovery: any AntigravityManagedProcessRecovering
    private let ledgerExists: @Sendable () -> Bool

    init(
        ledgerStore: any AntigravityManagedProcessLedgerStoring,
        recovery: any AntigravityManagedProcessRecovering,
        ledgerExists: @escaping @Sendable () -> Bool
    ) {
        self.ledgerStore = ledgerStore
        self.recovery = recovery
        self.ledgerExists = ledgerExists
    }

    func cleanUp() async -> AntigravityLegacyManagedProcessCleanupResult {
        guard ledgerExists() else { return .nothingRecorded }
        guard let snapshot = try? ledgerStore.loadLedger() else { return .deferred }
        guard !snapshot.entries.isEmpty else { return .nothingRecorded }
        do {
            try await recovery.recoverOrphanedProcesses()
            return .cleaned
        } catch {
            return .deferred
        }
    }

    static func production(
        stateDirectory: URL = AntigravityStoragePaths.canonicalStateDirectoryURL()
    ) -> Self {
        let ledgerURL = stateDirectory.appendingPathComponent("managed-agy-sessions.json")
        let ledgerStore = AntigravityManagedProcessRecordFileStore(fileURL: ledgerURL)
        let identityProvider = AntigravityManagedProcessIdentityProvider()
        let recordRecovery = AntigravityManagedProcessRecovery(
            recordStore: ledgerStore,
            processInspector: AntigravitySystemRecordedProcessInspector(identityProvider: identityProvider),
            processTreeInspector: AntigravitySystemManagedProcessTreeInspector(identityProvider: identityProvider),
            signaler: AntigravitySystemExactProcessSignaler()
        )
        let recovery = AntigravityManagedSessionLifecycleRecovery(
            ledgerStore: ledgerStore,
            intentInspector: AntigravitySystemManagedLaunchIntentInspector(identityProvider: identityProvider),
            recordRecovery: recordRecovery
        )
        return Self(
            ledgerStore: ledgerStore,
            recovery: recovery,
            ledgerExists: { FileManager.default.fileExists(atPath: ledgerURL.path) }
        )
    }
}
