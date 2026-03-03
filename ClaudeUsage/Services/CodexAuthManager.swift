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
}

class CodexAuthManager {
    static let shared = CodexAuthManager()

    private let refreshTokenClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    /// 실제 홈 디렉토리 (샌드박스 컨테이너가 아닌 /Users/xxx)
    private let authJsonPath: String = {
        let pw = getpwuid(getuid())!
        let realHome = String(cString: pw.pointee.pw_dir)
        return "\(realHome)/.codex/auth.json"
    }()

    /// 갱신된 토큰 캐시 (auth.json은 읽기 전용, 갱신 결과는 메모리에)
    private var refreshedToken: CodexAuthToken?

    private init() {
        // 이전 웹 로그인 방식의 잔여 데이터 정리
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "codex-auth-token")
        defaults.removeObject(forKey: "codex-device-id")
    }

    // MARK: - Token Access

    /// 현재 유효한 액세스 토큰 반환
    func getToken() -> CodexAuthToken? {
        // 1순위: 갱신된 토큰 캐시 (미만료)
        if let cached = refreshedToken, !cached.isExpired {
            return cached
        }

        // 2순위: auth.json
        if let authJsonToken = loadAuthJsonToken() {
            return authJsonToken
        }

        // 3순위: 만료된 캐시 토큰 (갱신 시도용)
        if let cached = refreshedToken {
            return cached
        }

        return nil
    }

    /// auth.json 파일 존재 여부
    var authJsonExists: Bool {
        FileManager.default.fileExists(atPath: authJsonPath)
    }

    /// 인증 상태 확인
    var isAuthenticated: Bool {
        getToken() != nil
    }

    /// 캐시 초기화
    func clearCache() {
        refreshedToken = nil
        Logger.info("Codex 토큰 캐시 초기화")
    }

    // MARK: - Token Refresh

    /// 토큰 갱신
    func refreshAccessToken(using refreshToken: String) async -> CodexAuthToken? {
        let url = URL(string: "https://auth.openai.com/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": refreshTokenClientID,
            "refresh_token": refreshToken,
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                Logger.error("Codex 토큰 갱신 실패: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                Logger.error("Codex 토큰 갱신 응답 파싱 실패")
                return nil
            }

            let newRefreshToken = json["refresh_token"] as? String ?? refreshToken
            let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
            let expiresAt = Date().addingTimeInterval(expiresIn)

            let newToken = CodexAuthToken(accessToken: accessToken, refreshToken: newRefreshToken, expiresAt: expiresAt)
            refreshedToken = newToken
            Logger.info("Codex 토큰 갱신 성공")
            return newToken
        } catch {
            Logger.error("Codex 토큰 갱신 네트워크 에러: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Private

    private func loadAuthJsonToken() -> CodexAuthToken? {
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
