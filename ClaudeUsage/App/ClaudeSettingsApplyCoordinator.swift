import Foundation

protocol ClaudeSessionKeyStoring: Sendable {
    func load() -> String?
    func save(_ sessionKey: String) throws
    func save(_ sessionKey: String, preferredOrganizationID: String?) throws
    func save(_ sessionKey: String, preferredOrganizationID: String?, displayName: String?) throws
    func save(
        _ sessionKey: String,
        preferredOrganizationID: String?,
        displayName: String?,
        source: ClaudeAccountSource?,
        sourceDetail: String?
    ) throws
    func delete() throws
}

extension KeychainManager: ClaudeSessionKeyStoring {}

extension ClaudeSessionKeyStoring {
    func save(_ sessionKey: String, preferredOrganizationID: String?) throws {
        try save(sessionKey)
    }

    func save(_ sessionKey: String, preferredOrganizationID: String?, displayName: String?) throws {
        try save(sessionKey, preferredOrganizationID: preferredOrganizationID)
    }

    func save(
        _ sessionKey: String,
        preferredOrganizationID: String?,
        displayName: String?,
        source: ClaudeAccountSource?,
        sourceDetail: String?
    ) throws {
        try save(sessionKey, preferredOrganizationID: preferredOrganizationID, displayName: displayName)
    }
}

protocol ClaudeSettingsApplyingService: Sendable {
    func updatePreferredOrganizationID(_ id: String) async
    func updateSessionKey(_ key: String) async
    func clearSession() async
    func validateCurrentSessionUsage() async throws -> ClaudeUsageResponse
    func fetchUsageHealthSnapshot() async -> ClaudeAPIService.UsageHealthSnapshot
    func fetchCachedProfileMetadata() async -> ClaudeProfileMetadata?
}

extension ClaudeAPIService: ClaudeSettingsApplyingService {}

struct ClaudeSettingsApplyResult {
    let snapshot: ClaudeAPIService.UsageHealthSnapshot
    let shouldStartMonitoring: Bool
    let shouldMarkSetupComplete: Bool
}

enum ClaudeSettingsApplyCoordinator {
    static func syncStoredCredential(
        apiService: any ClaudeSettingsApplyingService,
        preferredOrganizationID: String,
        providerEnabled: Bool,
        keychain: any ClaudeSessionKeyStoring = KeychainManager.shared
    ) async -> ClaudeSettingsApplyResult {
        await apiService.updatePreferredOrganizationID(preferredOrganizationID)

        if let key = keychain.load(), !key.isEmpty {
            await apiService.updateSessionKey(key)
        } else {
            await apiService.clearSession()
        }

        let snapshot = await apiService.fetchUsageHealthSnapshot()
        let cachedMetadata = await apiService.fetchCachedProfileMetadata()
        return ClaudeSettingsApplyResult(
            snapshot: snapshot,
            shouldStartMonitoring: providerEnabled && snapshot.runtime.credentialAvailability.hasAnyCredential,
            shouldMarkSetupComplete: SetupCompletionPolicy.shouldMarkSetupComplete(
                hasSuccessfulFetch: snapshot.lastOverallSuccessAt != nil,
                preferredOrganizationID: preferredOrganizationID,
                cachedMetadata: cachedMetadata
            )
        )
    }

    static func activateSessionKey(
        _ key: String,
        apiService: any ClaudeSettingsApplyingService,
        preferredOrganizationID: String,
        providerEnabled: Bool,
        displayName: String? = nil,
        source: ClaudeAccountSource? = .embeddedWebLogin,
        sourceDetail: String? = nil,
        keychain: any ClaudeSessionKeyStoring = KeychainManager.shared
    ) async throws -> ClaudeSettingsApplyResult {
        let previousKey = keychain.load()
        await apiService.updatePreferredOrganizationID(preferredOrganizationID)
        await apiService.updateSessionKey(key)

        do {
            _ = try await apiService.validateCurrentSessionUsage()
        } catch {
            await restorePreviousSessionKey(previousKey, apiService: apiService)
            throw error
        }

        do {
            try keychain.save(
                key,
                preferredOrganizationID: preferredOrganizationID,
                displayName: displayName,
                source: source,
                sourceDetail: sourceDetail
            )
        } catch {
            await restorePreviousSessionKey(previousKey, apiService: apiService)
            throw error
        }

        let snapshot = await apiService.fetchUsageHealthSnapshot()
        let cachedMetadata = await apiService.fetchCachedProfileMetadata()
        return ClaudeSettingsApplyResult(
            snapshot: snapshot,
            shouldStartMonitoring: providerEnabled && snapshot.runtime.credentialAvailability.hasAnyCredential,
            shouldMarkSetupComplete: SetupCompletionPolicy.shouldMarkSetupComplete(
                hasSuccessfulFetch: snapshot.lastOverallSuccessAt != nil,
                preferredOrganizationID: preferredOrganizationID,
                cachedMetadata: cachedMetadata
            )
        )
    }

    static func deleteBrowserSession(
        apiService: any ClaudeSettingsApplyingService,
        preferredOrganizationID: String,
        providerEnabled: Bool,
        keychain: any ClaudeSessionKeyStoring = KeychainManager.shared
    ) async -> ClaudeSettingsApplyResult {
        try? keychain.delete()
        await apiService.updatePreferredOrganizationID(preferredOrganizationID)
        await apiService.clearSession()

        let snapshot = await apiService.fetchUsageHealthSnapshot()
        return ClaudeSettingsApplyResult(
            snapshot: snapshot,
            shouldStartMonitoring: providerEnabled && snapshot.runtime.credentialAvailability.oauthCredentialAvailable,
            shouldMarkSetupComplete: false
        )
    }

    private static func restorePreviousSessionKey(
        _ previousKey: String?,
        apiService: any ClaudeSettingsApplyingService
    ) async {
        if let previousKey, !previousKey.isEmpty {
            await apiService.updateSessionKey(previousKey)
        } else {
            await apiService.clearSession()
        }
    }
}
