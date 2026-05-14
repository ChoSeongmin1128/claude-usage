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
    private let baseURL = "https://chatgpt.com/backend-api"

    // MARK: - Token Management

    /// 토큰 업데이트
    func updateToken(_ token: String) {
        self.accessToken = token
    }

    /// 현재 토큰 갱신 시도
    func refreshTokenIfNeeded() async -> Bool {
        let currentToken = await MainActor.run { CodexAuthManager.shared.getToken() }
        guard let currentToken else { return false }

        if !currentToken.isExpired {
            self.accessToken = currentToken.accessToken
            return true
        }

        guard let refreshToken = currentToken.refreshToken else { return false }

        if let newToken = await CodexAuthManager.shared.refreshAccessToken(using: refreshToken) {
            self.accessToken = newToken.accessToken
            return true
        }

        return false
    }

    // MARK: - Public API

    /// 사용량 데이터 가져오기 (OAuth Bearer 토큰, CodexBar 방식)
    func fetchUsage() async throws -> CodexUsageResponse {
        // 토큰 갱신 확인
        let storedToken = await MainActor.run { CodexAuthManager.shared.getToken() }
        if let token = storedToken, token.isExpired {
            let refreshed = await refreshTokenIfNeeded()
            if !refreshed {
                throw APIError.invalidSessionKey
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

        let url = URL(string: "\(baseURL)/wham/usage")!
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
            (data, response) = try await URLSession.shared.data(for: request)
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

    /// 재시도 로직을 포함한 사용량 가져오기
    func fetchUsageWithRetry(maxAttempts: Int = 3) async throws -> CodexUsageResponse {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await fetchUsage()
            } catch {
                // 인증 에러는 재시도 없이 즉시 throw
                if let apiError = error as? APIError, case .invalidSessionKey = apiError {
                    throw error
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
