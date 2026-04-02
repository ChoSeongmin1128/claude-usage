import Foundation

actor GeminiAPIService {
    private enum GeminiAuthType: String {
        case oauthPersonal = "oauth-personal"
        case apiKey = "api-key"
        case vertexAI = "vertex-ai"
        case unknown
    }

    private struct OAuthCredentials {
        let accessToken: String?
        let idToken: String?
        let refreshToken: String?
        let expiryDate: Date?
    }

    private struct OAuthClientCredentials {
        let clientID: String
        let clientSecret: String
    }

    private struct TokenClaims {
        let email: String?
        let hostedDomain: String?
    }

    private struct QuotaBucket: Decodable {
        let remainingFraction: Double?
        let resetTime: String?
        let modelId: String?
    }

    private struct QuotaResponse: Decodable {
        let buckets: [QuotaBucket]?
    }

    private let quotaEndpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    private let tokenRefreshEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private let requestTimeout: TimeInterval = 20

    func fetchUsage() async throws -> GeminiUsageResponse {
        let authType = currentAuthType()
        switch authType {
        case .oauthPersonal, .unknown:
            break
        case .apiKey, .vertexAI:
            throw APIError.invalidSessionKey
        }

        let credentials = try loadCredentials()
        var accessToken = credentials.accessToken
        if let expiryDate = credentials.expiryDate, expiryDate <= Date() {
            guard let refreshToken = credentials.refreshToken else {
                throw APIError.invalidSessionKey
            }
            accessToken = try await refreshAccessToken(refreshToken: refreshToken)
        }

        guard let accessToken, !accessToken.isEmpty else {
            throw APIError.invalidSessionKey
        }

        var request = URLRequest(url: quotaEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknownError("Invalid HTTP response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401, 403:
            throw APIError.invalidSessionKey
        default:
            throw APIError.serverError(httpResponse.statusCode)
        }

        let claims = extractClaims(from: credentials.idToken)
        do {
            return try parseUsage(data, claims: claims)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.parseError
        }
    }

    func fetchUsageWithRetry(maxAttempts: Int = 3) async throws -> GeminiUsageResponse {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await fetchUsage()
            } catch let error as APIError {
                if error.isDefinitiveAuthFailure {
                    throw error
                }
                lastError = error
                if attempt < maxAttempts {
                    let delay = UInt64(pow(2.0, Double(attempt - 1)) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: delay)
                }
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    let delay = UInt64(pow(2.0, Double(attempt - 1)) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }

        if let apiError = lastError as? APIError {
            throw apiError
        }
        throw APIError.unknownError(lastError?.localizedDescription ?? "Gemini 사용량 조회 실패")
    }

    private func currentAuthType() -> GeminiAuthType {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/settings.json")

        guard
            let data = try? Data(contentsOf: settingsURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let security = json["security"] as? [String: Any],
            let auth = security["auth"] as? [String: Any],
            let selectedType = auth["selectedType"] as? String
        else {
            return .unknown
        }

        return GeminiAuthType(rawValue: selectedType) ?? .unknown
    }

    private func loadCredentials() throws -> OAuthCredentials {
        let credsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/oauth_creds.json")
        guard FileManager.default.fileExists(atPath: credsURL.path) else {
            throw APIError.invalidSessionKey
        }

        let data = try Data(contentsOf: credsURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.parseError
        }

        let accessToken = json["access_token"] as? String
        let idToken = json["id_token"] as? String
        let refreshToken = json["refresh_token"] as? String
        let expiryDate: Date?
        if let expiryMs = json["expiry_date"] as? Double {
            expiryDate = Date(timeIntervalSince1970: expiryMs / 1000)
        } else if let expiryMs = json["expiry_date"] as? Int {
            expiryDate = Date(timeIntervalSince1970: Double(expiryMs) / 1000)
        } else {
            expiryDate = nil
        }

        return OAuthCredentials(
            accessToken: accessToken,
            idToken: idToken,
            refreshToken: refreshToken,
            expiryDate: expiryDate
        )
    }

    private func refreshAccessToken(refreshToken: String) async throws -> String {
        guard let client = extractOAuthClientCredentials() else {
            throw APIError.unknownError("Gemini OAuth client 설정을 찾지 못했습니다")
        }

        var request = URLRequest(url: tokenRefreshEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id": client.clientID,
            "client_secret": client.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknownError("Invalid refresh response")
        }
        guard httpResponse.statusCode == 200 else {
            throw APIError.invalidSessionKey
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let newAccessToken = json["access_token"] as? String
        else {
            throw APIError.parseError
        }

        try updateStoredCredentials(refreshResponse: json)
        return newAccessToken
    }

    private func updateStoredCredentials(refreshResponse: [String: Any]) throws {
        let credsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/oauth_creds.json")
        guard
            let existingData = try? Data(contentsOf: credsURL),
            var json = try JSONSerialization.jsonObject(with: existingData) as? [String: Any]
        else {
            return
        }

        if let accessToken = refreshResponse["access_token"] {
            json["access_token"] = accessToken
        }
        if let idToken = refreshResponse["id_token"] {
            json["id_token"] = idToken
        }
        if let expiresIn = refreshResponse["expires_in"] as? Double {
            json["expiry_date"] = (Date().timeIntervalSince1970 + expiresIn) * 1000
        } else if let expiresIn = refreshResponse["expires_in"] as? Int {
            json["expiry_date"] = (Date().timeIntervalSince1970 + Double(expiresIn)) * 1000
        }

        let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try updatedData.write(to: credsURL, options: .atomic)
    }

    private func extractOAuthClientCredentials() -> OAuthClientCredentials? {
        let candidates = geminiOAuthConfigCandidates()
        for candidate in candidates {
            guard let content = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
            if let credentials = parseOAuthClientCredentials(from: content) {
                return credentials
            }
        }
        return nil
    }

    private func geminiOAuthConfigCandidates() -> [URL] {
        guard let binaryURL = resolvedGeminiBinaryURL() else { return [] }
        let realURL = binaryURL.resolvingSymlinksInPath()
        let baseDir = realURL.deletingLastPathComponent().deletingLastPathComponent()

        return [
            baseDir.appendingPathComponent("libexec/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"),
            baseDir.appendingPathComponent("lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"),
            baseDir.appendingPathComponent("share/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"),
            baseDir.appendingPathComponent("../gemini-cli-core/dist/src/code_assist/oauth2.js"),
            baseDir.appendingPathComponent("node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"),
        ]
    }

    private func resolvedGeminiBinaryURL() -> URL? {
        let envPaths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let fallbackPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let candidates = Array(Set(envPaths + fallbackPaths))
        let fm = FileManager.default

        for path in candidates {
            let url = URL(fileURLWithPath: path).appendingPathComponent("gemini")
            if fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func parseOAuthClientCredentials(from content: String) -> OAuthClientCredentials? {
        let clientIDPattern = #"OAUTH_CLIENT_ID\s*=\s*['"]([\w\-\.]+)['"]\s*;"#
        let secretPattern = #"OAUTH_CLIENT_SECRET\s*=\s*['"]([\w\-]+)['"]\s*;"#

        guard
            let clientRegex = try? NSRegularExpression(pattern: clientIDPattern),
            let secretRegex = try? NSRegularExpression(pattern: secretPattern)
        else {
            return nil
        }

        let range = NSRange(content.startIndex..., in: content)
        guard
            let clientMatch = clientRegex.firstMatch(in: content, range: range),
            let clientRange = Range(clientMatch.range(at: 1), in: content),
            let secretMatch = secretRegex.firstMatch(in: content, range: range),
            let secretRange = Range(secretMatch.range(at: 1), in: content)
        else {
            return nil
        }

        return OAuthClientCredentials(
            clientID: String(content[clientRange]),
            clientSecret: String(content[secretRange])
        )
    }

    private func extractClaims(from idToken: String?) -> TokenClaims {
        guard let idToken else { return TokenClaims(email: nil, hostedDomain: nil) }
        let segments = idToken.components(separatedBy: ".")
        guard segments.count >= 2 else { return TokenClaims(email: nil, hostedDomain: nil) }

        var payload = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard
            let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return TokenClaims(email: nil, hostedDomain: nil)
        }

        return TokenClaims(
            email: json["email"] as? String,
            hostedDomain: json["hd"] as? String
        )
    }

    private func parseUsage(_ data: Data, claims: TokenClaims) throws -> GeminiUsageResponse {
        let response = try JSONDecoder().decode(QuotaResponse.self, from: data)
        guard let buckets = response.buckets, !buckets.isEmpty else {
            throw APIError.parseError
        }

        var quotaByModel: [String: (remaining: Double, resetTime: String?)] = [:]
        for bucket in buckets {
            guard let modelID = bucket.modelId, let remaining = bucket.remainingFraction else { continue }
            if let existing = quotaByModel[modelID] {
                if remaining < existing.remaining {
                    quotaByModel[modelID] = (remaining, bucket.resetTime)
                }
            } else {
                quotaByModel[modelID] = (remaining, bucket.resetTime)
            }
        }

        let quotas = quotaByModel
            .map { modelID, info in
                GeminiUsageWindow(
                    label: windowLabel(for: modelID),
                    modelID: modelID,
                    usedPercent: clampUsedPercent(fromRemainingFraction: info.remaining),
                    resetAtISO: normalizeISODate(info.resetTime)
                )
            }
            .sorted { $0.modelID < $1.modelID }

        let primary = quotas.first(where: { isProModel(id: $0.modelID) }) ?? quotas.first
        let secondary = quotas.first(where: { isFlashModel(id: $0.modelID) }) ?? quotas.dropFirst().first
        let tertiary = quotas.first(where: { isFlashLiteModel(id: $0.modelID) })

        let accountPlan: String? = {
            if claims.hostedDomain?.isEmpty == false {
                return "Workspace"
            }
            return "OAuth"
        }()

        return GeminiUsageResponse(
            accountEmail: claims.email,
            accountPlan: accountPlan,
            primaryWindow: primary,
            secondaryWindow: secondary,
            tertiaryWindow: tertiary
        )
    }

    private func clampUsedPercent(fromRemainingFraction remainingFraction: Double) -> Double {
        let used = (1.0 - remainingFraction) * 100.0
        return min(max(used, 0), 100)
    }

    private func normalizeISODate(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return formatter.string(from: date)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) {
            return formatter.string(from: date)
        }
        return raw
    }

    private func windowLabel(for modelID: String) -> String {
        if isFlashLiteModel(id: modelID) {
            return "Flash Lite"
        }
        if isFlashModel(id: modelID) {
            return "Flash"
        }
        if isProModel(id: modelID) {
            return "Pro"
        }
        return modelID
    }

    private func isFlashLiteModel(id: String) -> Bool {
        id.lowercased().contains("flash-lite")
    }

    private func isFlashModel(id: String) -> Bool {
        let lowered = id.lowercased()
        return lowered.contains("flash") && !lowered.contains("flash-lite")
    }

    private func isProModel(id: String) -> Bool {
        id.lowercased().contains("pro")
    }
}
