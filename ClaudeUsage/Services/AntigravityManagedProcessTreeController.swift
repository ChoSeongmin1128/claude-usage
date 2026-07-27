import Darwin
import Foundation

nonisolated enum AntigravityManagedProcessCleanupResult:
    Sendable,
    Equatable
{
    /// The root and every provable descendant disappeared and the record was
    /// removed.
    case complete

    /// No owned execution remained, but deleting the durable record failed.
    case recordRemovalFailed

    /// At least one execution or ownership ambiguity remains. The record must
    /// be preserved for a later fail-closed recovery.
    case incomplete
}

nonisolated protocol AntigravityManagedProcessTreeTerminating:
    Sendable
{
    func terminate(
        sessionID: UUID,
        handle: any AntigravityManagedCLIProcessHandling,
        gracePeriod: Duration
    ) async -> AntigravityManagedProcessCleanupResult
}

nonisolated enum AntigravityManagedProcessObservationResult:
    Sendable,
    Equatable
{
    case complete
    case incomplete
}

nonisolated protocol AntigravityManagedProcessTreeObserving:
    Sendable
{
    func observe(
        sessionID: UUID
    ) async -> AntigravityManagedProcessObservationResult
}

nonisolated protocol AntigravityManagedProcessTreeControlling:
    AntigravityManagedProcessTreeTerminating,
    AntigravityManagedProcessTreeObserving
{}

/// Coordinates normal owned-process teardown.
///
/// The spawned handle remains responsible for its unreaped root and dedicated
/// process group. This controller owns ancestry observation, durable record
/// updates, and exact signalling of descendants that left that group.
nonisolated struct AntigravityManagedProcessTreeController:
    AntigravityManagedProcessTreeControlling
{
    private let recordStore:
        any AntigravityManagedProcessRecordStoring
    private let processInspector:
        any AntigravityRecordedProcessInspecting
    private let processTreeInspector:
        any AntigravityManagedProcessTreeInspecting
    private let signaler: any AntigravityExactProcessSignaling
    private let now: @Sendable () -> Date
    private let observationDelay: Duration
    private let sleep:
        @Sendable (Duration) async throws -> Void

    init(
        recordStore:
            any AntigravityManagedProcessRecordStoring,
        processInspector:
            any AntigravityRecordedProcessInspecting,
        processTreeInspector:
            any AntigravityManagedProcessTreeInspecting,
        signaler:
            any AntigravityExactProcessSignaling =
                AntigravitySystemExactProcessSignaler(),
        now: @escaping @Sendable () -> Date = Date.init,
        observationDelay: Duration = .milliseconds(50),
        sleep:
            @escaping @Sendable (Duration) async throws -> Void = {
                try await Task.sleep(for: $0)
            }
    ) {
        self.recordStore = recordStore
        self.processInspector = processInspector
        self.processTreeInspector = processTreeInspector
        self.signaler = signaler
        self.now = now
        self.observationDelay = observationDelay
        self.sleep = sleep
    }

    func observe(
        sessionID: UUID
    ) async -> AntigravityManagedProcessObservationResult {
        guard let record = loadRecord(sessionID: sessionID) else {
            return .incomplete
        }
        let observation = observeRecord(record)
        guard !observation.persistenceFailed,
              observation.record.observationCompleteness
                == .complete else {
            return .incomplete
        }
        return .complete
    }

    func terminate(
        sessionID: UUID,
        handle: any AntigravityManagedCLIProcessHandling,
        gracePeriod: Duration
    ) async -> AntigravityManagedProcessCleanupResult {
        guard var record = loadRecord(sessionID: sessionID) else {
            _ = await handle.terminateTree(
                gracePeriod: gracePeriod
            )
            return .incomplete
        }

        var persistenceFailed = false
        let beforeTermination = observeRecord(record)
        record = beforeTermination.record
        persistenceFailed = beforeTermination.persistenceFailed
        var signallingFailed = signalDescendants(
            in: record,
            signal: SIGTERM
        )

        // The handle keeps the root unreaped until its group TERM/KILL is
        // complete, so the process-group ID cannot be reused during this call.
        let rootTermination = await handle.terminateTree(
            gracePeriod: gracePeriod
        )

        let afterGroup = observeRecord(record)
        record = afterGroup.record
        persistenceFailed =
            persistenceFailed || afterGroup.persistenceFailed
        signallingFailed =
            signalDescendants(
                in: record,
                signal: SIGKILL
            ) || signallingFailed

        if observationDelay > .zero {
            try? await sleep(observationDelay)
        }

        let final = observeRecord(record)
        record = final.record
        persistenceFailed =
            persistenceFailed || final.persistenceFailed

        guard !persistenceFailed,
              !signallingFailed,
              rootTermination == .confirmed,
              record.observationCompleteness == .complete,
              allRecordedExecutionsAreGone(record) else {
            return .incomplete
        }

        do {
            try recordStore.remove(sessionID: sessionID)
            return .complete
        } catch {
            return .recordRemovalFailed
        }
    }

    private func loadRecord(
        sessionID: UUID
    ) -> AntigravityManagedProcessRecord? {
        guard let records = try? recordStore.load(),
              records.filter({
                  $0.sessionID == sessionID
              }).count == 1 else {
            return nil
        }
        return records.first {
            $0.sessionID == sessionID
        }
    }

    private func observeRecord(
        _ record: AntigravityManagedProcessRecord
    ) -> (
        record: AntigravityManagedProcessRecord,
        persistenceFailed: Bool
    ) {
        let snapshot = processTreeInspector.snapshot(
            for: record
        )
        guard let updated = record.mergingObservation(
            rootExecution: snapshot?.rootExecution,
            descendants: snapshot?.descendants ?? [],
            scanWasComplete: snapshot?.isComplete == true,
            observedAt: now()
        ) else {
            return (record, true)
        }
        guard updated != record else {
            return (record, false)
        }
        do {
            try recordStore.update(updated)
            return (updated, false)
        } catch {
            return (record, true)
        }
    }

    /// Returns true when any exact signal failed for a reason other than the
    /// target having already exited.
    private func signalDescendants(
        in record: AntigravityManagedProcessRecord,
        signal: Int32
    ) -> Bool {
        guard let identities =
            AntigravityManagedProcessTerminationOrder.deepestFirst(
                record.observedDescendants + [record.child]
            ) else {
            return true
        }
        var failed = false
        for identity in identities
        where identity.kernelIdentity.uniqueID
            != record.child.kernelIdentity.uniqueID {
            do {
                try signaler.signal(identity, signal: signal)
            } catch AntigravityExactProcessSignalError.processNotFound {
                continue
            } catch {
                failed = true
            }
        }
        return failed
    }

    private func allRecordedExecutionsAreGone(
        _ record: AntigravityManagedProcessRecord
    ) -> Bool {
        for identity in
            record.observedDescendants + [record.child] {
            switch processInspector.process(for: identity.pid) {
            case .notFound:
                continue
            case .running(let current):
                // A reused PID is not this managed execution.
                if current.kernelIdentity.uniqueID
                    != identity.kernelIdentity.uniqueID {
                    continue
                }
                // The same unique process may have exec'd after the final
                // observation. Keep the record so a fresh snapshot can
                // persist and signal its new pidversion.
                return false
            case .unavailable:
                return false
            }
        }
        return true
    }
}
