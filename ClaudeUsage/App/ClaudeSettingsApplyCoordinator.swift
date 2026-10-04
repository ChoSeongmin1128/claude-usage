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

nonisolated protocol ClaudeSettingsApplyingService: Sendable {
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

    static func activateSessionKey(
        _ key: String,
        apiService: any ClaudeSettingsApplyingService,
        preferredOrganizationID: String,
        displayName: String? = nil,
        source: ClaudeAccountSource? = .embeddedWebLogin,
        sourceDetail: String? = nil,
        keychain: any ClaudeSessionKeyStoring = KeychainManager.shared,
        makeValidator: @Sendable (String) -> any ClaudeSettingsApplyingService = { ClaudeAPIService(sessionKey: $0) },
        refreshRequester: @escaping @Sendable () -> Void = {
            NotificationCenter.default.post(name: .claudeCredentialRefreshRequested, object: nil)
        }
    ) async throws {
        // 새 키는 따로 만든 서비스로 검증한다. 공용 서비스에 먼저 넣으면 검증하는 동안 예약된 조회가
        // 새 키의 결과를 지금 계정의 것으로 기록한다.
        let validator = makeValidator(key)
        await validator.updatePreferredOrganizationID(preferredOrganizationID)
        _ = try await validator.validateCurrentSessionUsage()

        let resolvedOrganization = await validator.resolvedSessionOrganizationForLastValidation()
        let normalizedPreferredOrganizationID = normalizeOrganizationID(preferredOrganizationID)
        let identity = resolvedOrganization.map {
            ClaudeAccountIdentity(
                organizationName: $0.name,
                organizationID: $0.id
            )
        }

        try keychain.save(
            key,
            // 자동으로 선택된 organization은 identity로만 기록한다. 강제
            // preference는 사용자가 직접 선택한 경우에만 저장해야 이후 더
            // 적합한 조직 계정이 발견됐을 때 자동 선택이 다시 평가된다.
            preferredOrganizationID: normalizedPreferredOrganizationID,
            displayName: displayName,
            identity: identity,
            source: source,
            sourceDetail: sourceDetail
        )
        await apiService.updateSessionKey(key)

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

}
