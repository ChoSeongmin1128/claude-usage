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

        var displayName: String {
            if let name, !name.isEmpty {
                return "\(name) (\(id))"
            }
            return id
        }
    }

    struct OrganizationPreview: Sendable, Equatable, Identifiable {
        let organization: OrganizationSummary
        let fiveHourPercentage: Double?
        let weeklyPercentage: Double?
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
        let sessionCooldownRemaining: Int?
        let oauthPreferredRemaining: Int?
    }

    struct UsageHealthSnapshot: Sendable, Equatable {
        let lastOverallSuccessAt: Date?
        let session: AuthPathHealthSnapshot
        let oauth: AuthPathHealthSnapshot
        let runtime: RuntimeAuthSnapshot
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
    private let baseURL = "https://claude.ai/api"
    private var cachedOrganizationID: String?
    private var preferredOrganizationID: String?
    private var preferOAuthUntil: Date?
    private let oauthPreferDuration: TimeInterval = 10 * 60
    private var sessionPathCooldownUntil: Date?
    private var sessionPathCooldownReason: APIError?
    private var sessionPathLimitStrike = 0
    private let requestTimeout: TimeInterval = 20
    private var discoveredCLIServiceNames: [String] = []
    private var didDiscoverCLIServiceNames = false
    private let organizationCacheDefaultsKey = "ClaudeUsage.cachedOrganizations.v1"
    private let organizationCacheTTL: TimeInterval = 7 * 24 * 60 * 60
    private static let authPathHealthDefaultsKey = "ClaudeUsage.authPathHealth.v1"
    private var authPathHealthStore = ClaudeAPIService.loadAuthPathHealthStore()

    private struct OrganizationCache: Codable {
        let savedAt: Date
        let organizations: [OrganizationSummary]
        let sessionFingerprint: String?
    }

    // MARK: - Init

    /// Keychain에서 자동으로 세션 키를 로드하는 기본 생성자
    init() {
        self.sessionKey = KeychainManager.shared.load()
    }

    /// 특정 세션 키로 초기화 (연결 테스트용)
    init(sessionKey: String) {
        self.sessionKey = sessionKey
    }

    // MARK: - Session Key Management

    /// 세션 키 업데이트 (Keychain 저장 후 호출)
    func updateSessionKey(_ key: String) {
        self.sessionKey = key
        self.cachedOrganizationID = nil  // 캐시 초기화
        self.preferOAuthUntil = nil
        self.sessionPathCooldownUntil = nil
        self.sessionPathCooldownReason = nil
        self.sessionPathLimitStrike = 0
    }

    /// 런타임 세션 키 초기화 (로그아웃 시 호출)
    func clearSession() {
        self.sessionKey = nil
        self.cachedOrganizationID = nil
        self.preferOAuthUntil = nil
        self.sessionPathCooldownUntil = nil
        self.sessionPathCooldownReason = nil
        self.sessionPathLimitStrike = 0
    }

    func updatePreferredOrganizationID(_ id: String) {
        let normalized = Self.normalizeOrganizationID(id)
        if preferredOrganizationID == normalized {
            return
        }
        preferredOrganizationID = normalized
        cachedOrganizationID = nil
        Logger.info("선호 Organization ID 업데이트: \(normalized ?? "자동 선택")")
    }

    /// 세션 키가 설정되어 있는지 확인
    func hasSessionKey() -> Bool {
        guard let key = sessionKey else { return false }
        return !key.isEmpty
    }

    func fetchUsageHealthSnapshot() -> UsageHealthSnapshot {
        UsageHealthSnapshot(
            lastOverallSuccessAt: authPathHealthStore.lastOverallSuccessAt,
            session: makeAuthPathSnapshot(for: .session),
            oauth: makeAuthPathSnapshot(for: .oauth),
            runtime: makeRuntimeAuthSnapshot()
        )
    }

    // MARK: - Public API

    /// 사용량 데이터 가져오기
    func fetchUsage() async throws -> ClaudeUsageResponse {
        Logger.info("사용량 데이터 요청 시작")
        var sessionPathError: APIError?
        let normalizedSessionKey: String? = {
            guard let sessionKey, !sessionKey.isEmpty else { return nil }
            return sessionKey
        }()
        let sessionCooldownError = normalizedSessionKey != nil ? currentSessionPathCooldownError() : nil

        // 세션키가 없거나 쿨다운 중일 때만 OAuth 우선 모드를 강제한다.
        // 세션키가 정상이라면 항상 세션키를 먼저 시도한다.
        if shouldPreferOAuthNow(), normalizedSessionKey == nil || sessionCooldownError != nil {
            do {
                let usage = try await fetchUsageViaOAuth()
                recordOverallUsageSuccess()
                Logger.debug("OAuth 우선 경로 사용 중")
                return usage
            } catch {
                // 우선 경로가 실패하면 즉시 해제하고 세션 키 경로로 복귀
                preferOAuthUntil = nil
                Logger.warning("OAuth 우선 경로 실패 → 세션키 경로로 복귀: \(error.localizedDescription)")
            }
        }

        if let sessionKey = normalizedSessionKey {
            if let cooldownError = sessionCooldownError {
                sessionPathError = cooldownError
                Logger.warning("세션키 경로 쿨다운 중(\(cooldownError.localizedDescription)) → OAuth 경로 시도")
            } else {
                do {
                    let usage = try await fetchUsageWithSessionKey(sessionKey)
                    preferOAuthUntil = nil
                    resetSessionPathCooldown()
                    recordOverallUsageSuccess()
                    return usage
                } catch let apiError as APIError {
                    sessionPathError = apiError
                    Logger.warning("세션키 경로 실패: \(apiError.localizedDescription)")
                } catch {
                    sessionPathError = .unknownError(error.localizedDescription)
                    Logger.warning("세션키 경로 실패: \(error.localizedDescription)")
                }
            }
        } else {
            sessionPathError = .invalidSessionKey
            Logger.warning("세션 키 없음 → OAuth 경로 시도")
        }

        do {
            Logger.info("OAuth 경로 시도 시작")
            let usage = try await fetchUsageViaOAuth()
            if let sessionPathError, shouldPreferOAuthAfter(error: sessionPathError) {
                let duration = oauthPreferDuration(after: sessionPathError)
                preferOAuthUntil = Date().addingTimeInterval(duration)
            }
            if let sessionPathError {
                Logger.warning("세션키 경로 실패(\(sessionPathError.localizedDescription)) → OAuth 경로 성공")
            }
            recordOverallUsageSuccess()
            return usage
        } catch {
            Logger.warning("OAuth 경로 실패: \(error.localizedDescription)")
            if let sessionPathError {
                throw sessionPathError
            }
            throw APIError.invalidSessionKey
        }
    }

    /// 현재 세션 키 기준 organization 목록 조회 (설정 UI 용도)
    func fetchOrganizations() async throws -> [OrganizationSummary] {
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
        guard let sessionKey, !sessionKey.isEmpty else {
            throw APIError.invalidSessionKey
        }

        let organizations = try await fetchOrganizations()
        return await fetchOrganizationPreviews(for: organizations, maxOrganizations: maxOrganizations, sessionKey: sessionKey)
    }

    /// 전달된 organization 목록 기준으로 미리보기 조회 (목록/상세 분리 로딩용)
    func fetchOrganizationPreviews(for organizations: [OrganizationSummary], maxOrganizations: Int = 8) async -> [OrganizationPreview] {
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
        var oauthFallbackUsage: ClaudeUsageResponse?

        for organization in targets {
            var usage: ClaudeUsageResponse?
            var usageErrorMessage: String?
            do {
                usage = try await fetchUsageWithSessionKey(sessionKey, organizationID: organization.id)
            } catch let apiError as APIError {
                // 임시 장애 시 OAuth usage를 1회 조회해 최소 비교 정보는 유지
                if apiError.isTemporaryFailure {
                    if oauthFallbackUsage == nil {
                        oauthFallbackUsage = try? await fetchUsageViaOAuth()
                    }
                    if let oauthFallbackUsage {
                        usage = oauthFallbackUsage
                        usageErrorMessage = "세션 제한으로 OAuth 기준 값을 표시 중"
                    } else {
                        usageErrorMessage = apiError.localizedDescription
                    }
                } else {
                    usageErrorMessage = apiError.localizedDescription
                }
            } catch {
                usageErrorMessage = error.localizedDescription
            }

            previews.append(
                OrganizationPreview(
                    organization: organization,
                    fiveHourPercentage: usage?.fiveHour.utilization,
                    weeklyPercentage: usage?.sevenDay?.utilization,
                    overageUsed: nil,
                    overageLimit: nil,
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
        guard let sessionKey = sessionKey, !sessionKey.isEmpty else {
            throw APIError.invalidSessionKey
        }

        if shouldPreferOAuthNow() {
            let remaining = max(1, Int(ceil((preferOAuthUntil ?? Date()).timeIntervalSinceNow)))
            Logger.debug("추가 사용량 조회 스킵: OAuth 우선 경로 유지 중(\(remaining)초)")
            throw APIError.rateLimited(retryAfter: remaining)
        }

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
                return OverageSpendLimitResponse(
                    monthlyCreditLimitCents: 0,
                    usedCreditsCents: 0,
                    isEnabled: false,
                    outOfCredits: false,
                    currency: "USD"
                )
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
            return preferred.id
        }

        if let preferredOrganizationID {
            Logger.warning("선호 Organization ID 미발견(\(preferredOrganizationID)) → 첫 organization으로 대체")
        }

        let selected = organizations[0]
        Logger.info("Organization ID 선택: \(selected.id) (총 \(organizations.count)개)")
        cachedOrganizationID = selected.id
        return selected.id
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

            let organizations = json.compactMap { org -> OrganizationSummary? in
                guard let uuid = org["uuid"] as? String, !uuid.isEmpty else { return nil }
                let name = (org["name"] as? String) ??
                           (org["display_name"] as? String) ??
                           (org["company_name"] as? String)
                return OrganizationSummary(id: uuid, name: name)
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
        UserDefaults.standard.set(data, forKey: organizationCacheDefaultsKey)
    }

    private func loadCachedOrganizations() -> [OrganizationSummary]? {
        guard let data = UserDefaults.standard.data(forKey: organizationCacheDefaultsKey),
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

    private func shouldPreferOAuthNow() -> Bool {
        guard let until = preferOAuthUntil else { return false }
        return until > Date()
    }

    private func shouldPreferOAuthAfter(error: APIError) -> Bool {
        switch error {
        case .rateLimited(_), .cloudflareBlocked(_):
            return true
        case .networkError, .serverError, .invalidSessionKey, .parseError, .unknownError:
            return false
        }
    }

    private func oauthPreferDuration(after error: APIError) -> TimeInterval {
        switch error {
        case .rateLimited(let retryAfter):
            return max(oauthPreferDuration, TimeInterval(max(0, retryAfter ?? 0)))
        case .cloudflareBlocked(let retryAfter):
            return max(oauthPreferDuration, TimeInterval(max(0, retryAfter ?? 0)))
        case .networkError, .serverError, .invalidSessionKey, .parseError, .unknownError:
            return oauthPreferDuration
        }
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
        recordPathAttempt(.oauth)

        guard let accessToken = try readSystemOAuthAccessToken() else {
            let apiError = APIError.unknownError("Claude Code OAuth 토큰을 찾을 수 없습니다")
            recordPathFailure(.oauth, error: apiError)
            throw apiError
        }

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

    private func readSystemOAuthAccessToken() throws -> String? {
        // 1) 키체인 기본 서비스 먼저 시도 (대부분 케이스)
        let primaryService = "Claude Code-credentials"
        if let credentials = try readKeychainCredentialPayload(serviceName: primaryService),
           let token = parseOAuthAccessToken(from: credentials) {
            Logger.info("OAuth 토큰 조회 성공 (키체인 서비스: \(primaryService))")
            return token
        }

        // 2) 파일 fallback: 키체인 접근이 제한된 환경 대비
        if let token = readOAuthAccessTokenFromCredentialFiles() {
            return token
        }

        // 3) 기본 서비스/파일 실패 시에만 hashed 서비스 탐색
        let discoveredServices = getDiscoveredCLIServiceNames().filter { $0 != primaryService }
        if !discoveredServices.isEmpty {
            Logger.debug("OAuth 토큰 조회: 추가 키체인 서비스 \(discoveredServices.count)개 후보")
        }
        for service in discoveredServices {
            guard let credentials = try readKeychainCredentialPayload(serviceName: service) else { continue }
            if let token = parseOAuthAccessToken(from: credentials) {
                Logger.info("OAuth 토큰 조회 성공 (키체인 서비스: \(service))")
                return token
            }
        }

        Logger.warning("OAuth 토큰 조회 실패 (파일/키체인 모두 실패)")
        return nil
    }

    private func readKeychainCredentialPayload(serviceName: String) throws -> String? {
        guard let result = try runSecurityCommand(
            arguments: [
            "find-generic-password",
            "-s", serviceName,
            "-a", NSUserName(),
            "-w"
            ],
            timeout: 2.5
        ) else {
            Logger.warning("키체인 조회 타임아웃(service: \(serviceName))")
            return nil
        }

        let exitCode = result.status
        if exitCode == 44 {
            return nil
        }

        guard exitCode == 0 else {
            let errorMessage = result.stderr.isEmpty ? "unknown error" : result.stderr
            throw APIError.unknownError("시스템 키체인 오류(code: \(exitCode), service: \(serviceName)): \(errorMessage)")
        }

        let credentials = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credentials.isEmpty else {
            return nil
        }

        return credentials
    }

    private func getDiscoveredCLIServiceNames() -> [String] {
        if didDiscoverCLIServiceNames {
            return discoveredCLIServiceNames
        }
        didDiscoverCLIServiceNames = true
        discoveredCLIServiceNames = discoverClaudeCredentialServiceNames()
        return discoveredCLIServiceNames
    }

    private func discoverClaudeCredentialServiceNames() -> [String] {
        guard let result = try? runSecurityCommand(arguments: ["dump-keychain"], timeout: 1.0) else {
            Logger.debug("키체인 서비스 탐색 타임아웃")
            return []
        }

        guard result.status == 0, !result.stdout.isEmpty else {
            return []
        }

        let output = result.stdout

        let pattern = #""svce"<blob>="(Claude Code-credentials[^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let nsrange = NSRange(output.startIndex..<output.endIndex, in: output)
        let matches = regex.matches(in: output, range: nsrange)
        return matches.compactMap { match in
            guard match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: output) else { return nil }
            return String(output[range])
        }
    }

    private func runSecurityCommand(arguments: [String], timeout: TimeInterval) throws -> (status: Int32, stdout: String, stderr: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw APIError.unknownError("security 실행 실패: \(error.localizedDescription)")
        }

        let startedAt = Date()
        while process.isRunning {
            if Date().timeIntervalSince(startedAt) >= timeout {
                process.terminate()
                process.waitUntilExit()
                return nil
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private func readOAuthAccessTokenFromCredentialFiles() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".claude/.credentials.json"),
            home.appendingPathComponent(".claude/credentials.json")
        ]

        for fileURL in candidates {
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8),
                  !text.isEmpty else { continue }

            if let token = parseOAuthAccessToken(from: text) {
                Logger.info("OAuth 토큰 조회 성공 (파일: \(fileURL.lastPathComponent))")
                return token
            }
        }

        Logger.debug("OAuth 토큰 파일 조회 실패 (~/.claude)")
        return nil
    }

    private func parseOAuthAccessToken(from credentialsText: String) -> String? {
        if let data = credentialsText.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = json["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String,
           !token.isEmpty {
            return token
        }
        // 키체인 JSON이 잘린 경우를 위해 accessToken 정규식 fallback
        return extractAccessTokenByRegex(from: credentialsText)
    }

    private func extractAccessTokenByRegex(from text: String) -> String? {
        let pattern = #""accessToken"\s*:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsrange),
              match.numberOfRanges >= 2,
              let tokenRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let token = String(text[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func currentSessionFingerprint() -> String? {
        guard let sessionKey, !sessionKey.isEmpty else { return nil }
        return Self.computeSessionFingerprint(sessionKey)
    }

    private static func computeSessionFingerprint(_ sessionKey: String) -> String {
        let digest = SHA256.hash(data: Data(sessionKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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

    private func makeRuntimeAuthSnapshot() -> RuntimeAuthSnapshot {
        let now = Date()
        let hasSessionCredential = hasSessionKey()
        let sessionState = authPathState(for: .session)
        let oauthState = authPathState(for: .oauth)
        let sessionCooldownRemaining: Int? = {
            guard let until = sessionPathCooldownUntil else { return nil }
            let remaining = Int(ceil(until.timeIntervalSince(now)))
            return remaining > 0 ? remaining : nil
        }()
        let oauthPreferredRemaining: Int? = {
            guard let until = preferOAuthUntil else { return nil }
            let remaining = Int(ceil(until.timeIntervalSince(now)))
            return remaining > 0 ? remaining : nil
        }()

        let activePath: RuntimeAuthSnapshot.ActivePath = {
            if !hasSessionCredential {
                // 세션 키가 없으면 OAuth 전용 경로가 실질 기본
                if oauthState.lastSuccessAt != nil || oauthState.lastAttemptAt != nil {
                    return .oauthFallback
                }
                return .unauthenticated
            }
            if let oauthPreferredRemaining, oauthPreferredRemaining > 0 {
                return .oauthPreferred
            }
            if let sessionCooldownRemaining, sessionCooldownRemaining > 0 {
                return .oauthFallback
            }
            // 최근 실제 성공 경로가 OAuth면 표기를 OAuth로 유지해 표시와 체감 불일치를 줄인다.
            if let sessionSuccess = sessionState.lastSuccessAt,
               let oauthSuccess = oauthState.lastSuccessAt,
               oauthSuccess > sessionSuccess {
                return .oauthFallback
            }
            return .sessionPrimary
        }()

        return RuntimeAuthSnapshot(
            activePath: activePath,
            sessionCooldownRemaining: sessionCooldownRemaining,
            oauthPreferredRemaining: oauthPreferredRemaining
        )
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
        UserDefaults.standard.set(data, forKey: Self.authPathHealthDefaultsKey)
    }

    private static func loadAuthPathHealthStore() -> AuthPathHealthStore {
        guard let data = UserDefaults.standard.data(forKey: Self.authPathHealthDefaultsKey),
              let decoded = try? JSONDecoder().decode(AuthPathHealthStore.self, from: data) else {
            return AuthPathHealthStore()
        }
        return decoded
    }

    private static func normalizeOrganizationID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
