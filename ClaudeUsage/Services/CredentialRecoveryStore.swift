import CryptoKit
import Darwin
import Foundation

nonisolated enum CredentialRecoveryProvider: String, Codable, Sendable {
    case claude, codex
}

nonisolated enum CredentialRecoveryStatus: Equatable, Sendable {
    case ready
    case recovering
    case reconnectRequired
    case blocked
    case closing
}

nonisolated struct CredentialRecoveryResult: Equatable, Sendable {
    var claude: CredentialRecoveryStatus = .ready
    var codex: CredentialRecoveryStatus = .ready
    var didRecover = false
}

nonisolated struct CredentialRecoveryAffectedSources: Equatable, Sendable {
    var sourceReferences: Set<String> = []
    var includesCurrentAppVault = false
    var isUnknown = false
}

nonisolated enum CredentialRecoveryError: Error, Equatable, Sendable {
    case busy, unreadable, unsupported, changed, sealed, writeFailed
}

/// These locations describe account-switch components, not arbitrary app data.
nonisolated struct CredentialRecoveryLocation: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable { case file, claudeKeychain }
    let kind: Kind
    let reference: String
    /// Preserve the user's symlink while refusing a later retargeting.
    let physicalPath: String?
    var keychainAccount: String? = nil

    static func file(_ url: URL) -> Self {
        Self(kind: .file, reference: url.path, physicalPath: url.resolvingSymlinksInPath().path)
    }

    static func claudeKeychain(_ service: String, account: String? = nil) -> Self {
        Self(kind: .claudeKeychain, reference: service, physicalPath: nil, keychainAccount: account)
    }

    func checkedFileURL() throws -> URL {
        let url = URL(fileURLWithPath: reference)
        guard kind == .file, url.path == reference,
            url.resolvingSymlinksInPath().path == physicalPath
        else { throw CredentialRecoveryError.changed }
        return URL(fileURLWithPath: physicalPath ?? reference)
    }
}

nonisolated struct CredentialRecoverySwitchComponent: Codable, Equatable, Sendable {
    let location: CredentialRecoveryLocation
    let original: Data?
    let proposed: Data?
}

nonisolated struct CredentialRecoverySwitchStep: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case replace, exchange }
    let kind: Kind
    let components: [Int]
    let before: [Data?]
    let after: [Data?]
    /// Determined before the intent is saved, on each destination volume.
    let temporaryPaths: [String]
}

nonisolated struct CredentialRecoverySwitchRecord: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let operationID: UUID
    let provider: CredentialRecoveryProvider
    let accountID: String?
    let components: [CredentialRecoverySwitchComponent]
    var steps: [CredentialRecoverySwitchStep]
    var nextStep = 0
    var intendedStep: Int?
    var restoring = false
    var verifiedStates: [Data?]?
    var claudeLockLocations: [CredentialRecoveryClaudeLockLocation] = []
    var automaticRecoveryAllowed = true
    var affectedAccountIDs: [String] = []
}

nonisolated struct CredentialRecoveryClaudeLockLocation: Codable, Equatable, Sendable {
    let configDirectory: URL
    let profileFile: URL
}

nonisolated struct CredentialRecoveryRefreshRecord: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case prepared, started, successor, verified }
    var schemaVersion = 1
    let operationID: UUID
    let accountID: String?
    let originalPayload: String
    var phase: Phase = .prepared
    var successorPayload: String?
    var automaticRecoveryAllowed = true
}

/// Two fixed records in a channel-owned service. Unknown material is never
/// decoded into defaults or overwritten, including by an explicit reconnect.
nonisolated final class CredentialRecoveryStore: @unchecked Sendable {
    static let switchReference = "oauth.account-switch-recovery.v1"
    static let refreshReference = "oauth.claude-refresh-recovery.v1"
    private let vault: any OAuthCredentialVault
    private let lock = NSRecursiveLock()

    init(vault: any OAuthCredentialVault) { self.vault = vault }

    static func production() -> Self {
        Self(
            vault: SecurityFrameworkOAuthCredentialVault(
                service: AppIdentifiers.credentialRecoveryService(
                    bundleIdentifier: AppDistribution.current.bundleIdentifier)))
    }

    func loadSwitch() throws -> CredentialRecoverySwitchRecord? {
        try load(reference: Self.switchReference)
    }

    func loadRefresh() throws -> CredentialRecoveryRefreshRecord? {
        try load(reference: Self.refreshReference)
    }

    func create(_ record: CredentialRecoverySwitchRecord) throws {
        try create(record, reference: Self.switchReference)
    }

    func create(_ record: CredentialRecoveryRefreshRecord) throws {
        try create(record, reference: Self.refreshReference)
    }

    func update(_ record: CredentialRecoverySwitchRecord) throws {
        try lock.withLock {
            guard let previous = try loadSwitch(), previous.operationID == record.operationID else {
                throw CredentialRecoveryError.changed
            }
            try save(record, reference: Self.switchReference)
        }
    }

    func update(_ record: CredentialRecoveryRefreshRecord) throws {
        try lock.withLock {
            guard let previous = try loadRefresh(), previous.operationID == record.operationID else {
                throw CredentialRecoveryError.changed
            }
            try save(record, reference: Self.refreshReference)
        }
    }

    func deleteSwitch(_ record: CredentialRecoverySwitchRecord) throws {
        try lock.withLock {
            guard record.verifiedStates != nil, try loadSwitch() == record else {
                throw CredentialRecoveryError.changed
            }
            try vault.deletePayload(reference: Self.switchReference)
            guard try vault.loadPayload(reference: Self.switchReference) == nil else {
                throw CredentialRecoveryError.writeFailed
            }
        }
    }

    func deleteRefresh(_ record: CredentialRecoveryRefreshRecord) throws {
        try lock.withLock {
            guard record.phase == .verified, try loadRefresh() == record else {
                throw CredentialRecoveryError.changed
            }
            try vault.deletePayload(reference: Self.refreshReference)
            guard try vault.loadPayload(reference: Self.refreshReference) == nil else {
                throw CredentialRecoveryError.writeFailed
            }
        }
    }

    private func load<Record: Codable>(reference: String) throws -> Record? {
        try lock.withLock {
            guard let data = try vault.loadPayload(reference: reference) else { return nil }
            do {
                let record = try JSONDecoder().decode(Record.self, from: data)
                let original = try JSONSerialization.jsonObject(with: data) as? NSDictionary
                let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? NSDictionary
                // Synthesized decoding ignores unknown fields. Recovery must not.
                guard let original, let encoded, original.isEqual(encoded),
                    original["schemaVersion"] as? Int == 1
                else { throw CredentialRecoveryError.unsupported }
                return record
            } catch let error as CredentialRecoveryError { throw error } catch {
                throw CredentialRecoveryError.unreadable
            }
        }
    }

    private func create<Record: Encodable>(_ record: Record, reference: String) throws {
        try lock.withLock {
            let data = try JSONEncoder().encode(record)
            guard try vault.createIfAbsent(data, reference: reference) else { throw CredentialRecoveryError.busy }
            guard try vault.loadPayload(reference: reference) == data else { throw CredentialRecoveryError.writeFailed }
        }
    }

    private func save<Record: Encodable>(_ record: Record, reference: String) throws {
        let data = try JSONEncoder().encode(record)
        try vault.savePayload(data, reference: reference)
        guard try vault.loadPayload(reference: reference) == data else { throw CredentialRecoveryError.writeFailed }
    }
}

/// Isolated unit-test storage; never selected for a production process.
nonisolated final class CredentialRecoveryMemoryVault: OAuthCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func loadPayload(reference: String) throws -> Data? { lock.withLock { values[reference] } }
    func savePayload(_ payload: Data, reference: String) throws { lock.withLock { values[reference] = payload } }
    func createIfAbsent(_ payload: Data, reference: String) throws -> Bool {
        lock.withLock {
            guard values[reference] == nil else { return false }
            values[reference] = payload
            return true
        }
    }
    func deletePayload(reference: String) throws { lock.withLock { _ = values.removeValue(forKey: reference) } }
    func references(in namespace: OAuthCredentialVaultNamespace) throws -> Set<String> {
        lock.withLock { Set(values.keys.filter(namespace.contains)) }
    }
}

nonisolated final class CredentialRecoveryMemoryClaudeVault: ClaudeOAuthCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func loadPayload() throws -> String? { lock.withLock { value } }
    func savePayload(_ payload: String) throws { lock.withLock { value = payload } }
    func deletePayload() throws { lock.withLock { value = nil } }
}

/// Only replacement of a recorded account file. The original remains in its
/// location until a complete destination-volume temporary has been verified.
nonisolated enum CredentialRecoveryFile {
    struct Identity: Hashable, Sendable {
        let device: Int32
        let inode: UInt64
    }

    static func identity(_ location: CredentialRecoveryLocation) throws -> Identity? {
        let target = try location.checkedFileURL()
        let descriptor = open(target.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw CredentialRecoveryError.unreadable
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        var current = stat()
        guard fstat(descriptor, &opened) == 0, lstat(target.path, &current) == 0,
            opened.st_mode & S_IFMT == S_IFREG, current.st_mode & S_IFMT == S_IFREG,
            opened.st_dev == current.st_dev, opened.st_ino == current.st_ino,
            try location.checkedFileURL() == target
        else { throw CredentialRecoveryError.changed }
        return Identity(device: opened.st_dev, inode: opened.st_ino)
    }

    static func refuseAliases(_ components: [CredentialRecoverySwitchComponent]) throws {
        var identities: Set<Identity> = []
        var keychainItems: Set<CredentialRecoveryLocation> = []
        for component in components {
            if component.location.kind == .file {
                if let identity = try identity(component.location), !identities.insert(identity).inserted {
                    throw CredentialRecoveryError.changed
                }
            } else {
                guard component.location.keychainAccount != nil,
                    keychainItems.insert(component.location).inserted
                else {
                    throw CredentialRecoveryError.changed
                }
            }
        }
    }

    static func read(_ location: CredentialRecoveryLocation) throws -> Data? {
        let url = try location.checkedFileURL()
        do { return try Data(contentsOf: url) } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    static func temporaryPath(for location: CredentialRecoveryLocation, operationID: UUID, step: Int) throws -> String {
        let target = try location.checkedFileURL()
        return target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).recovery-\(operationID.uuidString)-\(step).tmp").path
    }

    static func replace(
        _ location: CredentialRecoveryLocation, expected: Data?, replacement: Data?, temporaryPath: String
    ) throws {
        let target = try location.checkedFileURL()
        guard try read(location) == expected else { throw CredentialRecoveryError.changed }
        guard let replacement else {
            // Deletion is never used for cross-volume exchange, only an exact
            // recorded originally-absent component during restoration.
            if expected != nil {
                guard unlink(target.path) == 0 else { throw CredentialRecoveryError.writeFailed }
                try synchronizeDirectory(target.deletingLastPathComponent())
            }
            return
        }
        let temporary = URL(fileURLWithPath: temporaryPath)
        guard temporary.deletingLastPathComponent() == target.deletingLastPathComponent(),
            temporary.lastPathComponent.hasPrefix(".\(target.lastPathComponent).recovery-")
        else { throw CredentialRecoveryError.changed }
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if descriptor < 0 {
            guard errno == EEXIST,
                isPrivateRegularFile(temporary),
                try Data(contentsOf: temporary) == replacement
            else { throw CredentialRecoveryError.changed }
        } else {
            var created = stat()
            guard fstat(descriptor, &created) == 0 else {
                Darwin.close(descriptor); throw CredentialRecoveryError.writeFailed
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: replacement)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                // This invocation owns this exact O_EXCL-created inode. A crash
                // without that proof still leaves a partial copy protected.
                var current = stat()
                if lstat(temporary.path, &current) == 0,
                    current.st_dev == created.st_dev, current.st_ino == created.st_ino,
                    isPrivateRegularFile(temporary)
                {
                    if unlink(temporary.path) == 0 { try? synchronizeDirectory(temporary.deletingLastPathComponent()) }
                }
                throw error
            }
        }
        let copied = try Data(contentsOf: temporary)
        guard isPrivateRegularFile(temporary), SHA256.hash(data: copied) == SHA256.hash(data: replacement),
            try read(location) == expected,
            try location.checkedFileURL() == target
        else { throw CredentialRecoveryError.changed }
        guard rename(temporary.path, target.path) == 0 else { throw CredentialRecoveryError.writeFailed }
        try synchronizeDirectory(target.deletingLastPathComponent())
        guard try read(location) == replacement else { throw CredentialRecoveryError.changed }
    }

    static func removeVerifiedTemporary(path: String, expected: Data) throws {
        let url = URL(fileURLWithPath: path)
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw CredentialRecoveryError.unreadable
        }
        guard isPrivateRegularFile(url), try Data(contentsOf: url) == expected else {
            throw CredentialRecoveryError.changed
        }
        guard unlink(path) == 0 else { throw CredentialRecoveryError.writeFailed }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private static func isPrivateRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
            && (info.st_mode & 0o777) == 0o600 && info.st_uid == getuid() && info.st_nlink == 1
    }

    static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CredentialRecoveryError.writeFailed }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CredentialRecoveryError.writeFailed }
    }
}
