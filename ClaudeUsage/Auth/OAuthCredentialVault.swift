import Foundation
import Security

nonisolated struct OAuthCredentialVaultNamespace: Hashable, Sendable {
    let prefix: String

    init(prefix: String) throws {
        guard !prefix.isEmpty,
              prefix.hasSuffix("."),
              !prefix.contains(where: { $0.isWhitespace })
        else {
            throw OAuthCredentialVaultError.invalidNamespace
        }
        self.prefix = prefix
    }

    func contains(_ reference: String) -> Bool {
        reference.hasPrefix(prefix) && reference.count > prefix.count
    }
}

nonisolated struct OAuthCredentialVaultCleanupResult: Equatable, Sendable {
    let deletedReferences: Set<String>
    let preservedReferences: Set<String>
}

nonisolated enum OAuthCredentialVaultError: Error, Equatable, Sendable {
    case invalidNamespace
    case invalidReference
    case invalidPayload
    case deletionVerificationFailed
    case interactionNotAllowed
    case unexpectedStatus(OSStatus)
}

/// App-owned OAuth secret storage primitive.
///
/// Callers own payload encoding. The vault owns exact generic-password access and
/// attribute-only discovery inside an explicit account namespace. Implementations
/// must never log payloads or derive a reference from credential contents.
protocol OAuthCredentialVault: Sendable {
    nonisolated func loadPayload(reference: String) throws -> Data?
    nonisolated func savePayload(_ payload: Data, reference: String) throws
    nonisolated func deletePayload(reference: String) throws
    nonisolated func references(in namespace: OAuthCredentialVaultNamespace) throws -> Set<String>
}

extension OAuthCredentialVault {
    nonisolated func deleteOrphans(
        in namespace: OAuthCredentialVaultNamespace,
        preserving requestedReferences: Set<String>
    ) throws -> OAuthCredentialVaultCleanupResult {
        guard requestedReferences.allSatisfy(namespace.contains) else {
            throw OAuthCredentialVaultError.invalidReference
        }

        let discovered = try references(in: namespace)
        guard discovered.allSatisfy(namespace.contains) else {
            throw OAuthCredentialVaultError.invalidReference
        }

        let preserved = discovered.intersection(requestedReferences)
        let orphans = discovered.subtracting(preserved)
        for reference in orphans.sorted() {
            try deletePayload(reference: reference)
            guard try loadPayload(reference: reference) == nil else {
                throw OAuthCredentialVaultError.deletionVerificationFailed
            }
        }
        return OAuthCredentialVaultCleanupResult(
            deletedReferences: orphans,
            preservedReferences: preserved
        )
    }
}

/// Security.framework-backed app vault shared by provider-specific repositories.
///
/// The service remains the app bundle identifier. Provider and schema isolation
/// live in immutable account references such as `oauth.antigravity.v2.<uuid>`.
///
/// Items stay in the file-based keychain that the shipped app already uses for
/// Claude credentials. The Data Protection Keychain would additionally require a
/// `keychain-access-groups` entitlement, and Developer ID distribution only honors
/// that entitlement when an embedded provisioning profile authorizes it. Adopting
/// that domain is a separate task that has to begin by issuing the profile, so
/// every query here stays in the domain a Developer ID build can actually reach.
final class SecurityFrameworkOAuthCredentialVault: OAuthCredentialVault, @unchecked Sendable {
    nonisolated static let shared = SecurityFrameworkOAuthCredentialVault()

    private let service: String

    nonisolated init(
        service: String = Bundle.main.bundleIdentifier ?? "ClaudeUsage"
    ) {
        self.service = service
    }

    nonisolated func loadPayload(reference: String) throws -> Data? {
        try Self.validateExactReference(reference)
        var query = Self.exactItemQuery(
            service: service,
            reference: reference
        )
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw OAuthCredentialVaultError.invalidPayload
            }
            return data
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw OAuthCredentialVaultError.interactionNotAllowed
        default:
            throw OAuthCredentialVaultError.unexpectedStatus(status)
        }
    }

    nonisolated func savePayload(_ payload: Data, reference: String) throws {
        try Self.validateExactReference(reference)
        guard !payload.isEmpty else {
            throw OAuthCredentialVaultError.invalidPayload
        }

        let query = Self.exactItemQuery(
            service: service,
            reference: reference
        )
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: payload] as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            try addOrRetryUpdate(payload: payload, query: query)
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw OAuthCredentialVaultError.interactionNotAllowed
        default:
            // Preserve the existing Claude app-vault behavior: an unexpected
            // first update result still gets one add/duplicate-update attempt.
            try addOrRetryUpdate(payload: payload, query: query)
        }
    }

    nonisolated func deletePayload(reference: String) throws {
        try Self.validateExactReference(reference)
        let status = SecItemDelete(
            Self.exactItemQuery(
                service: service,
                reference: reference
            ) as CFDictionary
        )
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw OAuthCredentialVaultError.interactionNotAllowed
        default:
            throw OAuthCredentialVaultError.unexpectedStatus(status)
        }
    }

    nonisolated func references(in namespace: OAuthCredentialVaultNamespace) throws -> Set<String> {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            Self.attributeEnumerationQuery(
                service: service
            ) as CFDictionary,
            &result
        )
        switch status {
        case errSecItemNotFound:
            return []
        case errSecSuccess:
            let attributes: [[String: Any]]
            if let many = result as? [[String: Any]] {
                attributes = many
            } else if let one = result as? [String: Any] {
                attributes = [one]
            } else {
                throw OAuthCredentialVaultError.invalidPayload
            }
            return Set(attributes.compactMap { attributes in
                guard let account = attributes[kSecAttrAccount as String] as? String,
                      namespace.contains(account)
                else {
                    return nil
                }
                return account
            })
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw OAuthCredentialVaultError.interactionNotAllowed
        default:
            throw OAuthCredentialVaultError.unexpectedStatus(status)
        }
    }

    nonisolated static func exactItemQuery(
        service: String,
        reference: String
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecAttrSynchronizable as String: false,
        ]
        KeychainAccessPreflight.applyNoUI(to: &query)
        return query
    }

    nonisolated static func attributeEnumerationQuery(
        service: String
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        KeychainAccessPreflight.applyNoUI(to: &query)
        return query
    }

    nonisolated static func addItemAttributes(
        service: String,
        reference: String,
        payload: Data
    ) -> [String: Any] {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecAttrSynchronizable as String: false,
        ]
        attributes[kSecValueData as String] = payload
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return attributes
    }

    private nonisolated static func validateExactReference(_ reference: String) throws {
        guard !reference.isEmpty,
              reference == reference.trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.contains(where: { $0.isNewline })
        else {
            throw OAuthCredentialVaultError.invalidReference
        }
    }

    private nonisolated func addOrRetryUpdate(
        payload: Data,
        query: [String: Any]
    ) throws {
        guard let reference = query[kSecAttrAccount as String] as? String else {
            throw OAuthCredentialVaultError.invalidReference
        }
        let attributes = Self.addItemAttributes(
            service: service,
            reference: reference,
            payload: payload
        )
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let retryStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: payload] as CFDictionary
            )
            switch retryStatus {
            case errSecSuccess:
                return
            case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
                throw OAuthCredentialVaultError.interactionNotAllowed
            default:
                throw OAuthCredentialVaultError.unexpectedStatus(retryStatus)
            }
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw OAuthCredentialVaultError.interactionNotAllowed
        default:
            throw OAuthCredentialVaultError.unexpectedStatus(addStatus)
        }
    }
}
