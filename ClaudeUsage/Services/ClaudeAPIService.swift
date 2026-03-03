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
    private var preferOAuthUntil: Date?
    private let oauthPreferDuration: TimeInterval = 10 * 60
    private let requestTimeout: TimeInterval = 20

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
    }

    /// 런타임 세션 키 초기화 (로그아웃 시 호출)
    func clearSession() {
        self.sessionKey = nil
        self.cachedOrganizationID = nil
        self.preferOAuthUntil = nil
    }

    /// 세션 키가 설정되어 있는지 확인
    func hasSessionKey() -> Bool {
        guard let key = sessionKey else { return false }
        return !key.isEmpty
    }

    // MARK: - Public API

    /// 사용량 데이터 가져오기
    func fetchUsage() async throws -> ClaudeUsageResponse {
        Logger.info("사용량 데이터 요청 시작")
        var sessionPathError: APIError?

        if shouldPreferOAuthNow() {
            do {
                let usage = try await fetchUsageViaOAuth()
                Logger.debug("OAuth 우선 경로 사용 중")
                return usage
            } catch {
                // 우선 경로가 실패하면 즉시 해제하고 세션 키 경로로 복귀
                preferOAuthUntil = nil
                Logger.warning("OAuth 우선 경로 실패 → 세션키 경로로 복귀: \(error.localizedDescription)")
            }
        }

        if let sessionKey, !sessionKey.isEmpty {
            do {
                let usage = try await fetchUsageWithSessionKey(sessionKey)
                preferOAuthUntil = nil
                return usage
            } catch let apiError as APIError {
                sessionPathError = apiError
                Logger.warning("세션키 경로 실패: \(apiError.localizedDescription)")
            } catch {
                sessionPathError = .unknownError(error.localizedDescription)
                Logger.warning("세션키 경로 실패: \(error.localizedDescription)")
            }
        } else {
            sessionPathError = .invalidSessionKey
            Logger.warning("세션 키 없음 → OAuth 경로 시도")
        }

        do {
            Logger.info("OAuth 경로 시도 시작")
            let usage = try await fetchUsageViaOAuth()
            if let sessionPathError, shouldPreferOAuthAfter(error: sessionPathError) {
                preferOAuthUntil = Date().addingTimeInterval(oauthPreferDuration)
            }
            if let sessionPathError {
                Logger.warning("세션키 경로 실패(\(sessionPathError.localizedDescription)) → OAuth 경로 성공")
            }
            return usage
        } catch {
            Logger.warning("OAuth 경로 실패: \(error.localizedDescription)")
            if let sessionPathError {
                throw sessionPathError
            }
            throw APIError.invalidSessionKey
        }
    }

    private func fetchUsageWithSessionKey(_ sessionKey: String) async throws -> ClaudeUsageResponse {
        let orgID = try await getOrganizationID()

        let url = URL(string: "\(baseURL)/organizations/\(orgID)/usage")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        Logger.debug("API 요청: \(url.absoluteString)")

        let (data, response) = try await data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            Logger.error("유효하지 않은 응답")
            throw APIError.unknownError("Invalid HTTP response")
        }

        Logger.debug("HTTP 상태 코드: \(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            Logger.error("HTTP 에러: \(httpResponse.statusCode)")
            throw classifyHTTPError(statusCode: httpResponse.statusCode, data: data)
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

        let (data, response) = try await data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknownError("Invalid HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw classifyHTTPError(statusCode: httpResponse.statusCode, data: data)
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

        let (data, response) = try await data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknownError("Invalid HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw classifyHTTPError(statusCode: httpResponse.statusCode, data: data)
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
                if let apiError = error as? APIError, apiError.isDefinitiveAuthFailure {
                    throw apiError
                }

                // 제한/차단류는 같은 사이클 재시도로 더 악화될 수 있어 즉시 종료
                if let apiError = error as? APIError {
                    switch apiError {
                    case .rateLimited, .cloudflareBlocked:
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
            case .rateLimited:
                seconds = min(60, 6 * pow(1.8, Double(cappedAttempt - 1)))
            case .cloudflareBlocked:
                seconds = min(75, 8 * pow(1.8, Double(cappedAttempt - 1)))
            default:
                seconds = pow(2.0, Double(cappedAttempt - 1))
            }
        } else {
            seconds = pow(2.0, Double(cappedAttempt - 1))
        }

        return UInt64(seconds * 1_000_000_000)
    }

    private func classifyHTTPError(statusCode: Int, data: Data?) -> APIError {
        if statusCode == 429 {
            return .rateLimited
        }

        if statusCode == 401 {
            return .invalidSessionKey
        }

        if statusCode == 403 {
            if isLikelyCloudflareChallenge(data) {
                return .cloudflareBlocked
            }
            return .invalidSessionKey
        }

        return .serverError(statusCode)
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
        case .rateLimited, .cloudflareBlocked:
            return true
        case .networkError, .serverError, .invalidSessionKey, .parseError, .unknownError:
            return false
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
        guard let accessToken = try readSystemOAuthAccessToken() else {
            throw APIError.unknownError("Claude Code OAuth 토큰을 찾을 수 없습니다")
        }

        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw APIError.unknownError("OAuth usage endpoint URL 생성 실패")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.1.5", forHTTPHeaderField: "User-Agent")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknownError("Invalid OAuth HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.serverError(httpResponse.statusCode)
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(ClaudeUsageResponse.self, from: data)
        } catch {
            throw APIError.parseError
        }
    }

    private func readSystemOAuthAccessToken() throws -> String? {
        // 1) 키체인: legacy + hashed service 이름 모두 시도
        var serviceNames: [String] = ["Claude Code-credentials"]
        serviceNames.append(contentsOf: discoverClaudeCredentialServiceNames())
        serviceNames = Array(NSOrderedSet(array: serviceNames).compactMap { $0 as? String })
        Logger.debug("OAuth 토큰 조회: 키체인 서비스 \(serviceNames.count)개 후보")

        for service in serviceNames {
            guard let credentials = try readKeychainCredentialPayload(serviceName: service) else { continue }
            if let token = parseOAuthAccessToken(from: credentials) {
                Logger.info("OAuth 토큰 조회 성공 (키체인 서비스: \(service))")
                return token
            }
        }

        // 2) 키체인이 잘리거나 누락된 경우 파일 fallback
        Logger.warning("키체인 OAuth 토큰 조회 실패 → 파일 fallback 시도")
        return readOAuthAccessTokenFromCredentialFiles()
    }

    private func readKeychainCredentialPayload(serviceName: String) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", serviceName,
            "-a", NSUserName(),
            "-w"
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw APIError.unknownError("시스템 키체인에서 OAuth 토큰 조회 실패: \(error.localizedDescription)")
        }

        let exitCode = process.terminationStatus
        if exitCode == 44 {
            return nil
        }

        guard exitCode == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "unknown error"
            throw APIError.unknownError("시스템 키체인 오류(code: \(exitCode), service: \(serviceName)): \(errorMessage)")
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let credentials = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !credentials.isEmpty else {
            return nil
        }

        return credentials
    }

    private func discoverClaudeCredentialServiceNames() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["dump-keychain"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard process.terminationStatus == 0,
              let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
              !output.isEmpty else {
            return []
        }

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

        Logger.warning("OAuth 토큰 조회 실패 (키체인/파일 모두 실패)")
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
}
