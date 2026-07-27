import Darwin
import Foundation

nonisolated protocol AntigravityProcessIDListing: Sendable {
    func allProcessIDs() -> [Int32]?
}

nonisolated enum AntigravityProcessExistence:
    Sendable,
    Equatable
{
    case present
    /// The PID is still reserved by a zombie, but no user execution remains.
    case terminated
    case notFound
    case unavailable
}

nonisolated struct AntigravityProcessTableState:
    Sendable,
    Equatable
{
    let processID: Int32
    let parentProcessID: Int32
    let processGroupID: Int32
    let effectiveUserID: UInt32
    let realUserID: UInt32
    let startedAtSeconds: Int64
    let startedAtMicroseconds: Int32
    let isZombie: Bool

    init?(
        processID: Int32,
        parentProcessID: Int32,
        processGroupID: Int32,
        effectiveUserID: UInt32,
        realUserID: UInt32,
        startedAtSeconds: Int64,
        startedAtMicroseconds: Int32,
        isZombie: Bool
    ) {
        guard processID > 1,
              parentProcessID >= 0,
              processGroupID >= 0,
              startedAtSeconds >= 0,
              (0..<1_000_000).contains(
                  startedAtMicroseconds
              ) else {
            return nil
        }
        self.processID = processID
        self.parentProcessID = parentProcessID
        self.processGroupID = processGroupID
        self.effectiveUserID = effectiveUserID
        self.realUserID = realUserID
        self.startedAtSeconds = startedAtSeconds
        self.startedAtMicroseconds = startedAtMicroseconds
        self.isZombie = isZombie
    }
}

nonisolated protocol AntigravityProcessTableStateReading:
    Sendable
{
    /// Returns nil when the kernel process table cannot be read.
    func state(
        for processID: Int32
    ) -> AntigravityProcessTableState?
}

/// Reads process state from KERN_PROC_PID. Unlike libproc's detailed identity
/// flavors, this remains available for unreaped same-user zombies.
nonisolated struct AntigravitySystemProcessTableStateReader:
    AntigravityProcessTableStateReading
{
    func state(
        for processID: Int32
    ) -> AntigravityProcessTableState? {
        guard processID > 1 else { return nil }

        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name = [
            CTL_KERN,
            KERN_PROC,
            KERN_PROC_PID,
            processID,
        ]
        let result = name.withUnsafeMutableBufferPointer { buffer in
            sysctl(
                buffer.baseAddress,
                u_int(buffer.count),
                &process,
                &size,
                nil,
                0
            )
        }
        guard result == 0,
              size == MemoryLayout<kinfo_proc>.size,
              process.kp_proc.p_pid == processID else {
            return nil
        }
        return AntigravityProcessTableState(
            processID: processID,
            parentProcessID: process.kp_eproc.e_ppid,
            processGroupID: process.kp_eproc.e_pgid,
            effectiveUserID:
                process.kp_eproc.e_ucred.cr_uid,
            realUserID:
                process.kp_eproc.e_pcred.p_ruid,
            startedAtSeconds:
                Int64(process.kp_proc.p_starttime.tv_sec),
            startedAtMicroseconds:
                Int32(process.kp_proc.p_starttime.tv_usec),
            isZombie: process.kp_proc.p_stat == SZOMB
        )
    }
}

nonisolated protocol AntigravityProcessExistenceChecking:
    Sendable
{
    func existence(
        of processID: Int32
    ) -> AntigravityProcessExistence
}

nonisolated struct AntigravitySystemProcessExistenceChecker:
    AntigravityProcessExistenceChecking
{
    private let processTableStateReader:
        any AntigravityProcessTableStateReading

    init(
        processTableStateReader:
            any AntigravityProcessTableStateReading =
                AntigravitySystemProcessTableStateReader()
    ) {
        self.processTableStateReader = processTableStateReader
    }

    func existence(
        of processID: Int32
    ) -> AntigravityProcessExistence {
        guard processID > 1 else { return .notFound }
        let initialSignalResult = Darwin.kill(processID, 0)
        if initialSignalResult == -1, errno == ESRCH {
            return .notFound
        }
        guard initialSignalResult == 0 || errno == EPERM else {
            return .unavailable
        }

        if let state = processTableStateReader.state(
            for: processID
        ) {
            return state.isZombie ? .terminated : .present
        }

        // The process may have disappeared between kill(2) and sysctl(3).
        if Darwin.kill(processID, 0) == -1, errno == ESRCH {
            return .notFound
        }
        return .unavailable
    }
}

nonisolated protocol AntigravitySystemBootTimeProviding:
    Sendable
{
    func bootTime() -> Date?
}

nonisolated struct AntigravitySystemBootTimeProvider:
    AntigravitySystemBootTimeProviding
{
    func bootTime() -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname(
            "kern.boottime",
            &value,
            &size,
            nil,
            0
        ) == 0,
        size == MemoryLayout<timeval>.size,
        value.tv_sec >= 0,
        (0..<1_000_000).contains(value.tv_usec) else {
            return nil
        }
        return Date(
            timeIntervalSince1970:
                TimeInterval(value.tv_sec)
                + (TimeInterval(value.tv_usec) / 1_000_000)
        )
    }
}

nonisolated struct AntigravitySystemProcessIDList:
    AntigravityProcessIDListing
{
    private static let maximumProcessCount = 65_536

    func allProcessIDs() -> [Int32]? {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return nil }

        var capacity = min(
            max(Int(estimatedCount) + 64, 256),
            Self.maximumProcessCount
        )
        for _ in 0..<3 {
            var processIDs = [Int32](
                repeating: 0,
                count: capacity
            )
            let count = processIDs.withUnsafeMutableBytes {
                proc_listallpids(
                    $0.baseAddress,
                    Int32($0.count)
                )
            }
            guard count > 0 else { return nil }
            if count < capacity {
                return Array(
                    processIDs.prefix(Int(count))
                ).filter { $0 > 1 }
            }
            guard capacity < Self.maximumProcessCount else {
                return nil
            }
            capacity = min(
                capacity * 2,
                Self.maximumProcessCount
            )
        }
        return nil
    }
}

nonisolated struct AntigravityManagedProcessTreeSnapshot:
    Sendable,
    Equatable
{
    /// The current root execution when the original kernel unique identifier
    /// still resolves. `nil` is positive absence or PID reuse, not authority
    /// to replace the persisted root.
    let rootExecution: AntigravityRecordedProcessIdentity?

    /// Descendants are ordered deepest-first for termination.
    let descendants: [AntigravityRecordedProcessIdentity]
    let isComplete: Bool

    init(
        rootExecution: AntigravityRecordedProcessIdentity? = nil,
        descendants: [AntigravityRecordedProcessIdentity],
        isComplete: Bool
    ) {
        self.rootExecution = rootExecution
        self.descendants = descendants
        self.isComplete = isComplete
    }
}

nonisolated protocol AntigravityManagedProcessTreeInspecting:
    Sendable
{
    func snapshot(
        for record: AntigravityManagedProcessRecord
    ) -> AntigravityManagedProcessTreeSnapshot?
}

/// Discovers descendants through XNU's immutable parent unique identifier.
///
/// Unlike PPID, `parentUniqueID` is not rewritten when a process is
/// reparented. Durable descendants are also ancestry seeds, so a child first
/// observed after its already-recorded parent exits remains attributable. A
/// process that completed an unobserved double-fork before any durable
/// snapshot is intentionally not guessed.
nonisolated final class AntigravitySystemManagedProcessTreeInspector:
    AntigravityManagedProcessTreeInspecting,
    @unchecked Sendable
{
    private struct Node {
        let processID: Int32
        let kernelIdentity: AntigravityKernelProcessIdentity
    }

    private let processIDList: any AntigravityProcessIDListing
    private let kernelIdentityReader:
        any AntigravityKernelProcessIdentityReading
    private let identityProvider:
        any AntigravityManagedProcessIdentityProviding
    private let existenceChecker:
        any AntigravityProcessExistenceChecking
    private let processTableStateReader:
        any AntigravityProcessTableStateReading
    private let bootTimeProvider:
        any AntigravitySystemBootTimeProviding

    init(
        processIDList: any AntigravityProcessIDListing =
            AntigravitySystemProcessIDList(),
        kernelIdentityReader:
            any AntigravityKernelProcessIdentityReading =
                AntigravitySystemKernelProcessIdentityReader(
                    includeTerminatedProcesses: true
                ),
        identityProvider:
            any AntigravityManagedProcessIdentityProviding,
        existenceChecker:
            any AntigravityProcessExistenceChecking =
                AntigravitySystemProcessExistenceChecker(),
        processTableStateReader:
            any AntigravityProcessTableStateReading =
                AntigravitySystemProcessTableStateReader(),
        bootTimeProvider:
            any AntigravitySystemBootTimeProviding =
                AntigravitySystemBootTimeProvider()
    ) {
        self.processIDList = processIDList
        self.kernelIdentityReader = kernelIdentityReader
        self.identityProvider = identityProvider
        self.existenceChecker = existenceChecker
        self.processTableStateReader = processTableStateReader
        self.bootTimeProvider = bootTimeProvider
    }

    func snapshot(
        for record: AntigravityManagedProcessRecord
    ) -> AntigravityManagedProcessTreeSnapshot? {
        snapshot(
            for: record,
            mayRetryOpaqueProcesses: true
        )
    }

    private func snapshot(
        for record: AntigravityManagedProcessRecord,
        mayRetryOpaqueProcesses: Bool
    ) -> AntigravityManagedProcessTreeSnapshot? {
        guard let processIDs = processIDList.allProcessIDs() else {
            return nil
        }
        guard let bootTime = bootTimeProvider.bootTime() else {
            return nil
        }

        let durableIdentities =
            [record.child] + record.observedDescendants
        guard record.createdAt >= bootTime,
              durableIdentities.allSatisfy({
                  Self.startedAt($0) >= bootTime
              }) else {
            return AntigravityManagedProcessTreeSnapshot(
                descendants: [],
                isComplete: false
            )
        }

        var nodesByUniqueID: [UInt64: Node] = [:]
        var opaqueProcesses: [AntigravityProcessTableState] = []
        var complete = true
        for processID in Set(processIDs) {
            let kernelIdentity:
                AntigravityKernelProcessIdentity
            if let initial = kernelIdentityReader.kernelIdentity(
                for: processID
            ) {
                kernelIdentity = initial
            } else {
                let initialExistence =
                    existenceChecker.existence(of: processID)
                if initialExistence == .notFound {
                    continue
                }
                if let retry =
                    kernelIdentityReader.kernelIdentity(
                        for: processID
                    ) {
                    kernelIdentity = retry
                } else if let state =
                    processTableStateReader.state(
                        for: processID
                    ),
                    state.processID == processID {
                    opaqueProcesses.append(state)
                    continue
                } else {
                    let finalExistence =
                        existenceChecker.existence(
                            of: processID
                        )
                    if finalExistence == .notFound {
                        continue
                    }
                    complete = false
                    continue
                }
            }
            let node = Node(
                processID: processID,
                kernelIdentity: kernelIdentity
            )
            if nodesByUniqueID[kernelIdentity.uniqueID] != nil {
                // A kernel unique identifier must map to one execution.
                return nil
            }
            nodesByUniqueID[kernelIdentity.uniqueID] = node
        }

        var depthByUniqueID = Self.durableSeedDepths(
            durableIdentities,
            rootUniqueID: record.child.kernelIdentity.uniqueID
        )
        var madeProgress = true
        while madeProgress {
            madeProgress = false
            for node in nodesByUniqueID.values
            where depthByUniqueID[
                node.kernelIdentity.uniqueID
            ] == nil {
                guard let parentDepth = depthByUniqueID[
                    node.kernelIdentity.parentUniqueID
                ] else {
                    continue
                }
                depthByUniqueID[node.kernelIdentity.uniqueID] =
                    parentDepth + 1
                madeProgress = true
            }
        }

        let currentManagedProcessIDs = Set(
            nodesByUniqueID.values.compactMap { node in
                depthByUniqueID[
                    node.kernelIdentity.uniqueID
                ] == nil ? nil : node.processID
            }
        )
        let relatedOpaqueProcesses =
            Self.potentiallyManagedOpaqueProcesses(
            opaqueProcesses,
            managedProcessIDs:
                currentManagedProcessIDs,
            record: record
        )
        var shouldRetryOpaqueProcesses = false
        var hasUnresolvedRelatedProcess = false
        for observed in relatedOpaqueProcesses {
            if let current = processTableStateReader.state(
                for: observed.processID
            ) {
                guard current.hasSameExecution(as: observed) else {
                    continue
                }
                if kernelIdentityReader.kernelIdentity(
                    for: observed.processID
                ) != nil {
                    shouldRetryOpaqueProcesses = true
                } else {
                    hasUnresolvedRelatedProcess = true
                }
            } else {
                let existence = existenceChecker.existence(
                    of: observed.processID
                )
                if existence != .notFound {
                    hasUnresolvedRelatedProcess = true
                }
            }
        }
        if shouldRetryOpaqueProcesses,
           mayRetryOpaqueProcesses {
            return snapshot(
                for: record,
                mayRetryOpaqueProcesses: false
            )
        }
        if hasUnresolvedRelatedProcess
            || (shouldRetryOpaqueProcesses
                && !mayRetryOpaqueProcesses) {
            complete = false
        }

        let descendantNodes = nodesByUniqueID.values.filter {
            depthByUniqueID[$0.kernelIdentity.uniqueID] != nil
                && $0.kernelIdentity.uniqueID
                    != record.child.kernelIdentity.uniqueID
        }
        var rootExecution: AntigravityRecordedProcessIdentity?
        if let rootNode = nodesByUniqueID[
            record.child.kernelIdentity.uniqueID
        ] {
            guard rootNode.processID == record.child.pid else {
                return AntigravityManagedProcessTreeSnapshot(
                    descendants: [],
                    isComplete: false
                )
            }
            if let currentRoot = identityProvider.identity(
                for: rootNode.processID
            ) {
                guard currentRoot.kernelIdentity
                        == rootNode.kernelIdentity,
                      currentRoot.hasStableExecutionInvariants(
                        as: record.child
                      ) else {
                    return AntigravityManagedProcessTreeSnapshot(
                        descendants: [],
                        isComplete: false
                    )
                }
                rootExecution = currentRoot
            } else {
                let existence = existenceChecker.existence(
                    of: rootNode.processID
                )
                if existence != .notFound,
                   existence != .terminated {
                    complete = false
                }
            }
        }

        var descendants:
            [(identity: AntigravityRecordedProcessIdentity, depth: Int)] = []
        descendants.reserveCapacity(descendantNodes.count)

        for node in descendantNodes {
            guard let identity = identityProvider.identity(
                for: node.processID
            ) else {
                // An exited process remains useful as an ancestry edge for
                // children captured in this same snapshot. A still-live but
                // unreadable execution makes the snapshot ambiguous.
                let existence = existenceChecker.existence(
                    of: node.processID
                )
                if existence == .notFound
                    || existence == .terminated {
                    continue
                }
                complete = false
                continue
            }
            guard identity.kernelIdentity == node.kernelIdentity,
                  identity.effectiveUserID
                    == record.child.effectiveUserID,
                  identity.realUserID
                    == record.child.realUserID,
                  Self.startedAt(identity) >= bootTime else {
                complete = false
                continue
            }

            if let durable = durableIdentities.first(where: {
                $0.kernelIdentity.uniqueID
                    == identity.kernelIdentity.uniqueID
            }),
            !identity.hasStableExecutionInvariants(as: durable) {
                complete = false
                continue
            }
            descendants.append((
                identity,
                depthByUniqueID[
                    node.kernelIdentity.uniqueID
                ] ?? 1
            ))
        }

        descendants.sort {
            if $0.depth != $1.depth {
                return $0.depth > $1.depth
            }
            if $0.identity.kernelIdentity.uniqueID
                != $1.identity.kernelIdentity.uniqueID {
                return $0.identity.kernelIdentity.uniqueID
                    < $1.identity.kernelIdentity.uniqueID
            }
            return $0.identity.pid < $1.identity.pid
        }
        return AntigravityManagedProcessTreeSnapshot(
            rootExecution: rootExecution,
            descendants: descendants.map(\.identity),
            isComplete: complete
        )
    }

    private static func durableSeedDepths(
        _ identities: [AntigravityRecordedProcessIdentity],
        rootUniqueID: UInt64
    ) -> [UInt64: Int] {
        var depths = [rootUniqueID: 0]
        var unresolved = Dictionary(
            uniqueKeysWithValues: identities
                .filter {
                    $0.kernelIdentity.uniqueID != rootUniqueID
                }
                .map {
                    ($0.kernelIdentity.uniqueID, $0)
                }
        )
        var madeProgress = true
        while madeProgress {
            madeProgress = false
            let resolved = unresolved.compactMap {
                entry -> (UInt64, Int)? in
                let (uniqueID, identity) = entry
                guard let parentDepth = depths[
                    identity.kernelIdentity.parentUniqueID
                ] else { return nil }
                return (uniqueID, parentDepth + 1)
            }
            for (uniqueID, depth) in resolved {
                depths[uniqueID] = depth
                unresolved.removeValue(forKey: uniqueID)
                madeProgress = true
            }
        }

        // Each identity was durably proven in an earlier complete scan. Keep
        // disconnected persisted identities as conservative ancestry seeds.
        // The boot-time check above is only a sanity check; the durable
        // ledger must also require exact boot-session UUID equality before
        // any persisted unique ID becomes signal authority.
        for uniqueID in unresolved.keys {
            depths[uniqueID] = 1
        }
        return depths
    }

    private static func startedAt(
        _ identity: AntigravityRecordedProcessIdentity
    ) -> Date {
        Date(
            timeIntervalSince1970:
                TimeInterval(identity.startedAtSeconds)
                + (
                    TimeInterval(identity.startedAtMicroseconds)
                    / 1_000_000
                )
        )
    }

    private static func potentiallyManagedOpaqueProcesses(
        _ processes: [AntigravityProcessTableState],
        managedProcessIDs: Set<Int32>,
        record: AntigravityManagedProcessRecord
    ) -> [AntigravityProcessTableState] {
        let durableProcesses =
            [record.child] + record.observedDescendants
        let durableProcessIDs = Set(
            durableProcesses.map(\.pid)
        )
        var relatedProcessIDs =
            durableProcessIDs.union(managedProcessIDs)
        var remaining = Dictionary(
            uniqueKeysWithValues: processes.map {
                ($0.processID, $0)
            }
        )

        var madeProgress = true
        while madeProgress {
            let newlyRelated = remaining.values.filter {
                durableProcessIDs.contains($0.processID)
                    || $0.processGroupID == record.processGroupID
                    || relatedProcessIDs.contains(
                        $0.parentProcessID
                    )
            }
            madeProgress = !newlyRelated.isEmpty
            for process in newlyRelated {
                let processID = process.processID
                relatedProcessIDs.insert(processID)
                remaining.removeValue(forKey: processID)
            }
        }
        return processes.filter {
            relatedProcessIDs.contains($0.processID)
        }
    }
}

private nonisolated extension AntigravityProcessTableState {
    func hasSameExecution(
        as other: AntigravityProcessTableState
    ) -> Bool {
        processID == other.processID
            && effectiveUserID == other.effectiveUserID
            && realUserID == other.realUserID
            && startedAtSeconds == other.startedAtSeconds
            && startedAtMicroseconds
                == other.startedAtMicroseconds
    }
}

nonisolated enum AntigravityManagedProcessTerminationOrder {
    static func deepestFirst(
        _ identities: [AntigravityRecordedProcessIdentity]
    ) -> [AntigravityRecordedProcessIdentity]? {
        let grouped = Dictionary(
            grouping: identities,
            by: \.kernelIdentity.uniqueID
        )
        guard grouped.values.allSatisfy({ $0.count == 1 }) else {
            return nil
        }
        let identitiesByUniqueID = grouped.mapValues { $0[0] }
        var depths: [UInt64: Int] = [:]
        var visiting: Set<UInt64> = []

        func depth(for uniqueID: UInt64) -> Int? {
            if let cached = depths[uniqueID] {
                return cached
            }
            guard !visiting.contains(uniqueID),
                  let identity = identitiesByUniqueID[uniqueID] else {
                return nil
            }
            visiting.insert(uniqueID)
            defer { visiting.remove(uniqueID) }

            let resolvedDepth: Int
            if identitiesByUniqueID[
                identity.kernelIdentity.parentUniqueID
            ] != nil {
                guard let parentDepth = depth(
                    for: identity.kernelIdentity.parentUniqueID
                ) else {
                    return nil
                }
                resolvedDepth = parentDepth + 1
            } else {
                resolvedDepth = 0
            }
            depths[uniqueID] = resolvedDepth
            return resolvedDepth
        }

        for uniqueID in identitiesByUniqueID.keys {
            guard depth(for: uniqueID) != nil else {
                return nil
            }
        }
        return identities.sorted {
            let leftDepth =
                depths[$0.kernelIdentity.uniqueID] ?? 0
            let rightDepth =
                depths[$1.kernelIdentity.uniqueID] ?? 0
            if leftDepth != rightDepth {
                return leftDepth > rightDepth
            }
            if $0.kernelIdentity.uniqueID
                != $1.kernelIdentity.uniqueID {
                return $0.kernelIdentity.uniqueID
                    < $1.kernelIdentity.uniqueID
            }
            return $0.pid < $1.pid
        }
    }
}

nonisolated enum AntigravityExactProcessSignalError:
    Error,
    Equatable
{
    case invalidSignal
    case processNotFound
    case posix(Int32)
}

nonisolated protocol AntigravityExactProcessSignaling: Sendable {
    func signal(
        _ identity: AntigravityRecordedProcessIdentity,
        signal: Int32
    ) throws
}

/// Signals an exact `(pid, pidversion)` execution.
///
/// `proc_signal_with_audittoken` resolves and validates the process while
/// holding a kernel reference. A PID reused between userspace inspection and
/// this call therefore produces `ESRCH` instead of signalling the new owner.
nonisolated struct AntigravitySystemExactProcessSignaler:
    AntigravityExactProcessSignaling
{
    func signal(
        _ identity: AntigravityRecordedProcessIdentity,
        signal: Int32
    ) throws {
        guard signal == SIGTERM || signal == SIGKILL else {
            throw AntigravityExactProcessSignalError.invalidSignal
        }

        var token = audit_token_t(val: (
            0,
            identity.effectiveUserID,
            0,
            identity.realUserID,
            0,
            UInt32(bitPattern: identity.pid),
            0,
            UInt32(bitPattern: identity.kernelIdentity.pidVersion)
        ))
        let status = proc_signal_with_audittoken(
            &token,
            signal
        )
        switch status {
        case 0:
            return
        case ESRCH:
            throw AntigravityExactProcessSignalError
                .processNotFound
        default:
            throw AntigravityExactProcessSignalError
                .posix(status)
        }
    }
}
