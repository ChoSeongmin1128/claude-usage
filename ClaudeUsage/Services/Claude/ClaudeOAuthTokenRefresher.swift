import Foundation

/// `Claude Code` OAuth access token 의 refresh token 갱신을 담당.
///
/// 책임 분리 원칙:
///   - 자격 증명 조회/저장 → `ClaudeCodeCredentialReader`
///   - 갱신 절차 (HTTP, cooldown, in-flight dedup, terminal disposition) → 본 actor
///   - 사용량 호출 → `ClaudeAPIService.fetchUsageViaOAuth`
///
/// 동시 요청 중복 방지: 진행 중인 `inFlight` Task 가 있으면 그 결과를 공유한다.
/// (예: 401 retry 와 init 시 readCredential 이 동시에 refresh 를 트리거해도 1회만 호출)
///
/// Cooldown: transient 실패(네트워크, 5xx) 시 `cooldownInterval` 동안 차단.
///
/// Terminal disposition: `invalid_grant` 오류는 refresh 자체가 불가능한 상태이므로
/// 더 이상 시도하지 않는다 — 사용자가 `claude` 로 재로그인해야 함을 의미.
actor ClaudeOAuthTokenRefresher {
    typealias HTTPRunner = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum RefreshError: Error, Equatable, LocalizedError {
        /// 서버가 `invalid_grant` 로 거부 — 사용자 재로그인 필요. 더 시도하지 않음.
        case invalidGrant
        /// 일시적 실패. cooldown 만료 후 재시도 가능.
        case temporary(String)
        /// refresh token 자체가 없거나 비어 있음.
        case missingRefreshToken
        /// 응답이 JSON 디코딩 실패 등 비정상.
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .invalidGrant:
                return "Claude OAuth refresh가 거부되었습니다. claude 로그인을 다시 진행해 주세요."
            case .temporary(let detail):
                return "Claude OAuth refresh 일시 실패: \(detail)"
            case .missingRefreshToken:
                return "Refresh token을 찾지 못했습니다."
            case .invalidResponse(let detail):
                return "Refresh 응답이 올바르지 않습니다: \(detail)"
            }
        }
    }

    /// 공식 Claude Code CLI 가 사용하는 PKCE 클라이언트 ID. 비밀이 아닌 공개 식별자.
    /// Anthropic 가 변경할 경우 `CLAUDEUSAGE_OAUTH_CLIENT_ID` 환경 변수로 override 가능.
    private static let defaultClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let environmentClientIDKey = "CLAUDEUSAGE_OAUTH_CLIENT_ID"
    private static let endpointURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    private let httpRunner: HTTPRunner
    private let clientIDOverride: String?
    private let cooldownInterval: TimeInterval
    private let now: @Sendable () -> Date

    private var inFlight: Task<ClaudeCodeOAuthCredential, Error>?
    private var cooldownUntil: Date?
    private var terminalFailureRecorded: Bool = false

    init(
        httpRunner: @escaping HTTPRunner = { request in
            try await URLSession.shared.data(for: request)
        },
        clientIDOverride: String? = nil,
        cooldownInterval: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.httpRunner = httpRunner
        self.clientIDOverride = clientIDOverride
        self.cooldownInterval = cooldownInterval
        self.now = now
    }

    /// 주어진 credential 을 refresh 한다.
    /// - in-flight 중복 호출은 같은 Task 결과를 공유한다.
    /// - cooldown / terminal 상태면 즉시 throw.
    func refresh(_ credential: ClaudeCodeOAuthCredential) async throws -> ClaudeCodeOAuthCredential {
        if terminalFailureRecorded {
            throw RefreshError.invalidGrant
        }
        if let cooldownUntil, now() < cooldownUntil {
            let remaining = Int(cooldownUntil.timeIntervalSince(now()))
            throw RefreshError.temporary("cooldown 잔여 \(remaining)s")
        }
        guard let refreshToken = credential.refreshToken,
              !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw RefreshError.missingRefreshToken
        }

        if let inFlight {
            return try await inFlight.value
        }

        let task = Task<ClaudeCodeOAuthCredential, Error> {
            try await self.performRefresh(refreshToken: refreshToken)
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// 테스트/긴급 복구용 — cooldown 과 terminal 상태를 모두 해제한다.
    func resetState() {
        cooldownUntil = nil
        terminalFailureRecorded = false
    }

    /// 외부에서 cooldown/terminal 여부를 확인할 수 있게 expose. 디버그/UI 용.
    func currentBlockReason() -> RefreshError? {
        if terminalFailureRecorded {
            return .invalidGrant
        }
        if let cooldownUntil, now() < cooldownUntil {
            let remaining = Int(cooldownUntil.timeIntervalSince(now()))
            return .temporary("cooldown 잔여 \(remaining)s")
        }
        return nil
    }

    // MARK: - Internal

    private func performRefresh(refreshToken: String) async throws -> ClaudeCodeOAuthCredential {
        var request = URLRequest(url: Self.endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: resolvedClientID())
        ]
        request.httpBody = (components.percentEncodedQuery ?? "").data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpRunner(request)
        } catch {
            scheduleCooldown()
            throw RefreshError.temporary("네트워크: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            scheduleCooldown()
            throw RefreshError.invalidResponse("HTTPURLResponse 아님")
        }

        if http.statusCode != 200 {
            if Self.containsInvalidGrant(in: data) {
                terminalFailureRecorded = true
                Logger.warning("Claude OAuth refresh 거부 (invalid_grant) — 재로그인 필요")
                throw RefreshError.invalidGrant
            }
            scheduleCooldown()
            Logger.warning("Claude OAuth refresh 실패 HTTP \(http.statusCode)")
            throw RefreshError.temporary("HTTP \(http.statusCode)")
        }

        struct TokenResponse: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Int?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }

        let decoded: TokenResponse
        do {
            decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw RefreshError.invalidResponse("디코딩 실패: \(error.localizedDescription)")
        }

        let expiresAt: Date? = decoded.expiresIn.map { now().addingTimeInterval(TimeInterval($0)) }
        Logger.info("Claude OAuth refresh 성공 (다음 만료까지 \(decoded.expiresIn.map(String.init) ?? "?")s)")
        return ClaudeCodeOAuthCredential(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken ?? refreshToken,
            expiresAt: expiresAt,
            source: .refreshed)
    }

    private func resolvedClientID() -> String {
        if let override = clientIDOverride, !override.isEmpty {
            return override
        }
        if let fromEnv = ProcessInfo.processInfo.environment[Self.environmentClientIDKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fromEnv.isEmpty
        {
            return fromEnv
        }
        return Self.defaultClientID
    }

    private func scheduleCooldown() {
        cooldownUntil = now().addingTimeInterval(cooldownInterval)
    }

    private static func containsInvalidGrant(in data: Data) -> Bool {
        guard let body = String(data: data, encoding: .utf8) else { return false }
        // 응답 본문에 OAuth 표준 error 코드 "invalid_grant" 가 포함되어 있는지 검사.
        // CodexBar 와 동일한 휴리스틱. 정확한 JSON 파싱은 비표준 응답까지 커버하려고 안 한다.
        return body.lowercased().contains("invalid_grant")
    }
}
