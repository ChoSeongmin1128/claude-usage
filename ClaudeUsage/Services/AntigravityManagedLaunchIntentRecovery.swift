import Foundation

nonisolated enum AntigravityManagedLaunchIntentOwnerState:
    Sendable,
    Equatable
{
    case live
    case gone
    case unavailable
}

nonisolated enum AntigravityManagedLaunchCandidateInspection:
    Sendable,
    Equatable
{
    case none
    case unique(AntigravityRecordedProcessIdentity)
    case multiple
    case unavailable
}

nonisolated protocol AntigravityManagedLaunchIntentInspecting:
    Sendable
{
    func ownerState(
        for owner: AntigravityRecordedProcessIdentity
    ) -> AntigravityManagedLaunchIntentOwnerState

    func candidates(
        ownedBy owner: AntigravityRecordedProcessIdentity,
        executable: AntigravityManagedExecutableDescriptor
    ) -> AntigravityManagedLaunchCandidateInspection
}

/// Performs the complete, fail-closed process scan needed to recover a launch
/// intent. PID order, recency, and basename matching are never ownership
/// evidence.
nonisolated struct AntigravitySystemManagedLaunchIntentInspector:
    AntigravityManagedLaunchIntentInspecting
{
    private let processIDList: any AntigravityProcessIDListing
    private let kernelIdentityReader:
        any AntigravityKernelProcessIdentityReading
    private let identityProvider:
        any AntigravityManagedProcessIdentityProviding
    private let existenceChecker:
        any AntigravityProcessExistenceChecking
    private let processTableStateReader:
        any AntigravityProcessTableStateReading

    init(
        processIDList: any AntigravityProcessIDListing =
            AntigravitySystemProcessIDList(),
        kernelIdentityReader:
            any AntigravityKernelProcessIdentityReading =
                AntigravitySystemKernelProcessIdentityReader(
                    includeTerminatedProcesses: true
                ),
        identityProvider:
            any AntigravityManagedProcessIdentityProviding =
                AntigravityManagedProcessIdentityProvider(),
        existenceChecker:
            any AntigravityProcessExistenceChecking =
                AntigravitySystemProcessExistenceChecker(),
        processTableStateReader:
            any AntigravityProcessTableStateReading =
                AntigravitySystemProcessTableStateReader()
    ) {
        self.processIDList = processIDList
        self.kernelIdentityReader = kernelIdentityReader
        self.identityProvider = identityProvider
        self.existenceChecker = existenceChecker
        self.processTableStateReader =
            processTableStateReader
    }

    func ownerState(
        for owner: AntigravityRecordedProcessIdentity
    ) -> AntigravityManagedLaunchIntentOwnerState {
        switch existenceChecker.existence(of: owner.pid) {
        case .notFound, .terminated:
            return .gone
        case .unavailable:
            return .unavailable
        case .present:
            break
        }

        guard let current = readKernelIdentity(
            for: owner.pid
        ) else {
            let existence = existenceChecker.existence(
                of: owner.pid
            )
            return existence == .notFound
                || existence == .terminated
                ? .gone
                : .unavailable
        }
        return current.uniqueID == owner.kernelIdentity.uniqueID
            ? .live
            : .gone
    }

    func candidates(
        ownedBy owner: AntigravityRecordedProcessIdentity,
        executable: AntigravityManagedExecutableDescriptor
    ) -> AntigravityManagedLaunchCandidateInspection {
        guard let processIDs = processIDList.allProcessIDs() else {
            return .unavailable
        }

        var seenPIDs = Set<Int32>()
        var seenUniqueIDs = Set<UInt64>()
        var candidates: [AntigravityRecordedProcessIdentity] = []

        for processID in processIDs {
            guard processID > 1,
                  seenPIDs.insert(processID).inserted else {
                return .unavailable
            }
            guard let kernelIdentity = readKernelIdentity(
                for: processID
            ) else {
                let existence = existenceChecker.existence(
                    of: processID
                )
                if existence == .notFound
                    || existence == .terminated {
                    continue
                }
                if let state = processTableStateReader.state(
                    for: processID
                ) {
                    guard Self.couldBeManagedCandidate(
                        state,
                        owner: owner
                    ) else {
                        continue
                    }
                }
                return .unavailable
            }
            guard seenUniqueIDs.insert(
                kernelIdentity.uniqueID
            ).inserted else {
                return .unavailable
            }
            guard kernelIdentity.parentUniqueID
                    == owner.kernelIdentity.uniqueID else {
                continue
            }

            guard let identity = identityProvider.identity(
                for: processID
            ) else {
                let existence = existenceChecker.existence(
                    of: processID
                )
                if existence == .notFound
                    || existence == .terminated {
                    continue
                }
                // A matching lineage node that disappears or changes while
                // being inspected may already have created descendants.
                return .unavailable
            }
            guard identity.kernelIdentity.uniqueID
                    == kernelIdentity.uniqueID,
                  identity.kernelIdentity.parentUniqueID
                    == kernelIdentity.parentUniqueID else {
                return .unavailable
            }
            guard identity.effectiveUserID
                    == owner.effectiveUserID,
                  identity.realUserID == owner.realUserID,
                  identity.executablePath
                    == executable.canonicalPath else {
                // A START_SUSPENDED managed child cannot change executable
                // or credentials before promotion. An exact, readable
                // lineage node with different values is therefore unrelated.
                continue
            }
            guard identityProvider.processGroupID(
                for: processID
            ) == processID else {
                // A matching suspended executable without its dedicated
                // launch group may be a partially completed managed spawn.
                return .unavailable
            }
            candidates.append(identity)
        }

        switch candidates.count {
        case 0:
            return .none
        case 1:
            return .unique(candidates[0])
        default:
            return .multiple
        }
    }

    private func readKernelIdentity(
        for processID: Int32
    ) -> AntigravityKernelProcessIdentity? {
        if let identity = kernelIdentityReader.kernelIdentity(
            for: processID
        ) {
            return identity
        }
        let existence = existenceChecker.existence(
            of: processID
        )
        guard existence != .notFound,
              existence != .terminated else {
            return nil
        }
        return kernelIdentityReader.kernelIdentity(
            for: processID
        )
    }

    private static func couldBeManagedCandidate(
        _ state: AntigravityProcessTableState,
        owner: AntigravityRecordedProcessIdentity
    ) -> Bool {
        guard !state.isZombie,
              state.effectiveUserID
                == owner.effectiveUserID,
              state.realUserID == owner.realUserID,
              state.processGroupID == state.processID else {
            return false
        }
        if state.startedAtSeconds != owner.startedAtSeconds {
            return state.startedAtSeconds
                > owner.startedAtSeconds
        }
        return state.startedAtMicroseconds
            >= owner.startedAtMicroseconds
    }
}

nonisolated protocol AntigravityManagedSessionLifecycleRecovering:
    AntigravityManagedProcessRecovering
{
    func prepareForLaunch(
        owner: AntigravityRecordedProcessIdentity,
        executable: AntigravityManagedExecutableDescriptor
    ) async throws -> AntigravityBootSessionID
}

/// Resolves the launch ledger before normal record recovery.
///
/// A stale boot can be discarded because macOS processes do not survive a
/// reboot. Within the same boot, every ambiguous lookup blocks the whole batch
/// before any signal or ledger mutation.
actor AntigravityManagedSessionLifecycleRecovery:
    AntigravityManagedSessionLifecycleRecovering
{
    private enum Resolution {
        case remove(AntigravityManagedLaunchIntent)
        case promote(
            AntigravityManagedLaunchIntent,
            AntigravityManagedProcessRecord
        )
    }

    private let ledgerStore:
        any AntigravityManagedProcessLedgerStoring
    private let bootSessionProvider:
        any AntigravityBootSessionIdentityProviding
    private let intentInspector:
        any AntigravityManagedLaunchIntentInspecting
    private let recordRecovery:
        any AntigravityManagedProcessRecovering

    init(
        ledgerStore:
            any AntigravityManagedProcessLedgerStoring,
        bootSessionProvider:
            any AntigravityBootSessionIdentityProviding =
                AntigravitySystemBootSessionIdentityProvider(),
        intentInspector:
            any AntigravityManagedLaunchIntentInspecting =
                AntigravitySystemManagedLaunchIntentInspector(),
        recordRecovery:
            any AntigravityManagedProcessRecovering
    ) {
        self.ledgerStore = ledgerStore
        self.bootSessionProvider = bootSessionProvider
        self.intentInspector = intentInspector
        self.recordRecovery = recordRecovery
    }

    func recoverOrphanedProcesses() async throws {
        guard let currentBoot =
                bootSessionProvider.currentBootSessionID() else {
            throw AntigravityManagedSessionError
                .recordRecoveryBlocked
        }
        try await recover(
            currentBoot: currentBoot,
            reclaimingOwner: nil,
            executable: nil
        )
    }

    func prepareForLaunch(
        owner: AntigravityRecordedProcessIdentity,
        executable: AntigravityManagedExecutableDescriptor
    ) async throws -> AntigravityBootSessionID {
        guard let currentBoot =
                bootSessionProvider.currentBootSessionID() else {
            throw AntigravityManagedSessionError
                .recordRecoveryBlocked
        }
        try await recover(
            currentBoot: currentBoot,
            reclaimingOwner: owner,
            executable: executable
        )

        guard bootSessionProvider.currentBootSessionID()
                == currentBoot,
              intentInspector.candidates(
                  ownedBy: owner,
                  executable: executable
              ) == .none else {
            throw AntigravityManagedSessionError
                .recordRecoveryBlocked
        }
        return currentBoot
    }

    private func recover(
        currentBoot: AntigravityBootSessionID,
        reclaimingOwner:
            AntigravityRecordedProcessIdentity?,
        executable:
            AntigravityManagedExecutableDescriptor?
    ) async throws {
        let snapshot: AntigravityManagedProcessLedgerSnapshot
        do {
            snapshot = try ledgerStore.loadLedger()
        } catch {
            throw AntigravityManagedSessionError
                .recordRecoveryBlocked
        }

        if let persistedBoot = snapshot.bootSessionID,
           persistedBoot != currentBoot {
            do {
                try ledgerStore.removeEntriesFromStaleBoot(
                    persistedBoot
                )
                return
            } catch {
                throw AntigravityManagedSessionError
                    .recordRecoveryBlocked
            }
        }

        var resolutions: [Resolution] = []
        for intent in snapshot.launchIntents {
            guard intent.bootSessionID == currentBoot else {
                throw AntigravityManagedSessionError
                    .recordRecoveryBlocked
            }
            switch intentInspector.ownerState(for: intent.owner) {
            case .live:
                guard intent.owner == reclaimingOwner,
                      intent.executable == executable,
                      intentInspector.candidates(
                          ownedBy: intent.owner,
                          executable: intent.executable
                      ) == .none else {
                    throw AntigravityManagedSessionError
                        .recordRecoveryBlocked
                }
                // An exact current-owner intent with no candidate is a
                // failed pre-spawn transaction from this process. The caller
                // already holds the cross-process launch lock, so removing
                // it cannot race a live launch transaction.
                resolutions.append(.remove(intent))
                continue
            case .unavailable:
                throw AntigravityManagedSessionError
                    .recordRecoveryBlocked
            case .gone:
                break
            }

            switch intentInspector.candidates(
                ownedBy: intent.owner,
                executable: intent.executable
            ) {
            case .none:
                resolutions.append(.remove(intent))
            case .unique(let child):
                guard let record = AntigravityManagedProcessRecord(
                    sessionID: intent.sessionID,
                    bootSessionID: currentBoot,
                    child: child,
                    processGroupID: child.pid,
                    owner: intent.owner,
                    createdAt: intent.createdAt
                ) else {
                    throw AntigravityManagedSessionError
                        .recordRecoveryBlocked
                }
                resolutions.append(.promote(intent, record))
            case .multiple, .unavailable:
                throw AntigravityManagedSessionError
                    .recordRecoveryBlocked
            }
        }

        do {
            for resolution in resolutions {
                switch resolution {
                case .remove(let intent):
                    try ledgerStore.removeIntent(intent)
                case .promote(let intent, let record):
                    try ledgerStore.promoteIntent(
                        intent,
                        to: record
                    )
                }
            }
        } catch {
            throw AntigravityManagedSessionError
                .recordRecoveryBlocked
        }

        try await recordRecovery.recoverOrphanedProcesses()
    }
}
