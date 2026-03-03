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
    private var sessionPathCooldownUntil: Date?
    private var sessionPathCooldownReason: APIError?
    private var sessionPathLimitStrike = 0
    private let requestTimeout: TimeInterval = 20
    private var discoveredCLIServiceNames: [String] = []
    private var didDiscoverCLIServiceNames = false

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
            if let cooldownError = currentSessionPathCooldownError() {
                sessionPathError = cooldownError
                Logger.warning("세션키 경로 쿨다운 중(\(cooldownError.localizedDescription)) → OAuth 경로 시도")
            } else {
                do {
                    let usage = try await fetchUsageWithSessionKey(sessionKey)
                    preferOAuthUntil = nil
                    resetSessionPathCooldown()
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
            let apiError = classifyHTTPError(statusCode: httpResponse.statusCode, data: data, response: httpResponse)
            updateSessionPathCooldownIfNeeded(with: apiError)
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
            let apiError = classifyHTTPError(statusCode: httpResponse.statusCode, data: data, response: httpResponse)
            throw apiError
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
            let apiError = classifyHTTPError(statusCode: httpResponse.statusCode, data: data, response: httpResponse)
            updateSessionPathCooldownIfNeeded(with: apiError)
            throw apiError
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
            throw classifyHTTPError(statusCode: httpResponse.statusCode, data: data, response: httpResponse)
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(ClaudeUsageResponse.self, from: data)
        } catch {
            throw APIError.parseError
        }
    }

    private func readSystemOAuthAccessToken() throws -> String? {
        // 1) 파일 우선: 키체인 블로킹 이슈를 피하고 최신 CLI 자격증명을 빠르게 반영
        if let token = readOAuthAccessTokenFromCredentialFiles() {
            return token
        }

        // 2) 키체인 기본 서비스 먼저 시도 (대부분 케이스)
        let primaryService = "Claude Code-credentials"
        if let credentials = try readKeychainCredentialPayload(serviceName: primaryService),
           let token = parseOAuthAccessToken(from: credentials) {
            Logger.info("OAuth 토큰 조회 성공 (키체인 서비스: \(primaryService))")
            return token
        }

        // 3) 기본 서비스 실패 시에만 hashed 서비스 탐색
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
}
