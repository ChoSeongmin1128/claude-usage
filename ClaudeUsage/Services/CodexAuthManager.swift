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
    let expiresAt: Date?

    nonisolated var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
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

final class CodexAuthManager {
    static let shared = CodexAuthManager()

    private let refreshTokenClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    /// 실제 홈 디렉토리 (샌드박스 컨테이너가 아닌 /Users/xxx)
    private let authJsonPath: String = {
        let realHome: String
        if let pw = getpwuid(getuid()) {
            realHome = String(cString: pw.pointee.pw_dir)
        } else {
            realHome = NSHomeDirectory()
        }
        return "\(realHome)/.codex/auth.json"
    }()

    // MARK: - Thread-safe caches
    //
    // 기존에는 매 isAuthenticated / getToken 호출마다 ~/.codex/auth.json 을
    // Data(contentsOf:) + JSONSerialization 으로 동기 파싱했다. UI body /
    // settings 렌더 사이클에 수 차례 호출되어 main thread 를 낭비하고, 동시에
    // refreshedToken 쓰기 (async refreshAccessToken) 와 읽기 (UI) 간 race 도
    // 있었다. → NSLock + 60s TTL in-memory 캐시 + file mtime 기반 무효화.

    private let lock = NSLock()
    private var refreshedToken: CodexAuthToken?

    private struct CachedAuthJson {
        let token: CodexAuthToken?
        let fileMtime: Date?
        let cachedAt: Date
    }
    private var authJsonCache: CachedAuthJson?
    private static let authJsonCacheTTL: TimeInterval = 60

    private init() {
        // 이전 웹 로그인 방식의 잔여 데이터 정리
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "codex-auth-token")
        defaults.removeObject(forKey: "codex-device-id")
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
        FileManager.default.fileExists(atPath: authJsonPath)
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
    func refreshAccessToken(using refreshToken: String) async -> CodexAuthToken? {
        let url = URL(string: "https://auth.openai.com/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // CodexBar 와 동일한 페이로드 (`scope` 포함) — 일부 OAuth provider 가 scope 누락 요청을
        // 거부하는 케이스가 있어 안전한 default 로 채워 둔다.
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": refreshTokenClientID,
            "refresh_token": refreshToken,
            "scope": "openid profile email",
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                Logger.error("Codex 토큰 갱신: 응답이 HTTP 가 아님")
                return nil
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                // 사용자 안내 메시지에 도움이 되도록 에러 코드를 상세히 로깅한다.
                let codeDescription = Self.refreshErrorCode(from: data) ?? "unknown"
                Logger.error("Codex 토큰 갱신 실패: HTTP \(httpResponse.statusCode) (\(codeDescription))")
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String,
                  !accessToken.isEmpty
            else {
                Logger.error("Codex 토큰 갱신 응답 파싱 실패")
                return nil
            }

            // 서버가 새 refresh_token 을 안 주면 기존 값을 유지 (CodexBar 와 동일).
            let newRefreshToken = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken
            let newIdToken = json["id_token"] as? String
            let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
            let expiresAt = Date().addingTimeInterval(expiresIn)

            let newToken = CodexAuthToken(accessToken: accessToken, refreshToken: newRefreshToken, expiresAt: expiresAt)
            // 1) in-memory cache 갱신 + 파싱 캐시 무효화
            setRefreshedToken(newToken)
            // 2) 영구 저장: 다음 부팅에서도 새 refresh_token 사용 → reused 에러 방지
            //    write 실패해도 in-memory 캐시는 살아있어 현재 세션은 정상.
            persistRefreshedTokenToAuthJson(
                accessToken: accessToken,
                refreshToken: newRefreshToken,
                idToken: newIdToken
            )
            Logger.info("Codex 토큰 갱신 성공 (auth.json write-back 시도)")
            return newToken
        } catch {
            Logger.error("Codex 토큰 갱신 네트워크 에러: \(error.localizedDescription)")
            return nil
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

    /// 새 토큰을 `~/.codex/auth.json` 에 atomic write-back.
    /// CLI 가 이미 auth.json 을 가지고 있는 환경에서도 race 를 최소화하려고
    /// (a) 기존 JSON 을 읽어 tokens / last_refresh 만 교체 (b) 임시 파일에 쓴 뒤 rename.
    /// FileManager 의 `.atomic` 옵션이 macOS 에서 rename 기반이라 안전하다.
    private func persistRefreshedTokenToAuthJson(
        accessToken: String,
        refreshToken: String,
        idToken: String?
    ) {
        let url = URL(fileURLWithPath: authJsonPath)
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            json = existing
        }

        var tokens: [String: Any] = (json["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = accessToken
        tokens["refresh_token"] = refreshToken
        if let idToken, !idToken.isEmpty {
            tokens["id_token"] = idToken
        }
        json["tokens"] = tokens

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        json["last_refresh"] = isoFormatter.string(from: Date())

        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            Logger.error("Codex auth.json 직렬화 실패 — in-memory 캐시만 유지됨")
            return
        }

        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            Logger.error("Codex auth.json write-back 실패: \(error.localizedDescription) — in-memory 캐시만 유지됨")
        }
    }

    // MARK: - Private

    /// auth.json 파싱 결과 반환. mtime 이 동일하면서 캐시 TTL 안쪽이면 파싱 skip.
    /// 외부에서 CLI 로 로그인 / 로그아웃 하면 mtime 이 바뀌므로 즉시 반영됨.
    private func loadAuthJsonToken() -> CodexAuthToken? {
        let currentMtime = fileModificationDate(atPath: authJsonPath)
        let now = Date()

        if let cache = withCacheLock({ authJsonCache }) {
            let freshEnough = now.timeIntervalSince(cache.cachedAt) < Self.authJsonCacheTTL
            let fileUnchanged = cache.fileMtime == currentMtime
            if freshEnough && fileUnchanged {
                return cache.token
            }
        }

        let parsed = parseAuthJson()
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

    private func fileModificationDate(atPath path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func parseAuthJson() -> CodexAuthToken? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authJsonPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // CodexBar 형식: { "tokens": { "access_token": "...", "refresh_token": "...", ... }, "last_refresh": "..." }
        // 레거시 형식: { "access_token": "...", "refresh_token": "..." }
        let tokens: [String: Any]
        if let nested = json["tokens"] as? [String: Any] {
            tokens = nested
        } else {
            tokens = json
        }

        guard let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty else {
            // 레거시: OPENAI_API_KEY
            if let apiKey = json["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
                return CodexAuthToken(accessToken: apiKey, refreshToken: nil, expiresAt: nil)
            }
            return nil
        }

        let refreshToken = tokens["refresh_token"] as? String

        // expiresAt: last_refresh 기반 (8일) 또는 expires_at 직접 지정
        var expiresAt: Date?
        if let lastRefreshStr = json["last_refresh"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let lastRefresh = formatter.date(from: lastRefreshStr) {
                expiresAt = lastRefresh.addingTimeInterval(8 * 24 * 60 * 60) // 8일
            } else {
                formatter.formatOptions = [.withInternetDateTime]
                if let lastRefresh = formatter.date(from: lastRefreshStr) {
                    expiresAt = lastRefresh.addingTimeInterval(8 * 24 * 60 * 60)
                }
            }
        } else if let expiresAtStr = tokens["expires_at"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expiresAt = formatter.date(from: expiresAtStr)
            if expiresAt == nil {
                formatter.formatOptions = [.withInternetDateTime]
                expiresAt = formatter.date(from: expiresAtStr)
            }
        } else if let expiresAtTimestamp = tokens["expires_at"] as? Double {
            expiresAt = Date(timeIntervalSince1970: expiresAtTimestamp)
        }

        return CodexAuthToken(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
    }
}
