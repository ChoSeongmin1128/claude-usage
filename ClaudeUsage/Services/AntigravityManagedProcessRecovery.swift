import Darwin
import Foundation

nonisolated protocol AntigravityManagedProcessRecovering: Sendable {
    func recoverOrphanedProcesses() async throws
}

/// A tri-state process lookup used during crash recovery.
///
/// `notFound` is positive evidence that a PID is no longer present.
/// `unavailable` means the process could not be identified safely and must
/// therefore retain its record without receiving a signal.
nonisolated enum AntigravityRecordedProcessLookup:
    Sendable,
    Equatable
{
    case running(AntigravityRecordedProcessIdentity)
    case notFound
    case unavailable
}

nonisolated protocol AntigravityRecordedProcessInspecting: Sendable {
    func process(
        for processID: Int32
    ) -> AntigravityRecordedProcessLookup
}

extension AntigravityRecordedProcessInspecting {
    /// Positive evidence that every listed execution no longer exists.
    ///
    /// A PID running with a different kernel unique ID is a reused PID,
    /// which is positive absence of the recorded execution. A matching
    /// unique ID is never absence: the same unique process may have exec'd
    /// after the last observation, so the record must be kept. An
    /// unavailable lookup is never treated as absence. This single policy
    /// is shared by shutdown cleanup and crash recovery so the two ledger
    /// owners cannot drift apart.
    func executionsAreProvablyGone(
        _ identities: [AntigravityRecordedProcessIdentity]
    ) -> Bool {
        for identity in identities {
            switch process(for: identity.pid) {
            case .notFound:
                continue
            case .unavailable:
                return false
            case .running(let current):
                guard current.kernelIdentity.uniqueID
                    != identity.kernelIdentity.uniqueID
                else {
                    return false
                }
            }
        }
        return true
    }
}

/// Reports whether any live process may still belong to a recorded process
/// group. Used only as negative evidence for reclaiming an incomplete
/// record: a live member (including a false positive from PGID reuse) keeps
/// the record, never authorizes a signal.
nonisolated protocol AntigravityProcessGroupLivenessChecking: Sendable {
    func groupMayHaveLiveMember(_ processGroupID: Int32) -> Bool
}

nonisolated struct AntigravitySystemProcessGroupLivenessChecker:
    AntigravityProcessGroupLivenessChecking
{
    private let processIDList: any AntigravityProcessIDListing

    init(
        processIDList: any AntigravityProcessIDListing =
            AntigravitySystemProcessIDList()
    ) {
        self.processIDList = processIDList
    }

    func groupMayHaveLiveMember(_ processGroupID: Int32) -> Bool {
        guard processGroupID > 1 else { return true }
        guard let processIDs = processIDList.allProcessIDs() else {
            return true
        }
        for processID in processIDs where processID > 1 {
            if getpgid(processID) == processGroupID {
                return true
            }
        }
        return false
    }
}

nonisolated struct AntigravitySystemRecordedProcessInspector:
    AntigravityRecordedProcessInspecting
{
    private let identityProvider:
        any AntigravityManagedProcessIdentityProviding
    private let existenceChecker:
        any AntigravityProcessExistenceChecking

    init(
        identityProvider:
            any AntigravityManagedProcessIdentityProviding =
                AntigravityManagedProcessIdentityProvider(),
        existenceChecker:
            any AntigravityProcessExistenceChecking =
                AntigravitySystemProcessExistenceChecker()
    ) {
        self.identityProvider = identityProvider
        self.existenceChecker = existenceChecker
    }

    func process(
        for processID: Int32
    ) -> AntigravityRecordedProcessLookup {
        guard processID > 1 else { return .notFound }

        switch existenceChecker.existence(of: processID) {
        case .notFound, .terminated:
            return .notFound
        case .unavailable:
            return .unavailable
        case .present:
            break
        }

        if let identity = identityProvider.identity(
            for: processID
        ) {
            return .running(identity)
        }

        // The process may have exited while libproc was double-reading it.
        // Only ESRCH turns that race into positive absence; every other
        // failure remains unavailable.
        switch existenceChecker.existence(of: processID) {
        case .notFound, .terminated:
            return .notFound
        case .present, .unavailable:
            return .unavailable
        }
    }

}

/// Recovers only process executions whose durable kernel identities still
/// match. Recovery never signals a persisted process-group ID: after an app
/// crash there is no unreaped child reserving that ID, so a group signal could
/// target an unrelated process after PID/PGID reuse.
actor AntigravityManagedProcessRecovery:
    AntigravityManagedProcessRecovering
{
    private struct RecoveryCandidate {
        let record: AntigravityManagedProcessRecord
        let targets: [AntigravityRecordedProcessIdentity]
    }

    private enum Inspection {
        case stale(AntigravityManagedProcessRecord)
        case recoverable(RecoveryCandidate)
        case blocked
    }

    private let recordStore:
        any AntigravityManagedProcessRecordStoring
    private let processInspector:
        any AntigravityRecordedProcessInspecting
    private let processTreeInspector:
        any AntigravityManagedProcessTreeInspecting
    private let processGroupLiveness:
        any AntigravityProcessGroupLivenessChecking
    private let signaler: any AntigravityExactProcessSignaling
    private let sleep:
        @Sendable (Duration) async throws -> Void
    private let terminationGracePeriod: Duration
    private let killObservationDelay: Duration
    private let now: @Sendable () -> Date

    init(
        recordStore:
            any AntigravityManagedProcessRecordStoring,
        processInspector:
            any AntigravityRecordedProcessInspecting =
                AntigravitySystemRecordedProcessInspector(),
        processTreeInspector:
            (any AntigravityManagedProcessTreeInspecting)? = nil,
        processGroupLiveness:
            any AntigravityProcessGroupLivenessChecking =
                AntigravitySystemProcessGroupLivenessChecker(),
        signaler:
            any AntigravityExactProcessSignaling =
                AntigravitySystemExactProcessSignaler(),
        terminationGracePeriod: Duration = .milliseconds(250),
        killObservationDelay: Duration = .milliseconds(50),
        now: @escaping @Sendable () -> Date = Date.init,
        sleep:
            @escaping @Sendable (Duration) async throws -> Void = {
                try await Task.sleep(for: $0)
            }
    ) {
        self.recordStore = recordStore
        self.processInspector = processInspector
        if let processTreeInspector {
            self.processTreeInspector = processTreeInspector
        } else {
            let identityProvider =
                AntigravityManagedProcessIdentityProvider()
            self.processTreeInspector =
                AntigravitySystemManagedProcessTreeInspector(
                    identityProvider: identityProvider
                )
        }
        self.processGroupLiveness = processGroupLiveness
        self.signaler = signaler
        self.terminationGracePeriod = terminationGracePeriod
        self.killObservationDelay = killObservationDelay
        self.now = now
        self.sleep = sleep
    }

    func recoverOrphanedProcesses() async throws {
        let records: [AntigravityManagedProcessRecord]
        do {
            records = try recordStore.load()
        } catch {
            throw AntigravityManagedSessionError.recordRecoveryBlocked
        }

        var staleRecords: [AntigravityManagedProcessRecord] = []
        var candidates: [RecoveryCandidate] = []
        var recoveryWasBlocked = false

        // Preflight every record before sending any signal. A single
        // ambiguous record blocks the batch so two app instances cannot make
        // conflicting ownership decisions from a partially mutated file.
        for record in records {
            switch inspect(record) {
            case .stale(let updated):
                staleRecords.append(updated)
            case .recoverable(let candidate):
                candidates.append(candidate)
            case .blocked:
                recoveryWasBlocked = true
            }
        }

        guard !recoveryWasBlocked else {
            throw AntigravityManagedSessionError
                .recordRecoveryBlocked
        }
        for record in staleRecords {
            do {
                try recordStore.remove(
                    sessionID: record.sessionID
                )
            } catch {
                recoveryWasBlocked = true
            }
        }
        guard !recoveryWasBlocked else {
            throw AntigravityManagedSessionError
                .recordRecoveryBlocked
        }

        for candidate in candidates {
            do {
                try await terminate(candidate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AntigravityManagedSessionError
                    .recordRecoveryBlocked
            }
        }
    }

    private func inspect(
        _ record: AntigravityManagedProcessRecord
    ) -> Inspection {
        guard let observation = observe(record) else {
            return .blocked
        }
        if observation.record.observationCompleteness
            == .incomplete {
            // An incomplete record never authorizes signals: descendants
            // may exist that were never observed. Reclaiming it as stale
            // is allowed only on layered positive evidence that nothing it
            // could still be protecting exists:
            //  1. the recorded descendant list was never truncated,
            //  2. the fresh tree scan had full process-table visibility
            //     and attributes no live root or descendant,
            //  3. every recorded execution (owner, root child, observed
            //     descendants) is provably gone,
            //  4. no live process may belong to the recorded process
            //     group (PGID-reuse false positives only keep the record).
            // Any ambiguity keeps the record blocking, fail-closed.
            // Without reclamation such a record would block managed launch
            // until the next reboot while adding no cleanup ability.
            guard observation.record.observedDescendants.count
                < AntigravityManagedProcessRecord
                    .maximumObservedDescendantCount,
                observation.snapshot.isComplete,
                observation.snapshot.rootExecution == nil,
                observation.snapshot.descendants.isEmpty,
                recordedExecutionsAreProvablyGone(
                    observation.record
                ),
                !processGroupLiveness.groupMayHaveLiveMember(
                    observation.record.processGroupID
                )
            else {
                return .blocked
            }
            return .stale(observation.record)
        }

        let currentTargets: [AntigravityRecordedProcessIdentity]
        switch exactTargets(in: observation.record) {
        case .success(let targets):
            currentTargets = targets
        case .failure:
            return .blocked
        }

        guard !currentTargets.isEmpty else {
            return .stale(observation.record)
        }

        switch processInspector.process(
            for: observation.record.owner.pid
        ) {
        case .running(let owner):
            guard owner.kernelIdentity.uniqueID
                    != observation.record.owner
                        .kernelIdentity.uniqueID else {
                // The same owner may have exec'd between observations.
                return .blocked
            }
            return .recoverable(RecoveryCandidate(
                record: observation.record,
                targets: currentTargets
            ))
        case .unavailable:
            return .blocked
        case .notFound:
            return .recoverable(RecoveryCandidate(
                record: observation.record,
                targets: currentTargets
            ))
        }
    }

    private func terminate(
        _ initial: RecoveryCandidate
    ) async throws {
        try signal(
            initial.targets,
            signal: SIGTERM
        )

        if terminationGracePeriod > .zero {
            try await sleep(terminationGracePeriod)
        }

        guard let afterTerm = observe(initial.record),
              afterTerm.record.observationCompleteness
                != .incomplete else {
            throw AntigravityManagedSessionError
                .recordRecoveryBlocked
        }
        let killTargets: [AntigravityRecordedProcessIdentity]
        switch exactTargets(in: afterTerm.record) {
        case .success(let targets):
            killTargets = targets
        case .failure:
            throw AntigravityManagedSessionError
                .recordRecoveryBlocked
        }
        try signal(killTargets, signal: SIGKILL)

        if killObservationDelay > .zero {
            try await sleep(killObservationDelay)
        }

        guard let final = observe(afterTerm.record),
              final.record.observationCompleteness
                != .incomplete else {
            throw AntigravityManagedSessionError
                .recordRecoveryBlocked
        }
        switch exactTargets(in: final.record) {
        case .success(let remaining) where remaining.isEmpty:
            try recordStore.remove(
                sessionID: final.record.sessionID
            )
        case .success, .failure:
            throw AntigravityManagedSessionError
                .recordRecoveryBlocked
        }
    }

    private func recordedExecutionsAreProvablyGone(
        _ record: AntigravityManagedProcessRecord
    ) -> Bool {
        processInspector.executionsAreProvablyGone(
            [record.owner, record.child]
                + record.observedDescendants
        )
    }

    private func observe(
        _ record: AntigravityManagedProcessRecord
    ) -> (
        record: AntigravityManagedProcessRecord,
        snapshot: AntigravityManagedProcessTreeSnapshot
    )? {
        guard let snapshot = processTreeInspector.snapshot(
            for: record
        ),
        let updated = record.mergingObservation(
            rootExecution: snapshot.rootExecution,
            descendants: snapshot.descendants,
            scanWasComplete: snapshot.isComplete,
            observedAt: now()
        ) else {
            return nil
        }

        if updated != record {
            do {
                try recordStore.update(updated)
            } catch {
                return nil
            }
        }
        return (updated, snapshot)
    }

    private func exactTargets(
        in record: AntigravityManagedProcessRecord
    ) -> Result<
        [AntigravityRecordedProcessIdentity],
        AntigravityManagedSessionError
    > {
        guard let identities =
            AntigravityManagedProcessTerminationOrder.deepestFirst(
                record.observedDescendants + [record.child]
            ) else {
            return .failure(.recordRecoveryBlocked)
        }
        var targets: [AntigravityRecordedProcessIdentity] = []
        for identity in identities {
            switch processInspector.process(for: identity.pid) {
            case .notFound:
                continue
            case .unavailable:
                return .failure(.recordRecoveryBlocked)
            case .running(let current):
                // PID reuse or exec after the last observation is not signal
                // authority. A fresh tree observation may record an exec'd
                // descendant under the same kernel unique ID.
                guard current == identity else {
                    if current.kernelIdentity.uniqueID
                        == identity.kernelIdentity.uniqueID {
                        return .failure(.recordRecoveryBlocked)
                    }
                    continue
                }
                targets.append(identity)
            }
        }
        return .success(targets)
    }

    private func signal(
        _ identities: [AntigravityRecordedProcessIdentity],
        signal: Int32
    ) throws {
        for identity in identities {
            do {
                try signaler.signal(identity, signal: signal)
            } catch AntigravityExactProcessSignalError.processNotFound {
                // The exact execution exited between snapshot and the atomic
                // kernel lookup. No other process received the signal.
                continue
            } catch {
                throw AntigravityManagedSessionError
                    .recordRecoveryBlocked
            }
        }
    }
}
