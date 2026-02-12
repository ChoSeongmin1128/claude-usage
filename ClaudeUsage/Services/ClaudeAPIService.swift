//
//  ClaudeAPIService.swift
//  ClaudeUsage
//
//  Phase 1+3: Claude.ai API 호출 서비스 (Keychain 연동)
//

import Foundation

/// Claude.ai API 서비스 (Thread-Safe Actor)
actor ClaudeAPIService {
    // MARK: - Properties

    private var sessionKey: String?
    private let baseURL = "https://claude.ai/api"
    private var cachedOrganizationID: String?

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
    }

    /// 세션 키가 설정되어 있는지 확인
    func hasSessionKey() -> Bool {
        guard let key = sessionKey else { return false }
        return !key.isEmpty
    }

    // MARK: - Public API

    /// 사용량 데이터 가져오기
    func fetchUsage() async throws -> ClaudeUsageResponse {
        guard let sessionKey = sessionKey, !sessionKey.isEmpty else {
            throw APIError.invalidSessionKey
        }

        Logger.info("사용량 데이터 요청 시작")

        let orgID = try await getOrganizationID()

        let url = URL(string: "\(baseURL)/organizations/\(orgID)/usage")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        Logger.debug("API 요청: \(url.absoluteString)")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            Logger.error("유효하지 않은 응답")
            throw APIError.unknownError("Invalid HTTP response")
        }

        Logger.debug("HTTP 상태 코드: \(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            Logger.error("HTTP 에러: \(httpResponse.statusCode)")

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw APIError.invalidSessionKey
            } else {
                throw APIError.serverError(httpResponse.statusCode)
            }
        }

        // 디버그: raw JSON 출력
        if let jsonString = String(data: data, encoding: .utf8) {
            Logger.debug("Raw JSON 응답: \(jsonString)")
        }

        do {
            let decoder = JSONDecoder()
            let usageResponse = try decoder.decode(ClaudeUsageResponse.self, from: data)

            Logger.info("사용량 데이터 수신 성공: \(usageResponse.fiveHourPercentage)%")
            return usageResponse

        } catch {
            Logger.error("JSON 파싱 실패: \(error)")
            throw APIError.parseError
        }
    }

    /// 추가 사용량(Extra Usage) 정보 가져오기
    func fetchOverageSpendLimit() async throws -> OverageSpendLimitResponse {
        guard let sessionKey = sessionKey, !sessionKey.isEmpty else {
            throw APIError.invalidSessionKey
        }

        let orgID = try await getOrganizationID()

        let url = URL(string: "\(baseURL)/organizations/\(orgID)/overage_spend_limit")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        Logger.debug("Overage API 요청: \(url.absoluteString)")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknownError("Invalid HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw APIError.invalidSessionKey
            } else {
                throw APIError.serverError(httpResponse.statusCode)
            }
        }

        if let jsonString = String(data: data, encoding: .utf8) {
            Logger.debug("Overage Raw JSON: \(jsonString)")
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

        let url = URL(string: "\(baseURL)/organizations")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknownError("Invalid HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw APIError.invalidSessionKey
            } else {
                throw APIError.serverError(httpResponse.statusCode)
            }
        }

        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let firstOrg = json.first,
               let uuid = firstOrg["uuid"] as? String {

                Logger.info("Organization ID 추출 성공: \(uuid)")
                cachedOrganizationID = uuid
                return uuid

            } else {
                Logger.error("Organization ID를 찾을 수 없음")
                throw APIError.parseError
            }

        } catch let apiError as APIError {
            throw apiError
        } catch {
            Logger.error("JSON 파싱 실패: \(error)")
            throw APIError.parseError
        }
    }

    /// 재시도 로직을 포함한 사용량 가져오기
    func fetchUsageWithRetry(maxAttempts: Int = 3) async throws -> ClaudeUsageResponse {
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
                Logger.warning("시도 \(attempt)/\(maxAttempts) 실패: \(error.localizedDescription)")

                if attempt < maxAttempts {
                    let delay = UInt64(pow(2.0, Double(attempt - 1)) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }

        throw lastError ?? APIError.unknownError("모든 재시도 실패")
    }
}
