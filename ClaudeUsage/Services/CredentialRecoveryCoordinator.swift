import Darwin
import Foundation

nonisolated struct CredentialRecoveryReadLease: Sendable {
    let generation: UInt64
    let originalPayload: String?
    let vaultWasReadable: Bool
}

/// The gate is also checked inside synchronous I/O. sealWrites therefore cannot
/// return while a protected synchronous mutation is still running.
nonisolated private final class CredentialRecoveryWriteGate: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var closing = false
    private var sealed = false
    private var generation: UInt64 = 0
    private var asyncWrites: [UUID: Task<Bool, Never>] = [:]

    func beginClosing() {
        lock.withLock {
            closing = true; generation &+= 1
            asyncWrites.values.forEach { $0.cancel() }
        }
    }
    func sealWrites() {
        lock.withLock {
            closing = true; sealed = true; generation &+= 1
            asyncWrites.values.forEach { $0.cancel() }
        }
    }
    func startAsyncWrite(_ operation: @escaping @Sendable () async -> Bool) throws -> (UUID, Task<Bool, Never>) {
        try perform {
            let id = UUID()
            let task = Task {
                guard !Task.isCancelled else { return false }; return await operation()
            }
            asyncWrites[id] = task
            return (id, task)
        }
    }
    func finishAsyncWrite(_ id: UUID) { _ = lock.withLock { asyncWrites.removeValue(forKey: id) } }
    func abortClosing() { lock.withLock { if !sealed { closing = false; generation &+= 1 } } }
    func invalidateReads() { lock.withLock { generation &+= 1 } }
    var isClosing: Bool { lock.withLock { closing } }
    var currentGeneration: UInt64 { lock.withLock { generation } }

    func perform<T>(allowClosing: Bool = false, _ operation: () throws -> T) throws -> T {
        try lock.withLock {
            guard !sealed, allowClosing || !closing else { throw CredentialRecoveryError.sealed }
            return try operation()
        }
    }
}

/// Owns just account switching, legacy app-managed rotation, and their recovery
/// rights. Records are secret storage and never become UI/snapshot payloads.
actor CredentialRecoveryCoordinator {
    static let shared: CredentialRecoveryCoordinator = {
        if AppRuntimeEnvironment.isRunningUnitTests {
            return isolated(appVault: CredentialRecoveryMemoryClaudeVault())
        }
        return CredentialRecoveryCoordinator(store: .production())
    }()

    nonisolated private let gate = CredentialRecoveryWriteGate()
    private let store: CredentialRecoveryStore
    private let appVault: any ClaudeOAuthCredentialVault
    private let keychain: ClaudeCodeKeychain
    private var activeSwitch: UUID?
    private var activeRefresh: UUID?
    private var activeImport: UUID?
    /// Failed durable successor writes must not fall back to the TTL cache.
    private var pendingSuccessor: (operationID: UUID, payload: String)?

    init(
        store: CredentialRecoveryStore,
        appVault: any ClaudeOAuthCredentialVault = KeychainClaudeOAuthCredentialVault.shared,
        keychain: ClaudeCodeKeychain = .system
    ) {
        self.store = store
        self.appVault = appVault
        self.keychain = keychain
    }

    static func isolated(
        appVault: any ClaudeOAuthCredentialVault = CredentialRecoveryMemoryClaudeVault(),
        keychain: ClaudeCodeKeychain = .none
    ) -> CredentialRecoveryCoordinator {
        CredentialRecoveryCoordinator(
            store: CredentialRecoveryStore(vault: CredentialRecoveryMemoryVault()), appVault: appVault,
            keychain: keychain)
    }

    static func operationDefault(keychain: ClaudeCodeKeychain = .none) -> CredentialRecoveryCoordinator {
        AppRuntimeEnvironment.isRunningUnitTests ? isolated(keychain: keychain) : shared
    }

    nonisolated func beginClosing() { gate.beginClosing() }
    nonisolated func sealWrites() { gate.sealWrites() }
    nonisolated func abortClosing() { gate.abortClosing() }
    nonisolated func invalidateReadOperations() { gate.invalidateReads() }
    nonisolated func withMetadataWritePermission<Value>(
        lease: CredentialRecoveryReadLease? = nil, _ operation: () throws -> Value
    ) throws -> Value {
        try gate.perform {
            try Task.checkCancellation()
            if let lease, lease.generation != gate.currentGeneration { throw CredentialRecoveryError.changed }
            return try operation()
        }
    }

    nonisolated func isReadCurrent(_ lease: CredentialRecoveryReadLease) -> Bool {
        !gate.isClosing && lease.generation == gate.currentGeneration
    }

    func status(provider: CredentialRecoveryProvider, accountID: String? = nil) -> CredentialRecoveryStatus {
        if gate.isClosing { return .closing }
        do {
            if let record = try store.loadSwitch(), record.provider == provider,
                accountID == nil || record.accountID == nil || record.accountID == accountID
                    || record.affectedAccountIDs.contains(accountID ?? "")
            {
                return activeSwitch == record.operationID ? .recovering : .blocked
            }
            if provider == .claude, let record = try store.loadRefresh(), try refreshRecordIsRelevant(record),
                accountID == nil || record.accountID == nil || record.accountID == accountID
            {
                if activeRefresh == record.operationID { return .recovering }
                return record.phase == .started ? .reconnectRequired : .blocked
            }
            return .ready
        } catch { return .blocked }
    }

    func affectedSources(provider: CredentialRecoveryProvider) -> CredentialRecoveryAffectedSources {
        var result = CredentialRecoveryAffectedSources()
        do {
            if let record = try store.loadSwitch(), record.provider == provider {
                if provider == .claude {
                    let references = Set(record.claudeLockLocations.map { $0.configDirectory.path })
                    if !record.automaticRecoveryAllowed, try switchIsSupersededByFreshCLI(record),
                        record.components.count >= 4
                    {
                        let otherFolder = URL(fileURLWithPath: record.components[3].location.reference)
                            .deletingLastPathComponent().path
                        result.sourceReferences.formUnion(references.filter { $0 == otherFolder })
                    } else {
                        result.sourceReferences.formUnion(references)
                    }
                } else {
                    result.sourceReferences.formUnion(
                        record.components.filter { $0.location.kind == .file }.map {
                            URL(fileURLWithPath: $0.location.reference).deletingLastPathComponent().path
                        })
                }
            }
            if provider == .claude, let record = try store.loadRefresh(), try refreshRecordIsRelevant(record) {
                result.includesCurrentAppVault = true
            }
        } catch {
            result.isUnknown = true
            result.includesCurrentAppVault = provider == .claude
        }
        return result
    }

    private func refreshRecordIsRelevant(_ record: CredentialRecoveryRefreshRecord) throws -> Bool {
        guard !record.automaticRecoveryAllowed, let current = try appVault.loadPayload(),
            ClaudeOAuthCredentialVaultPayload.ownership(of: current) == .cliMirror,
            let original = ClaudeCodeCredentialReader.parseCredential(
                from: record.originalPayload, source: .appManagedVault),
            let imported = ClaudeCodeCredentialReader.parseCredential(from: current, source: .refreshed),
            let oldGeneration = original.refreshToken, let newGeneration = imported.refreshToken,
            !newGeneration.isEmpty, oldGeneration != newGeneration
        else { return true }
        return false
    }

    func beginRead() throws -> CredentialRecoveryReadLease {
        try gate.perform {
            // Read-only native CLI usage does not require interpreting a damaged
            // recovery record. Its write lease still records vault readability.
            do {
                return CredentialRecoveryReadLease(
                    generation: gate.currentGeneration, originalPayload: try appVault.loadPayload(),
                    vaultWasReadable: true)
            } catch {
                return CredentialRecoveryReadLease(
                    generation: gate.currentGeneration, originalPayload: nil, vaultWasReadable: false)
            }
        }
    }

    func saveMirror(_ payload: String, lease: CredentialRecoveryReadLease) throws {
        try gate.perform {
            try requireClaudeAvailable()
            guard lease.vaultWasReadable, lease.generation == gate.currentGeneration,
                try appVault.loadPayload() == lease.originalPayload
            else { throw CredentialRecoveryError.changed }
            try appVault.savePayload(payload)
            guard try appVault.loadPayload() == payload else { throw CredentialRecoveryError.writeFailed }
        }
    }

    func beginImport() throws -> UUID {
        try gate.perform {
            try requireImportAvailable()
            let id = UUID()
            activeImport = id
            return id
        }
    }

    func cancelImport(_ id: UUID) { if activeImport == id { activeImport = nil } }

    func validateImport(_ id: UUID) throws {
        try gate.perform {
            guard activeImport == id else { throw CredentialRecoveryError.changed }
            try requireImportAvailable()
        }
    }

    func saveImport(_ payload: String, operationID: UUID, expectedPayload: String?) throws {
        try gate.perform {
            try Task.checkCancellation()
            guard activeImport == operationID else { throw CredentialRecoveryError.changed }
            try requireImportAvailable()
            guard try appVault.loadPayload() == expectedPayload else { throw CredentialRecoveryError.changed }
            let previous = try store.loadRefresh()
            var suspended = previous
            let previousSwitch = try store.loadSwitch().flatMap { $0.provider == .claude ? $0 : nil }
            var suspendedSwitch = previousSwitch
            do {
                if var record = previous {
                    guard
                        let original = ClaudeCodeCredentialReader.parseCredential(
                            from: record.originalPayload, source: .appManagedVault),
                        let imported = ClaudeCodeCredentialReader.parseCredential(from: payload, source: .refreshed),
                        let oldGeneration = original.refreshToken, let newGeneration = imported.refreshToken,
                        !newGeneration.isEmpty, oldGeneration != newGeneration,
                        ClaudeOAuthCredentialVaultPayload.ownership(of: payload) == .cliMirror
                    else { throw CredentialRecoveryError.changed }
                    record.automaticRecoveryAllowed = false
                    suspended = record
                    try store.update(record)
                }
                if var record = previousSwitch {
                    let originals = record.components.compactMap {
                        $0.original.map { String(decoding: $0, as: UTF8.self) }
                    }
                    guard isFreshCLIImport(payload, comparedTo: originals) else {
                        throw CredentialRecoveryError.changed
                    }
                    record.automaticRecoveryAllowed = false
                    suspendedSwitch = record
                    try store.update(record)
                }
                try Task.checkCancellation()
                try appVault.savePayload(payload)
                guard try appVault.loadPayload() == payload else { throw CredentialRecoveryError.writeFailed }
            } catch {
                // Restore recovery permission only when both the exact record
                // and active generation prove this import made no change.
                let activeIsUnchanged: Bool
                do { activeIsUnchanged = try appVault.loadPayload() == expectedPayload } catch {
                    activeIsUnchanged = false
                }
                if activeIsUnchanged {
                    if let previous, let suspended, previous != suspended,
                        (try? store.loadRefresh()) == suspended
                    {
                        try? store.update(previous)
                    }
                    if let previousSwitch, let suspendedSwitch, previousSwitch != suspendedSwitch,
                        (try? store.loadSwitch()) == suspendedSwitch
                    {
                        try? store.update(previousSwitch)
                    }
                }
                throw error
            }
        }
    }

    private func requireClaudeAvailable() throws {
        guard activeRefresh == nil, pendingSuccessor == nil else { throw CredentialRecoveryError.busy }
        if let record = try store.loadRefresh(), try refreshRecordIsRelevant(record) {
            throw CredentialRecoveryError.busy
        }
        if let record = try store.loadSwitch(), record.provider == .claude,
            try (record.automaticRecoveryAllowed || !switchIsSupersededByFreshCLI(record))
        {
            throw CredentialRecoveryError.busy
        }
    }

    private func requireImportAvailable() throws {
        // Decode failure is not permission to replace/delete the record. A known
        // pending refresh can be isolated by a proven new explicit CLI generation.
        _ = try store.loadRefresh()
        _ = try store.loadSwitch()
        guard activeSwitch == nil else { throw CredentialRecoveryError.busy }
    }

    private func isDifferentGeneration(_ imported: ClaudeCodeOAuthCredential, from originals: [String]) -> Bool {
        guard imported.refreshToken?.isEmpty == false else { return false }
        let credentials = originals.compactMap {
            ClaudeCodeCredentialReader.parseCredential(from: $0, source: .refreshed)
        }
        guard !credentials.isEmpty else { return false }
        return credentials.allSatisfy {
            if let generation = $0.refreshToken { return generation != imported.refreshToken }
            return $0.accessToken != imported.accessToken
        }
    }

    private func isFreshCLIImport(_ payload: String, comparedTo originals: [String]) -> Bool {
        guard ClaudeOAuthCredentialVaultPayload.ownership(of: payload) == .cliMirror,
            let imported = ClaudeCodeCredentialReader.parseCredential(from: payload, source: .refreshed)
        else { return false }
        return isDifferentGeneration(imported, from: originals)
    }

    private func switchIsSupersededByFreshCLI(_ record: CredentialRecoverySwitchRecord) throws -> Bool {
        guard let current = try appVault.loadPayload() else { return false }
        return isFreshCLIImport(
            current,
            comparedTo: record.components.compactMap {
                $0.original.map { String(decoding: $0, as: UTF8.self) }
            })
    }

    func canRefreshCLIGeneration(_ credential: ClaudeCodeOAuthCredential, duringSwitch operationID: UUID? = nil) -> Bool
    {
        guard !gate.isClosing else { return false }
        do {
            if let record = try store.loadSwitch(), record.provider == .claude {
                let ownsSwitch = operationID == record.operationID && activeSwitch == record.operationID
                let freshConnection =
                    try
                    (!record.automaticRecoveryAllowed && switchIsSupersededByFreshCLI(record)
                    && isDifferentGeneration(
                        credential,
                        from: record.components.compactMap {
                            $0.original.map { String(decoding: $0, as: UTF8.self) }
                        }))
                guard ownsSwitch || freshConnection else { return false }
            }
            if let record = try store.loadRefresh() {
                guard
                    let original = ClaudeCodeCredentialReader.parseCredential(
                        from: record.originalPayload, source: .appManagedVault),
                    let generation = credential.refreshToken, generation != original.refreshToken
                else { return false }
            }
            return true
        } catch { return false }
    }

    func beginSwitch(
        provider: CredentialRecoveryProvider, accountID: String?,
        components: [CredentialRecoverySwitchComponent], preferAtomicExchange: Bool = false,
        claudeLockLocations: [CredentialRecoveryClaudeLockLocation] = [], affectedAccountIDs: [String] = []
    ) throws -> UUID {
        try gate.perform {
            guard activeSwitch == nil, try store.loadSwitch() == nil else { throw CredentialRecoveryError.busy }
            if provider == .claude {
                try requireClaudeAvailable()
                guard activeImport == nil else { throw CredentialRecoveryError.busy }
                gate.invalidateReads()
            }
            guard !components.isEmpty, Set(components.map(\.location)).count == components.count else {
                throw CredentialRecoveryError.changed
            }
            try CredentialRecoveryFile.refuseAliases(components)
            let id = UUID()
            let steps: [CredentialRecoverySwitchStep]
            if preferAtomicExchange, components.count == 2,
                components.allSatisfy({ $0.location.kind == .file && $0.original != nil })
            {
                steps = [
                    .init(
                        kind: .exchange, components: [0, 1], before: components.map(\.original),
                        after: components.map(\.proposed), temporaryPaths: [])
                ]
            } else {
                steps = try replacementSteps(components: components, id: id)
            }
            var record = CredentialRecoverySwitchRecord(
                operationID: id, provider: provider, accountID: accountID, components: components, steps: steps)
            record.claudeLockLocations = claudeLockLocations
            record.affectedAccountIDs = affectedAccountIDs
            try store.create(record)
            activeSwitch = id
            return id
        }
    }

    func applySwitch(_ id: UUID) async throws {
        let record = try currentSwitch(id)
        let locks = record.claudeLockLocations.map {
            ClaudeCodeDirectoryLock(configDirectory: $0.configDirectory, profileFile: $0.profileFile)
        }
        defer { for lock in locks.reversed() { lock.release() } }
        for lock in locks { try await BlockingWork.run { try lock.acquire() } }
        do { try await executeSwitch(id) } catch {
            // The durable record, not an assumption about a failed write, owns
            // subsequent restoration. Unknown actual state is left untouched.
            throw error
        }
    }

    func switchStates(_ id: UUID) async throws -> [Data?] {
        let record = try currentSwitch(id)
        return try await readStates(record)
    }

    func completeSwitch(_ id: UUID, verifiedStates: [Data?]) async throws {
        var record = try currentSwitch(id)
        guard record.nextStep == record.steps.count, record.intendedStep == nil,
            verifiedStates.count == record.components.count,
            try await readStates(record) == verifiedStates
        else { throw CredentialRecoveryError.changed }
        try gate.perform {
            record.verifiedStates = verifiedStates
            do { try store.update(record) } catch {
                activeSwitch = nil
                throw AccountSwitchError.recoveryPending
            }
            // Credentials and owners are already verified. Keep this completed
            // record if only its owned temporary/record cleanup fails.
            do {
                try cleanTemporaries(record)
                try store.deleteSwitch(record)
            } catch { Logger.warning("계정 전환 완료 기록 정리 보류") }
            activeSwitch = nil
        }
    }

    func rollbackSwitch(_ id: UUID) async throws {
        var record = try currentSwitch(id)
        guard record.verifiedStates == nil else { throw CredentialRecoveryError.changed }
        let locks = record.claudeLockLocations.map {
            ClaudeCodeDirectoryLock(configDirectory: $0.configDirectory, profileFile: $0.profileFile)
        }
        defer { for lock in locks.reversed() { lock.release() } }
        for lock in locks { try await BlockingWork.run { try lock.acquire() } }
        let states = try await reconcile(record: &record)
        if !record.restoring {
            try gate.perform { try cleanTemporaries(record) }
            record.steps = Array(record.steps.prefix(record.nextStep))
            record.restoring = true
            for index in record.components.indices where states[index] != record.components[index].original {
                let temporary = try temporaryPath(record.components[index].location, id: id, step: record.steps.count)
                record.steps.append(
                    .init(
                        kind: .replace, components: [index], before: [states[index]],
                        after: [record.components[index].original], temporaryPaths: [temporary]))
            }
            try gate.perform { try store.update(record) }
        }
        try await executeSwitch(id)
        try await completeSwitch(id, verifiedStates: record.components.map(\.original))
    }

    func releaseSwitch(_ id: UUID) { if activeSwitch == id { activeSwitch = nil } }

    private func currentSwitch(_ id: UUID) throws -> CredentialRecoverySwitchRecord {
        guard activeSwitch == id, let record = try store.loadSwitch(), record.operationID == id else {
            throw CredentialRecoveryError.changed
        }
        return record
    }

    private func readStates(_ record: CredentialRecoverySwitchRecord) async throws -> [Data?] {
        try CredentialRecoveryFile.refuseAliases(record.components)
        var result: [Data?] = []
        for component in record.components {
            switch component.location.kind {
            case .file: result.append(try CredentialRecoveryFile.read(component.location))
            case .claudeKeychain:
                guard let account = component.location.keychainAccount else {
                    throw CredentialRecoveryError.unsupported
                }
                let outcome: ClaudeCodeKeychainCLI.Outcome
                if let readExact = keychain.readExact {
                    outcome = await readExact(component.location.reference, account)
                } else {
                    outcome = await keychain.read(component.location.reference)
                }
                switch outcome {
                case .payload(let payload): result.append(Data(payload.utf8))
                case .notFound: result.append(nil)
                case .failed: throw CredentialRecoveryError.unreadable
                }
            }
        }
        return result
    }

    private func expectedStates(_ record: CredentialRecoverySwitchRecord) throws -> [Data?] {
        guard record.nextStep >= 0, record.nextStep <= record.steps.count,
            record.intendedStep == nil || record.intendedStep == record.nextStep
        else { throw CredentialRecoveryError.unsupported }
        var result = record.components.map(\.original)
        for step in record.steps.prefix(record.nextStep) { try apply(step, to: &result) }
        return result
    }

    private func apply(_ step: CredentialRecoverySwitchStep, to states: inout [Data?]) throws {
        guard step.components.count == step.before.count, step.components.count == step.after.count else {
            throw CredentialRecoveryError.unsupported
        }
        for (offset, index) in step.components.enumerated() {
            guard states.indices.contains(index), states[index] == step.before[offset] else {
                throw CredentialRecoveryError.unsupported
            }
            states[index] = step.after[offset]
        }
    }

    private func reconcile(record: inout CredentialRecoverySwitchRecord) async throws -> [Data?] {
        let observed = try await readStates(record)
        let before = try expectedStates(record)
        if observed == before {
            if record.intendedStep != nil {
                record.intendedStep = nil
                try gate.perform { try store.update(record) }
            }
            return observed
        }
        guard let intent = record.intendedStep, record.steps.indices.contains(intent) else {
            throw CredentialRecoveryError.changed
        }
        var after = before
        try apply(record.steps[intent], to: &after)
        guard observed == after else { throw CredentialRecoveryError.changed }
        record.nextStep += 1
        record.intendedStep = nil
        try gate.perform { try store.update(record) }
        return observed
    }

    private func executeSwitch(_ id: UUID) async throws {
        var record = try currentSwitch(id)
        _ = try await reconcile(record: &record)
        while record.nextStep < record.steps.count {
            try Task.checkCancellation()
            let step = record.steps[record.nextStep]
            let expected = try expectedStates(record)
            guard try await readStates(record) == expected else { throw CredentialRecoveryError.changed }
            record.intendedStep = record.nextStep
            try gate.perform { try store.update(record) }
            if step.kind == .exchange {
                let a = try record.components[step.components[0]].location.checkedFileURL()
                let b = try record.components[step.components[1]].location.checkedFileURL()
                let exchanged = try gate.perform {
                    guard try CredentialRecoveryFile.read(record.components[0].location) == expected[0],
                        try CredentialRecoveryFile.read(record.components[1].location) == expected[1]
                    else { throw CredentialRecoveryError.changed }
                    return renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0
                }
                if !exchanged {
                    // A failed atomic exchange made no change. Keep cross-volume
                    // support using verified copies on each TARGET volume.
                    guard try await readStates(record) == expected else { throw CredentialRecoveryError.changed }
                    record.steps = try replacementSteps(components: record.components, id: id)
                    record.nextStep = 0
                    record.intendedStep = nil
                    try gate.perform { try store.update(record) }
                    continue
                }
                try gate.perform {
                    try CredentialRecoveryFile.synchronizeDirectory(a.deletingLastPathComponent())
                    if a.deletingLastPathComponent() != b.deletingLastPathComponent() {
                        try CredentialRecoveryFile.synchronizeDirectory(b.deletingLastPathComponent())
                    }
                }
            } else {
                guard step.components.count == 1, step.temporaryPaths.count == 1 else {
                    throw CredentialRecoveryError.unsupported
                }
                let index = step.components[0]
                let location = record.components[index].location
                switch location.kind {
                case .file:
                    try gate.perform {
                        try CredentialRecoveryFile.replace(
                            location, expected: step.before[0], replacement: step.after[0],
                            temporaryPath: step.temporaryPaths[0])
                    }
                case .claudeKeychain:
                    guard let payload = step.after[0], let account = location.keychainAccount else {
                        throw CredentialRecoveryError.unsupported
                    }
                    let keychain = self.keychain
                    let (writeID, writing) = try gate.startAsyncWrite {
                        guard !Task.isCancelled else { return false }
                        if let updateExact = keychain.updateExact {
                            return await updateExact(location.reference, account, payload)
                        }
                        return await keychain.update(location.reference, payload)
                    }
                    let didWrite = await writing.value
                    gate.finishAsyncWrite(writeID)
                    guard didWrite else { throw CredentialRecoveryError.writeFailed }
                // No direct interactive fallback in a recovery path.
                }
            }
            var after = expected
            try apply(step, to: &after)
            guard try await readStates(record) == after else { throw CredentialRecoveryError.changed }
            record.nextStep += 1
            record.intendedStep = nil
            try gate.perform { try store.update(record) }
        }
    }

    private func temporaryPath(_ location: CredentialRecoveryLocation, id: UUID, step: Int) throws -> String {
        location.kind == .file
            ? try CredentialRecoveryFile.temporaryPath(for: location, operationID: id, step: step) : ""
    }

    private func cleanTemporaries(_ record: CredentialRecoverySwitchRecord) throws {
        for step in record.steps where step.kind == .replace {
            guard step.components.count == 1, step.temporaryPaths.count == 1, step.after.count == 1 else {
                throw CredentialRecoveryError.unsupported
            }
            let index = step.components[0]
            guard record.components.indices.contains(index) else { throw CredentialRecoveryError.unsupported }
            let location = record.components[index].location
            if location.kind == .file, let expected = step.after[0] {
                let path = step.temporaryPaths[0]
                let target = try location.checkedFileURL()
                guard URL(fileURLWithPath: path).deletingLastPathComponent() == target.deletingLastPathComponent(),
                    URL(fileURLWithPath: path).lastPathComponent.contains(record.operationID.uuidString)
                else { throw CredentialRecoveryError.changed }
                try CredentialRecoveryFile.removeVerifiedTemporary(path: path, expected: expected)
            }
        }
    }

    private func replacementSteps(
        components: [CredentialRecoverySwitchComponent], id: UUID
    ) throws -> [CredentialRecoverySwitchStep] {
        var result: [CredentialRecoverySwitchStep] = []
        for index in components.indices where components[index].original != components[index].proposed {
            result.append(
                .init(
                    kind: .replace, components: [index], before: [components[index].original],
                    after: [components[index].proposed],
                    temporaryPaths: [try temporaryPath(components[index].location, id: id, step: result.count)]))
        }
        return result
    }

    func beginRefresh(originalPayload: String, accountID: String?) throws -> UUID {
        try gate.perform {
            try requireClaudeAvailable()
            guard activeImport == nil, try appVault.loadPayload() == originalPayload,
                ClaudeOAuthCredentialVaultPayload.ownership(of: originalPayload) == .appManaged
            else { throw CredentialRecoveryError.changed }
            let id = UUID()
            try store.create(
                CredentialRecoveryRefreshRecord(
                    operationID: id, accountID: accountID, originalPayload: originalPayload))
            activeRefresh = id
            return id
        }
    }

    func markRefreshStarted(_ id: UUID) throws {
        try gate.perform {
            guard activeRefresh == id, var record = try store.loadRefresh(), record.operationID == id,
                record.phase == .prepared, try appVault.loadPayload() == record.originalPayload
            else { throw CredentialRecoveryError.changed }
            record.phase = .started
            try store.update(record)
        }
    }

    func preserveSuccessor(_ payload: String, operationID id: UUID) throws {
        guard activeRefresh == id else { throw CredentialRecoveryError.changed }
        pendingSuccessor = (id, payload)
        guard var record = try store.loadRefresh(), record.operationID == id,
            record.phase == .started || record.phase == .successor
        else { throw CredentialRecoveryError.changed }
        try gate.perform(allowClosing: true) {
            record.successorPayload = payload
            record.phase = .successor
            try store.update(record)
            pendingSuccessor = nil
        }
    }

    func finishRefreshWithoutSending(_ id: UUID) throws {
        try gate.perform(allowClosing: true) {
            guard activeRefresh == id, var record = try store.loadRefresh(), record.operationID == id,
                record.successorPayload == nil, try appVault.loadPayload() == record.originalPayload
            else { throw CredentialRecoveryError.changed }
            record.successorPayload = record.originalPayload
            record.phase = .verified
            try store.update(record)
            try store.deleteRefresh(record)
            activeRefresh = nil
        }
    }

    func releaseRefresh(_ id: UUID) { if activeRefresh == id { activeRefresh = nil } }

    func retainRejectedRefresh(_ id: UUID) throws {
        try gate.perform(allowClosing: true) {
            guard activeRefresh == id, var record = try store.loadRefresh(), record.operationID == id else {
                throw CredentialRecoveryError.changed
            }
            if record.phase == .prepared {
                record.phase = .started
                try store.update(record)
            }
        }
    }

    /// Returns only a successor belonging to the exact still-current generation.
    /// started without successor is an uncertain POST, even after a restart.
    func recoveredRefreshPayload() throws -> String? {
        guard var record = try store.loadRefresh() else {
            guard pendingSuccessor == nil else { throw CredentialRecoveryError.busy }
            return nil
        }
        guard activeRefresh == nil else { throw CredentialRecoveryError.busy }
        if let pendingSuccessor, pendingSuccessor.operationID == record.operationID {
            do {
                try gate.perform(allowClosing: true) {
                    record.successorPayload = pendingSuccessor.payload
                    record.phase = .successor
                    try store.update(record)
                    self.pendingSuccessor = nil
                }
            } catch {
                return try usableSuccessor(record)
            }
        }
        do { return try restoreRefresh(record) } catch {
            if let successor = try? usableSuccessor(record) { return successor }
            throw error
        }
    }

    func applyRefreshSuccessor(_ id: UUID) throws -> String {
        guard activeRefresh == id, let record = try store.loadRefresh(), record.operationID == id else {
            throw CredentialRecoveryError.changed
        }
        guard let result = try restoreRefresh(record) else { throw CredentialRecoveryError.busy }
        activeRefresh = nil
        return result
    }

    func usableRefreshSuccessor(_ id: UUID) throws -> String? {
        guard let record = try store.loadRefresh(), record.operationID == id else {
            throw CredentialRecoveryError.changed
        }
        return try usableSuccessor(record)
    }

    private func usableSuccessor(_ record: CredentialRecoveryRefreshRecord) throws -> String? {
        try gate.perform {
            guard record.automaticRecoveryAllowed, activeImport == nil,
                try appVault.loadPayload() == record.originalPayload
            else { throw CredentialRecoveryError.changed }
            if let pendingSuccessor, pendingSuccessor.operationID == record.operationID {
                return pendingSuccessor.payload
            }
            return record.phase == .successor ? record.successorPayload : nil
        }
    }

    private func restoreRefresh(_ initial: CredentialRecoveryRefreshRecord) throws -> String? {
        var record = initial
        return try gate.perform {
            guard record.automaticRecoveryAllowed, activeImport == nil,
                try store.loadSwitch()?.provider != .claude
            else { throw CredentialRecoveryError.busy }
            let current = try appVault.loadPayload()
            if record.phase == .prepared {
                guard current == record.originalPayload else { throw CredentialRecoveryError.changed }
                record.successorPayload = record.originalPayload
                record.phase = .verified
                try store.update(record)
                try store.deleteRefresh(record)
                return nil
            }
            guard let successor = record.successorPayload,
                record.phase == .successor || record.phase == .verified,
                current == record.originalPayload || current == successor
            else { throw CredentialRecoveryError.busy }
            if current != successor {
                try appVault.savePayload(successor)
                guard try appVault.loadPayload() == successor else { throw CredentialRecoveryError.writeFailed }
            }
            record.phase = .verified
            try store.update(record)
            try? store.deleteRefresh(record)
            pendingSuccessor = nil
            return successor
        }
    }

    func recoverPending() async -> CredentialRecoveryResult {
        var result = CredentialRecoveryResult()
        guard !gate.isClosing else {
            result.claude = .closing; result.codex = .closing
            return result
        }
        do {
            if let record = try store.loadSwitch() {
                if !record.automaticRecoveryAllowed {
                    if record.provider == .claude { result.claude = .blocked } else { result.codex = .blocked }
                } else {
                    guard activeSwitch == nil else { throw CredentialRecoveryError.busy }
                    activeSwitch = record.operationID
                    defer { activeSwitch = nil }
                    if let verified = record.verifiedStates {
                        guard try await readStates(record) == verified else { throw CredentialRecoveryError.changed }
                        try gate.perform {
                            try cleanTemporaries(record); try store.deleteSwitch(record)
                        }
                    } else {
                        try await rollbackSwitch(record.operationID)
                    }
                    result.didRecover = true
                }
            }
        } catch {
            if let record = try? store.loadSwitch() {
                if record.provider == .claude { result.claude = .blocked } else { result.codex = .blocked }
            } else {
                result.claude = .blocked; result.codex = .blocked
            }
        }
        do {
            if let record = try store.loadRefresh(), record.automaticRecoveryAllowed {
                _ = try recoveredRefreshPayload()
                result.didRecover = true
            }
        } catch { result.claude = .reconnectRequired }
        return result
    }

    /// No new/late apply may race a reset. False preserves unresolved records;
    /// a five-second shutdown timeout must seal, never pretend this succeeded.
    func finishClosing() async {
        while activeSwitch != nil || activeRefresh != nil || activeImport != nil || pendingSuccessor != nil {
            if Task.isCancelled { return }
            try? persistPendingSuccessor()
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
        }
    }

    private func persistPendingSuccessor() throws {
        guard let pendingSuccessor else { return }
        try gate.perform(allowClosing: true) {
            guard var record = try store.loadRefresh(), record.operationID == pendingSuccessor.operationID,
                record.phase == .started || record.phase == .successor
            else { throw CredentialRecoveryError.changed }
            record.successorPayload = pendingSuccessor.payload
            record.phase = .successor
            try store.update(record)
            self.pendingSuccessor = nil
        }
    }

    func prepareForReset(timeout: Duration = .seconds(5)) async -> Bool {
        beginClosing()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while activeSwitch != nil || activeRefresh != nil || activeImport != nil {
            guard clock.now < deadline, !Task.isCancelled else { break }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
        }
        do {
            if var record = try store.loadSwitch() {
                if let verified = record.verifiedStates, activeSwitch == nil,
                    (try? await readStates(record)) == verified
                {
                    try gate.perform(allowClosing: true) {
                        try cleanTemporaries(record); try store.deleteSwitch(record)
                    }
                } else {
                    record.automaticRecoveryAllowed = false
                    try gate.perform(allowClosing: true) { try store.update(record) }
                }
            }
            if var record = try store.loadRefresh() {
                if let pendingSuccessor, pendingSuccessor.operationID == record.operationID {
                    record.successorPayload = pendingSuccessor.payload
                    record.phase = .successor
                }
                if record.phase == .verified, activeRefresh == nil, let successor = record.successorPayload,
                    try appVault.loadPayload() == successor
                {
                    try gate.perform(allowClosing: true) { try store.deleteRefresh(record) }
                } else {
                    record.automaticRecoveryAllowed = false
                    try gate.perform(allowClosing: true) { try store.update(record) }
                }
            }
            guard try store.loadSwitch()?.automaticRecoveryAllowed != true,
                try store.loadRefresh()?.automaticRecoveryAllowed != true
            else { throw CredentialRecoveryError.writeFailed }
            if activeSwitch != nil || activeRefresh != nil || activeImport != nil { sealWrites() }
            return true
        } catch {
            abortClosing()
            return false
        }
    }
}
