import Foundation

struct ClaudeSettingsApplyResult {
    let snapshot: ClaudeAPIService.UsageHealthSnapshot
    let shouldStartMonitoring: Bool
    let shouldMarkSetupComplete: Bool
}

enum ClaudeSettingsApplyCoordinator {
    static func syncStoredCredential(
        apiService: ClaudeAPIService,
        preferredOrganizationID: String,
        providerEnabled: Bool
    ) async -> ClaudeSettingsApplyResult {
        await apiService.updatePreferredOrganizationID(preferredOrganizationID)
        let credentialAvailability = await apiService.fetchCredentialAvailability()

        if credentialAvailability.sessionCredentialAvailable,
           let key = KeychainManager.shared.load(),
           !key.isEmpty {
            await apiService.updateSessionKey(key)
        } else {
            await apiService.clearSession()
        }

        let snapshot = await apiService.fetchUsageHealthSnapshot()
        return ClaudeSettingsApplyResult(
            snapshot: snapshot,
            shouldStartMonitoring: providerEnabled && snapshot.runtime.credentialAvailability.hasAnyCredential,
            shouldMarkSetupComplete: snapshot.runtime.credentialAvailability.hasAnyCredential
        )
    }

    static func activateSessionKey(
        _ key: String,
        apiService: ClaudeAPIService,
        preferredOrganizationID: String,
        providerEnabled: Bool
    ) async throws -> ClaudeSettingsApplyResult {
        try KeychainManager.shared.save(key)
        await apiService.updatePreferredOrganizationID(preferredOrganizationID)
        await apiService.updateSessionKey(key)

        let snapshot = await apiService.fetchUsageHealthSnapshot()
        return ClaudeSettingsApplyResult(
            snapshot: snapshot,
            shouldStartMonitoring: providerEnabled && snapshot.runtime.credentialAvailability.hasAnyCredential,
            shouldMarkSetupComplete: snapshot.runtime.credentialAvailability.hasAnyCredential
        )
    }

    static func logout(
        apiService: ClaudeAPIService,
        preferredOrganizationID: String,
        providerEnabled: Bool
    ) async -> ClaudeSettingsApplyResult {
        try? KeychainManager.shared.delete()
        await apiService.updatePreferredOrganizationID(preferredOrganizationID)
        await apiService.clearSession()

        let snapshot = await apiService.fetchUsageHealthSnapshot()
        return ClaudeSettingsApplyResult(
            snapshot: snapshot,
            shouldStartMonitoring: false,
            shouldMarkSetupComplete: providerEnabled && snapshot.runtime.credentialAvailability.hasAnyCredential
        )
    }
}
