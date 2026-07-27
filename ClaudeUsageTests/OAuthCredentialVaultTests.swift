import LocalAuthentication
import Security
import XCTest
@testable import ClaudeUsage

final class OAuthCredentialVaultTests: XCTestCase {
    func testClaudeAdapterKeepsExactExistingReferenceAndUTF8PayloadBehavior() throws {
        let vault = RecordingOAuthCredentialVault()
        let adapter = KeychainClaudeOAuthCredentialVault(vault: vault)
        let payload = #"{"claudeAiOauth":{"accessToken":"access"}}"#

        try adapter.savePayload(payload)
        XCTAssertEqual(try adapter.loadPayload(), payload)
        try adapter.deletePayload()

        XCTAssertEqual(vault.savedReferences, [KeychainClaudeOAuthCredentialVault.account])
        XCTAssertEqual(vault.loadedReferences, [KeychainClaudeOAuthCredentialVault.account])
        XCTAssertEqual(vault.deletedReferences, [KeychainClaudeOAuthCredentialVault.account])
        XCTAssertNil(try adapter.loadPayload())
    }

    func testClaudeAdapterPreservesInvalidUTF8AndEmptyValueSemantics() throws {
        let vault = RecordingOAuthCredentialVault(
            values: [KeychainClaudeOAuthCredentialVault.account: Data([0xFF])]
        )
        let adapter = KeychainClaudeOAuthCredentialVault(vault: vault)

        XCTAssertNil(try adapter.loadPayload())
        XCTAssertThrowsError(try adapter.savePayload("")) { error in
            guard let keychainError = error as? ClaudeKeychainStoreError,
                  case .invalidValue = keychainError
            else {
                return XCTFail("기존 ClaudeKeychainStoreError.invalidValue를 유지해야 합니다")
            }
        }
        XCTAssertTrue(vault.savedReferences.isEmpty)
    }

    func testEnumerationQueryRequestsAttributesWithoutSecretDataAndForbidsUI() {
        let query = SecurityFrameworkOAuthCredentialVault.attributeEnumerationQuery(
            service: "com.example.ClaudeUsage"
        )

        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.example.ClaudeUsage")
        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertNil(query[kSecReturnData as String])
        XCTAssertNil(query[kSecAttrAccount as String])
        XCTAssertEqual(
            query[kSecMatchLimit as String] as? String,
            kSecMatchLimitAll as String
        )
        assertReachableKeychainDomain(query)
        assertNoUI(query)
    }

    func testExactQueriesKeepAppServiceAndDeviceOnlyAccessibility() {
        let service = "com.example.ClaudeUsage"
        let reference = "oauth.antigravity.v2.reference"
        let payload = Data("secret".utf8)
        let exact = SecurityFrameworkOAuthCredentialVault.exactItemQuery(
            service: service,
            reference: reference
        )
        let add = SecurityFrameworkOAuthCredentialVault.addItemAttributes(
            service: service,
            reference: reference,
            payload: payload
        )

        XCTAssertEqual(exact[kSecAttrService as String] as? String, service)
        XCTAssertEqual(exact[kSecAttrAccount as String] as? String, reference)
        XCTAssertEqual(exact[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertNil(exact[kSecReturnData as String])
        XCTAssertEqual(add[kSecValueData as String] as? Data, payload)
        XCTAssertEqual(
            add[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        XCTAssertEqual(add[kSecAttrSynchronizable as String] as? Bool, false)
        assertReachableKeychainDomain(exact)
        assertReachableKeychainDomain(add)
        assertNoUI(exact)
        XCTAssertNil(add[kSecUseAuthenticationContext as String])
        XCTAssertNil(add[kSecUseAuthenticationUI as String])
    }

    func testShippedClaudeCacheReferenceUsesTheSameReachableDomainAsAntigravity() {
        let service = "com.example.ClaudeUsage"
        let reference = KeychainClaudeOAuthCredentialVault.account
        let payload = Data("legacy-compatible".utf8)
        let exact = SecurityFrameworkOAuthCredentialVault.exactItemQuery(
            service: service,
            reference: reference
        )
        let enumeration = SecurityFrameworkOAuthCredentialVault.attributeEnumerationQuery(
            service: service
        )
        let add = SecurityFrameworkOAuthCredentialVault.addItemAttributes(
            service: service,
            reference: reference,
            payload: payload
        )

        XCTAssertEqual(exact[kSecAttrAccount as String] as? String, reference)
        assertReachableKeychainDomain(exact)
        assertReachableKeychainDomain(enumeration)
        assertReachableKeychainDomain(add)
        assertNoUI(exact)
        assertNoUI(enumeration)
    }

    func testInvalidReferencesAreRejectedBeforeAnySecurityFrameworkAccess() throws {
        let vault = SecurityFrameworkOAuthCredentialVault(
            service: "com.example.ClaudeUsage"
        )

        for reference in ["", " leading", "trailing ", "with\nnewline"] {
            XCTAssertThrowsError(try vault.loadPayload(reference: reference)) { error in
                XCTAssertEqual(error as? OAuthCredentialVaultError, .invalidReference)
            }
            XCTAssertThrowsError(
                try vault.savePayload(Data("secret".utf8), reference: reference)
            ) { error in
                XCTAssertEqual(error as? OAuthCredentialVaultError, .invalidReference)
            }
            XCTAssertThrowsError(try vault.deletePayload(reference: reference)) { error in
                XCTAssertEqual(error as? OAuthCredentialVaultError, .invalidReference)
            }
        }
    }

    /// A Developer ID build carries no provisioning profile, so the Data
    /// Protection Keychain is unreachable and no query may opt into it or name
    /// an access group.
    private func assertReachableKeychainDomain(
        _ attributes: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(
            attributes[kSecUseDataProtectionKeychain as String],
            file: file,
            line: line
        )
        XCTAssertNil(
            attributes[kSecAttrAccessGroup as String],
            file: file,
            line: line
        )
    }

    private func assertNoUI(
        _ query: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        XCTAssertEqual(context?.interactionNotAllowed, true, file: file, line: line)
        XCTAssertEqual(
            query[kSecUseAuthenticationUI as String] as? String,
            KeychainAccessPreflight.authenticationUIFailPolicyForTesting(),
            file: file,
            line: line
        )
    }

    func testOrphanCleanupRejectsPreservedReferenceOutsideNamespace() throws {
        let vault = RecordingOAuthCredentialVault()
        let namespace = try OAuthCredentialVaultNamespace(prefix: "oauth.antigravity.v2.")

        XCTAssertThrowsError(
            try vault.deleteOrphans(
                in: namespace,
                preserving: ["claude-code-oauth-cache.v2"]
            )
        ) { error in
            XCTAssertEqual(error as? OAuthCredentialVaultError, .invalidReference)
        }
        XCTAssertTrue(vault.deletedReferences.isEmpty)
    }

    func testOrphanCleanupDeletesOnlyDiscoveredItemsInsideRequestedNamespace() throws {
        let namespace = try OAuthCredentialVaultNamespace(prefix: "oauth.antigravity.v2.")
        let kept = "oauth.antigravity.v2.kept"
        let orphan = "oauth.antigravity.v2.orphan"
        let vault = RecordingOAuthCredentialVault(
            values: [
                kept: Data("kept".utf8),
                orphan: Data("orphan".utf8),
                "claude-code-oauth-cache.v2": Data("claude".utf8),
            ]
        )

        let result = try vault.deleteOrphans(in: namespace, preserving: [kept])

        XCTAssertEqual(result.deletedReferences, [orphan])
        XCTAssertEqual(result.preservedReferences, [kept])
        XCTAssertEqual(vault.deletedReferences, [orphan])
        XCTAssertNotNil(vault.value(for: "claude-code-oauth-cache.v2"))
    }
}

private final class RecordingOAuthCredentialVault: OAuthCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data]
    private var recordedSavedReferences: [String] = []
    private var recordedLoadedReferences: [String] = []
    private var recordedDeletedReferences: [String] = []

    init(values: [String: Data] = [:]) {
        self.values = values
    }

    var savedReferences: [String] { lock.withLock { recordedSavedReferences } }
    var loadedReferences: [String] { lock.withLock { recordedLoadedReferences } }
    var deletedReferences: [String] { lock.withLock { recordedDeletedReferences } }

    func value(for reference: String) -> Data? {
        lock.withLock { values[reference] }
    }

    nonisolated func loadPayload(reference: String) throws -> Data? {
        lock.withLock {
            recordedLoadedReferences.append(reference)
            return values[reference]
        }
    }

    nonisolated func savePayload(_ payload: Data, reference: String) throws {
        lock.withLock {
            recordedSavedReferences.append(reference)
            values[reference] = payload
        }
    }

    nonisolated func deletePayload(reference: String) throws {
        lock.withLock {
            recordedDeletedReferences.append(reference)
            values.removeValue(forKey: reference)
        }
    }

    nonisolated func references(in namespace: OAuthCredentialVaultNamespace) throws -> Set<String> {
        lock.withLock {
            Set(values.keys.filter(namespace.contains))
        }
    }
}
