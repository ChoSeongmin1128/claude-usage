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
    // MARK: - Properties

    struct OrganizationSummary: Sendable, Equatable, Identifiable, Codable {
        let id: String
        let name: String?
        let planLabel: String?
        let billingType: String?
        let rateLimitTier: String?

        nonisolated init(
            id: String,
            name: String?,
            planLabel: String? = nil,
            billingType: String? = nil,
            rateLimitTier: String? = nil
        ) {
            self.id = id
            self.name = Self.normalized(name)
            self.planLabel = Self.normalized(planLabel)
            self.billingType = Self.normalized(billingType)
            self.rateLimitTier = Self.normalized(rateLimitTier)
        }

        var displayName: String {
            if let name, !name.isEmpty {
                return "\(name) (\(id))"
            }
            return id
        }

        var hasTeamPlanSignal: Bool {
            let values = [planLabel, billingType, rateLimitTier]
                .compactMap { $0?.lowercased() }
            return values.contains { value in
                value.contains("team")
                    || value.contains("enterprise")
                    || value.contains("business")
                    || value.contains("organization")
                    || value.contains("org")
            }
        }

        private nonisolated static func normalized(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    struct OrganizationPreview: Sendable, Equatable, Identifiable {
        let organization: OrganizationSummary
        let fiveHourPercentage: Double?
        let weeklyPercentage: Double?
        let overageEnabled: Bool?
        let overageUsed: Double?
        let overageLimit: Double?
        let usageErrorMessage: String?

        var id: String { organization.id }
    }

    struct AuthPathHealthSnapshot: Sendable, Equatable {
        let lastAttemptAt: Date?
        let lastSuccessAt: Date?
        let lastFailureAt: Date?
        let lastErrorMessage: String?
        let consecutiveFailures: Int
        let totalAttempts: Int
        let totalFailures: Int

        nonisolated var hasAttempt: Bool {
            lastAttemptAt != nil || lastSuccessAt != nil || lastFailureAt != nil
        }

        nonisolated var isUnstable: Bool {
            if consecutiveFailures >= 2 {
                return true
            }
            guard let lastFailureAt else { return false }
            guard let lastSuccessAt else { return true }
            return lastFailureAt > lastSuccessAt
        }

        nonisolated var failureRatePercent: Int? {
            guard totalAttempts > 0 else { return nil }
            let ratio = (Double(totalFailures) / Double(totalAttempts)) * 100
            return Int(ratio.rounded())
        }
    }

    struct RuntimeAuthSnapshot: Sendable, Equatable {
        enum ActivePath: String, Sendable {
            case unauthenticated
            case sessionPrimary
            case oauthPreferred
            case oauthFallback
        }

        let activePath: ActivePath
        let credentialAvailability: ClaudeCredentialAvailability
        let sessionValidationState: ClaudeCredentialValidationState
        let oauthValidationState: ClaudeCredentialValidationState
        let sessionCooldownRemaining: Int?
        let oauthPreferredRemaining: Int?
    }

    struct UsageHealthSnapshot: Sendable, Equatable {
        let lastOverallSuccessAt: Date?
        let session: AuthPathHealthSnapshot
        let oauth: AuthPathHealthSnapshot
        let runtime: RuntimeAuthSnapshot
        let accounts: [ClaudeAccount]
        let activeAccountID: String?

        init(
            lastOverallSuccessAt: Date?,
            session: AuthPathHealthSnapshot,
            oauth: AuthPathHealthSnapshot,
            runtime: RuntimeAuthSnapshot,
            accounts: [ClaudeAccount] = [],
            activeAccountID: String? = nil
        ) {
            self.lastOverallSuccessAt = lastOverallSuccessAt
            self.session = session
            self.oauth = oauth
            self.runtime = runtime
            self.accounts = accounts
            self.activeAccountID = activeAccountID
        }

        var activeAccount: ClaudeAccount? {
            guard let activeAccountID else { return nil }
            return accounts.first(where: { $0.id == activeAccountID })
        }
    }

    private enum AuthFetchPath: String, Codable {
        case session
        case oauth
    }

    private struct AuthPathHealthState: Codable {
        enum CodingKeys: String, CodingKey {
            case lastAttemptAt
            case lastSuccessAt
            case lastFailureAt
            case lastErrorMessage
            case consecutiveFailures
            case totalAttempts
            case totalFailures
        }

        var lastAttemptAt: Date?
        var lastSuccessAt: Date?
        var lastFailureAt: Date?
        var lastErrorMessage: String?
        var consecutiveFailures: Int = 0
        var totalAttempts: Int = 0
        var totalFailures: Int = 0

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
            lastSuccessAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
            lastFailureAt = try container.decodeIfPresent(Date.self, forKey: .lastFailureAt)
            lastErrorMessage = try container.decodeIfPresent(String.self, forKey: .lastErrorMessage)
            consecutiveFailures = try container.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
            totalAttempts = try container.decodeIfPresent(Int.self, forKey: .totalAttempts) ?? 0
            totalFailures = try container.decodeIfPresent(Int.self, forKey: .totalFailures) ?? 0
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(lastAttemptAt, forKey: .lastAttemptAt)
            try container.encodeIfPresent(lastSuccessAt, forKey: .lastSuccessAt)
            try container.encodeIfPresent(lastFailureAt, forKey: .lastFailureAt)
            try container.encodeIfPresent(lastErrorMessage, forKey: .lastErrorMessage)
            try container.encode(consecutiveFailures, forKey: .consecutiveFailures)
            try container.encode(totalAttempts, forKey: .totalAttempts)
            try container.encode(totalFailures, forKey: .totalFailures)
        }
    }

    private struct AuthPathHealthStore: Codable {
        var session = AuthPathHealthState()
        var oauth = AuthPathHealthState()
        var lastOverallSuccessAt: Date?
    }

    private var sessionKey: String?
    private let accountStore: ClaudeAccountStore
    private let usesStoredActiveAccount: Bool
    private var activeAccount: ClaudeAccount?
    private let baseURL = "https://claude.ai/api"
    private var cachedOrganizationID: String?
    private var preferredOrganizationID: String?
    private var sessionPathCooldownUntil: Date?
    private var sessionPathCooldownReason: APIError?
    private var sessionPathLimitStrike = 0
    private let requestTimeout: TimeInterval = 20
    private let sourcePlanner = ClaudeSourcePlanner()
    private let messagesHeaderFallbackFetcher = ClaudeMessagesHeaderFallbackFetcher()
    private var profileMetadataStore: ClaudeProfileMetadataStore
    private let oauthProfileMetadataStore: ClaudeProfileMetadataStore
    private var oauthCredentialReader: ClaudeCodeCredentialReader
    private let organizationCacheTTL: TimeInterval = 7 * 24 * 60 * 60
    private static let authPathHealthDefaultsKeyPrefix = "ClaudeUsage.authPathHealth.v1"
    private static let organizationCacheDefaultsKeyPrefix = "ClaudeUsage.cachedOrganizations.v1"
    private var authPathHealthStore = AuthPathHealthStore()
    private var lastKnownUsagePercent: Double?
    private var lastSuccessfulUsageSource: ClaudeUsageSource?
    private var lastResolvedSessionOrganization: OrganizationSummary?

    private struct OrganizationCache: Codable {
        let savedAt: Date
        let organizations: [OrganizationSummary]
        let sessionFingerprint: String?
    }

    // MARK: - Init

    /// Keychain에서 자동으로 세션 키를 로드하는 기본 생성자
    init() {
        self.accountStore = ClaudeAccountStore.shared
        self.usesStoredActiveAccount = true
        self.accountStore.ensureLegacyMigrationIfNeeded()
        let activeAccount = self.accountStore.activeAccount()
        let profileMetadataStore = ClaudeProfileMetadataStore(accountID: activeAccount?.id)
        let oauthProfileMetadataStore = ClaudeProfileMetadataStore(accountID: ClaudeAccountStore.claudeCodeExternalAccountID)
        self.profileMetadataStore = profileMetadataStore
        self.oauthProfileMetadataStore = oauthProfileMetadataStore
        self.oauthCredentialReader = ClaudeCodeCredentialReader(profileMetadataStore: oauthProfileMetadataStore)
        self.activeAccount = activeAccount
        self.authPathHealthStore = Self.loadAuthPathHealthStore(for: activeAccount?.id)
        self.sessionKey = activeAccount?.kind == .webSession
            ? activeAccount.flatMap { KeychainManager.shared.load(for: $0.id) }
            : nil
        self.preferredOrganizationID = activeAccount?.kind == .webSession
            ? Self.normalizeOrganizationID(activeAccount?.preferredOrganizationID)
            : nil
    }

    /// 특정 세션 키로 초기화 (연결 테스트용)
    init(sessionKey: String) {
        self.accountStore = ClaudeAccountStore.shared
        self.usesStoredActiveAccount = false
        let profileMetadataStore = ClaudeProfileMetadataStore()
        let oauthProfileMetadataStore = ClaudeProfileMetadataStore(accountID: ClaudeAccountStore.claudeCodeExternalAccountID)
        self.profileMetadataStore = profileMetadataStore
        self.oauthProfileMetadataStore = oauthProfileMetadataStore
        self.oauthCredentialReader = ClaudeCodeCredentialReader(profileMetadataStore: nil)
        self.sessionKey = sessionKey
        self.activeAccount = nil
        self.authPathHealthStore = Self.loadAuthPathHealthStore(for: nil)
    }

    func reloadActiveAccount() {
        guard usesStoredActiveAccount else { return }
        accountStore.ensureLegacyMigrationIfNeeded()
        let nextAccount = accountStore.activeAccount()
        guard nextAccount?.id != activeAccount?.id else {
            if nextAccount?.kind == .webSession {
                sessionKey = nextAccount.flatMap { KeychainManager.shared.load(for: $0.id) }
                preferredOrganizationID = Self.normalizeOrganizationID(nextAccount?.preferredOrganizationID)
            } else {
                sessionKey = nil
                preferredOrganizationID = nil
            }
            return
        }

        activeAccount = nextAccount
        profileMetadataStore = ClaudeProfileMetadataStore(accountID: nextAccount?.id)
        authPathHealthStore = Self.loadAuthPathHealthStore(for: nextAccount?.id)
        cachedOrganizationID = nil
        lastResolvedSessionOrganization = nil
        lastKnownUsagePercent = nil
        lastSuccessfulUsageSource = nil
        resetSessionPathCooldown()

        if nextAccount?.kind == .webSession {
            sessionKey = nextAccount.flatMap { KeychainManager.shared.load(for: $0.id) }
            preferredOrganizationID = Self.normalizeOrganizationID(nextAccount?.preferredOrganizationID)
        } else {
            sessionKey = nil
            preferredOrganizationID = nil
        }
    }

    func currentActiveAccountID() -> String? {
        reloadActiveAccount()
        return activeAccount?.id
    }

    // MARK: - Session Key Management

    /// 세션 키 업데이트 (Keychain 저장 후 호출)
    func updateSessionKey(_ key: String) {
        let previousFingerprint = currentSessionFingerprint()
        self.sessionKey = key
        self.cachedOrganizationID = nil  // 캐시 초기화
        self.lastResolvedSessionOrganization = nil
        self.sessionPathCooldownUntil = nil
        self.sessionPathCooldownReason = nil
        self.sessionPathLimitStrike = 0
        if previousFingerprint != currentSessionFingerprint() {
            self.clearCachedOrganizations()
        }
    }

    /// 런타임 브라우저 sessionKey 상태 초기화
    func clearSession() {
        self.sessionKey = nil
        self.cachedOrganizationID = nil
        self.lastResolvedSessionOrganization = nil
        self.sessionPathCooldownUntil = nil
        self.sessionPathCooldownReason = nil
        self.sessionPathLimitStrike = 0
        self.clearCachedOrganizations()
    }

    func updatePreferredOrganizationID(_ id: String) {
        let normalized = Self.normalizeOrganizationID(id)
        if preferredOrganizationID == normalized {
            return
        }
        preferredOrganizationID = normalized
        cachedOrganizationID = nil
        if usesStoredActiveAccount,
           let activeAccount,
           activeAccount.kind == .webSession {
            accountStore.updatePreferredOrganizationID(normalized ?? "", for: activeAccount.id)
            self.activeAccount = accountStore.activeAccount()
        }
        Logger.info("선호 Organization ID 업데이트: \(normalized ?? "자동 선택")")
    }

    /// 세션 키가 설정되어 있는지 확인
    func hasSessionKey() -> Bool {
        guard let key = sessionKey else { return false }
        return !key.isEmpty
    }

    func fetchUsageHealthSnapshot() async -> UsageHealthSnapshot {
        reloadActiveAccount()
        let oauthCredentialAvailable: Bool
        if usesStoredActiveAccount {
            oauthCredentialAvailable = (try? await readSystemOAuthAccessToken()) != nil
        } else {
            oauthCredentialAvailable = false
        }
        if usesStoredActiveAccount, oauthCredentialAvailable {
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
            lastOverallSuccessAt: authPathHealthStore.lastOverallSuccessAt,
            session: makeAuthPathSnapshot(for: .session),
            oauth: makeAuthPathSnapshot(for: .oauth),
            runtime: makeRuntimeAuthSnapshot(oauthCredentialAvailable: oauthCredentialAvailable),
            accounts: state.accounts,
            activeAccountID: state.activeAccountID
        )
    }

    func fetchCachedProfileMetadata() async -> ClaudeProfileMetadata? {
        await profileMetadataStore.load()
    }

    private func claudeCodeAccountIdentity() async -> ClaudeAccountIdentity {
        let metadata = await oauthProfileMetadataStore.load()
        return ClaudeAccountIdentity(
            organizationID: metadata?.organizationUUID,
            planLabel: metadata?.subscriptionType ?? metadata?.rateLimitTier
        )
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

    /// 사용량 데이터 가져오기
    func fetchUsage() async throws -> ClaudeUsageResponse {
        reloadActiveAccount()
        Logger.info("사용량 데이터 요청 시작")
        let oauthAccessToken = try await readSystemOAuthAccessToken()
        if usesStoredActiveAccount,
           activeAccount?.id == nil,
           oauthAccessToken != nil {
            _ = accountStore.upsertClaudeCodeExternalAccount(
                identity: await claudeCodeAccountIdentity(),
                validationState: stableClaudeCodeValidationState(credentialAvailable: true),
                setActiveIfMissing: true
            )
            reloadActiveAccount()
        }

        let activeKind: ClaudeAccountKind? = {
            if usesStoredActiveAccount {
                return activeAccount?.kind
            }
            return .webSession
        }()

        let normalizedSessionKey: String? = {
            guard activeKind == .webSession else { return nil }
            guard let sessionKey, !sessionKey.isEmpty else { return nil }
            return sessionKey
        }()
        let sessionCooldownError = normalizedSessionKey != nil ? currentSessionPathCooldownError() : nil
        let accountScopedOAuthToken = activeKind == .claudeCodeExternal ? oauthAccessToken : nil
        let context = ClaudeFetchContext(
            accountKind: activeKind,
            sourcePreference: .auto,
            webSessionAvailable: normalizedSessionKey != nil && sessionCooldownError == nil,
            oauthAvailable: accountScopedOAuthToken != nil,
            webSessionValidationState: validationState(for: .session, credentialAvailable: normalizedSessionKey != nil && sessionCooldownError == nil),
            oauthValidationState: validationState(for: .oauth, credentialAvailable: accountScopedOAuthToken != nil),
            recentSuccessfulSource: nil,
            currentUsagePercent: lastKnownUsagePercent,
            fallbackPolicy: await currentMessagesFallbackPolicy())
        let plan = sourcePlanner.makePlan(from: context)
        var sourceErrors: [ClaudeUsageSource: APIError] = [:]

        if let cooldownError = sessionCooldownError {
            sourceErrors[.webSession] = cooldownError
            Logger.warning("세션키 경로 쿨다운 중(\(cooldownError.localizedDescription))")
        }

        for candidate in plan.primaryCandidates where candidate.isAvailable {
            switch candidate.source {
            case .webSession:
                guard let sessionKey = normalizedSessionKey else {
                    sourceErrors[.webSession] = .invalidSessionKey
                    continue
                }
                do {
                    let usage = try await fetchUsageWithSessionKey(sessionKey)
                    resetSessionPathCooldown()
                    rememberSuccessfulUsage(usage, source: .webSession)
                    return usage
                } catch let apiError as APIError {
                    sourceErrors[.webSession] = apiError
                    markActiveAccountValidationFailed()
                    Logger.warning("세션키 경로 실패: \(apiError.localizedDescription)")
                } catch {
                    let apiError = APIError.unknownError(error.localizedDescription)
                    sourceErrors[.webSession] = apiError
                    markActiveAccountValidationFailed()
                    Logger.warning("세션키 경로 실패: \(error.localizedDescription)")
                }

            case .oauth:
                guard let oauthAccessToken = accountScopedOAuthToken else {
                    sourceErrors[.oauth] = .unknownError("Claude Code OAuth 토큰을 찾을 수 없습니다")
                    continue
                }

                do {
                    let usage = try await fetchUsageViaOAuth(accessToken: oauthAccessToken)
                    rememberSuccessfulUsage(usage, source: .oauth)
                    return usage
                } catch let apiError as APIError {
                    sourceErrors[.oauth] = apiError
                    markActiveAccountValidationFailed()
                    Logger.warning("OAuth 경로 실패: \(apiError.localizedDescription)")

                    if plan.shouldAttemptAutomaticFallback {
                        do {
                            let usage = try await fetchUsageViaMessagesFallback(
                                accessToken: oauthAccessToken,
                                policy: plan.fallbackPolicy,
                                currentUsagePercent: lastKnownUsagePercent)
                            Logger.warning("OAuth 경로 실패 → Messages 헤더 복구 성공")
                            rememberSuccessfulUsage(usage, source: .messagesHeaderFallback)
                            return usage
                        } catch {
                            Logger.warning("Messages 헤더 복구 실패: \(error.localizedDescription)")
                        }
                    }
                } catch {
                    let apiError = APIError.unknownError(error.localizedDescription)
                    sourceErrors[.oauth] = apiError
                    markActiveAccountValidationFailed()
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
        throw APIError.invalidSessionKey
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
               !cached.isEmpty {
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
                usage = try await fetchUsageWithSessionKey(sessionKey, organizationID: organization.id)
            } catch let apiError as APIError {
                usageErrorMessage = apiError.localizedDescription
            } catch {
                usageErrorMessage = error.localizedDescription
            }

            do {
                overage = try await fetchOverageSpendLimitWithSessionKey(sessionKey, organizationID: organization.id)
            } catch {
                Logger.debug("Organization 추가 사용량 미리보기 실패(\(organization.id)): \(error.localizedDescription)")
            }

            previews.append(
                OrganizationPreview(
                    organization: organization,
                    fiveHourPercentage: usage?.fiveHour.utilization,
                    weeklyPercentage: usage?.sevenDay?.utilization,
                    overageEnabled: overage?.isEnabled,
                    overageUsed: overage?.isEnabled == true ? overage?.usedCredits : nil,
                    overageLimit: overage?.isEnabled == true ? overage?.monthlyCreditLimit : nil,
                    usageErrorMessage: usageErrorMessage
                )
            )
        }

        return previews
    }

    private func fetchUsageWithSessionKey(_ sessionKey: String) async throws -> ClaudeUsageResponse {
        let orgID = try await getOrganizationID()
        return try await fetchUsageWithSessionKey(sessionKey, organizationID: orgID)
    }

    private func fetchUsageWithSessionKey(_ sessionKey: String, organizationID orgID: String) async throws -> ClaudeUsageResponse {
        recordPathAttempt(.session)

        let url = URL(string: "\(baseURL)/organizations/\(orgID)/usage")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        Logger.debug("API 요청: \(url.absoluteString)")

        let (data, response) = try await data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            Logger.error("유효하지 않은 응답")
            let apiError = APIError.unknownError("Invalid HTTP response")
            recordPathFailure(.session, error: apiError)
            throw apiError
        }

        Logger.debug("HTTP 상태 코드: \(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            Logger.error("HTTP 에러: \(httpResponse.statusCode)")
            let apiError = classifyHTTPError(statusCode: httpResponse.statusCode, data: data, response: httpResponse)
            updateSessionPathCooldownIfNeeded(with: apiError)
            recordPathFailure(.session, error: apiError)
            throw apiError
        }

        // 디버그: raw JSON 출력
        if let jsonString = String(data: data, encoding: .utf8) {
            Logger.debug("Raw JSON 응답: \(jsonString)")
        }

        do {
            let decoder = JSONDecoder()
            let usageResponse = try decoder.decode(ClaudeUsageResponse.self, from: data)

            Logger.info("사용량 데이터 수신 성공: \(usageResponse.fiveHourPercentage)%")
            recordPathSuccess(.session)
            return usageResponse

        } catch {
            Logger.error("JSON 파싱 실패: \(error)")
            let apiError = APIError.parseError
            recordPathFailure(.session, error: apiError)
            throw apiError
        }
    }

    /// 추가 사용량(Extra Usage) 정보 가져오기
    func fetchOverageSpendLimit() async throws -> OverageSpendLimitResponse {
        reloadActiveAccount()
        guard !usesStoredActiveAccount || activeAccount?.kind == .webSession else {
            throw APIError.invalidSessionKey
        }
        guard let sessionKey = sessionKey, !sessionKey.isEmpty else {
            throw APIError.invalidSessionKey
        }

        // 추가 사용량 API는 브라우저 로그인 계정에서만 지원합니다.
        if let cooldownError = currentSessionPathCooldownError() {
            Logger.debug("추가 사용량 조회 스킵: 세션키 경로 쿨다운 중(\(cooldownError.localizedDescription))")
            throw cooldownError
        }

        let orgID = try await getOrganizationID()
        return try await fetchOverageSpendLimitWithSessionKey(sessionKey, organizationID: orgID)
    }

    private func fetchOverageSpendLimitWithSessionKey(_ sessionKey: String, organizationID orgID: String) async throws -> OverageSpendLimitResponse {
        let url = URL(string: "\(baseURL)/organizations/\(orgID)/overage_spend_limit")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        Logger.debug("Overage API 요청: \(url.absoluteString)")

        let (data, response) = try await data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknownError("Invalid HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let apiError = classifyHTTPError(statusCode: httpResponse.statusCode, data: data, response: httpResponse)
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

    /// Organization ID 가져오기 (첫 호출 시 자동 추출 및 캐싱)
    private func getOrganizationID() async throws -> String {
        if let cached = cachedOrganizationID {
            Logger.debug("캐시된 Organization ID 사용: \(cached)")
            return cached
        }

        guard let sessionKey = sessionKey, !sessionKey.isEmpty else {
            throw APIError.invalidSessionKey
        }

        Logger.info("Organization ID 가져오기 시작")
        let organizations = try await fetchOrganizationsWithSessionKey(sessionKey)
        guard !organizations.isEmpty else {
            Logger.error("Organization 목록이 비어 있음")
            throw APIError.parseError
        }

        if let preferredOrganizationID,
           let preferred = organizations.first(where: { $0.id == preferredOrganizationID }) {
            Logger.info("선호 Organization ID 사용: \(preferred.id)")
            cachedOrganizationID = preferred.id
            lastResolvedSessionOrganization = preferred
            await rememberActiveOrganization(preferred)
            return preferred.id
        }

        if let preferredOrganizationID {
            Logger.warning("선호 Organization ID 미발견(\(preferredOrganizationID)) → 자동 선택으로 대체")
        }

        let selected = await selectAutomaticOrganization(organizations, sessionKey: sessionKey) ?? organizations[0]
        Logger.info("Organization ID 선택: \(selected.id) (총 \(organizations.count)개)")
        cachedOrganizationID = selected.id
        lastResolvedSessionOrganization = selected
        await rememberActiveOrganization(selected)
        return selected.id
    }

    private func rememberActiveOrganization(_ organization: OrganizationSummary) async {
        guard let activeAccount, activeAccount.kind == .webSession else { return }
        var metadata = await profileMetadataStore.load() ?? ClaudeProfileMetadata()
        metadata.organizationUUID = organization.id
        metadata.lastUpdatedAt = Date()
        await profileMetadataStore.save(metadata)
        accountStore.mergeIdentity(
            ClaudeAccountIdentity(
                organizationName: organization.name,
                organizationID: organization.id
            ),
            for: activeAccount.id
        )
        self.activeAccount = accountStore.activeAccount()
    }

    private func selectAutomaticOrganization(
        _ organizations: [OrganizationSummary],
        sessionKey: String
    ) async -> OrganizationSummary? {
        guard organizations.count > 1 else {
            return organizations.first
        }

        var candidates: [ClaudeAutomaticOrganizationCandidate] = []
        candidates.reserveCapacity(organizations.count)

        for organization in organizations {
            var overage: OverageSpendLimitResponse?
            do {
                overage = try await fetchOverageSpendLimitWithSessionKey(sessionKey, organizationID: organization.id)
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
        if let cooldownError = currentSessionPathCooldownError() {
            Logger.debug("Organization 목록 조회 스킵: 세션키 경로 쿨다운 중(\(cooldownError.localizedDescription))")
            throw cooldownError
        }

        let url = URL(string: "\(baseURL)/organizations")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknownError("Invalid HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let apiError = classifyHTTPError(statusCode: httpResponse.statusCode, data: data, response: httpResponse)
            updateSessionPathCooldownIfNeeded(with: apiError)
            throw apiError
        }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw APIError.parseError
            }

            func firstNonEmptyString(_ values: Any?...) -> String? {
                values.compactMap { $0 as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty })
            }

            let organizations = json.compactMap { org -> OrganizationSummary? in
                guard let uuid = org["uuid"] as? String, !uuid.isEmpty else { return nil }
                let name = firstNonEmptyString(
                    org["name"],
                    org["display_name"],
                    org["company_name"])
                let planLabel = firstNonEmptyString(
                    org["plan"],
                    org["plan_label"],
                    org["planLabel"],
                    org["subscription_type"],
                    org["subscriptionType"])
                let billingType = firstNonEmptyString(org["billing_type"], org["billingType"])
                let rateLimitTier = firstNonEmptyString(org["rate_limit_tier"], org["rateLimitTier"])
                return OrganizationSummary(
                    id: uuid,
                    name: name,
                    planLabel: planLabel,
                    billingType: billingType,
                    rateLimitTier: rateLimitTier
                )
            }

            if organizations.isEmpty {
                Logger.error("Organization ID를 찾을 수 없음")
            } else {
                saveCachedOrganizations(organizations)
            }
            return organizations
        } catch let apiError as APIError {
            throw apiError
        } catch {
            Logger.error("Organization JSON 파싱 실패: \(error)")
            throw APIError.parseError
        }
    }

    private func saveCachedOrganizations(_ organizations: [OrganizationSummary]) {
        guard !organizations.isEmpty else { return }
        let cache = OrganizationCache(
            savedAt: Date(),
            organizations: organizations,
            sessionFingerprint: currentSessionFingerprint()
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: organizationCacheDefaultsKey())
    }

    private func loadCachedOrganizations() -> [OrganizationSummary]? {
        guard let data = UserDefaults.standard.data(forKey: organizationCacheDefaultsKey()),
              let cache = try? JSONDecoder().decode(OrganizationCache.self, from: data) else {
            return nil
        }

        let age = Date().timeIntervalSince(cache.savedAt)
        guard age <= organizationCacheTTL else { return nil }

        guard let cachedFingerprint = cache.sessionFingerprint else {
            // 과거 버전 캐시는 세션 식별자가 없어 계정 전환 시 오염 가능성이 있으므로 무시
            return nil
        }

        guard let currentFingerprint = currentSessionFingerprint(),
              currentFingerprint == cachedFingerprint else {
            Logger.debug("캐시된 Organization 목록 무시: 세션 변경 감지")
            return nil
        }

        return cache.organizations
    }

    private func clearCachedOrganizations() {
        UserDefaults.standard.removeObject(forKey: organizationCacheDefaultsKey())
    }

    private func organizationCacheDefaultsKey() -> String {
        guard let accountID = activeAccount?.id else {
            return "\(Self.organizationCacheDefaultsKeyPrefix).ephemeral"
        }
        return "\(Self.organizationCacheDefaultsKeyPrefix).\(accountID)"
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

    /// 재시도 로직을 포함한 사용량 가져오기
    func fetchUsageWithRetry(maxAttempts: Int = 3) async throws -> ClaudeUsageResponse {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await fetchUsage()

            } catch {
                // 인증 에러는 재시도 없이 즉시 throw
                if let apiError = error as? APIError, apiError.isDefinitiveAuthFailure {
                    throw apiError
                }

                // 제한/차단류는 같은 사이클 재시도로 더 악화될 수 있어 즉시 종료
                if let apiError = error as? APIError {
                    switch apiError {
                    case .rateLimited(_), .cloudflareBlocked(_):
                        throw apiError
                    case .invalidSessionKey, .networkError, .parseError, .serverError, .unknownError:
                        break
                    }
                }

                lastError = error
                Logger.warning("시도 \(attempt)/\(maxAttempts) 실패: \(error.localizedDescription)")

                if attempt < maxAttempts {
                    let delay = retryDelayNanoseconds(for: error, attempt: attempt)
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }

        throw lastError ?? APIError.unknownError("모든 재시도 실패")
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
            throw APIError.unknownError("보조 사용량 복구가 비활성화되어 있습니다")
        }

        let manualPolicy = ClaudeMessagesHeaderFallbackPolicy(
            isEnabled: true,
            allowAutomaticFallback: true,
            minimumUsagePercent: 0)
        let usage = try await fetchUsageViaMessagesFallback(
            accessToken: accessToken,
            policy: manualPolicy,
            currentUsagePercent: nil)
        rememberSuccessfulUsage(usage, source: .messagesHeaderFallback)
        return usage
    }

    private func retryDelayNanoseconds(for error: Error, attempt: Int) -> UInt64 {
        let cappedAttempt = max(1, attempt)
        let seconds: Double

        if let apiError = error as? APIError {
            switch apiError {
            case .rateLimited(let retryAfter):
                if let retryAfter {
                    seconds = Double(max(5, min(retryAfter, 300)))
                } else {
                    seconds = min(60, 6 * pow(1.8, Double(cappedAttempt - 1)))
                }
            case .cloudflareBlocked(let retryAfter):
                if let retryAfter {
                    seconds = Double(max(5, min(retryAfter, 300)))
                } else {
                    seconds = min(75, 8 * pow(1.8, Double(cappedAttempt - 1)))
                }
            default:
                seconds = pow(2.0, Double(cappedAttempt - 1))
            }
        } else {
            seconds = pow(2.0, Double(cappedAttempt - 1))
        }

        return UInt64(seconds * 1_000_000_000)
    }

    private func classifyHTTPError(statusCode: Int, data: Data?, response: HTTPURLResponse?) -> APIError {
        let retryAfter = retryAfterSeconds(from: response)
        if statusCode == 429 {
            return .rateLimited(retryAfter: retryAfter)
        }

        if statusCode == 401 {
            return .invalidSessionKey
        }

        if statusCode == 403 {
            if isLikelyCloudflareChallenge(data) {
                return .cloudflareBlocked(retryAfter: retryAfter)
            }
            return .invalidSessionKey
        }

        return .serverError(statusCode)
    }

    private func retryAfterSeconds(from response: HTTPURLResponse?) -> Int? {
        guard let response, let header = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty else {
            return nil
        }

        if let seconds = Int(header), seconds > 0 {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let retryAt = formatter.date(from: header) else {
            return nil
        }

        let remaining = Int(ceil(retryAt.timeIntervalSinceNow))
        return remaining > 0 ? remaining : nil
    }

    private func updateSessionPathCooldownIfNeeded(with error: APIError) {
        switch error {
        case .rateLimited(let retryAfter):
            applySessionPathCooldown(kind: .rateLimited, retryAfter: retryAfter)
        case .cloudflareBlocked(let retryAfter):
            applySessionPathCooldown(kind: .cloudflareBlocked, retryAfter: retryAfter)
        default:
            break
        }
    }

    private enum SessionPathCooldownKind {
        case rateLimited
        case cloudflareBlocked
    }

    private func applySessionPathCooldown(kind: SessionPathCooldownKind, retryAfter: Int?) {
        sessionPathLimitStrike += 1

        let baseSeconds: Double
        switch kind {
        case .rateLimited:
            baseSeconds = 30
        case .cloudflareBlocked:
            baseSeconds = 45
        }

        let calculated = min(300, baseSeconds * pow(1.7, Double(max(0, sessionPathLimitStrike - 1))))
        let finalSeconds = Int(max(Double(retryAfter ?? 0), calculated))
        sessionPathCooldownUntil = Date().addingTimeInterval(Double(finalSeconds))

        switch kind {
        case .rateLimited:
            sessionPathCooldownReason = .rateLimited(retryAfter: finalSeconds)
        case .cloudflareBlocked:
            sessionPathCooldownReason = .cloudflareBlocked(retryAfter: finalSeconds)
        }

        Logger.warning("세션키 경로 백오프 적용: \(finalSeconds)초 (연속 제한 \(sessionPathLimitStrike)회)")
    }

    private func currentSessionPathCooldownError() -> APIError? {
        guard let until = sessionPathCooldownUntil else { return nil }

        let remaining = Int(ceil(until.timeIntervalSinceNow))
        if remaining <= 0 {
            sessionPathCooldownUntil = nil
            sessionPathCooldownReason = nil
            return nil
        }

        switch sessionPathCooldownReason {
        case .cloudflareBlocked(_):
            return .cloudflareBlocked(retryAfter: remaining)
        case .rateLimited(_):
            return .rateLimited(retryAfter: remaining)
        default:
            return .rateLimited(retryAfter: remaining)
        }
    }

    private func resetSessionPathCooldown() {
        sessionPathCooldownUntil = nil
        sessionPathCooldownReason = nil
        sessionPathLimitStrike = 0
    }

    private func isLikelyCloudflareChallenge(_ data: Data?) -> Bool {
        guard let data, let body = String(data: data, encoding: .utf8)?.lowercased() else {
            return false
        }

        return body.contains("just a moment") ||
               body.contains("cloudflare") ||
               body.contains("cf-ray") ||
               body.contains("attention required")
    }

    private func data(for originalRequest: URLRequest) async throws -> (Data, URLResponse) {
        var request = originalRequest
        request.timeoutInterval = requestTimeout

        do {
            return try await URLSession.shared.data(for: request)
        } catch let urlError as URLError {
            if urlError.code == .timedOut {
                throw APIError.networkError("요청 시간 초과 (\(Int(requestTimeout))초)")
            }
            throw APIError.networkError(urlError.localizedDescription)
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }
    }

    private func fetchUsageViaOAuth() async throws -> ClaudeUsageResponse {
        guard let accessToken = try await readSystemOAuthAccessToken() else {
            let apiError = APIError.unknownError("Claude Code OAuth 토큰을 찾을 수 없습니다")
            recordPathFailure(.oauth, error: apiError)
            throw apiError
        }
        return try await fetchUsageViaOAuth(accessToken: accessToken)
    }

    private func fetchUsageViaOAuth(accessToken: String) async throws -> ClaudeUsageResponse {
        recordPathAttempt(.oauth)

        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            let apiError = APIError.unknownError("OAuth usage endpoint URL 생성 실패")
            recordPathFailure(.oauth, error: apiError)
            throw apiError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.1.5", forHTTPHeaderField: "User-Agent")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            let apiError = APIError.unknownError("Invalid OAuth HTTP response")
            recordPathFailure(.oauth, error: apiError)
            throw apiError
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let apiError = classifyHTTPError(statusCode: httpResponse.statusCode, data: data, response: httpResponse)
            recordPathFailure(.oauth, error: apiError)
            throw apiError
        }

        do {
            let decoder = JSONDecoder()
            let usage = try decoder.decode(ClaudeUsageResponse.self, from: data)
            recordPathSuccess(.oauth)
            return usage
        } catch {
            let apiError = APIError.parseError
            recordPathFailure(.oauth, error: apiError)
            throw apiError
        }
    }

    private func readSystemOAuthAccessToken() async throws -> String? {
        try await oauthCredentialReader.readAccessToken()
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

    private func rememberSuccessfulUsage(_ usage: ClaudeUsageResponse, source: ClaudeUsageSource) {
        lastKnownUsagePercent = usage.fiveHourPercentage
        if source != .messagesHeaderFallback {
            lastSuccessfulUsageSource = source
        }
        markActiveAccountVerified()
        recordOverallUsageSuccess()
    }

    private func markActiveAccountVerified() {
        guard usesStoredActiveAccount, let activeAccount else { return }
        accountStore.updateValidationState(.verified, for: activeAccount.id)
        self.activeAccount = accountStore.activeAccount()
    }

    private func markActiveAccountValidationFailed() {
        guard usesStoredActiveAccount, let activeAccount else { return }
        accountStore.updateValidationState(.failed, for: activeAccount.id)
        self.activeAccount = accountStore.activeAccount()
    }

    private func recordOverallUsageSuccess() {
        authPathHealthStore.lastOverallSuccessAt = Date()
        persistAuthPathHealthStore()
    }

    private func recordPathAttempt(_ path: AuthFetchPath) {
        updateAuthPathState(path) { state in
            state.lastAttemptAt = Date()
            state.totalAttempts += 1
        }
    }

    private func recordPathSuccess(_ path: AuthFetchPath) {
        updateAuthPathState(path) { state in
            state.lastSuccessAt = Date()
            state.lastErrorMessage = nil
            state.consecutiveFailures = 0
        }
    }

    private func recordPathFailure(_ path: AuthFetchPath, error: APIError) {
        recordPathFailure(path, message: error.localizedDescription)
    }

    private func recordPathFailure(_ path: AuthFetchPath, message: String) {
        updateAuthPathState(path) { state in
            state.lastFailureAt = Date()
            state.lastErrorMessage = message
            state.consecutiveFailures += 1
            state.totalFailures += 1
        }
    }

    private func makeAuthPathSnapshot(for path: AuthFetchPath) -> AuthPathHealthSnapshot {
        let state = authPathState(for: path)
        return AuthPathHealthSnapshot(
            lastAttemptAt: state.lastAttemptAt,
            lastSuccessAt: state.lastSuccessAt,
            lastFailureAt: state.lastFailureAt,
            lastErrorMessage: state.lastErrorMessage,
            consecutiveFailures: state.consecutiveFailures,
            totalAttempts: state.totalAttempts,
            totalFailures: state.totalFailures
        )
    }

    private func makeRuntimeAuthSnapshot(oauthCredentialAvailable: Bool) -> RuntimeAuthSnapshot {
        let now = Date()
        let hasSessionCredential = activeAccount?.kind == .webSession && hasSessionKey()
        let hasOAuthCredential = activeAccount?.kind == .claudeCodeExternal && oauthCredentialAvailable
        let credentialAvailability = ClaudeCredentialAvailability(
            sessionCredentialAvailable: hasSessionCredential,
            oauthCredentialAvailable: hasOAuthCredential || oauthCredentialAvailable
        )
        let sessionCooldownRemaining: Int? = {
            guard let until = sessionPathCooldownUntil else { return nil }
            let remaining = Int(ceil(until.timeIntervalSince(now)))
            return remaining > 0 ? remaining : nil
        }()
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
            sessionValidationState: validationState(for: .session, credentialAvailable: hasSessionCredential),
            oauthValidationState: stableClaudeCodeValidationState(credentialAvailable: oauthCredentialAvailable),
            sessionCooldownRemaining: sessionCooldownRemaining,
            oauthPreferredRemaining: oauthPreferredRemaining
        )
    }

    private func stableClaudeCodeValidationState(
        credentialAvailable: Bool
    ) -> ClaudeCredentialValidationState {
        let measured = validationState(for: .oauth, credentialAvailable: credentialAvailable)
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

    private func validationState(
        for path: AuthFetchPath,
        credentialAvailable: Bool
    ) -> ClaudeCredentialValidationState {
        guard credentialAvailable else { return .unavailable }

        let state = authPathState(for: path)
        if let lastFailureAt = state.lastFailureAt,
           state.lastSuccessAt.map({ lastFailureAt > $0 }) ?? true {
            return .failed
        }

        if state.lastSuccessAt != nil {
            return .verified
        }

        return .detected
    }

    private func authPathState(for path: AuthFetchPath) -> AuthPathHealthState {
        switch path {
        case .session:
            return authPathHealthStore.session
        case .oauth:
            return authPathHealthStore.oauth
        }
    }

    private func updateAuthPathState(_ path: AuthFetchPath, update: (inout AuthPathHealthState) -> Void) {
        switch path {
        case .session:
            update(&authPathHealthStore.session)
        case .oauth:
            update(&authPathHealthStore.oauth)
        }
        persistAuthPathHealthStore()
    }

    private func persistAuthPathHealthStore() {
        guard let data = try? JSONEncoder().encode(authPathHealthStore) else { return }
        UserDefaults.standard.set(data, forKey: authPathHealthDefaultsKey())
    }

    private func authPathHealthDefaultsKey() -> String {
        Self.authPathHealthDefaultsKey(for: activeAccount?.id)
    }

    private static func loadAuthPathHealthStore(for accountID: String?) -> AuthPathHealthStore {
        guard let data = UserDefaults.standard.data(forKey: Self.authPathHealthDefaultsKey(for: accountID)),
              let decoded = try? JSONDecoder().decode(AuthPathHealthStore.self, from: data) else {
            return AuthPathHealthStore()
        }
        return decoded
    }

    private static func authPathHealthDefaultsKey(for accountID: String?) -> String {
        guard let accountID else {
            return "\(Self.authPathHealthDefaultsKeyPrefix).ephemeral"
        }
        return "\(Self.authPathHealthDefaultsKeyPrefix).\(accountID)"
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
