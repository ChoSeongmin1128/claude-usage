//
//  CodexAuthManager.swift
//  ClaudeUsage
//
//  Codex (ChatGPT) 인증 관리 — ~/.codex/auth.json (OAuth, codex login)
//  참고: https://github.com/steipete/CodexBar
//

import Foundation

/// Codex 인증 토큰
struct CodexAuthToken: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let accountID: String?
    let lastRefresh: Date?
    let expiresAt: Date?
    /// `tokens.expires_at` 또는 access JWT `exp` 처럼 토큰 자체에서 신뢰 가능한 만료 시각을 읽었는지.
    /// 없으면 `last_refresh + N일` 같은 휴리스틱은 가정만이므로 만료 판단을 보류한다.
    /// 사용 패턴: 실제 401 받았을 때만 refresh 시도, 그 외에는 access_token 그대로 사용.
    let expiresAtIsExplicit: Bool

    nonisolated init(
        accessToken: String,
        refreshToken: String? = nil,
        idToken: String? = nil,
        accountID: String? = nil,
        lastRefresh: Date? = nil,
        expiresAt: Date? = nil,
        expiresAtIsExplicit: Bool = false
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountID = accountID
        self.lastRefresh = lastRefresh
        self.expiresAt = expiresAt
        self.expiresAtIsExplicit = expiresAtIsExplicit
    }

    nonisolated var isExpired: Bool {
        // [A] 보수화: 토큰 자체에서 만료 시각을 확인했을 때만 그 시각 기준으로 만료 판단.
        // 토큰 근거가 없으면 우리가 추측(last_refresh + 8일)으로 만료를 단정짓지 않는다.
        // 이유: ChatGPT OAuth access_token 의 실제 수명은 last_refresh 기준 휴리스틱과
        // 다를 수 있고, 사용자의 CLI 가 같은 토큰을 잘 쓰는 한 우리도 그대로 써야 안전하다.
        // 진짜 만료(401) 는 API 호출 시점에 판단한다.
        guard let expiresAt, expiresAtIsExplicit else { return false }
        return Date() >= expiresAt.addingTimeInterval(-300) // 5분 전부터 만료 취급
    }

    nonisolated var hasRefreshToken: Bool {
        guard let refreshToken else { return false }
        return !refreshToken.isEmpty
    }

    nonisolated var isUsableOrRefreshable: Bool {
        !isExpired || hasRefreshToken
    }
}

/// OAuth refresh 결과.
///
/// 종전에는 `CodexAuthToken?` 만 반환했다. 호출자는 `nil` 만으로 "영구 실패(재로그인 필요)"인지
/// "일시 실패(재시도 가능)"인지 구분하지 못해 사용자에게 동일한 "갱신 실패" 메시지만 노출했다.
/// → codex-lb 의 `PERMANENT_FAILURE_CODES` 패턴을 차용해 분기한다.
enum CodexRefreshResult: Sendable {
    case success(CodexAuthToken)
    /// refresh_token 이 영구 무효화. 사용자가 `codex login` 으로 재로그인해야 한다.
    /// 예: `refresh_token_reused`, `refresh_token_expired`, `refresh_token_invalidated`, `invalid_grant`.
    case permanentFailure(reason: String)
    /// 네트워크/일시 서버 오류. 다음 주기에서 재시도하면 회복될 수 있다.
    case transientFailure(reason: String)
}

private struct CodexAuthJSONStore {
    let authJsonPath: String

    var exists: Bool {
        FileManager.default.fileExists(atPath: authJsonPath)
    }

    func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: authJsonPath))?[.modificationDate] as? Date
    }

    func loadToken() -> CodexAuthToken? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authJsonPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Codex CLI 형식: { "tokens": { "access_token": "...", "refresh_token": "...", ... }, "last_refresh": "..." }
        // 레거시 형식: { "access_token": "...", "refresh_token": "..." }
        let tokens: [String: Any]
        if let nested = json["tokens"] as? [String: Any] {
            tokens = nested
        } else {
            tokens = json
        }

        guard let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty else {
            if let apiKey = json["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
                return CodexAuthToken(accessToken: apiKey, refreshToken: nil, expiresAt: nil)
            }
            return nil
        }

        let refreshToken = tokens["refresh_token"] as? String
        let idToken = tokens["id_token"] as? String
        let accountID = (json["account_id"] as? String) ?? (tokens["account_id"] as? String)
        let lastRefresh = Self.parseISODate(json["last_refresh"] as? String)

        // 1순위: auth.json 이 명시한 expires_at.
        // 2순위: access_token 이 JWT 인 경우 payload.exp.
        // 둘 다 없으면 last_refresh 기반 만료 추정은 하지 않는다.
        let explicitExpiresAt = Self.parseExpiresAt(tokens["expires_at"]) ?? Self.jwtExpirationDate(from: accessToken)

        return CodexAuthToken(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountID: accountID,
            lastRefresh: lastRefresh,
            expiresAt: explicitExpiresAt,
            expiresAtIsExplicit: explicitExpiresAt != nil)
    }

    func persist(token: CodexAuthToken) -> Bool {
        let url = URL(fileURLWithPath: authJsonPath)
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        var tokens: [String: Any] = (json["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = token.accessToken
        if let refreshToken = token.refreshToken, !refreshToken.isEmpty {
            tokens["refresh_token"] = refreshToken
        }
        if let idToken = token.idToken, !idToken.isEmpty {
            tokens["id_token"] = idToken
        }
        json["tokens"] = tokens
        if let accountID = token.accountID, !accountID.isEmpty {
            json["account_id"] = accountID
        }
        json["last_refresh"] = Self.isoString(from: token.lastRefresh ?? Date())

        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            Logger.error("Codex auth.json 직렬화 실패 — in-memory 캐시만 유지됨")
            return false
        }

        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            Logger.error("Codex auth.json write-back 실패: \(error.localizedDescription) — in-memory 캐시만 유지됨")
            return false
        }
    }

    private static func parseExpiresAt(_ rawValue: Any?) -> Date? {
        if let expiresAtStr = rawValue as? String {
            return parseISODate(expiresAtStr)
        }
        if let expiresAtTimestamp = rawValue as? Double {
            return Date(timeIntervalSince1970: expiresAtTimestamp)
        }
        if let expiresAtTimestamp = rawValue as? Int {
            return Date(timeIntervalSince1970: TimeInterval(expiresAtTimestamp))
        }
        return nil
    }

    private static func parseISODate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func jwtExpirationDate(from token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = base64URLDecode(String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }

        if let exp = payload["exp"] as? Double {
            return Date(timeIntervalSince1970: exp)
        }
        if let exp = payload["exp"] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(exp))
        }
        return nil
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: padding)
        }
        return Data(base64Encoded: base64)
    }
}

private struct CodexOAuthTokenRefresher {
    let urlSession: URLSession
    let clientID: String

    func refreshAccessToken(using refreshToken: String) async -> CodexRefreshResult {
        let url = URL(string: "https://auth.openai.com/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // CodexBar 와 동일한 페이로드 (`scope` 포함) — 일부 OAuth provider 가 scope 누락 요청을
        // 거부하는 케이스가 있어 안전한 default 로 채워 둔다.
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken,
            "scope": "openid profile email",
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return .transientFailure(reason: "request body serialization failed")
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                Logger.error("Codex 토큰 갱신: 응답이 HTTP 가 아님")
                return .transientFailure(reason: "non-HTTP response")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let errorCode = Self.refreshErrorCode(from: data)
                let codeDescription = errorCode ?? "unknown"
                Logger.error("Codex 토큰 갱신 실패: HTTP \(httpResponse.statusCode) (\(codeDescription))")
                if httpResponse.statusCode == 401 || Self.isPermanentRefreshError(code: errorCode) {
                    return .permanentFailure(reason: codeDescription)
                }
                return .transientFailure(reason: "HTTP \(httpResponse.statusCode) (\(codeDescription))")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String,
                  !accessToken.isEmpty else {
                Logger.error("Codex 토큰 갱신 응답 파싱 실패")
                return .transientFailure(reason: "response parse failure")
            }

            let newRefreshToken = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken
            let newIdToken = json["id_token"] as? String
            let accountID = (json["account_id"] as? String) ?? (json["account_id"] as? Int).map(String.init)
            let expiresIn = (json["expires_in"] as? TimeInterval) ?? 3600
            let now = Date()
            let expiresAt = now.addingTimeInterval(expiresIn)
            return .success(CodexAuthToken(
                accessToken: accessToken,
                refreshToken: newRefreshToken,
                idToken: newIdToken,
                accountID: accountID,
                lastRefresh: now,
                expiresAt: expiresAt,
                expiresAtIsExplicit: true))
        } catch {
            Logger.error("Codex 토큰 갱신 네트워크 에러: \(error.localizedDescription)")
            return .transientFailure(reason: error.localizedDescription)
        }
    }

    /// refresh 응답 본문에서 OAuth 에러 코드를 짧게 추출. 로깅/진단용.
    private static func refreshErrorCode(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let nested = json["error"] as? [String: Any] {
            if let code = nested["code"] as? String { return code }
            if let type = nested["type"] as? String { return type }
            if let message = nested["message"] as? String { return message }
        }
        if let value = json["error"] as? String { return value }
        return nil
    }

    private static let permanentRefreshErrorCodes: Set<String> = [
        "refresh_token_reused",
        "refresh_token_expired",
        "refresh_token_invalidated",
        "refresh_token_revoked",
        "invalid_grant",
        "invalid_client",
        "unauthorized_client",
    ]

    private static func isPermanentRefreshError(code: String?) -> Bool {
        guard let code else { return false }
        return permanentRefreshErrorCodes.contains(code)
    }
}

final class CodexAuthManager {
    static let shared = CodexAuthManager()

    private let refreshTokenClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private let authStore: CodexAuthJSONStore
    private let tokenRefresher: CodexOAuthTokenRefresher

    // MARK: - Thread-safe caches
    //
    // 기존에는 매 isAuthenticated / getToken 호출마다 ~/.codex/auth.json 을
    // Data(contentsOf:) + JSONSerialization 으로 동기 파싱했다. UI body /
    // settings 렌더 사이클에 수 차례 호출되어 main thread 를 낭비하고, 동시에
    // refreshedToken 쓰기 (async refreshAccessToken) 와 읽기 (UI) 간 race 도
    // 있었다. → NSLock + 60s TTL in-memory 캐시 + file mtime 기반 무효화.

    private let lock = NSLock()
    private var refreshedToken: CodexAuthToken?
    private var refreshTask: Task<CodexRefreshResult, Never>?

    private struct CachedAuthJson {
        let token: CodexAuthToken?
        let fileMtime: Date?
        let cachedAt: Date
    }
    private var authJsonCache: CachedAuthJson?
    private static let authJsonCacheTTL: TimeInterval = 60

    private convenience init() {
        self.init(authJsonPath: Self.defaultAuthJsonPath(), urlSession: .shared)
    }

    init(authJsonPath: String, urlSession: URLSession = .shared) {
        self.authStore = CodexAuthJSONStore(authJsonPath: authJsonPath)
        self.tokenRefresher = CodexOAuthTokenRefresher(
            urlSession: urlSession,
            clientID: refreshTokenClientID
        )
        // 이전 웹 로그인 방식의 잔여 데이터 정리
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "codex-auth-token")
        defaults.removeObject(forKey: "codex-device-id")
    }

    private static func defaultAuthJsonPath() -> String {
        let realHome: String
        if let pw = getpwuid(getuid()) {
            realHome = String(cString: pw.pointee.pw_dir)
        } else {
            realHome = NSHomeDirectory()
        }
        return "\(realHome)/.codex/auth.json"
    }

    // MARK: - Token Access

    /// 현재 유효한 액세스 토큰 반환.
    /// 호출 빈도가 높아도 in-memory 캐시 + mtime 체크로 비용이 작다.
    func getToken() -> CodexAuthToken? {
        let refreshed = withCacheLock { refreshedToken }

        // 1순위: 갱신된 토큰 캐시 (미만료)
        if let refreshed, !refreshed.isExpired {
            return refreshed
        }

        // 2순위: auth.json (in-memory cache hit 시 blocking 없음)
        if let authJsonToken = loadAuthJsonToken() {
            return authJsonToken
        }

        // 3순위: 만료된 캐시 토큰 (refresh 시도용)
        return refreshed
    }

    /// auth.json 파일 존재 여부. `FileManager.fileExists` 는 stat 한 번이라 가볍다.
    var authJsonExists: Bool {
        authStore.exists
    }

    /// 인증 상태 확인
    var isAuthenticated: Bool {
        getToken()?.isUsableOrRefreshable == true
    }

    /// 캐시 초기화 (refresh 토큰 캐시 + auth.json 파싱 캐시 모두).
    func clearCache() {
        withCacheLock {
            refreshedToken = nil
            authJsonCache = nil
        }
        Logger.info("Codex 토큰 캐시 초기화")
    }

    // MARK: - Token Refresh

    /// 토큰 갱신.
    ///
    /// **OAuth refresh_token rotation 정책 대응**:
    /// OpenAI 의 OAuth 서버는 한 번 쓴 refresh_token 을 invalidate 한다.
    /// 우리 앱이 새 토큰을 받고도 auth.json 에 write-back 하지 않으면, 다음 부팅 시
    /// 같은 옛 refresh_token 으로 또 호출 → 401 `refresh_token_reused` → expired UI.
    /// 동시에 codex CLI 와도 토큰이 어긋나 CLI 까지 다시 로그인해야 한다.
    /// → 응답 성공 시 새 토큰을 **반드시 auth.json 에 atomic write-back** 한다.
    func refreshAccessToken(using refreshToken: String) async -> CodexRefreshResult {
        if let refreshTask {
            return await refreshTask.value
        }

        let task = Task { [tokenRefresher] in
            await tokenRefresher.refreshAccessToken(using: refreshToken)
        }
        refreshTask = task
        let result = await task.value
        refreshTask = nil

        if case .success(let newToken) = result {
            setRefreshedToken(newToken)
            _ = authStore.persist(token: newToken)
            Logger.info("Codex 토큰 갱신 성공 (auth.json write-back 시도)")
        }
        return result
    }

    /// 요청 전 선제 갱신. 신뢰 가능한 expires_at/JWT exp 가 만료 임박일 때만 refresh 한다.
    func refreshTokenIfNeeded() async -> CodexRefreshResult {
        guard let currentToken = getToken() else {
            return .permanentFailure(reason: "missing_auth_token")
        }
        guard currentToken.isExpired else {
            return .success(currentToken)
        }
        guard let refreshToken = currentToken.refreshToken, !refreshToken.isEmpty else {
            return .permanentFailure(reason: "missing_refresh_token")
        }
        return await refreshAccessToken(using: refreshToken)
    }

    /// Codex usage API 가 401/403 을 반환했을 때의 단일 복구 진입점.
    /// 1) CLI/다른 프로세스가 auth.json 을 이미 갱신했을 수 있으므로 캐시를 우회해 재로드한다.
    /// 2) 같은 토큰이면 refresh_token 으로 1회 갱신한다.
    /// 3) 성공한 토큰만 호출자가 사용량 요청을 1회 재시도한다. 여기서는 API retry loop 를 돌리지 않는다.
    func recoverFromUnauthorized(failedAccessToken: String?) async -> CodexRefreshResult {
        let reloadedToken = loadAuthJsonToken(forceReload: true)
        if let reloadedToken,
           reloadedToken.accessToken != failedAccessToken,
           !reloadedToken.isExpired {
            setRefreshedToken(reloadedToken)
            Logger.info("Codex auth.json 에 새 access token 이 있어 refresh 없이 재시도합니다")
            return .success(reloadedToken)
        }

        guard let candidate = reloadedToken ?? getToken() else {
            return .permanentFailure(reason: "missing_auth_token")
        }
        guard let refreshToken = candidate.refreshToken, !refreshToken.isEmpty else {
            return .permanentFailure(reason: "missing_refresh_token")
        }
        return await refreshAccessToken(using: refreshToken)
    }

    // MARK: - Private

    /// auth.json 파싱 결과 반환. mtime 이 동일하면서 캐시 TTL 안쪽이면 파싱 skip.
    /// 외부에서 CLI 로 로그인 / 로그아웃 하면 mtime 이 바뀌므로 즉시 반영됨.
    private func loadAuthJsonToken(forceReload: Bool = false) -> CodexAuthToken? {
        let currentMtime = authStore.modificationDate()
        let now = Date()

        if !forceReload, let cache = withCacheLock({ authJsonCache }) {
            let freshEnough = now.timeIntervalSince(cache.cachedAt) < Self.authJsonCacheTTL
            let fileUnchanged = cache.fileMtime == currentMtime
            if freshEnough && fileUnchanged {
                return cache.token
            }
        }

        let parsed = authStore.loadToken()
        withCacheLock {
            authJsonCache = CachedAuthJson(token: parsed, fileMtime: currentMtime, cachedAt: now)
        }
        return parsed
    }

    private func withCacheLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func setRefreshedToken(_ token: CodexAuthToken?) {
        withCacheLock {
            refreshedToken = token
            authJsonCache = nil
        }
    }
}
