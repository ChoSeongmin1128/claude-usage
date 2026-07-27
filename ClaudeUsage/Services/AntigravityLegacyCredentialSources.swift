import Darwin
import Foundation
import LocalAuthentication
import Security

nonisolated enum AntigravityLegacyReadResult: Equatable, Sendable {
    case notFound
    case readable(Data)
    case interactionRequired
    case cancelled
    case invalid
    case failure(Int)
}

nonisolated enum AntigravityLegacyDeleteResult: Equatable, Sendable {
    case absent
    case deleted
    case changed
    case interactionRequired
    case cancelled
    case failure(Int)
}

protocol AntigravityLegacyFileAccessing: Sendable {
    nonisolated func read(_ source: AntigravityLegacySourceID) -> AntigravityLegacyReadResult
    nonisolated func readQuarantine(
        _ source: AntigravityLegacySourceID
    ) -> AntigravityLegacyReadResult
    nonisolated func deleteIfUnchanged(
        _ source: AntigravityLegacySourceID,
        expectedPayloadFingerprint: String
    ) -> AntigravityLegacyDeleteResult
    nonisolated func deleteAllIdentities(
        _ source: AntigravityLegacySourceID
    ) -> AntigravityLegacyDeleteResult
    nonisolated func removeAntigravityDirectoryIfEmpty() throws
}

protocol AntigravityLegacyKeychainAccessing: Sendable {
    nonisolated func read(
        _ source: AntigravityLegacySourceID,
        authenticationContext: LAContext?
    ) -> AntigravityLegacyReadResult
    nonisolated func readQuarantine(
        _ source: AntigravityLegacySourceID,
        authenticationContext: LAContext?
    ) -> AntigravityLegacyReadResult
    nonisolated func deleteIfUnchanged(
        _ source: AntigravityLegacySourceID,
        expectedPayloadFingerprint: String,
        authenticationContext: LAContext?
    ) -> AntigravityLegacyDeleteResult
    nonisolated func deleteAllIdentities(
        _ source: AntigravityLegacySourceID,
        authenticationContext: LAContext?
    ) -> AntigravityLegacyDeleteResult
}

nonisolated struct AntigravitySecurityItemReadResult: Sendable {
    let status: OSStatus
    let data: Data?
}

protocol AntigravitySecurityItemAccessing: Sendable {
    nonisolated func copyMatching(
        _ query: [String: Any]
    ) -> AntigravitySecurityItemReadResult
    nonisolated func update(
        _ query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus
    nonisolated func delete(_ query: [String: Any]) -> OSStatus
}

nonisolated struct SystemAntigravitySecurityItemAccess:
    AntigravitySecurityItemAccessing
{
    nonisolated func copyMatching(
        _ query: [String: Any]
    ) -> AntigravitySecurityItemReadResult {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return AntigravitySecurityItemReadResult(
            status: status,
            data: result as? Data
        )
    }

    nonisolated func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }

    nonisolated func update(
        _ query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus {
        SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
    }
}

nonisolated final class AntigravityLegacyOAuthFileAccess:
    AntigravityLegacyFileAccessing,
    @unchecked Sendable
{
    let directoryURL: URL
    private let fileManager: FileManager

    init(
        directoryURL: URL = AntigravityOAuthCredentialsStore.defaultDirectoryURL(),
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    nonisolated func read(
        _ source: AntigravityLegacySourceID
    ) -> AntigravityLegacyReadResult {
        guard let url = url(for: source) else { return .notFound }
        return readRegularFile(at: url)
    }

    nonisolated func readQuarantine(
        _ source: AntigravityLegacySourceID
    ) -> AntigravityLegacyReadResult {
        guard let url = url(for: source) else { return .notFound }
        return readRegularFile(at: quarantineURL(for: url))
    }

    nonisolated func deleteIfUnchanged(
        _ source: AntigravityLegacySourceID,
        expectedPayloadFingerprint: String
    ) -> AntigravityLegacyDeleteResult {
        guard let originalURL = url(for: source) else { return .absent }
        let quarantineURL = quarantineURL(for: originalURL)

        switch readRegularFile(at: quarantineURL) {
        case .notFound:
            break
        case .readable, .invalid:
            return resolveQuarantinedFile(
                originalURL: originalURL,
                quarantineURL: quarantineURL,
                expectedPayloadFingerprint: expectedPayloadFingerprint
            )
        case let .failure(code):
            return .failure(code)
        case .interactionRequired, .cancelled:
            return .failure(Int(EIO))
        }

        switch atomicMoveExcludingDestination(
            from: originalURL,
            to: quarantineURL
        ) {
        case .moved:
            return resolveQuarantinedFile(
                originalURL: originalURL,
                quarantineURL: quarantineURL,
                expectedPayloadFingerprint: expectedPayloadFingerprint
            )
        case .sourceAbsent:
            // A prior process may have completed the move between the first
            // quarantine check and rename. Re-enter through the fixed identity.
            if case .notFound = readRegularFile(at: quarantineURL) {
                return .absent
            }
            return resolveQuarantinedFile(
                originalURL: originalURL,
                quarantineURL: quarantineURL,
                expectedPayloadFingerprint: expectedPayloadFingerprint
            )
        case .destinationExists:
            return resolveQuarantinedFile(
                originalURL: originalURL,
                quarantineURL: quarantineURL,
                expectedPayloadFingerprint: expectedPayloadFingerprint
            )
        case let .failure(code):
            return .failure(code)
        }
    }

    nonisolated func deleteAllIdentities(
        _ source: AntigravityLegacySourceID
    ) -> AntigravityLegacyDeleteResult {
        guard let originalURL = url(for: source) else { return .absent }
        let targets = [originalURL, quarantineURL(for: originalURL)]
        var deletedAny = false
        for target in targets {
            var metadata = stat()
            guard lstat(target.path, &metadata) == 0 else {
                if errno == ENOENT { continue }
                return .failure(Int(errno))
            }
            guard unlink(target.path) == 0 else {
                if errno == ENOENT { continue }
                return .failure(Int(errno))
            }
            deletedAny = true
        }
        guard targets.allSatisfy({ !identityExists(at: $0) }) else {
            return .failure(Int(EIO))
        }
        return deletedAny ? .deleted : .absent
    }

    nonisolated func removeAntigravityDirectoryIfEmpty() throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        guard contents.isEmpty else { return }
        try fileManager.removeItem(at: directoryURL)
    }

    private nonisolated func url(for source: AntigravityLegacySourceID) -> URL? {
        let name: String
        switch source {
        case .accountFile:
            name = "oauth_accounts.json"
        case .activeCredentialFile:
            name = "oauth_creds.json"
        case .metadataFile:
            name = "oauth_metadata.json"
        case .bundleIdentifierKeychain, .claudeUsageKeychain:
            return nil
        }
        return directoryURL.appendingPathComponent(name)
    }

    private enum AtomicMoveResult {
        case moved
        case sourceAbsent
        case destinationExists
        case failure(Int)
    }

    private nonisolated func atomicMoveExcludingDestination(
        from source: URL,
        to destination: URL
    ) -> AtomicMoveResult {
        let result = renamex_np(
            source.path,
            destination.path,
            UInt32(RENAME_EXCL)
        )
        guard result == 0 else {
            switch errno {
            case ENOENT:
                return .sourceAbsent
            case EEXIST:
                return .destinationExists
            default:
                return .failure(Int(errno))
            }
        }
        return .moved
    }

    private nonisolated func resolveQuarantinedFile(
        originalURL: URL,
        quarantineURL: URL,
        expectedPayloadFingerprint: String
    ) -> AntigravityLegacyDeleteResult {
        let quarantined = readRegularFile(at: quarantineURL)
        guard case let .readable(data) = quarantined,
              AntigravityMigrationFingerprint.data(data)
                == expectedPayloadFingerprint
        else {
            // A changed payload is restored only if doing so cannot overwrite
            // a value recreated at the original identity. Failed restoration
            // deliberately preserves quarantine for diagnosis/retry.
            if !identityExists(at: originalURL) {
                _ = atomicMoveExcludingDestination(
                    from: quarantineURL,
                    to: originalURL
                )
            }
            return .changed
        }

        let originalWasRecreated = identityExists(at: originalURL)
        guard unlink(quarantineURL.path) == 0 || errno == ENOENT else {
            return .failure(Int(errno))
        }
        guard !identityExists(at: quarantineURL) else {
            return .failure(Int(EIO))
        }
        // A writer may recreate the original after the first check. That value
        // is outside the owned quarantine identity and must never be removed.
        return originalWasRecreated || identityExists(at: originalURL)
            ? .changed
            : .deleted
    }

    private nonisolated func readRegularFile(
        at url: URL
    ) -> AntigravityLegacyReadResult {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return .notFound }
            if errno == ELOOP { return .invalid }
            return .failure(Int(errno))
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            return .failure(Int(errno))
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            // O_NOFOLLOW rejects symlinks at open time; fstat rejects devices,
            // sockets and every other non-regular node without a path re-open.
            return .invalid
        }
        do {
            let handle = FileHandle(
                fileDescriptor: descriptor,
                closeOnDealloc: false
            )
            let data = try handle.readToEnd() ?? Data()
            // Preserve even an empty payload so reconciliation can bind its
            // raw fingerprint before deleting an invalid redundant mirror.
            return .readable(data)
        } catch {
            return .failure((error as NSError).code)
        }
    }

    private nonisolated func identityExists(at url: URL) -> Bool {
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 { return true }
        return errno != ENOENT
    }

    private nonisolated func quarantineURL(for originalURL: URL) -> URL {
        originalURL.deletingLastPathComponent().appendingPathComponent(
            ".claudeusage-v2-quarantine-\(originalURL.lastPathComponent)"
        )
    }
}

nonisolated struct AntigravityLegacyOAuthKeychainAccess:
    AntigravityLegacyKeychainAccessing
{
    static let quarantineAccount =
        "claudeusage.antigravity.oauth.v2.quarantine"

    private let bundleIdentifierService: String
    private let securityItemAccess: any AntigravitySecurityItemAccessing

    init(
        bundleIdentifierService: String = Bundle.main.bundleIdentifier ?? "ClaudeUsage",
        securityItemAccess: any AntigravitySecurityItemAccessing =
            SystemAntigravitySecurityItemAccess()
    ) {
        self.bundleIdentifierService = bundleIdentifierService
        self.securityItemAccess = securityItemAccess
    }

    nonisolated func read(
        _ source: AntigravityLegacySourceID,
        authenticationContext: LAContext?
    ) -> AntigravityLegacyReadResult {
        read(
            source: source,
            account: AntigravityOAuthCredentialsStore.legacyKeychainAccount,
            authenticationContext: authenticationContext
        )
    }

    nonisolated func readQuarantine(
        _ source: AntigravityLegacySourceID,
        authenticationContext: LAContext?
    ) -> AntigravityLegacyReadResult {
        read(
            source: source,
            account: Self.quarantineAccount,
            authenticationContext: authenticationContext
        )
    }

    nonisolated func deleteIfUnchanged(
        _ source: AntigravityLegacySourceID,
        expectedPayloadFingerprint: String,
        authenticationContext: LAContext?
    ) -> AntigravityLegacyDeleteResult {
        let quarantined = readQuarantine(
            source,
            authenticationContext: authenticationContext
        )
        switch quarantined {
        case .notFound:
            break
        case .readable, .invalid:
            return resolveQuarantinedItem(
                source,
                expectedPayloadFingerprint: expectedPayloadFingerprint,
                authenticationContext: authenticationContext
            )
        case .interactionRequired:
            return .interactionRequired
        case .cancelled:
            return .cancelled
        case let .failure(code):
            return .failure(code)
        }

        guard let query = Self.updateQuery(
            source: source,
            bundleIdentifierService: bundleIdentifierService,
            account: AntigravityOAuthCredentialsStore.legacyKeychainAccount,
            authenticationContext: authenticationContext
        ) else {
            return .absent
        }
        let status = securityItemAccess.update(
            query,
            attributes: [
                kSecAttrAccount as String: Self.quarantineAccount,
            ]
        )
        switch status {
        case errSecSuccess:
            return resolveQuarantinedItem(
                source,
                expectedPayloadFingerprint: expectedPayloadFingerprint,
                authenticationContext: authenticationContext
            )
        case errSecItemNotFound:
            let retry = readQuarantine(
                source,
                authenticationContext: authenticationContext
            )
            if case .notFound = retry { return .absent }
            return resolveQuarantinedItem(
                source,
                expectedPayloadFingerprint: expectedPayloadFingerprint,
                authenticationContext: authenticationContext
            )
        case errSecDuplicateItem:
            return resolveQuarantinedItem(
                source,
                expectedPayloadFingerprint: expectedPayloadFingerprint,
                authenticationContext: authenticationContext
            )
        case errSecUserCanceled:
            return authenticationContext == nil ? .interactionRequired : .cancelled
        case errSecInteractionNotAllowed, errSecAuthFailed:
            return authenticationContext == nil
                ? .interactionRequired
                : .failure(Int(status))
        default:
            return .failure(Int(status))
        }
    }

    nonisolated func deleteAllIdentities(
        _ source: AntigravityLegacySourceID,
        authenticationContext: LAContext?
    ) -> AntigravityLegacyDeleteResult {
        var deletedAny = false
        for account in [
            AntigravityOAuthCredentialsStore.legacyKeychainAccount,
            Self.quarantineAccount,
        ] {
            let result = delete(
                source: source,
                account: account,
                authenticationContext: authenticationContext
            )
            switch result {
            case .absent:
                continue
            case .deleted:
                deletedAny = true
            case .changed:
                return .changed
            case .interactionRequired:
                return .interactionRequired
            case .cancelled:
                return .cancelled
            case let .failure(code):
                return .failure(code)
            }
        }
        return deletedAny ? .deleted : .absent
    }

    /// Kept as a concrete compatibility helper for query/status contract tests.
    nonisolated func delete(
        _ source: AntigravityLegacySourceID,
        authenticationContext: LAContext?
    ) -> AntigravityLegacyDeleteResult {
        deleteAllIdentities(
            source,
            authenticationContext: authenticationContext
        )
    }

    private nonisolated func resolveQuarantinedItem(
        _ source: AntigravityLegacySourceID,
        expectedPayloadFingerprint: String,
        authenticationContext: LAContext?
    ) -> AntigravityLegacyDeleteResult {
        let quarantined = readQuarantine(
            source,
            authenticationContext: authenticationContext
        )
        switch quarantined {
        case let .readable(data):
            guard AntigravityMigrationFingerprint.data(data)
                    == expectedPayloadFingerprint
            else {
                restoreQuarantineIfOriginalAbsent(
                    source,
                    authenticationContext: authenticationContext
                )
                return .changed
            }
        case .notFound:
            return .absent
        case .invalid:
            restoreQuarantineIfOriginalAbsent(
                source,
                authenticationContext: authenticationContext
            )
            return .changed
        case .interactionRequired:
            return .interactionRequired
        case .cancelled:
            return .cancelled
        case let .failure(code):
            return .failure(code)
        }

        let original = read(
            source,
            authenticationContext: authenticationContext
        )
        let originalWasRecreated: Bool
        switch original {
        case .notFound:
            originalWasRecreated = false
        case .readable, .invalid:
            originalWasRecreated = true
        case .interactionRequired:
            return .interactionRequired
        case .cancelled:
            return .cancelled
        case let .failure(code):
            return .failure(code)
        }

        let deletion = delete(
            source: source,
            account: Self.quarantineAccount,
            authenticationContext: authenticationContext
        )
        switch deletion {
        case .absent, .deleted:
            let recreatedAfterDelete = read(
                source,
                authenticationContext: authenticationContext
            )
            switch recreatedAfterDelete {
            case .notFound:
                return originalWasRecreated ? .changed : .deleted
            case .readable, .invalid:
                return .changed
            case .interactionRequired:
                return .interactionRequired
            case .cancelled:
                return .cancelled
            case let .failure(code):
                return .failure(code)
            }
        case .changed:
            return .changed
        case .interactionRequired:
            return .interactionRequired
        case .cancelled:
            return .cancelled
        case let .failure(code):
            return .failure(code)
        }
    }

    private nonisolated func restoreQuarantineIfOriginalAbsent(
        _ source: AntigravityLegacySourceID,
        authenticationContext: LAContext?
    ) {
        guard case .notFound = read(
            source,
            authenticationContext: authenticationContext
        ), let query = Self.updateQuery(
            source: source,
            bundleIdentifierService: bundleIdentifierService,
            account: Self.quarantineAccount,
            authenticationContext: authenticationContext
        ) else {
            return
        }
        // A duplicate-item response means an external writer recreated the
        // original. In that case quarantine is intentionally preserved.
        _ = securityItemAccess.update(
            query,
            attributes: [
                kSecAttrAccount as String:
                    AntigravityOAuthCredentialsStore.legacyKeychainAccount,
            ]
        )
    }

    private nonisolated func read(
        source: AntigravityLegacySourceID,
        account: String,
        authenticationContext: LAContext?
    ) -> AntigravityLegacyReadResult {
        guard let query = Self.readQuery(
            source: source,
            bundleIdentifierService: bundleIdentifierService,
            account: account,
            authenticationContext: authenticationContext
        ) else {
            return .notFound
        }
        let result = securityItemAccess.copyMatching(query)
        switch result.status {
        case errSecSuccess:
            guard let data = result.data else { return .invalid }
            return .readable(data)
        case errSecItemNotFound:
            return .notFound
        case errSecUserCanceled:
            return authenticationContext == nil ? .interactionRequired : .cancelled
        case errSecInteractionNotAllowed, errSecAuthFailed:
            return authenticationContext == nil
                ? .interactionRequired
                : .failure(Int(result.status))
        default:
            return .failure(Int(result.status))
        }
    }

    private nonisolated func delete(
        source: AntigravityLegacySourceID,
        account: String,
        authenticationContext: LAContext?
    ) -> AntigravityLegacyDeleteResult {
        guard let query = Self.deleteQuery(
            source: source,
            bundleIdentifierService: bundleIdentifierService,
            account: account,
            authenticationContext: authenticationContext
        ) else {
            return .absent
        }
        return mapDeleteStatus(
            securityItemAccess.delete(query),
            authenticationContext: authenticationContext
        )
    }

    private nonisolated func mapDeleteStatus(
        _ status: OSStatus,
        authenticationContext: LAContext?
    ) -> AntigravityLegacyDeleteResult {
        switch status {
        case errSecSuccess:
            return .deleted
        case errSecItemNotFound:
            return .absent
        case errSecUserCanceled:
            return authenticationContext == nil ? .interactionRequired : .cancelled
        case errSecInteractionNotAllowed, errSecAuthFailed:
            return authenticationContext == nil
                ? .interactionRequired
                : .failure(Int(status))
        default:
            return .failure(Int(status))
        }
    }

    nonisolated static func readQuery(
        source: AntigravityLegacySourceID,
        bundleIdentifierService: String,
        account: String = AntigravityOAuthCredentialsStore.legacyKeychainAccount,
        authenticationContext: LAContext?
    ) -> [String: Any]? {
        guard var query = baseQuery(
            source: source,
            bundleIdentifierService: bundleIdentifierService,
            account: account
        ) else {
            return nil
        }
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        applyAuthenticationPolicy(
            to: &query,
            authenticationContext: authenticationContext
        )
        return query
    }

    nonisolated static func deleteQuery(
        source: AntigravityLegacySourceID,
        bundleIdentifierService: String,
        account: String = AntigravityOAuthCredentialsStore.legacyKeychainAccount,
        authenticationContext: LAContext?
    ) -> [String: Any]? {
        guard var query = baseQuery(
            source: source,
            bundleIdentifierService: bundleIdentifierService,
            account: account
        ) else {
            return nil
        }
        applyAuthenticationPolicy(
            to: &query,
            authenticationContext: authenticationContext
        )
        return query
    }

    nonisolated static func updateQuery(
        source: AntigravityLegacySourceID,
        bundleIdentifierService: String,
        account: String,
        authenticationContext: LAContext?
    ) -> [String: Any]? {
        guard var query = baseQuery(
            source: source,
            bundleIdentifierService: bundleIdentifierService,
            account: account
        ) else {
            return nil
        }
        applyAuthenticationPolicy(
            to: &query,
            authenticationContext: authenticationContext
        )
        return query
    }

    private nonisolated static func baseQuery(
        source: AntigravityLegacySourceID,
        bundleIdentifierService: String,
        account: String
    ) -> [String: Any]? {
        let service: String
        switch source {
        case .bundleIdentifierKeychain:
            service = bundleIdentifierService
        case .claudeUsageKeychain:
            service = "ClaudeUsage"
        case .accountFile, .activeCredentialFile, .metadataFile:
            return nil
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private nonisolated static func applyAuthenticationPolicy(
        to query: inout [String: Any],
        authenticationContext: LAContext?
    ) {
        if let authenticationContext {
            query[kSecUseAuthenticationContext as String] = authenticationContext
        } else {
            KeychainAccessPreflight.applyNoUI(to: &query)
        }
    }
}
