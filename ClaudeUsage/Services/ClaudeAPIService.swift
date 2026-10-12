//
//  ClaudeAPIService.swift
//  ClaudeUsage
//
//  Phase 1+3: Claude.ai API 호출 서비스 (Keychain 연동)
//

import Foundation
import CryptoKit

/// Claude.ai API 서비스 (Thread-Safe Actor)
actor ClaudeAPIService {
    typealias HTTPRunner = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    /// UserDefaults operations are thread-safe; cache state transitions remain actor-isolated.
    nonisolated struct CacheStorage: @unchecked Sendable {
        private let defaults: UserDefaults
        private let profileMetadataDirectory: URL

        init(
            defaults: UserDefaults = .standard,
            profileMetadataDirectory: URL = ClaudeAccountLocalData.defaultDirectory()
        ) {
            self.defaults = defaults
            self.profileMetadataDirectory = profileMetadataDirectory
        }

        func profileMetadataStore(for accountID: String?) -> ClaudeProfileMetadataStore {
            ClaudeProfileMetadataStore(accountID: accountID, rootDirectory: profileMetadataDirectory)
        }

        func data(forKey key: String) -> Data? {
            defaults.data(forKey: key)
        }

        func set(_ data: Data, forKey key: String) {
            defaults.set(data, forKey: key)
        }

        func removeObject(forKey key: String) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Properties

    private var sessionKey: String?
    private let accountStore: ClaudeAccountStore
    private let cacheStorage: CacheStorage
    private let transport: ClaudeHTTPTransport
    private let organizationCache: ClaudeOrganizationListCache
    private var sessionContextRevision = 0
    private var oauthCredentialFingerprint: String?
    private var oauthReadRevision = 0
    private var appliedOAuthReadRevision = 0
    private var pendingOAuthIdentityGeneration: Int?
    private var runtimeOAuthIdentity: (identity: UsageAccountIdentity, generation: Int)?
    private let usesStoredActiveAccount: Bool
    private var activeAccount: ClaudeAccount?
    private let baseURL = ClaudeEndpoints.webAPIBase
    private var cachedOrganizationID: String?
    private var preferredOrganizationID: String?
    private var sessionCooldown = ClaudeSessionPathCooldown()
    /// OAuth 경로 보호: 토큰별 rate limit 예산이 작아서 (과거 429 → 2500초 대기 관측)
    /// 성공 결과를 짧게 캐시하고, 429 는 Retry-After 만큼 경로 쿨다운한다.
    private var oauthPathCooldownUntil: Date?
    private var lastOAuthSuccess: (usage: ClaudeUsageResponse, at: Date)?
    private var claudeCodeCredentialGeneration = 0
    private static let minimumOAuthCallInterval: TimeInterval = 300
    private let sourcePlanner = ClaudeSourcePlanner()
    private let messagesHeaderFallbackFetcher = ClaudeMessagesHeaderFallbackFetcher()
    private var profileMetadataStore: ClaudeProfileMetadataStore
    private let oauthProfileMetadataStore: ClaudeProfileMetadataStore
    private let oauthCredentialReader: any ClaudeOAuthCredentialReading
    private let sessionKeyLoader: @Sendable (String) -> String?
    private var health: ClaudeAuthPathHealthRecorder
    private var lastKnownUsagePercent: Double?
    private var lastSuccessfulUsageSource: ClaudeUsageSource?
    private var lastFetchMetadata: RuntimeProviderFetchMetadata?
    private var lastResolvedSessionOrganization: OrganizationSummary?
    private let accountStoreObserver = ClaudeAccountStoreNotificationObserver()

    // MARK: - Init

    /// Keychain에서 자동으로 세션 키를 로드하는 기본 생성자
    init(
        cacheStorage: CacheStorage = .init(),
        httpRunner: @escaping HTTPRunner = { try await URLSession.shared.data(for: $0) }
    ) {
        self.cacheStorage = cacheStorage
        self.transport = ClaudeHTTPTransport(runner: httpRunner, timeout: ClaudeEndpoints.requestTimeout)
        self.organizationCache = ClaudeOrganizationListCache(cacheStorage: cacheStorage)
        self.accountStore = ClaudeAccountStore.shared
        self.usesStoredActiveAccount = true
        self.accountStore.ensureLegacyMigrationIfNeeded()
        let activeAccount = self.accountStore.activeAccount()
        let oauthProfileMetadataStore = cacheStorage.profileMetadataStore(
            for: ClaudeAccountStore.claudeCodeExternalAccountID)
        self.profileMetadataStore = Self.profileMetadataStore(
            for: activeAccount?.id, cacheStorage: cacheStorage, sharing: oauthProfileMetadataStore)
        self.oauthProfileMetadataStore = oauthProfileMetadataStore
        self.oauthCredentialReader = ClaudeCodeCredentialReader(profileMetadataStore: oauthProfileMetadataStore)
        let sessionKeyLoader: @Sendable (String) -> String? = { KeychainManager.shared.load(for: $0) }
        self.sessionKeyLoader = sessionKeyLoader
        self.activeAccount = activeAccount
        self.health = ClaudeAuthPathHealthRecorder(accountID: activeAccount?.id, cacheStorage: cacheStorage)
        // Actor initializers run synchronously on the caller's executor.
        // App startup constructs this service from the main actor, so a
        // Keychain-backed session load here can stall the UI. Every public
        // fetch path calls reloadActiveAccount() on the actor before using
        // credentials; defer the load to that isolated method.
        self.sessionKey = nil
        self.preferredOrganizationID = activeAccount?.kind == .webSession
            ? Self.normalizeOrganizationID(activeAccount?.userSelectedPreferredOrganizationID)
            : nil
        // ClaudeAccountStore 변경(계정 전환, 조직 선택 변경 등)을 받아 in-memory
        // 캐시를 자동 무효화한다. UI/Coordinator 가 store 만 갱신해도 다음 fetch 가
        // 곧바로 새 선택을 반영하도록 만드는 게 목적.
        accountStoreObserver.start { [weak self] in
            guard let self else { return }
            Task { [weak self] in
                await self?.reloadActiveAccount()
            }
        }
    }

    /// 특정 세션 키로 초기화 (연결 테스트용)
    init(
        sessionKey: String, cacheStorage: CacheStorage = .init(),
        httpRunner: @escaping HTTPRunner = { try await URLSession.shared.data(for: $0) }
    ) {
        self.cacheStorage = cacheStorage
        self.transport = ClaudeHTTPTransport(runner: httpRunner, timeout: ClaudeEndpoints.requestTimeout)
        self.organizationCache = ClaudeOrganizationListCache(cacheStorage: cacheStorage)
        self.accountStore = ClaudeAccountStore.shared
        self.usesStoredActiveAccount = false
        let profileMetadataStore = cacheStorage.profileMetadataStore(for: nil)
        let oauthProfileMetadataStore = cacheStorage.profileMetadataStore(
            for: ClaudeAccountStore.claudeCodeExternalAccountID)
        self.profileMetadataStore = profileMetadataStore
        self.oauthProfileMetadataStore = oauthProfileMetadataStore
        self.oauthCredentialReader = ClaudeCodeCredentialReader(profileMetadataStore: nil)
        self.sessionKeyLoader = { _ in nil }
        self.sessionKey = sessionKey
        self.activeAccount = nil
        self.health = ClaudeAuthPathHealthRecorder(accountID: nil, cacheStorage: cacheStorage)
    }

    /// Tests and orchestration checks can inject an OAuth reader without touching the real Keychain.
    init(
        accountStore: ClaudeAccountStore,
        oauthCredentialReader: any ClaudeOAuthCredentialReading,
        sessionKeyLoader: @escaping @Sendable (String) -> String?,
        cacheStorage: CacheStorage = .init(),
        httpRunner: @escaping HTTPRunner = { try await URLSession.shared.data(for: $0) }
    ) {
        self.cacheStorage = cacheStorage
        self.transport = ClaudeHTTPTransport(runner: httpRunner, timeout: ClaudeEndpoints.requestTimeout)
        self.organizationCache = ClaudeOrganizationListCache(cacheStorage: cacheStorage)
        self.accountStore = accountStore
        self.usesStoredActiveAccount = true
        self.accountStore.ensureLegacyMigrationIfNeeded()
        let activeAccount = self.accountStore.activeAccount()
        let oauthProfileMetadataStore = cacheStorage.profileMetadataStore(
            for: ClaudeAccountStore.claudeCodeExternalAccountID)
        self.profileMetadataStore = Self.profileMetadataStore(
            for: activeAccount?.id, cacheStorage: cacheStorage, sharing: oauthProfileMetadataStore)
        self.oauthProfileMetadataStore = oauthProfileMetadataStore
        self.oauthCredentialReader = oauthCredentialReader
        self.sessionKeyLoader = sessionKeyLoader
        self.activeAccount = activeAccount
        self.health = ClaudeAuthPathHealthRecorder(accountID: activeAccount?.id, cacheStorage: cacheStorage)
        self.sessionKey = nil
        self.preferredOrganizationID = activeAccount?.kind == .webSession
            ? Self.normalizeOrganizationID(activeAccount?.userSelectedPreferredOrganizationID)
            : nil
        accountStoreObserver.start { [weak self] in
            guard let self else { return }
            Task { [weak self] in
                await self?.reloadActiveAccount()
            }
        }
    }

    /// 같은 파일을 쓰는 메타데이터 저장소를 둘 만들면 서로의 갱신을 덮는다. Claude Code 계정은 OAuth 쪽 저장소를 함께 쓴다.
    private static func profileMetadataStore(
        for accountID: String?, cacheStorage: CacheStorage, sharing oauthStore: ClaudeProfileMetadataStore
    ) -> ClaudeProfileMetadataStore {
        accountID == ClaudeAccountStore.claudeCodeExternalAccountID
            ? oauthStore : cacheStorage.profileMetadataStore(for: accountID)
    }

    func reloadActiveAccount() {
        guard usesStoredActiveAccount else { return }
        accountStore.ensureLegacyMigrationIfNeeded()
        let nextAccount = accountStore.activeAccount()
        guard nextAccount?.id != activeAccount?.id else {
            // 같은 계정 안에서 organization 선택만 바뀐 경우에도 in-memory 캐시를
            // 함께 무효화해야 다음 사용량 조회가 새 organization 으로 나간다.
            let previousPreferredOrganizationID = preferredOrganizationID
            let previousSessionKey = sessionKey
            if nextAccount?.kind == .webSession {
                sessionKey = nextAccount.flatMap { sessionKeyLoader($0.id) }
                preferredOrganizationID = Self.normalizeOrganizationID(
                    nextAccount?.userSelectedPreferredOrganizationID
                )
            } else {
                sessionKey = nil
                preferredOrganizationID = nil
            }
            if previousPreferredOrganizationID != preferredOrganizationID || previousSessionKey != sessionKey {
                sessionContextRevision &+= 1
                cachedOrganizationID = nil
                lastResolvedSessionOrganization = nil
            }
            activeAccount = nextAccount
            return
        }

        sessionContextRevision &+= 1
        activeAccount = nextAccount
        profileMetadataStore = Self.profileMetadataStore(
            for: nextAccount?.id, cacheStorage: cacheStorage, sharing: oauthProfileMetadataStore)
        health = ClaudeAuthPathHealthRecorder(accountID: nextAccount?.id, cacheStorage: cacheStorage)
        cachedOrganizationID = nil
        lastResolvedSessionOrganization = nil
        lastKnownUsagePercent = nil
        lastSuccessfulUsageSource = nil
        sessionCooldown.reset()
        // 계정이 바뀌면 OAuth 캐시/쿨다운도 무효 (토큰이 계정별이므로)
        oauthPathCooldownUntil = nil
        lastOAuthSuccess = nil

        if nextAccount?.kind == .webSession {
            sessionKey = nextAccount.flatMap { sessionKeyLoader($0.id) }
            preferredOrganizationID = Self.normalizeOrganizationID(
                nextAccount?.userSelectedPreferredOrganizationID
            )
        } else {
            sessionKey = nil
            preferredOrganizationID = nil
        }
    }

    func currentClaudeCodeCredentialGeneration() -> Int {
        claudeCodeCredentialGeneration
    }

    func currentRuntimeUsageAccountIdentity() -> UsageAccountIdentity? {
        guard activeAccount?.kind == .claudeCodeExternal,
            pendingOAuthIdentityGeneration == nil,
            let observed = runtimeOAuthIdentity, observed.generation == claudeCodeCredentialGeneration
        else { return nil }
        return observed.identity
    }

    func currentSessionContextRevision() -> Int {
        reloadActiveAccount()
        return sessionContextRevision
    }

    func currentActiveAccountID() -> String? {
        reloadActiveAccount()
        return activeAccount?.id
    }

    // MARK: - Session Key Management

    /// 세션 키 업데이트 (Keychain 저장 후 호출)
    func updateSessionKey(_ key: String) {
        let previousFingerprint = currentSessionFingerprint()
        if self.sessionKey != key { sessionContextRevision &+= 1 }
        self.sessionKey = key
        self.cachedOrganizationID = nil  // 캐시 초기화
        self.lastResolvedSessionOrganization = nil
        self.sessionCooldown.reset()
        if previousFingerprint != currentSessionFingerprint() {
            self.clearCachedOrganizations()
        }
    }

    /// 런타임 브라우저 sessionKey 상태 초기화
    func clearSession() {
        sessionContextRevision &+= 1
        self.sessionKey = nil
        self.cachedOrganizationID = nil
        self.lastResolvedSessionOrganization = nil
        self.sessionCooldown.reset()
        self.clearCachedOrganizations()
    }

    /// In-memory 임시 선호 organization 설정. 영구 저장은 하지 않는다.
    /// - 사용 시점: 새 sessionKey 검증, ad-hoc `ClaudeAPIService(sessionKey:)` 인스턴스,
    ///   서비스가 곧 한 번 호출할 fetch 의 대상 organization 을 일회성으로 강제할 때.
    /// - 영구 저장은 `ClaudeAccountStore.updatePreferredOrganizationID(_:for:)` 로 하고,
    ///   그 변경은 `.claudeAccountsDidChange` 알림을 통해 이 서비스 인스턴스에 반영된다.
    func updatePreferredOrganizationID(_ id: String) {
        let normalized = Self.normalizeOrganizationID(id)
        if preferredOrganizationID == normalized {
            return
        }
        sessionContextRevision &+= 1
        preferredOrganizationID = normalized
        cachedOrganizationID = nil
        lastResolvedSessionOrganization = nil
        Logger.info("선호 Organization ID 임시 업데이트: \(normalized ?? "자동 선택")")
    }

    /// 세션 키가 설정되어 있는지 확인
    func hasSessionKey() -> Bool {
        guard let key = sessionKey else { return false }
        return !key.isEmpty
    }

    func fetchUsageHealthSnapshot() async -> UsageHealthSnapshot {
        await fetchUsageHealthSnapshot(refreshOAuthCredentialInventory: false)
    }

    func fetchUsageHealthSnapshot(refreshOAuthCredentialInventory: Bool) async -> UsageHealthSnapshot {
        reloadActiveAccount()
        let initialState = usesStoredActiveAccount
            ? accountStore.state()
            : ClaudeAccountState(accounts: [], activeAccountID: nil)
        let activeKind = usesStoredActiveAccount ? activeAccount?.kind : .webSession
        // 웹 계정이 메뉴바에 있으면 inactive CLI의 저장된 유무만 본다.
        // inventory reader도 만료 토큰을 갱신할 수 있어 명시 refresh 요청이어도 읽지 않는다.
        let shouldReadOAuthCredential =
            usesStoredActiveAccount && activeKind != .webSession
            && (refreshOAuthCredentialInventory || activeKind == .claudeCodeExternal || activeKind == nil)
        let oauthCredentialAvailable: Bool
        var credentialIssue: ClaudeCodeCredentialIssue?
        if shouldReadOAuthCredential {
            if refreshOAuthCredentialInventory,
                let inventoryRefresh = try? await refreshSystemOAuthCredentialInventory()
            {
                oauthCredentialAvailable = inventoryRefresh.accessToken != nil
            } else {
                do {
                    oauthCredentialAvailable = try await readSystemOAuthAccessToken() != nil
                } catch APIError.claudeCodeReconnectRequired {
                    oauthCredentialAvailable = false
                    credentialIssue = .reconnectRequired
                } catch APIError.claudeCodeReauthenticationRequired {
                    oauthCredentialAvailable = false
                    credentialIssue = .reauthenticationRequired
                } catch APIError.claudeCodeExecutableNotFound {
                    oauthCredentialAvailable = false
                    credentialIssue = .executableNotFound
                } catch {
                    oauthCredentialAvailable = false
                }
            }
        } else {
            oauthCredentialAvailable = Self.hasStoredOAuthCredentialInventory(initialState)
        }
        if shouldReadOAuthCredential, oauthCredentialAvailable {
            _ = accountStore.upsertClaudeCodeExternalAccount(
                identity: await claudeCodeAccountIdentity(),
                validationState: stableClaudeCodeValidationState(credentialAvailable: true),
                setActiveIfMissing: true
            )
            reloadActiveAccount()
        }
        let state = usesStoredActiveAccount
            ? accountStore.state()
            : ClaudeAccountState(accounts: [], activeAccountID: nil)
        return UsageHealthSnapshot(
            lastOverallSuccessAt: health.lastOverallSuccessAt,
            session: health.snapshot(.session),
            oauth: health.snapshot(.oauth),
            runtime: makeRuntimeAuthSnapshot(
                oauthCredentialAvailable: oauthCredentialAvailable,
                credentialIssue: credentialIssue
            ),
            accounts: state.accounts,
            activeAccountID: state.activeAccountID
        )
    }

    func fetchCachedProfileMetadata() async -> ClaudeProfileMetadata? {
        await profileMetadataStore.load()
    }

    /// 로그인 윈도우 카드 미리보기 등 가벼운 UI 결정 용도.
    /// 외부 Claude Code Keychain을 조회하지 않고 저장된 inventory만 사용한다.
    func hasStoredClaudeCodeCredentialInventory() -> Bool {
        guard usesStoredActiveAccount else { return false }
        return Self.hasStoredOAuthCredentialInventory(accountStore.state())
    }

    func invalidateClaudeCodeCredentialCache() async {
        await oauthCredentialReader.invalidateCache()
    }

    /// 사용자 본인이 Claude Code 연결을 선택한 경우에만 CLI 소유 Keychain
    /// credential을 한 번 읽어 앱 vault에 저장한다.
    func drainCredentialRecovery() async { await oauthCredentialReader.drainRecovery() }

    func importClaudeCodeCredentialForActivation() async throws {
        try Task.checkCancellation()
        switch await oauthCredentialReader.importActiveCLICredential() {
        case .available:
            try Task.checkCancellation()
            return
        case .imported:
            try Task.checkCancellation()
            // 명시적 가져오기는 vault가 비어 있어 이전 token과 비교할 수 없는
            // 경우에도 다른 CLI 계정일 수 있다. 과거 identity/profile/usage
            // 캐시를 항상 비워 새 credential의 응답으로 다시 채운다.
            let previousGeneration = claudeCodeCredentialGeneration
            _ = try? await readSystemOAuthAccessToken()
            try Task.checkCancellation()
            if previousGeneration == claudeCodeCredentialGeneration { invalidateClaudeCodeRequestGeneration() }
            await clearClaudeCodeIdentityState()
            try Task.checkCancellation()
        case .notFound:
            throw APIError.claudeCodeCredentialUnavailable
        case .cancelled:
            throw ClaudeOAuthCredentialImportError.cancelled
        case .failed(let message):
            throw ClaudeOAuthCredentialImportError.failed(message)
        }
    }

    private func invalidateClaudeCodeRequestGeneration() {
        claudeCodeCredentialGeneration &+= 1
        oauthPathCooldownUntil = nil
        lastOAuthSuccess = nil
        pendingOAuthIdentityGeneration = claudeCodeCredentialGeneration
        // Retain the last verified owner only for comparison; pending/generation guards prevent publication.
    }

    private func clearClaudeCodeIdentityState(resetHealth: Bool = true) async {
        let claudeCodeAccountID = ClaudeAccountStore.claudeCodeExternalAccountID
        runtimeOAuthIdentity = nil
        if resetHealth {
            lastKnownUsagePercent = nil
            lastSuccessfulUsageSource = nil
            lastFetchMetadata = nil
            ClaudeAuthPathHealthRecorder.removeHistory(for: claudeCodeAccountID, cacheStorage: cacheStorage)
            if activeAccount?.id == claudeCodeAccountID { health.reset() }
            accountStore.updateValidationState(.detected, for: claudeCodeAccountID)
        }
        accountStore.replaceIdentity(ClaudeAccountIdentity(), for: claudeCodeAccountID)
        await oauthProfileMetadataStore.clear()
        activeAccount = accountStore.activeAccount()
    }

    /// CLI external account 가 store 에 있다면 그 cached profile metadata 를 반환.
    /// 로그인 윈도우 미리보기에서 organizationUUID / planLabel 표시에 사용.
    func fetchCachedClaudeCodeProfileMetadata() async -> ClaudeProfileMetadata? {
        await oauthProfileMetadataStore.load()
    }

    /// OAuth 자격으로 `/api/oauth/profile` 호출. 사용량 호출과 같은 401 retry 정책을 공유한다.
    func fetchOAuthProfile() async throws -> ClaudeOAuthProfileResponse {
        try await fetchOAuthProfileOutcome().profile
    }

    private func fetchOAuthProfileOutcome() async throws -> (profile: ClaudeOAuthProfileResponse, generation: Int) {
        guard let accessToken = try await readSystemOAuthAccessToken() else {
            throw APIError.unknownError("Claude Code OAuth 토큰을 찾을 수 없습니다")
        }
        return try await performOAuthProfileRequest(accessToken: accessToken, allowRefreshRetry: true)
    }

    private func performOAuthProfileRequest(
        accessToken: String,
        allowRefreshRetry: Bool
    ) async throws -> (profile: ClaudeOAuthProfileResponse, generation: Int) {
        let generation = claudeCodeCredentialGeneration
        var request = URLRequest(url: ClaudeEndpoints.oauthProfileURL)
        request.httpMethod = "GET"
        ClaudeEndpoints.applyOAuthHeaders(to: &request, accessToken: accessToken)

        let (data, response) = try await transport.send(request)
        try validateOAuthCredential(accessToken: accessToken, generation: generation)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.unknownError("Invalid OAuth profile HTTP response")
        }
        if !(200...299).contains(http.statusCode) {
            // fetchUsageViaOAuth 와 동일 정책: 401 시 1회 refresh + retry
            if http.statusCode == 401, allowRefreshRetry,
               let newToken = try await forceRefreshSystemOAuthAccessToken(),
               newToken != accessToken
            {
                return try await performOAuthProfileRequest(accessToken: newToken, allowRefreshRetry: false)
            }
            throw ClaudeHTTPTransport.classify(statusCode: http.statusCode, data: data, response: http)
        }
        do {
            return (try JSONDecoder().decode(ClaudeOAuthProfileResponse.self, from: data), generation)
        } catch {
            throw APIError.parseError
        }
    }

    /// OAuth profile 응답을 가져와 CLI external account 의 identity 와 profile metadata 를 동기화한다.
    /// 실패해도 silent return — 사용자가 사용량 자체는 계속 볼 수 있어야 하기 때문.
    /// 호출 시점: CLI 활성화 직후, 또는 사용량 OAuth 성공 후 identity 가 비어 있는 경우.
    func refreshClaudeCodeAccountProfile() async {
        guard let outcome = try? await fetchOAuthProfileOutcome() else { return }
        try? await applyOAuthProfile(outcome.profile, generation: outcome.generation)
    }

    private func synchronizeOAuthIdentityIfNeeded(accessToken: String) async throws {
        let generation = claudeCodeCredentialGeneration
        guard pendingOAuthIdentityGeneration == generation else { return }
        do {
            let outcome = try await performOAuthProfileRequest(accessToken: accessToken, allowRefreshRetry: false)
            try await applyOAuthProfile(outcome.profile, generation: outcome.generation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try validateOAuthCredential(accessToken: accessToken, generation: generation)
            await clearClaudeCodeIdentityState()
            try validateOAuthCredential(accessToken: accessToken, generation: generation)
            pendingOAuthIdentityGeneration = nil
        }
    }

    private func applyOAuthProfile(_ profile: ClaudeOAuthProfileResponse, generation: Int) async throws {
        guard generation == claudeCodeCredentialGeneration else { throw CancellationError() }
        let identity = ClaudeAccountIdentity(
            email: profile.account?.email,
            organizationName: profile.organization?.name,
            organizationID: profile.organization?.uuid,
            planLabel: profile.organization?.organizationType ?? profile.organization?.rateLimitTier
        )
        let normalizedAccountUUID = profile.account?.uuid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountUUID = normalizedAccountUUID.flatMap { $0.isEmpty ? nil : $0 }
        guard let organizationID = identity.organizationID, accountUUID != nil || identity.email != nil else {
            if pendingOAuthIdentityGeneration == generation { await clearClaudeCodeIdentityState() }
            guard generation == claudeCodeCredentialGeneration else { throw CancellationError() }
            pendingOAuthIdentityGeneration = nil
            return
        }
        let accountID = ClaudeAccountStore.claudeCodeExternalAccountID
        let previous = accountStore.accounts().first { $0.id == accountID }?.identity
        let previousOwner = runtimeOAuthIdentity?.identity
        let isSameAccount: Bool
        if let accountUUID, let previousUUID = previousOwner?.accountID {
            isSameAccount = previousUUID == accountUUID && previousOwner?.organizationID == organizationID
        } else if let email = identity.email {
            isSameAccount =
                previous?.email?.caseInsensitiveCompare(email) == .orderedSame
                && previous?.organizationID == organizationID
        } else {
            isSameAccount = false
        }
        let displayIdentity = isSameAccount ? previous?.merging(identity) ?? identity : identity
        if !isSameAccount {
            await clearClaudeCodeIdentityState(resetHealth: pendingOAuthIdentityGeneration == generation)
            guard generation == claudeCodeCredentialGeneration else { throw CancellationError() }
            accountStore.replaceIdentity(identity, for: accountID)
        } else {
            accountStore.mergeIdentity(identity, for: accountID)
        }
        let metadata = ClaudeProfileMetadata(
            organizationUUID: organizationID,
            subscriptionType: profile.organization?.organizationType,
            rateLimitTier: profile.organization?.rateLimitTier,
            hasExtraUsageEnabled: profile.organization?.hasExtraUsageEnabled,
            billingType: profile.organization?.billingType,
            lastUpdatedAt: Date()
        )
        if isSameAccount {
            await oauthProfileMetadataStore.merge(metadata)
        } else {
            await oauthProfileMetadataStore.save(metadata)
        }
        guard generation == claudeCodeCredentialGeneration else { throw CancellationError() }
        if let accountUUID {
            runtimeOAuthIdentity = (
                UsageAccountIdentity(
                    accountID: accountUUID, organizationID: organizationID,
                    email: displayIdentity.email, organizationName: displayIdentity.organizationName), generation
            )
        } else {
            runtimeOAuthIdentity = nil
        }
        pendingOAuthIdentityGeneration = nil
    }

    private func claudeCodeAccountIdentity() async -> ClaudeAccountIdentity {
        let metadata = await oauthProfileMetadataStore.load()
        return ClaudeAccountIdentity(
            organizationID: metadata?.organizationUUID,
            planLabel: metadata?.subscriptionType ?? metadata?.rateLimitTier
        )
    }

    /// v2.3: OAuth (`/api/oauth/usage`) 경로를 정식 소스로 승격.
    /// v2.2.0 에서 비활성화했던 이유(토큰별 rate limit, refresh rotation 함정)는
    /// (1) OAuth 경로 최소 호출 간격 + 성공 캐시, (2) 429 Retry-After 쿨다운,
    /// (3) 파일 기반 자격만 회전 결과를 원본에 write-back하고 CLI Keychain
    /// 자격은 read-only mirror로 다루는 ownership-aware reader로 완화한다.
    /// 문제가 재발하면 환경변수 `CLAUDE_USAGE_ENABLE_CLAUDE_OAUTH_USAGE=0` 이 kill switch.
    nonisolated private static var claudeOAuthUsageCallsEnabled: Bool {
        ProcessInfo.processInfo.environment["CLAUDE_USAGE_ENABLE_CLAUDE_OAUTH_USAGE"] != "0"
    }

    // MARK: - Public API

    /// 브라우저 sessionKey만 검증합니다. OAuth fallback은 의도적으로 사용하지 않습니다.
    func validateCurrentSessionUsage() async throws -> ClaudeUsageResponse {
        guard let sessionKey, !sessionKey.isEmpty else {
            throw APIError.invalidSessionKey
        }
        return try await fetchUsageWithSessionKey(sessionKey)
    }

    func resolvedSessionOrganizationForLastValidation() async -> OrganizationSummary? {
        lastResolvedSessionOrganization
    }

    /// 기존 호출자를 위한 payload 전용 API. 런타임 표시는 provenance를 보존하는
    /// `fetchUsageOutcome()`을 사용해야 한다.
    func fetchUsage() async throws -> ClaudeUsageResponse {
        try await fetchUsageOutcome().usage
    }

    /// 사용량과 실제 조회 출처/계정 귀속을 함께 반환한다.
    func fetchUsageOutcome(bypassOAuthCache: Bool = false) async throws -> ClaudeUsageFetchOutcome {
        reloadActiveAccount()
        Logger.info("사용량 데이터 요청 시작")
        let initialActiveKind: ClaudeAccountKind? = {
            if usesStoredActiveAccount { return activeAccount?.kind }
            return .webSession
        }()
        let shouldReadOAuthCredential = usesStoredActiveAccount
            && (initialActiveKind == .claudeCodeExternal || initialActiveKind == nil)
        let oauthAccessToken = shouldReadOAuthCredential
            ? try await readSystemOAuthAccessToken()
            : nil
        // OAuth credential 이 발견되면 활성 계정 유무와 무관하게 CLI external account 를
        // 항상 store 에 등록한다. 등록만 하고 activeIfMissing 으로만 active 결정 →
        // 사용자가 다른 web 계정을 명시 선택한 경우 그 선택을 존중하지만,
        // 설정 UI 의 계정 목록과 health snapshot 에서 CLI 계정이 항상 보이도록 보장.
        if shouldReadOAuthCredential, oauthAccessToken != nil {
            _ = accountStore.upsertClaudeCodeExternalAccount(
                identity: await claudeCodeAccountIdentity(),
                validationState: stableClaudeCodeValidationState(credentialAvailable: true),
                setActiveIfMissing: true
            )
            reloadActiveAccount()
            if let oauthAccessToken {
                try await synchronizeOAuthIdentityIfNeeded(accessToken: oauthAccessToken)
                reloadActiveAccount()
            }
        }

        let activeKind: ClaudeAccountKind? = {
            if usesStoredActiveAccount {
                return activeAccount?.kind
            }
            return .webSession
        }()

        let requestAccountID = usesStoredActiveAccount ? activeAccount?.id : nil
        let requestClaudeCodeCredentialGeneration = claudeCodeCredentialGeneration
        let normalizedSessionKey: String? = {
            guard activeKind == .webSession else { return nil }
            guard let sessionKey, !sessionKey.isEmpty else { return nil }
            return sessionKey
        }()
        let sessionCooldownError = normalizedSessionKey != nil ? sessionCooldown.currentError() : nil
        // 시스템 Claude Code 로그인은 활성 웹 계정과 다른 사용자일 수 있다.
        // OAuth는 Claude Code 계정이 명시적으로 활성일 때만 해당 계정의 source로 노출한다.
        let oauthTokenForFetch: String? = {
            guard let token = oauthAccessToken else { return nil }
            return activeKind == .claudeCodeExternal ? token : nil
        }()
        // v2.3: OAuth 경로 정식 승격. 예산 보호(최소 호출 간격 + 429 쿨다운)는
        // fetch 루프의 .oauth 분기에서 처리한다. 환경변수 =0 이 kill switch.
        let effectiveOAuthAvailable = Self.claudeOAuthUsageCallsEnabled && oauthTokenForFetch != nil
        let context = ClaudeFetchContext(
            accountKind: activeKind,
            sourcePreference: .auto,
            webSessionAvailable: normalizedSessionKey != nil && sessionCooldownError == nil,
            oauthAvailable: effectiveOAuthAvailable,
            webSessionValidationState: health.validationState(
                .session, credentialAvailable: normalizedSessionKey != nil && sessionCooldownError == nil),
            oauthValidationState: health.validationState(.oauth, credentialAvailable: effectiveOAuthAvailable),
            recentSuccessfulSource: nil,
            currentUsagePercent: lastKnownUsagePercent,
            fallbackPolicy: await currentMessagesFallbackPolicy())
        let accountScopedOAuthToken = Self.claudeOAuthUsageCallsEnabled ? oauthTokenForFetch : nil
        let plan = sourcePlanner.makePlan(from: context)
        var sourceErrors: [ClaudeUsageSource: APIError] = [:]
        var attemptedSources: [ClaudeUsageSource] = []
        lastFetchMetadata = RuntimeProviderFetchMetadata(accountID: requestAccountID)

        if let cooldownError = sessionCooldownError {
            sourceErrors[.webSession] = cooldownError
            Logger.warning("세션키 경로 쿨다운 중(\(cooldownError.localizedDescription))")
        }

        for candidate in plan.primaryCandidates where candidate.isAvailable {
            attemptedSources.append(candidate.source)
            lastFetchMetadata = RuntimeProviderFetchMetadata(
                sourceLabel: candidate.source.displayName,
                accountID: requestAccountID,
                attemptedSourceLabels: attemptedSources.map(\.displayName))
            switch candidate.source {
            case .webSession:
                guard let sessionKey = normalizedSessionKey else {
                    sourceErrors[.webSession] = .invalidSessionKey
                    continue
                }
                do {
                    let result = try await fetchSessionUsage(sessionKey)
                    sessionCooldown.reset()
                    rememberSuccessfulUsage(result.usage, source: .webSession, accountID: requestAccountID)
                    return makeFetchOutcome(
                        usage: result.usage,
                        source: .webSession,
                        accountID: requestAccountID,
                        attemptedSources: attemptedSources,
                        webIdentity: result.identity)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let apiError as APIError {
                    sourceErrors[.webSession] = apiError
                    markAccountValidationFailedIfDefinitive(apiError, accountID: requestAccountID)
                    Logger.warning("세션키 경로 실패: \(apiError.localizedDescription)")
                } catch {
                    let apiError = APIError.unknownError(error.localizedDescription)
                    sourceErrors[.webSession] = apiError
                    Logger.warning("세션키 경로 실패: \(error.localizedDescription)")
                }

            case .oauth:
                guard let oauthAccessToken = accountScopedOAuthToken else {
                    sourceErrors[.oauth] = .unknownError("Claude Code OAuth 토큰을 찾을 수 없습니다")
                    continue
                }

                // OAuth 경로 예산 보호 1: 최소 호출 간격 안의 자동 조회는 마지막 성공 결과를 받아 온 시각과 함께 돌려준다.
                if !bypassOAuthCache, let cached = lastOAuthSuccess,
                    Self.canReuseOAuthUsage(cached.usage, fetchedAt: cached.at, now: Date())
                {
                    var outcome = makeFetchOutcome(
                        usage: cached.usage,
                        source: .oauth,
                        accountID: requestAccountID,
                        attemptedSources: attemptedSources)
                    outcome.fetchedAt = cached.at
                    return outcome
                }
                // OAuth 경로 예산 보호 2: 429 쿨다운 중이면 이번 사이클은 스킵
                if let until = oauthPathCooldownUntil {
                    let remaining = Int(ceil(until.timeIntervalSinceNow))
                    if remaining > 0 {
                        sourceErrors[.oauth] = .rateLimited(retryAfter: remaining)
                        continue
                    }
                    oauthPathCooldownUntil = nil
                }

                var oauthRequestGeneration = requestClaudeCodeCredentialGeneration
                do {
                    let result = try await fetchUsageViaOAuth(
                        accessToken: oauthAccessToken, requestGeneration: &oauthRequestGeneration)
                    guard result.generation == claudeCodeCredentialGeneration else {
                        throw CancellationError()
                    }
                    let usage = result.usage
                    lastOAuthSuccess = (usage, Date())
                    rememberSuccessfulUsage(usage, source: .oauth, accountID: requestAccountID)
                    // CLI external account 의 identity 가 비어 있으면 백그라운드로
                    // OAuth profile 을 가져와 email/조직 정보를 채운다. 실패해도 사용량 자체는
                    // 정상이므로 silent. 한 번 채워지면 다음부터는 이 분기 안 탐.
                    let needsProfileSync = accountStore.accounts()
                        .first(where: { $0.id == ClaudeAccountStore.claudeCodeExternalAccountID })?
                        .identity.email == nil
                    if needsProfileSync {
                        Task { [weak self] in
                            await self?.refreshClaudeCodeAccountProfile()
                        }
                    }
                    return makeFetchOutcome(
                        usage: usage,
                        source: .oauth,
                        accountID: requestAccountID,
                        attemptedSources: attemptedSources)
                } catch let apiError as APIError {
                    guard oauthRequestGeneration == claudeCodeCredentialGeneration else {
                        throw CancellationError()
                    }
                    sourceErrors[.oauth] = apiError
                    // 429 는 Retry-After 만큼 OAuth 경로를 쿨다운 (기본 15분)
                    if case .rateLimited(let retryAfter) = apiError {
                        let cooldown = TimeInterval(retryAfter ?? 900)
                        oauthPathCooldownUntil = Date().addingTimeInterval(cooldown)
                        Logger.warning("OAuth 경로 429 → \(Int(cooldown))초 쿨다운")
                    }
                    markAccountValidationFailedIfDefinitive(apiError, accountID: requestAccountID)
                    Logger.warning("OAuth 경로 실패: \(apiError.localizedDescription)")

                    if plan.shouldAttemptAutomaticFallback {
                        attemptedSources.append(.messagesHeaderFallback)
                        lastFetchMetadata = RuntimeProviderFetchMetadata(
                            sourceLabel: ClaudeUsageSource.messagesHeaderFallback.displayName,
                            accountID: requestAccountID,
                            attemptedSourceLabels: attemptedSources.map(\.displayName))
                        do {
                            let usage = try await fetchUsageViaMessagesFallback(
                                accessToken: oauthAccessToken,
                                policy: plan.fallbackPolicy,
                                currentUsagePercent: lastKnownUsagePercent)
                            guard oauthRequestGeneration == claudeCodeCredentialGeneration else {
                                throw CancellationError()
                            }
                            Logger.warning("OAuth 경로 실패 → Messages 헤더 복구 성공")
                            rememberSuccessfulUsage(
                                usage,
                                source: .messagesHeaderFallback,
                                accountID: requestAccountID)
                            return makeFetchOutcome(
                                usage: usage,
                                source: .messagesHeaderFallback,
                                accountID: requestAccountID,
                                attemptedSources: attemptedSources)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            Logger.warning("Messages 헤더 복구 실패: \(error.localizedDescription)")
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let apiError = APIError.unknownError(error.localizedDescription)
                    sourceErrors[.oauth] = apiError
                    Logger.warning("OAuth 경로 실패: \(error.localizedDescription)")
                }

            case .messagesHeaderFallback:
                continue
            }
        }

        if let oauthError = sourceErrors[.oauth] {
            throw oauthError
        }
        if let sessionError = sourceErrors[.webSession] {
            throw sessionError
        }
        // Claude Code 계정을 선택했지만 OAuth 자격을 읽지 못했거나 kill switch가
        // 활성인 경우, 웹 계정으로 몰래 전환하지 않고 해당 계정의 재로그인을 요구한다.
        if activeKind == .claudeCodeExternal, normalizedSessionKey == nil {
            throw APIError.claudeCodeCredentialUnavailable
        }
        throw APIError.invalidSessionKey
    }

    /// 그사이 한도 초기화 시각이 지났으면 캐시는 초기화 전 값이라 다시 받는다.
    nonisolated static func canReuseOAuthUsage(_ usage: ClaudeUsageResponse, fetchedAt: Date, now: Date) -> Bool {
        guard now.timeIntervalSince(fetchedAt) < minimumOAuthCallInterval else { return false }
        return !UsageLimitCatalog.claude(usage).contains { limit in
            limit.resetAt.map { $0 > fetchedAt && $0 <= now } ?? false
        }
    }

    /// 현재 세션 키 기준 organization 목록 조회 (설정 UI 용도)
    func fetchOrganizations() async throws -> [OrganizationSummary] {
        reloadActiveAccount()
        guard !usesStoredActiveAccount || activeAccount?.kind == .webSession else {
            throw APIError.invalidSessionKey
        }
        guard let sessionKey, !sessionKey.isEmpty else {
            throw APIError.invalidSessionKey
        }
        do {
            return try await fetchOrganizationsWithSessionKey(sessionKey)
        } catch let apiError as APIError {
            if apiError.isTemporaryFailure,
               let cached = loadCachedOrganizations(),
                !cached.isEmpty
            {
                Logger.warning("Organization 목록 네트워크 조회 실패 → 캐시 fallback 사용(\(cached.count)개)")
                return cached
            }
            throw apiError
        } catch {
            if let cached = loadCachedOrganizations(), !cached.isEmpty {
                Logger.warning("Organization 목록 조회 실패(\(error.localizedDescription)) → 캐시 fallback 사용(\(cached.count)개)")
                return cached
            }
            throw error
        }
    }

    /// 현재 세션 키 기준 organization별 사용량 미리보기 조회 (설정 UI 용도)
    func fetchOrganizationPreviews(maxOrganizations: Int = 8) async throws -> [OrganizationPreview] {
        reloadActiveAccount()
        guard !usesStoredActiveAccount || activeAccount?.kind == .webSession else {
            throw APIError.invalidSessionKey
        }
        guard let sessionKey, !sessionKey.isEmpty else {
            throw APIError.invalidSessionKey
        }

        let organizations = try await fetchOrganizations()
        return await fetchOrganizationPreviews(for: organizations, maxOrganizations: maxOrganizations, sessionKey: sessionKey)
    }

    /// 전달된 organization 목록 기준으로 미리보기 조회 (목록/상세 분리 로딩용)
    func fetchOrganizationPreviews(for organizations: [OrganizationSummary], maxOrganizations: Int = 8) async -> [OrganizationPreview] {
        reloadActiveAccount()
        guard !usesStoredActiveAccount || activeAccount?.kind == .webSession else {
            return []
        }
        guard let sessionKey, !sessionKey.isEmpty else {
            return []
        }
        return await fetchOrganizationPreviews(for: organizations, maxOrganizations: maxOrganizations, sessionKey: sessionKey)
    }

    /// 최근 캐시된 organization 목록 반환 (네트워크 실패 시 UI fallback)
    func cachedOrganizationsForDisplay() -> [OrganizationSummary] {
        loadCachedOrganizations() ?? []
    }

    private func fetchOrganizationPreviews(for organizations: [OrganizationSummary], maxOrganizations: Int, sessionKey: String) async -> [OrganizationPreview] {
        let targets = Array(organizations.prefix(max(1, maxOrganizations)))
        var previews: [OrganizationPreview] = []
        previews.reserveCapacity(targets.count)

        for organization in targets {
            var usage: ClaudeUsageResponse?
            var overage: OverageSpendLimitResponse?
            var usageErrorMessage: String?
            do {
                usage = try await fetchUsageWithSessionKey(
                    sessionKey, organizationID: organization.id, recordsPathHealth: false)
            } catch let apiError as APIError {
                usageErrorMessage = apiError.localizedDescription
            } catch {
                usageErrorMessage = error.localizedDescription
            }

            do {
                let result = try await ClaudeSupplementalRefreshResult.refresh(
                    embeddedUsage: usage?.extraUsage, source: .webSession
                ) {
                    try await self.fetchOverageSpendLimitWithSessionKey(sessionKey, organizationID: organization.id)
                }
                if case .success(let value, _) = result { overage = value }
            } catch {
                Logger.debug("Organization 추가 사용량 미리보기 실패(\(organization.id)): \(error.localizedDescription)")
            }

            previews.append(
                OrganizationPreview(
                    organization: organization,
                    fiveHourPercentage: usage?.fiveHour?.utilization,
                    weeklyPercentage: usage?.sevenDay?.utilization,
                    overage: overage,
                    usageErrorMessage: usageErrorMessage
                )
            )
        }

        return previews
    }

    private func fetchUsageWithSessionKey(_ sessionKey: String) async throws -> ClaudeUsageResponse {
        try await fetchSessionUsage(sessionKey).usage
    }

    private func fetchSessionUsage(_ sessionKey: String) async throws -> (
        usage: ClaudeUsageResponse, identity: UsageAccountIdentity
    ) {
        let accountID = activeAccount?.id
        let revision = sessionContextRevision
        let orgID = try await getOrganizationID(for: sessionKey)
        guard isCurrentRequest(accountID: accountID, sessionKey: sessionKey, revision: revision) else {
            throw CancellationError()
        }
        let organizationName = lastResolvedSessionOrganization.flatMap { $0.id == orgID ? $0.name : nil }
        let usage = try await fetchUsageWithSessionKey(sessionKey, organizationID: orgID)
        guard isCurrentRequest(accountID: accountID, sessionKey: sessionKey, revision: revision) else {
            throw CancellationError()
        }
        return (usage, UsageAccountIdentity(organizationID: orgID, organizationName: organizationName))
    }

    /// 조직 미리보기처럼 선택하지 않은 조직을 볼 때는 활성 계정의 경로 기록과 대기 시간을 남기지 않는다.
    private func fetchUsageWithSessionKey(
        _ sessionKey: String, organizationID orgID: String, recordsPathHealth: Bool = true
    ) async throws -> ClaudeUsageResponse {
        let requestAccountID = activeAccount?.id
        let requestRevision = sessionContextRevision
        if recordsPathHealth { health.recordAttempt(.session) }

        let url = ClaudeEndpoints.webUsageURL(organizationID: orgID)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        ClaudeEndpoints.applyWebHeaders(to: &request, sessionKey: sessionKey)

        Logger.debug("API 요청: \(url.absoluteString)")

        let (data, response) = try await transport.send(request)
        // 응답을 기다리는 동안 계정이 바뀌면 결과를 새 계정의 경로 상태에 남기지 않는다.
        guard isCurrentRequest(accountID: requestAccountID, sessionKey: sessionKey, revision: requestRevision) else {
            throw CancellationError()
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            Logger.error("유효하지 않은 응답")
            let apiError = APIError.unknownError("Invalid HTTP response")
            if recordsPathHealth { health.recordFailure(.session, error: apiError) }
            throw apiError
        }

        Logger.debug("HTTP 상태 코드: \(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            Logger.error("HTTP 에러: \(httpResponse.statusCode)")
            let apiError = ClaudeHTTPTransport.classify(
                statusCode: httpResponse.statusCode, data: data, response: httpResponse)
            if recordsPathHealth {
                sessionCooldown.apply(after: apiError)
                health.recordFailure(.session, error: apiError)
            }
            throw apiError
        }

        // 디버그: raw JSON 출력
        if let jsonString = String(data: data, encoding: .utf8) {
            Logger.debug("Raw JSON 응답: \(jsonString)")
        }

        do {
            let decoder = JSONDecoder()
            let usageResponse = try decoder.decode(ClaudeUsageResponse.self, from: data)

            Logger.info("사용량 데이터 수신 성공: \(usageResponse.usageSummaryText)")
            if recordsPathHealth { health.recordSuccess(.session) }
            return usageResponse

        } catch {
            Logger.error("JSON 파싱 실패: \(error)")
            let apiError = APIError.parseError
            if recordsPathHealth { health.recordFailure(.session, error: apiError) }
            throw apiError
        }
    }

    /// 추가 사용량(Extra Usage) 정보 가져오기
    func fetchOverageSpendLimit(
        organizationID: String? = nil, expectedSessionContextRevision: Int? = nil
    ) async throws -> OverageSpendLimitResponse {
        reloadActiveAccount()
        guard expectedSessionContextRevision.map({ $0 == sessionContextRevision }) ?? true else {
            throw CancellationError()
        }
        guard !usesStoredActiveAccount || activeAccount?.kind == .webSession else {
            throw APIError.invalidSessionKey
        }
        guard let sessionKey = sessionKey, !sessionKey.isEmpty else {
            throw APIError.invalidSessionKey
        }

        // 추가 사용량 API는 브라우저 로그인 계정에서만 지원합니다.
        if let cooldownError = sessionCooldown.currentError() {
            Logger.debug("추가 사용량 조회 스킵: 세션키 경로 쿨다운 중(\(cooldownError.localizedDescription))")
            throw cooldownError
        }

        let accountID = activeAccount?.id
        let revision = sessionContextRevision
        let orgID: String
        if let organizationID {
            guard let normalized = Self.normalizeOrganizationID(organizationID) else { throw APIError.parseError }
            orgID = normalized
        } else {
            orgID = try await getOrganizationID(for: sessionKey)
        }
        guard isCurrentRequest(accountID: accountID, sessionKey: sessionKey, revision: revision) else {
            throw CancellationError()
        }
        return try await fetchOverageSpendLimitWithSessionKey(sessionKey, organizationID: orgID)
    }

    private func fetchOverageSpendLimitWithSessionKey(_ sessionKey: String, organizationID orgID: String) async throws -> OverageSpendLimitResponse {
        let requestAccountID = activeAccount?.id
        let requestRevision = sessionContextRevision
        let url = URL(string: "\(baseURL)/organizations/\(orgID)/overage_spend_limit")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        ClaudeEndpoints.applyWebHeaders(to: &request, sessionKey: sessionKey)

        Logger.debug("Overage API 요청: \(url.absoluteString)")

        let (data, response) = try await transport.send(request)
        guard isCurrentRequest(accountID: requestAccountID, sessionKey: sessionKey, revision: requestRevision) else {
            throw CancellationError()
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknownError("Invalid HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let apiError = ClaudeHTTPTransport.classify(
                statusCode: httpResponse.statusCode, data: data, response: httpResponse)
            throw apiError
        }

        if let jsonString = String(data: data, encoding: .utf8) {
            Logger.debug("Overage Raw JSON: \(jsonString)")
            let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "null" || trimmed.isEmpty {
                Logger.info("추가 사용량 응답이 null로 반환됨 → 비활성 상태로 처리")
                return disabledOverageSpendLimitResponse()
            }
        }

        do {
            let decoder = JSONDecoder()
            let overage = try decoder.decode(OverageSpendLimitResponse.self, from: data)
            Logger.info("추가 사용량 수신: \(overage.formattedUsedCredits) / \(overage.formattedCreditLimit)")
            return overage
        } catch {
            Logger.error("Overage JSON 파싱 실패: \(error)")
            throw APIError.parseError
        }
    }

    // MARK: - Private Methods

    /// 이 요청을 시작한 계정과 세션 키가 아직 그대로인지
    private func isCurrentRequest(accountID: String?, sessionKey: String, revision: Int) -> Bool {
        guard activeAccount?.id == accountID, self.sessionKey == sessionKey, sessionContextRevision == revision else {
            return false
        }
        guard usesStoredActiveAccount else { return true }
        let stored = accountStore.activeAccount()
        return stored?.id == accountID
            && Self.normalizeOrganizationID(stored?.userSelectedPreferredOrganizationID) == preferredOrganizationID
    }

    /// Organization ID 가져오기 (첫 호출 시 자동 추출 및 캐싱). 캐시는 지금 세션 키의 것만 쓰고,
    /// 조회하는 동안 계정이나 세션 키가 바뀌면 고른 조직을 캐시와 계정 identity에 남기지 않는다.
    private func getOrganizationID(for sessionKey: String) async throws -> String {
        guard !sessionKey.isEmpty else { throw APIError.invalidSessionKey }
        if let cached = cachedOrganizationID, self.sessionKey == sessionKey {
            Logger.debug("캐시된 Organization ID 사용: \(cached)")
            return cached
        }
        let requestAccountID = activeAccount?.id
        let requestRevision = sessionContextRevision

        Logger.info("Organization ID 가져오기 시작")
        let organizations = try await fetchOrganizationsWithSessionKey(sessionKey)
        guard isCurrentRequest(accountID: requestAccountID, sessionKey: sessionKey, revision: requestRevision) else {
            throw CancellationError()
        }
        if let cached = cachedOrganizationID { return cached }
        guard !organizations.isEmpty else {
            Logger.error("Organization 목록이 비어 있음")
            throw APIError.parseError
        }

        if let preferredOrganizationID,
           let preferred = organizations.first(where: { $0.id == preferredOrganizationID }) {
            Logger.info("선호 Organization ID 사용: \(preferred.id)")
            guard isCurrentRequest(accountID: requestAccountID, sessionKey: sessionKey, revision: requestRevision)
            else { throw CancellationError() }
            cachedOrganizationID = preferred.id
            lastResolvedSessionOrganization = preferred
            await rememberActiveOrganization(preferred)
            return preferred.id
        }

        if let preferredOrganizationID {
            Logger.warning("선호 Organization ID 미발견(\(preferredOrganizationID)) → 자동 선택으로 대체")
        }

        let selected = try await selectAutomaticOrganization(organizations, sessionKey: sessionKey) ?? organizations[0]
        guard isCurrentRequest(accountID: requestAccountID, sessionKey: sessionKey, revision: requestRevision) else {
            throw CancellationError()
        }
        if let cached = cachedOrganizationID { return cached }
        Logger.info("Organization ID 선택: \(selected.id) (총 \(organizations.count)개)")
        cachedOrganizationID = selected.id
        lastResolvedSessionOrganization = selected
        await rememberActiveOrganization(selected)
        return selected.id
    }

    private func rememberActiveOrganization(_ organization: OrganizationSummary) async {
        guard let activeAccount,
              let sessionKey,
              Self.shouldRememberResolvedOrganization(
                  activeAccount: activeAccount,
                  sessionKey: sessionKey
              ) else {
            // 새 Chrome 프로필을 저장 전 검증하는 동안에는 공용 서비스의
            // activeAccount가 이전 계정일 수 있다. 새 조직 identity를 이전
            // 계정에 합치지 않고 coordinator가 새 계정을 저장할 때 전달한다.
            return
        }
        await profileMetadataStore.merge(
            ClaudeProfileMetadata(organizationUUID: organization.id, lastUpdatedAt: Date()))
        accountStore.mergeIdentity(
            ClaudeAccountIdentity(
                organizationName: organization.name,
                organizationID: organization.id
            ),
            for: activeAccount.id
        )
        self.activeAccount = accountStore.activeAccount()
    }

    nonisolated static func shouldRememberResolvedOrganization(
        activeAccount: ClaudeAccount?,
        sessionKey: String
    ) -> Bool {
        guard let activeAccount, activeAccount.kind == .webSession else { return false }
        let fingerprint = ClaudeAccountStore.fingerprint(for: sessionKey)
        return activeAccount.id == ClaudeAccountStore.webSessionAccountID(
            fingerprint: fingerprint
        )
    }

    private func selectAutomaticOrganization(
        _ organizations: [OrganizationSummary],
        sessionKey: String
    ) async throws -> OrganizationSummary? {
        guard organizations.count > 1 else {
            return organizations.first
        }

        var candidates: [ClaudeAutomaticOrganizationCandidate] = []
        candidates.reserveCapacity(organizations.count)

        for organization in organizations {
            var overage: OverageSpendLimitResponse?
            do {
                overage = try await fetchOverageSpendLimitWithSessionKey(sessionKey, organizationID: organization.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Logger.debug("자동 Organization 추가 사용량 확인 실패(\(organization.id)): \(error.localizedDescription)")
            }
            candidates.append(ClaudeAutomaticOrganizationCandidate(organization: organization, overage: overage))
        }

        guard let selectedCandidate = ClaudeAutomaticOrganizationSelectionPolicy.selectBest(from: candidates) else {
            return organizations.first
        }

        let selected = selectedCandidate.organization
        if selected.hasTeamPlanSignal {
            Logger.info("팀/조직 플랜 Organization 자동 선택: \(selected.id)")
        } else if selectedCandidate.overage?.isEnabled == true {
            Logger.info("추가 사용량 활성 Organization 자동 선택: \(selected.id)")
        }
        return selected
    }

    private func fetchOrganizationsWithSessionKey(_ sessionKey: String) async throws -> [OrganizationSummary] {
        if let cooldownError = sessionCooldown.currentError() {
            Logger.debug("Organization 목록 조회 스킵: 세션키 경로 쿨다운 중(\(cooldownError.localizedDescription))")
            throw cooldownError
        }

        let url = URL(string: "\(baseURL)/organizations")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        ClaudeEndpoints.applyWebHeaders(to: &request, sessionKey: sessionKey)

        let requestAccountID = activeAccount?.id
        let requestRevision = sessionContextRevision
        let (data, response) = try await transport.send(request)
        guard isCurrentRequest(accountID: requestAccountID, sessionKey: sessionKey, revision: requestRevision) else {
            throw CancellationError()
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknownError("Invalid HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let apiError = ClaudeHTTPTransport.classify(
                statusCode: httpResponse.statusCode, data: data, response: httpResponse)
            sessionCooldown.apply(after: apiError)
            throw apiError
        }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw APIError.parseError
            }

            let organizations = json.compactMap(OrganizationSummary.init(json:))

            if organizations.isEmpty {
                Logger.error("Organization ID를 찾을 수 없음")
            } else {
                organizationCache.save(
                    organizations, accountID: activeAccount?.id, sessionFingerprint: currentSessionFingerprint())
            }
            return organizations
        } catch let apiError as APIError {
            throw apiError
        } catch {
            Logger.error("Organization JSON 파싱 실패: \(error)")
            throw APIError.parseError
        }
    }

    private func loadCachedOrganizations() -> [OrganizationSummary]? {
        organizationCache.load(accountID: activeAccount?.id, sessionFingerprint: currentSessionFingerprint())
    }

    private func clearCachedOrganizations() {
        organizationCache.clear(accountID: activeAccount?.id)
    }

    private func disabledOverageSpendLimitResponse() -> OverageSpendLimitResponse {
        OverageSpendLimitResponse(
            monthlyCreditLimitCents: 0,
            usedCreditsCents: 0,
            isEnabled: false,
            outOfCredits: false,
            currency: "USD"
        )
    }

    /// 기존 payload 전용 API.
    func fetchUsageWithRetry(maxAttempts: Int = 3) async throws -> ClaudeUsageResponse {
        try await fetchUsageWithRetryOutcome(maxAttempts: maxAttempts).usage
    }

    /// provenance를 유지하는 재시도 API. 런타임 refresh는 이 경로만 사용한다.
    func fetchUsageWithRetryOutcome(
        maxAttempts: Int = 3, bypassOAuthCache: Bool = false
    ) async throws -> ClaudeUsageFetchOutcome {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await fetchUsageOutcome(bypassOAuthCache: bypassOAuthCache)

            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 인증 에러는 재시도 없이 즉시 throw
                if let apiError = error as? APIError, apiError.isDefinitiveAuthFailure {
                    throw apiError
                }

                // 제한/차단류는 같은 사이클 재시도로 더 악화될 수 있어 즉시 종료
                if let apiError = error as? APIError {
                    switch apiError {
                    case .rateLimited(_), .cloudflareBlocked(_), .permissionDenied, .claudeCodeExecutableNotFound:
                        throw apiError
                    case .invalidSessionKey, .codexReauthRequired, .codexTokenRefreshTemporary, .claudeCodeCredentialUnavailable, .claudeCodeReauthenticationRequired, .claudeCodeReconnectRequired, .networkError, .parseError, .serverError, .unknownError:
                        break
                    }
                }

                lastError = error
                Logger.warning("시도 \(attempt)/\(maxAttempts) 실패: \(error.localizedDescription)")

                if attempt < maxAttempts {
                    let delay = ClaudeHTTPTransport.retryDelayNanoseconds(for: error, attempt: attempt)
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }

        throw lastError ?? APIError.unknownError("모든 재시도 실패")
    }

    func currentFetchMetadataSnapshot() -> RuntimeProviderFetchMetadata? {
        lastFetchMetadata
    }

    func fetchUsageUsingMessagesFallback() async throws -> ClaudeUsageResponse {
        reloadActiveAccount()
        guard !usesStoredActiveAccount || activeAccount?.kind == .claudeCodeExternal else {
            throw APIError.unknownError("보조 사용량 복구는 Claude Code 계정에서만 사용할 수 있습니다")
        }
        guard let accessToken = try await readSystemOAuthAccessToken() else {
            throw APIError.unknownError("Claude Code OAuth 토큰을 찾을 수 없습니다")
        }

        let configuredPolicy = await currentMessagesFallbackPolicy()
        guard configuredPolicy.isEnabled else {
            throw APIError.unknownError("보조 사용량 복구가 꺼져 있습니다")
        }

        try await synchronizeOAuthIdentityIfNeeded(accessToken: accessToken)
        let credentialGeneration = claudeCodeCredentialGeneration
        let requestAccountID = usesStoredActiveAccount ? activeAccount?.id : nil
        try validateOAuthCredential(accessToken: accessToken, generation: credentialGeneration)
        let manualPolicy = ClaudeMessagesHeaderFallbackPolicy(
            isEnabled: true,
            allowAutomaticFallback: true,
            minimumUsagePercent: 0)
        let usage = try await fetchUsageViaMessagesFallback(
            accessToken: accessToken,
            policy: manualPolicy,
            currentUsagePercent: nil)
        try validateOAuthCredential(accessToken: accessToken, generation: credentialGeneration)
        guard !usesStoredActiveAccount || activeAccount?.id == requestAccountID else { throw CancellationError() }
        rememberSuccessfulUsage(
            usage,
            source: .messagesHeaderFallback,
            accountID: requestAccountID)
        return usage
    }

    private func fetchUsageViaOAuth(
        accessToken: String, requestGeneration: inout Int
    ) async throws -> (usage: ClaudeUsageResponse, generation: Int) {
        // 첫 시도: 주어진 access token 으로 호출.
        // 401 (unauthorized) 가 오면 토큰이 만료되었을 가능성이 높으므로
        // refresh 를 1회 강제 시도하고 새 토큰으로 재호출한다. 같은 단일 fetchUsage 흐름
        // 안에서만 retry 하므로 무한 루프 위험 없음.
        do {
            return try await performOAuthUsageRequest(accessToken: accessToken)
        } catch let firstError as APIError {
            guard case .invalidSessionKey = firstError else { throw firstError }
            guard let refreshedToken = try await forceRefreshSystemOAuthAccessToken(),
                  refreshedToken != accessToken
            else {
                throw firstError
            }
            Logger.info("OAuth 토큰 401 → refresh 성공, 재시도")
            try await synchronizeOAuthIdentityIfNeeded(accessToken: refreshedToken)
            requestGeneration = claudeCodeCredentialGeneration
            return try await performOAuthUsageRequest(accessToken: refreshedToken)
        }
    }

    private func performOAuthUsageRequest(accessToken: String) async throws -> (
        usage: ClaudeUsageResponse, generation: Int
    ) {
        let generation = claudeCodeCredentialGeneration
        let requestAccountID = activeAccount?.id
        health.recordAttempt(.oauth)

        var request = URLRequest(url: ClaudeEndpoints.oauthUsageURL)
        request.httpMethod = "GET"
        ClaudeEndpoints.applyOAuthHeaders(to: &request, accessToken: accessToken)

        var (data, response) = try await transport.send(request)
        try validateOAuthCredential(accessToken: accessToken, generation: generation)
        guard activeAccount?.id == requestAccountID else { throw CancellationError() }
        if let status = (response as? HTTPURLResponse)?.statusCode,
            ClaudeEndpoints.rejectsOptionalUsageQuery(status: status, data: data)
        {
            request.url = ClaudeEndpoints.oauthUsageURLWithoutResetCredits
            (data, response) = try await transport.send(request)
            try validateOAuthCredential(accessToken: accessToken, generation: generation)
            guard activeAccount?.id == requestAccountID else { throw CancellationError() }
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            let apiError = APIError.unknownError("Invalid OAuth HTTP response")
            health.recordFailure(.oauth, error: apiError)
            throw apiError
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let apiError = ClaudeHTTPTransport.classify(
                statusCode: httpResponse.statusCode, data: data, response: httpResponse)
            health.recordFailure(.oauth, error: apiError)
            throw apiError
        }

        do {
            let decoder = JSONDecoder()
            let usage = try decoder.decode(ClaudeUsageResponse.self, from: data)
            health.recordSuccess(.oauth)
            return (usage, generation)
        } catch {
            let apiError = APIError.parseError
            health.recordFailure(.oauth, error: apiError)
            throw apiError
        }
    }

    private func readSystemOAuthAccessToken() async throws -> String? {
        do {
            return try await resolveOAuthAccessToken(forceRefresh: false)
        } catch ClaudeOAuthCredentialReadError.reauthenticationRequired {
            throw APIError.claudeCodeReauthenticationRequired
        } catch ClaudeOAuthCredentialReadError.reconnectRequired {
            throw APIError.claudeCodeReconnectRequired
        } catch ClaudeOAuthCredentialReadError.executableNotFound {
            throw APIError.claudeCodeExecutableNotFound
        } catch ClaudeOAuthCredentialReadError.refreshUnavailable {
            // 로그인이 끊긴 것으로 보지 않는다. 마지막 값을 두고 잠시 뒤 다시 시도한다.
            throw APIError.networkError("Claude Code 로그인을 지금 갱신하지 못했습니다")
        }
    }

    private func forceRefreshSystemOAuthAccessToken() async throws -> String? {
        do {
            return try await resolveOAuthAccessToken(forceRefresh: true)
        } catch ClaudeOAuthCredentialReadError.reauthenticationRequired {
            throw APIError.claudeCodeReauthenticationRequired
        } catch ClaudeOAuthCredentialReadError.reconnectRequired {
            throw APIError.claudeCodeReconnectRequired
        } catch ClaudeOAuthCredentialReadError.executableNotFound {
            throw APIError.claudeCodeExecutableNotFound
        } catch ClaudeOAuthCredentialReadError.refreshUnavailable {
            // 로그인이 끊긴 것으로 보지 않는다. 마지막 값을 두고 잠시 뒤 다시 시도한다.
            throw APIError.networkError("Claude Code 로그인을 지금 갱신하지 못했습니다")
        }
    }

    private func beginOAuthCredentialRead() -> Int {
        oauthReadRevision &+= 1
        return oauthReadRevision
    }

    private func resolveOAuthAccessToken(forceRefresh: Bool) async throws -> String? {
        let revision = beginOAuthCredentialRead()
        let token =
            forceRefresh
            ? try await oauthCredentialReader.forceRefreshAccessToken()
            : try await oauthCredentialReader.readAccessToken()
        return try await adoptOAuthAccessToken(token, readRevision: revision)
    }

    private func refreshSystemOAuthCredentialInventory() async throws -> ClaudeOAuthCredentialInventoryRefresh {
        let revision = beginOAuthCredentialRead()
        let inventory = try await oauthCredentialReader.refreshCredentialInventoryWithoutUI()
        _ = try await adoptOAuthAccessToken(inventory.accessToken, readRevision: revision)
        return inventory
    }

    private func adoptOAuthAccessToken(_ token: String?, readRevision: Int) async throws -> String? {
        try Task.checkCancellation()
        let fingerprint = token.map(Self.computeSessionFingerprint)
        guard readRevision >= appliedOAuthReadRevision || fingerprint == oauthCredentialFingerprint else {
            throw CancellationError()
        }
        appliedOAuthReadRevision = max(appliedOAuthReadRevision, readRevision)
        if oauthCredentialFingerprint != fingerprint {
            oauthCredentialFingerprint = fingerprint
            invalidateClaudeCodeRequestGeneration()
            if token == nil { await clearClaudeCodeIdentityState() }
        }
        try Task.checkCancellation()
        guard fingerprint == oauthCredentialFingerprint else { throw CancellationError() }
        return token
    }

    private func validateOAuthCredential(accessToken: String, generation: Int) throws {
        try Task.checkCancellation()
        guard generation == claudeCodeCredentialGeneration,
            oauthCredentialFingerprint == Self.computeSessionFingerprint(accessToken)
        else { throw CancellationError() }
    }

    private nonisolated static func hasStoredOAuthCredentialInventory(_ state: ClaudeAccountState) -> Bool {
        guard let account = state.accounts.first(where: { $0.kind == .claudeCodeExternal }) else {
            return false
        }
        return account.lastValidationState == .detected || account.lastValidationState == .verified
    }

    private func currentMessagesFallbackPolicy() async -> ClaudeMessagesHeaderFallbackPolicy {
        await MainActor.run {
            SetupCompletionPolicy.messagesFallbackPolicy(from: AppSettings.shared)
        }
    }

    private func fetchUsageViaMessagesFallback(
        accessToken: String,
        policy: ClaudeMessagesHeaderFallbackPolicy,
        currentUsagePercent: Double?) async throws -> ClaudeUsageResponse
    {
        let snapshot = try await messagesHeaderFallbackFetcher.fetchSnapshot(
            accessToken: accessToken,
            policy: policy,
            currentUsagePercent: currentUsagePercent)
        return ClaudeUsageResponse(
            fiveHour: UsageWindow(
                utilization: snapshot.sessionUsagePercent,
                resetsAt: Self.isoString(from: snapshot.sessionResetAt)),
            sevenDay: UsageWindow(
                utilization: snapshot.weeklyUsagePercent,
                resetsAt: Self.isoString(from: snapshot.weeklyResetAt)))
    }

    private func currentSessionFingerprint() -> String? {
        guard let sessionKey, !sessionKey.isEmpty else { return nil }
        return Self.computeSessionFingerprint(sessionKey)
    }

    private static func computeSessionFingerprint(_ sessionKey: String) -> String {
        let digest = SHA256.hash(data: Data(sessionKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func makeFetchOutcome(
        usage: ClaudeUsageResponse,
        source: ClaudeUsageSource,
        accountID: String?,
        attemptedSources: [ClaudeUsageSource],
        webIdentity: UsageAccountIdentity? = nil
    ) -> ClaudeUsageFetchOutcome {
        let provenance = ClaudeFetchProvenance(
            source: source,
            accountID: accountID,
            attemptedSources: attemptedSources)
        lastFetchMetadata = RuntimeProviderFetchMetadata(
            sourceLabel: source.displayName,
            accountID: accountID,
            attemptedSourceLabels: attemptedSources.map(\.displayName))
        return ClaudeUsageFetchOutcome(
            usage: usage, provenance: provenance,
            identity: source == .webSession ? webIdentity : currentRuntimeUsageAccountIdentity(),
            credentialGeneration: source == .webSession ? nil : claudeCodeCredentialGeneration
        )
    }

    private func rememberSuccessfulUsage(
        _ usage: ClaudeUsageResponse,
        source: ClaudeUsageSource,
        accountID: String?
    ) {
        lastKnownUsagePercent = usage.fiveHourPercentage
        if source != .messagesHeaderFallback {
            lastSuccessfulUsageSource = source
        }
        markAccountVerified(accountID: accountID)
        health.recordOverallSuccess()
    }

    private func markAccountVerified(accountID: String?) {
        guard usesStoredActiveAccount, let accountID else { return }
        accountStore.updateValidationState(.verified, for: accountID)
        self.activeAccount = accountStore.activeAccount()
    }

    /// 네트워크, 제한, 서버 오류는 자격 증명이 틀렸다는 뜻이 아니므로 검증 상태를 바꾸지 않는다.
    private func markAccountValidationFailedIfDefinitive(_ error: APIError, accountID: String?) {
        guard error.isDefinitiveAuthFailure else { return }
        markAccountValidationFailed(accountID: accountID)
    }

    private func markAccountValidationFailed(accountID: String?) {
        guard usesStoredActiveAccount, let accountID else { return }
        accountStore.updateValidationState(.failed, for: accountID)
        self.activeAccount = accountStore.activeAccount()
    }

    private func makeRuntimeAuthSnapshot(
        oauthCredentialAvailable: Bool,
        credentialIssue: ClaudeCodeCredentialIssue? = nil
    ) -> RuntimeAuthSnapshot {
        let now = Date()
        let hasSessionCredential = activeAccount?.kind == .webSession && hasSessionKey()
        let hasOAuthCredential = activeAccount?.kind == .claudeCodeExternal && oauthCredentialAvailable
        let credentialAvailability = ClaudeCredentialAvailability(
            sessionCredentialAvailable: hasSessionCredential,
            oauthCredentialAvailable: hasOAuthCredential || oauthCredentialAvailable
        )
        let sessionCooldownRemaining = sessionCooldown.remainingSeconds(now: now)
        let oauthPreferredRemaining: Int? = nil

        let activePath: RuntimeAuthSnapshot.ActivePath = {
            guard let activeAccount else {
                if oauthCredentialAvailable { return .oauthFallback }
                return .unauthenticated
            }

            switch activeAccount.kind {
            case .webSession:
                return hasSessionCredential ? .sessionPrimary : .unauthenticated
            case .claudeCodeExternal:
                return oauthCredentialAvailable ? .oauthPreferred : .unauthenticated
            }
        }()

        return RuntimeAuthSnapshot(
            activePath: activePath,
            credentialAvailability: credentialAvailability,
            sessionValidationState: health.validationState(.session, credentialAvailable: hasSessionCredential),
            oauthValidationState: stableClaudeCodeValidationState(credentialAvailable: oauthCredentialAvailable),
            sessionCooldownRemaining: sessionCooldownRemaining,
            oauthPreferredRemaining: oauthPreferredRemaining,
            claudeCodeCredentialIssue: oauthCredentialAvailable ? nil : credentialIssue
        )
    }

    private func stableClaudeCodeValidationState(
        credentialAvailable: Bool
    ) -> ClaudeCredentialValidationState {
        let measured = health.validationState(.oauth, credentialAvailable: credentialAvailable)
        guard measured == .detected else { return measured }
        guard let existing = accountStore.accounts().first(where: { $0.id == ClaudeAccountStore.claudeCodeExternalAccountID })?.lastValidationState else {
            return measured
        }

        switch existing {
        case .verified, .failed:
            return existing
        case .unavailable, .detected:
            return measured
        }
    }

    private static func normalizeOrganizationID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

}
