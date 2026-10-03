import Darwin
import Foundation

nonisolated enum AntigravityLegacyManagedProcessCleanupResult: Sendable, Equatable {
    case nothingRecorded
    case cleaned
    case deferred
}

nonisolated protocol AntigravityLegacyManagedProcessCleaning: Sendable {
    func cleanUp() async -> AntigravityLegacyManagedProcessCleanupResult
}

// Earlier releases recorded the AGY processes they kept running. The previous
// app instance is gone after an update, so the fail-closed recovery can finish.
// Nothing current reads the ledger, so the result never gates refreshes.
nonisolated struct AntigravityLegacyManagedProcessCleanup: AntigravityLegacyManagedProcessCleaning {
    private let ledgerStore: any AntigravityManagedProcessLedgerStoring
    private let recovery: any AntigravityManagedProcessRecovering
    private let ledgerExists: @Sendable () -> Bool
    private let removeLaunchLock: @Sendable () -> Void

    init(
        ledgerStore: any AntigravityManagedProcessLedgerStoring,
        recovery: any AntigravityManagedProcessRecovering,
        ledgerExists: @escaping @Sendable () -> Bool,
        removeLaunchLock: @escaping @Sendable () -> Void = {}
    ) {
        self.ledgerStore = ledgerStore
        self.recovery = recovery
        self.ledgerExists = ledgerExists
        self.removeLaunchLock = removeLaunchLock
    }

    func cleanUp() async -> AntigravityLegacyManagedProcessCleanupResult {
        removeLaunchLock()
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

    static let launchLockFileName = "managed-agy-launch.lock"
    private static let launchLockSharedDirectoryName = AppIdentifiers.legacySharedSupportDirectoryName

    static func launchLockDirectory(homeDirectoryURL: URL) -> URL {
        AntigravityStoragePaths.canonicalStateDirectoryURL(
            homeDirectoryURL: homeDirectoryURL, directoryName: launchLockSharedDirectoryName)
    }

    // Earlier releases serialized managed launches with this lock, first in
    // each channel's state directory and later in a directory shared by
    // channels. Only empty shared directories are removed.
    static func removeLaunchLock(in directory: URL) {
        removeLaunchLockFile(in: directory)
        _ = rmdir(directory.path)
        _ = rmdir(directory.deletingLastPathComponent().path)
    }

    static func removeLaunchLockFile(in directory: URL) {
        let lockPath = directory.appendingPathComponent(launchLockFileName).path
        var metadata = stat()
        if lstat(lockPath, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG {
            _ = unlink(lockPath)
        }
    }

    static func production(
        stateDirectory: URL = AntigravityStoragePaths.canonicalStateDirectoryURL(),
        homeDirectoryURL: URL = FileManager.default.realHomeDirectory
    ) -> Self {
        let launchLockDirectory = launchLockDirectory(homeDirectoryURL: homeDirectoryURL)
        let ledgerURL = stateDirectory.appendingPathComponent(AntigravityManagedProcessRecordFileStore.fileName)
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
            ledgerExists: { FileManager.default.fileExists(atPath: ledgerURL.path) },
            removeLaunchLock: {
                removeLaunchLock(in: launchLockDirectory)
                removeLaunchLockFile(in: stateDirectory)
            }
        )
    }
}
