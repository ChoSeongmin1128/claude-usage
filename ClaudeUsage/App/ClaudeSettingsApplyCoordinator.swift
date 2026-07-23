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
        identity: ClaudeAccountIdentity?,
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
        try save(
            sessionKey,
            preferredOrganizationID: preferredOrganizationID,
            displayName: displayName,
            identity: nil,
            source: source,
            sourceDetail: sourceDetail
        )
    }
}

protocol ClaudeSettingsApplyingService: Sendable {
    func updatePreferredOrganizationID(_ id: String) async
    func updateSessionKey(_ key: String) async
    func clearSession() async
    func validateCurrentSessionUsage() async throws -> ClaudeUsageResponse
    func resolvedSessionOrganizationForLastValidation() async -> ClaudeAPIService.OrganizationSummary?
    func fetchUsageHealthSnapshot() async -> ClaudeAPIService.UsageHealthSnapshot
    func fetchCachedProfileMetadata() async -> ClaudeProfileMetadata?
}

extension ClaudeAPIService: ClaudeSettingsApplyingService {}

extension ClaudeSettingsApplyingService {
    func resolvedSessionOrganizationForLastValidation() async -> ClaudeAPIService.OrganizationSummary? {
        nil
    }
}

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
        // 선호 organization 은 ClaudeAccountStore 가 단일 진실의 출처이고, store
        // 변경 알림(.claudeAccountsDidChange) + 뒤따르는 reloadActiveAccount() 호출이
        // service in-memory 캐시를 자동으로 동기화한다. 여기서 service 에 별도로
        // 알릴 필요는 없다.
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
        displayName: String? = nil,
        source: ClaudeAccountSource? = .embeddedWebLogin,
        sourceDetail: String? = nil,
        keychain: any ClaudeSessionKeyStoring = KeychainManager.shared,
        refreshRequester: @escaping @Sendable () -> Void = {
            NotificationCenter.default.post(name: .claudeCredentialRefreshRequested, object: nil)
        }
    ) async throws {
        let previousKey = keychain.load()
        // 검증 fetch 가 어느 organization 으로 향할지 강제하기 위한 일회성
        // in-memory 설정. 영구 저장은 keychain.save(... preferredOrganizationID:)
        // 및 ClaudeAccountStore 가 담당한다.
        await apiService.updatePreferredOrganizationID(preferredOrganizationID)
        await apiService.updateSessionKey(key)

        do {
            _ = try await apiService.validateCurrentSessionUsage()
        } catch {
            await restorePreviousSessionKey(previousKey, apiService: apiService)
            throw error
        }

        let resolvedOrganization = await apiService.resolvedSessionOrganizationForLastValidation()
        let normalizedPreferredOrganizationID = normalizeOrganizationID(preferredOrganizationID)
        let resolvedPreferredOrganizationID = normalizedPreferredOrganizationID.isEmpty
            ? (resolvedOrganization?.id ?? normalizedPreferredOrganizationID)
            : normalizedPreferredOrganizationID
        let identity = resolvedOrganization.map {
            ClaudeAccountIdentity(
                organizationName: $0.name,
                organizationID: $0.id
            )
        }

        do {
            try keychain.save(
                key,
                preferredOrganizationID: resolvedPreferredOrganizationID,
                displayName: displayName,
                identity: identity,
                source: source,
                sourceDetail: sourceDetail
            )
        } catch {
            await restorePreviousSessionKey(previousKey, apiService: apiService)
            throw error
        }

        refreshRequester()
    }

    static func deleteBrowserSession(
        apiService: any ClaudeSettingsApplyingService,
        preferredOrganizationID: String,
        providerEnabled: Bool,
        keychain: any ClaudeSessionKeyStoring = KeychainManager.shared
    ) async -> ClaudeSettingsApplyResult {
        try? keychain.delete()
        // preferredOrganizationID 는 store 에서 이미 갱신됐다고 가정한다.
        // clearSession() 이 in-memory 캐시(cachedOrganizationID, sessionKey 등)를 비우고,
        // store 알림을 통해 활성 계정 변경/조직 변경이 반영된다.
        await apiService.clearSession()

        let snapshot = await apiService.fetchUsageHealthSnapshot()
        return ClaudeSettingsApplyResult(
            snapshot: snapshot,
            shouldStartMonitoring: providerEnabled && snapshot.runtime.credentialAvailability.oauthCredentialAvailable,
            shouldMarkSetupComplete: false
        )
    }

    private static func normalizeOrganizationID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
