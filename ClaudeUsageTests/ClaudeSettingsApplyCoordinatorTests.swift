import XCTest
@testable import ClaudeUsage

@MainActor
final class ClaudeSettingsApplyCoordinatorTests: XCTestCase {
    func testActivateSessionKeySavesOnlyAfterSessionUsageValidationSucceeds() async throws {
        let keychain = FakeClaudeSessionKeyStore()
        let service = FakeClaudeSettingsService()

        let result = try await ClaudeSettingsApplyCoordinator.activateSessionKey(
            "new-session",
            apiService: service,
            preferredOrganizationID: "org-company",
            providerEnabled: true,
            keychain: keychain
        )

        XCTAssertEqual(keychain.savedValues, ["new-session"])
        XCTAssertEqual(keychain.savedPreferredOrganizationIDs, ["org-company"])
        let validatedSessionKeys = await service.validatedSessionKeysSnapshot()
        let currentSessionKey = await service.currentSessionKeySnapshot()
        XCTAssertEqual(validatedSessionKeys, ["new-session"])
        XCTAssertEqual(currentSessionKey, "new-session")
        let preferredOrganizationID = await service.preferredOrganizationIDSnapshot()
        XCTAssertEqual(preferredOrganizationID, "org-company")
        XCTAssertTrue(result.shouldStartMonitoring)
    }

    func testActivateSessionKeyDoesNotSaveWhenSessionUsageValidationFails() async {
        let keychain = FakeClaudeSessionKeyStore(initialValue: "old-session")
        let service = FakeClaudeSettingsService()
        await service.setValidationError(APIError.invalidSessionKey)

        do {
            _ = try await ClaudeSettingsApplyCoordinator.activateSessionKey(
                "bad-session",
                apiService: service,
                preferredOrganizationID: "",
                providerEnabled: true,
                keychain: keychain
            )
            XCTFail("Expected validation failure")
        } catch {
            guard case APIError.invalidSessionKey = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertTrue(keychain.savedValues.isEmpty)
        XCTAssertEqual(keychain.currentValue, "old-session")
        let currentSessionKey = await service.currentSessionKeySnapshot()
        XCTAssertEqual(currentSessionKey, "old-session")
    }

    func testDeleteBrowserSessionKeepsOAuthAvailabilityAndDoesNotDeleteExternalCredential() async {
        let keychain = FakeClaudeSessionKeyStore(initialValue: "web-session")
        let service = FakeClaudeSettingsService(oauthAvailable: true)
        await service.updateSessionKey("web-session")

        let result = await ClaudeSettingsApplyCoordinator.deleteBrowserSession(
            apiService: service,
            preferredOrganizationID: "",
            providerEnabled: true,
            keychain: keychain
        )

        XCTAssertTrue(keychain.didDelete)
        XCTAssertNil(keychain.currentValue)
        let currentSessionKey = await service.currentSessionKeySnapshot()
        XCTAssertNil(currentSessionKey)
        XCTAssertFalse(result.snapshot.runtime.credentialAvailability.sessionCredentialAvailable)
        XCTAssertTrue(result.snapshot.runtime.credentialAvailability.oauthCredentialAvailable)
        XCTAssertTrue(result.shouldStartMonitoring)
    }
}

private final class FakeClaudeSessionKeyStore: ClaudeSessionKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private(set) var savedValues: [String] = []
    private(set) var savedPreferredOrganizationIDs: [String?] = []
    private(set) var savedDisplayNames: [String?] = []
    private(set) var didDelete = false

    init(initialValue: String? = nil) {
        self.value = initialValue
    }

    var currentValue: String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func load() -> String? {
        currentValue
    }

    func save(_ sessionKey: String) throws {
        lock.lock()
        value = sessionKey
        savedValues.append(sessionKey)
        lock.unlock()
    }

    func save(_ sessionKey: String, preferredOrganizationID: String?) throws {
        try save(sessionKey, preferredOrganizationID: preferredOrganizationID, displayName: nil)
    }

    func save(_ sessionKey: String, preferredOrganizationID: String?, displayName: String?) throws {
        lock.lock()
        value = sessionKey
        savedValues.append(sessionKey)
        savedPreferredOrganizationIDs.append(preferredOrganizationID)
        savedDisplayNames.append(displayName)
        lock.unlock()
    }

    func delete() throws {
        lock.lock()
        value = nil
        didDelete = true
        lock.unlock()
    }
}

private actor FakeClaudeSettingsService: ClaudeSettingsApplyingService {
    private(set) var currentSessionKey: String?
    private(set) var validatedSessionKeys: [String] = []
    private var validationError: Error?
    private var oauthAvailable: Bool
    private var preferredOrganizationID = ""

    init(oauthAvailable: Bool = false) {
        self.oauthAvailable = oauthAvailable
    }

    func setValidationError(_ error: Error?) {
        validationError = error
    }

    func currentSessionKeySnapshot() -> String? {
        currentSessionKey
    }

    func validatedSessionKeysSnapshot() -> [String] {
        validatedSessionKeys
    }

    func preferredOrganizationIDSnapshot() -> String {
        preferredOrganizationID
    }

    func updatePreferredOrganizationID(_ id: String) {
        preferredOrganizationID = id
    }

    func updateSessionKey(_ key: String) {
        currentSessionKey = key
    }

    func clearSession() {
        currentSessionKey = nil
    }

    func validateCurrentSessionUsage() async throws -> ClaudeUsageResponse {
        if let validationError {
            throw validationError
        }
        validatedSessionKeys.append(currentSessionKey ?? "")
        return ClaudeUsageResponse(
            fiveHour: UsageWindow(utilization: 10, resetsAt: nil),
            sevenDay: nil
        )
    }

    func fetchUsageHealthSnapshot() -> ClaudeAPIService.UsageHealthSnapshot {
        let sessionAvailable = currentSessionKey?.isEmpty == false
        return ClaudeAPIService.UsageHealthSnapshot(
            lastOverallSuccessAt: sessionAvailable ? Date() : nil,
            session: Self.pathSnapshot(available: sessionAvailable),
            oauth: Self.pathSnapshot(available: oauthAvailable),
            runtime: ClaudeAPIService.RuntimeAuthSnapshot(
                activePath: sessionAvailable ? .sessionPrimary : (oauthAvailable ? .oauthFallback : .unauthenticated),
                credentialAvailability: ClaudeCredentialAvailability(
                    sessionCredentialAvailable: sessionAvailable,
                    oauthCredentialAvailable: oauthAvailable
                ),
                sessionValidationState: sessionAvailable ? .verified : .unavailable,
                oauthValidationState: oauthAvailable ? .detected : .unavailable,
                sessionCooldownRemaining: nil,
                oauthPreferredRemaining: nil
            )
        )
    }

    func fetchCachedProfileMetadata() -> ClaudeProfileMetadata? {
        nil
    }

    private static func pathSnapshot(available: Bool) -> ClaudeAPIService.AuthPathHealthSnapshot {
        ClaudeAPIService.AuthPathHealthSnapshot(
            lastAttemptAt: available ? Date() : nil,
            lastSuccessAt: available ? Date() : nil,
            lastFailureAt: nil,
            lastErrorMessage: nil,
            consecutiveFailures: 0,
            totalAttempts: available ? 1 : 0,
            totalFailures: 0
        )
    }
}
