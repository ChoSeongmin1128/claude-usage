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

    /// 사용량 데이터 가져오기.
    /// 1순위: OAuth Bearer 토큰으로 ChatGPT backend `/wham/usage` 호출 (CodexBar 방식)
    /// 2순위(fallback): codex CLI 를 PTY 로 띄워 `/status` 슬래시 명령 캡처 + 파싱
    ///
    /// CLI fallback 이 필요한 이유:
    /// - OAuth refresh_token 이 rotation 으로 reused 되거나 access_token 이 진짜 만료된 경우
    ///   OAuth path 가 어떤 방법으로도 살아나지 못한다. 사용자 CLI 는 자체 토큰 관리로
    ///   계속 동작하므로, 그 CLI 를 활용해 사용량을 가져온다.
    /// - 이 fallback 은 OAuth 가 죽었을 때만 발동하고 정상 path 에서는 영향 없음.
    func fetchUsage() async throws -> CodexUsageResponse {
        do {
            return try await fetchUsageViaOAuth()
        } catch let error as APIError {
            // OAuth path 실패 — CLI fallback 시도 가치가 있는 케이스만 시도.
            // 네트워크 오류 / 서버 오류 / 인증 오류 모두 CLI 로 우회 가능. 파싱 오류도 동일.
            switch error {
            case .invalidSessionKey, .serverError, .networkError, .parseError, .rateLimited, .cloudflareBlocked, .unknownError:
                if let usage = await fetchUsageViaCLI() {
                    Logger.info("Codex OAuth 실패 → CLI fallback 으로 사용량 수신")
                    return usage
                }
                throw error
            }
        } catch {
            if let usage = await fetchUsageViaCLI() {
                Logger.info("Codex OAuth 실패(\(error.localizedDescription)) → CLI fallback 성공")
                return usage
            }
            throw error
        }
    }

    private func fetchUsageViaOAuth() async throws -> CodexUsageResponse {
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

        Logger.info("Codex 사용량 데이터 요청 시작 (OAuth)")

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

    /// CLI fallback. codex 바이너리를 PTY 로 띄워 `/status` 슬래시 명령 응답을 캡처/파싱.
    /// CLI 가 설치 안 됐거나 응답 파싱 실패면 nil → caller 가 원래 에러 throw.
    private func fetchUsageViaCLI() async -> CodexUsageResponse? {
        do {
            let snapshot = try await CodexStatusProbe().fetch()
            return CodexCLIStatusMapper.mapToUsageResponse(snapshot)
        } catch {
            Logger.warning("Codex CLI fallback 실패: \(error.localizedDescription)")
            return nil
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
