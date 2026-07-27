import Foundation

nonisolated protocol AntigravityRuntimeOwnershipResolving: Sendable {
    func ownership(
        for identity: AntigravityVerifiedProcessIdentity
    ) async -> AntigravityRuntimeOwnership
}

nonisolated protocol AntigravityManagedRuntimeRegistering: Sendable {
    func register(
        _ identity: AntigravityVerifiedProcessIdentity
    ) async

    func unregister(
        _ identity: AntigravityVerifiedProcessIdentity
    ) async

    func quarantine(
        _ identity: AntigravityVerifiedProcessIdentity
    ) async
}

nonisolated struct AntigravityDefaultRuntimeOwnershipResolver:
    AntigravityRuntimeOwnershipResolving
{
    func ownership(
        for identity: AntigravityVerifiedProcessIdentity
    ) async -> AntigravityRuntimeOwnership {
        switch identity.executable.role {
        case .appLanguageServer:
            .external
        case .agyCLI:
            .borrowed
        }
    }
}

/// Exact managed ownership is process-local evidence. A persisted crash record
/// is never registered here and therefore can never turn a stale or reused PID
/// into a managed discovery candidate.
actor AntigravityManagedRuntimeRegistry:
    AntigravityRuntimeOwnershipResolving,
    AntigravityManagedRuntimeRegistering
{
    private let ledgerStore:
        (any AntigravityManagedProcessLedgerStoring)?
    private let bootSessionProvider:
        any AntigravityBootSessionIdentityProviding
    private let identityProvider:
        any AntigravityManagedProcessIdentityProviding
    private var managedIdentities:
        Set<AntigravityVerifiedProcessIdentity> = []
    private var quarantinedIdentities:
        Set<AntigravityVerifiedProcessIdentity> = []

    init(
        ledgerStore:
            (any AntigravityManagedProcessLedgerStoring)? = nil,
        bootSessionProvider:
            any AntigravityBootSessionIdentityProviding =
                AntigravitySystemBootSessionIdentityProvider(),
        identityProvider:
            any AntigravityManagedProcessIdentityProviding =
                AntigravityManagedProcessIdentityProvider()
    ) {
        self.ledgerStore = ledgerStore
        self.bootSessionProvider = bootSessionProvider
        self.identityProvider = identityProvider
    }

    func register(
        _ identity: AntigravityVerifiedProcessIdentity
    ) {
        guard identity.executable.role == .agyCLI else { return }
        quarantinedIdentities.remove(identity)
        managedIdentities.insert(identity)
    }

    func unregister(
        _ identity: AntigravityVerifiedProcessIdentity
    ) {
        managedIdentities.remove(identity)
        quarantinedIdentities.remove(identity)
    }

    func quarantine(
        _ identity: AntigravityVerifiedProcessIdentity
    ) {
        guard identity.executable.role == .agyCLI else { return }
        managedIdentities.remove(identity)
        quarantinedIdentities.insert(identity)
    }

    func ownership(
        for identity: AntigravityVerifiedProcessIdentity
    ) async -> AntigravityRuntimeOwnership {
        switch identity.executable.role {
        case .appLanguageServer:
            return .external
        case .agyCLI:
            if quarantinedIdentities.contains(identity) {
                return .quarantined
            }
            if managedIdentities.contains(identity) {
                return .managed
            }
            return durablyOwnedOrUncertain(identity)
                ? .quarantined : .borrowed
        }
    }

    /// A current-boot ledger entry never grants reusable managed ownership.
    /// It only excludes the exact live execution from borrowed discovery
    /// until lifecycle recovery proves that the owned process disappeared.
    private func durablyOwnedOrUncertain(
        _ identity: AntigravityVerifiedProcessIdentity
    ) -> Bool {
        guard let ledgerStore else { return false }

        let snapshot: AntigravityManagedProcessLedgerSnapshot
        do {
            snapshot = try ledgerStore.loadLedger()
        } catch {
            // Malformed or unreadable ownership state cannot safely turn an
            // AGY process into a user-owned borrowed runtime.
            return true
        }
        guard !snapshot.entries.isEmpty else { return false }
        guard let currentBoot =
                bootSessionProvider.currentBootSessionID(),
              let persistedBoot = snapshot.bootSessionID else {
            return true
        }
        guard persistedBoot == currentBoot else {
            // No process execution survives a boot boundary.
            return false
        }
        guard let current = identityProvider.identity(
            for: identity.processID
        ),
        Self.matches(current, verified: identity) else {
            return true
        }

        for record in snapshot.processRecords {
            for recorded in
                [record.child] + record.observedDescendants
            where current.hasStableExecutionInvariants(
                as: recorded
            ) {
                return true
            }
        }
        for intent in snapshot.launchIntents
        where current.kernelIdentity.parentUniqueID
                == intent.owner.kernelIdentity.uniqueID
            && current.effectiveUserID
                == intent.owner.effectiveUserID
            && current.realUserID
                == intent.owner.realUserID
            && current.executablePath
                == intent.executable.canonicalPath {
            return true
        }
        return false
    }

    private static func matches(
        _ recorded: AntigravityRecordedProcessIdentity,
        verified: AntigravityVerifiedProcessIdentity
    ) -> Bool {
        recorded.pid == verified.processID
            && recorded.effectiveUserID
                == verified.effectiveUserID.rawValue
            && recorded.realUserID
                == verified.realUserID.rawValue
            && recorded.startedAtSeconds
                == verified.startedAt.seconds
            && recorded.startedAtMicroseconds
                == verified.startedAt.microseconds
            && recorded.executablePath
                == verified.executable.canonicalURL
                    .standardizedFileURL.path
    }
}
