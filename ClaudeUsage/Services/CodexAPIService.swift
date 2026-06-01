//
//  CodexAPIService.swift
//  ClaudeUsage
//
//  Codex (ChatGPT) API 서비스 — OAuth 토큰 기반 (CodexBar 방식)
//  참고: https://github.com/steipete/CodexBar
//

import Foundation

/// Codex (ChatGPT) API 서비스
actor CodexAPIService {
    // MARK: - Properties

    private var accessToken: String?
    private let baseURL: URL
    private let urlSession: URLSession
    private let authManager: CodexAuthManager

    init(
        baseURL: URL = URL(string: "https://chatgpt.com/backend-api")!,
        urlSession: URLSession = .shared,
        authManager: CodexAuthManager
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.authManager = authManager
    }

    // MARK: - Token Management

    /// 토큰 업데이트
    func updateToken(_ token: String) {
        self.accessToken = token
    }

    /// 현재 토큰 갱신 시도.
    ///
    /// - Returns: 토큰을 사용할 수 있는 상태가 됐는지 (`true`), 일시 실패 (`false`).
    /// - Throws: `APIError.codexReauthRequired` — refresh_token 이 영구 무효화돼 재로그인 필요.
    func refreshTokenIfNeeded() async throws -> Bool {
        let result = await authManager.refreshTokenIfNeeded()
        switch result {
        case .success(let token):
            self.accessToken = token.accessToken
            return true
        case .permanentFailure(let reason):
            throw APIError.codexReauthRequired(reason: reason)
        case .transientFailure(let reason):
            Logger.warning("Codex 토큰 선제 갱신 일시 실패: \(reason)")
            return false
        }
    }

    // MARK: - Public API

    /// 사용량 데이터 가져오기 (OAuth Bearer 토큰, CodexBar 방식)
    func fetchUsage() async throws -> CodexUsageResponse {
        // 토큰 갱신 확인. permanent 실패는 refreshTokenIfNeeded 가 .codexReauthRequired throw.
        let storedToken = await authManager.getToken()
        if let token = storedToken, token.isExpired {
            let refreshed = try await refreshTokenIfNeeded()
            if !refreshed {
                throw APIError.codexTokenRefreshTemporary(reason: "expired_access_token")
            }
        }

        // accessToken이 없으면 storedToken에서 가져오기
        if accessToken == nil, let token = storedToken {
            accessToken = token.accessToken
        }

        guard let accessToken = accessToken, !accessToken.isEmpty else {
            throw APIError.invalidSessionKey
        }

        Logger.info("Codex 사용량 데이터 요청 시작")

        do {
            return try await performUsageRequest(accessToken: accessToken)
        } catch APIError.invalidSessionKey {
            return try await recoverFromUnauthorizedAndRetry(failedAccessToken: accessToken)
        }
    }

    private func performUsageRequest(accessToken: String) async throws -> CodexUsageResponse {
        let url = baseURL.appendingPathComponent("wham/usage")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        // CodexBar 방식: 최소한의 헤더 (브라우저 흉내 안 함)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("ClaudeUsage", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        Logger.debug("Codex API 요청: \(url.absoluteString)")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknownError("Invalid HTTP response")
        }

        Logger.debug("Codex HTTP 상태 코드: \(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw APIError.invalidSessionKey
            } else {
                throw APIError.serverError(httpResponse.statusCode)
            }
        }

        if let jsonString = String(data: data, encoding: .utf8) {
            Logger.debug("Codex Raw JSON: \(String(jsonString.prefix(500)))")
        }

        do {
            let usageResponse = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            Logger.info("Codex 사용량 수신 성공: primary=\(usageResponse.rateLimit?.primaryWindow?.usedPercent ?? -1) secondary=\(usageResponse.rateLimit?.secondaryWindow?.usedPercent ?? -1)")
            return usageResponse
        } catch {
            Logger.error("Codex JSON 파싱 실패: \(error)")
            throw APIError.parseError
        }
    }

    private func recoverFromUnauthorizedAndRetry(failedAccessToken: String) async throws -> CodexUsageResponse {
        Logger.warning("Codex 사용량 API 인증 실패 — auth.json 재로드/refresh 복구를 시도합니다")
        let recovery = await authManager.recoverFromUnauthorized(failedAccessToken: failedAccessToken)
        switch recovery {
        case .success(let recoveredToken):
            self.accessToken = recoveredToken.accessToken
            do {
                return try await performUsageRequest(accessToken: recoveredToken.accessToken)
            } catch APIError.invalidSessionKey {
                throw APIError.codexReauthRequired(reason: "usage_unauthorized_after_recovery")
            }

        case .permanentFailure(let reason):
            throw APIError.codexReauthRequired(reason: reason)

        case .transientFailure(let reason):
            throw APIError.codexTokenRefreshTemporary(reason: reason)
        }
    }

    /// 재시도 로직을 포함한 사용량 가져오기
    func fetchUsageWithRetry(maxAttempts: Int = 3) async throws -> CodexUsageResponse {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await fetchUsage()
            } catch {
                // 인증 에러(영구) 는 재시도 없이 즉시 throw
                if let apiError = error as? APIError {
                    switch apiError {
                    case .invalidSessionKey, .codexReauthRequired, .codexTokenRefreshTemporary, .permissionDenied:
                        throw error
                    default:
                        break
                    }
                }

                lastError = error
                Logger.warning("Codex 시도 \(attempt)/\(maxAttempts) 실패: \(error.localizedDescription)")

                if attempt < maxAttempts {
                    let delay = UInt64(pow(2.0, Double(attempt - 1)) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }

        throw lastError ?? APIError.unknownError("모든 재시도 실패")
    }
}
