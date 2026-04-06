import Foundation

actor GeminiAPIService {
    private enum GeminiAuthType: String {
        case oauthPersonal = "oauth-personal"
        case apiKey = "api-key"
        case vertexAI = "vertex-ai"
        case unknown
    }

    private enum GeminiUserTierID: String {
        case free = "free-tier"
        case legacy = "legacy-tier"
        case standard = "standard-tier"
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

    private struct CodeAssistStatus {
        let tier: GeminiUserTierID?
        let projectID: String?

        static let empty = CodeAssistStatus(tier: nil, projectID: nil)
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
    private let loadCodeAssistEndpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private let projectsEndpoint = URL(string: "https://cloudresourcemanager.googleapis.com/v1/projects")!
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
        var accessToken = try await resolvedAccessToken(from: credentials)
        let claims = extractClaims(from: credentials.idToken)
        let codeAssistStatus = await loadCodeAssistStatus(accessToken: accessToken)
        let projectID = try await resolvedProjectID(accessToken: accessToken, codeAssistStatus: codeAssistStatus)

        do {
            let data = try await fetchQuotaData(accessToken: accessToken, projectID: projectID)
            return try parseUsage(data, claims: claims, codeAssistStatus: codeAssistStatus)
        } catch let error as APIError where error.isDefinitiveAuthFailure {
            guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
                throw error
            }
            accessToken = try await refreshAccessToken(refreshToken: refreshToken)
            let refreshedStatus = await loadCodeAssistStatus(accessToken: accessToken)
            let refreshedProjectID = try await resolvedProjectID(accessToken: accessToken, codeAssistStatus: refreshedStatus)
            let data = try await fetchQuotaData(accessToken: accessToken, projectID: refreshedProjectID)
            return try parseUsage(data, claims: claims, codeAssistStatus: refreshedStatus)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.parseError
        }
    }

    private func resolvedAccessToken(from credentials: OAuthCredentials) async throws -> String {
        var accessToken = credentials.accessToken
        if let expiryDate = credentials.expiryDate, expiryDate <= Date() {
            guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
                throw APIError.invalidSessionKey
            }
            accessToken = try await refreshAccessToken(refreshToken: refreshToken)
        }

        guard let accessToken, !accessToken.isEmpty else {
            throw APIError.invalidSessionKey
        }
        return accessToken
    }

    private func resolvedProjectID(accessToken: String, codeAssistStatus: CodeAssistStatus) async throws -> String? {
        if let detectedProjectID = codeAssistStatus.projectID {
            return detectedProjectID
        }
        return try? await discoverGeminiProjectID(accessToken: accessToken)
    }

    private func fetchQuotaData(accessToken: String, projectID: String?) async throws -> Data {
        var request = URLRequest(url: quotaEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let projectID, !projectID.isEmpty {
            request.httpBody = Data("{\"project\":\"\(projectID)\"}".utf8)
        } else {
            request.httpBody = Data("{}".utf8)
        }

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
            return data
        case 401, 403:
            throw APIError.invalidSessionKey
        default:
            throw APIError.serverError(httpResponse.statusCode)
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
        let settingsURL = FileManager.default.realHomeDirectory
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
        let credsURL = FileManager.default.realHomeDirectory
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
        let credsURL = FileManager.default.realHomeDirectory
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
        let executableURL = resolvedGeminiExecutableURL(from: binaryURL)
        let installRoot = geminiInstallRoot(for: executableURL)
        let fm = FileManager.default

        var candidates: [URL] = [
            installRoot.appendingPathComponent("node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"),
            installRoot.appendingPathComponent("bundle/gemini.js"),
        ]

        let bundleDirectories = [
            installRoot.appendingPathComponent("bundle"),
            installRoot.appendingPathComponent("libexec/lib/node_modules/@google/gemini-cli/bundle"),
            installRoot.appendingPathComponent("lib/node_modules/@google/gemini-cli/bundle"),
        ]
        for bundleDir in bundleDirectories where fm.fileExists(atPath: bundleDir.path) {
            if let enumerator = fm.enumerator(at: bundleDir, includingPropertiesForKeys: nil) {
                for case let fileURL as URL in enumerator {
                    guard fileURL.pathExtension == "js" else { continue }
                    candidates.append(fileURL)
                }
            }
        }

        return candidates
    }

    private func geminiInstallRoot(for executableURL: URL) -> URL {
        if executableURL.lastPathComponent == "gemini.js",
           executableURL.deletingLastPathComponent().lastPathComponent == "bundle" {
            return executableURL.deletingLastPathComponent().deletingLastPathComponent()
        }

        return executableURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    private func resolvedGeminiExecutableURL(from binaryURL: URL) -> URL {
        var currentURL = binaryURL
        var safetyCounter = 0

        while safetyCounter < 8 {
            safetyCounter += 1
            let path = currentURL.path
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
                return currentURL
            }

            if destination.hasPrefix("/") {
                currentURL = URL(fileURLWithPath: destination)
                continue
            }

            currentURL = URL(fileURLWithPath: path)
                .deletingLastPathComponent()
                .appendingPathComponent(destination)
                .standardizedFileURL
        }

        return currentURL
    }

    private func resolvedGeminiBinaryURL() -> URL? {
        let home = FileManager.default.realHomeDirectory.path
        let envPaths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let fallbackPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "\(home)/.bun/bin",
            "\(home)/.npm/bin",
            "\(home)/.local/bin",
            "\(home)/bin",
        ]
        let candidates = Array(Set(envPaths + fallbackPaths))
        let fm = FileManager.default

        for path in candidates {
            let url = URL(fileURLWithPath: path).appendingPathComponent("gemini")
            if fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        if let shellPath = shellBinaryPath(named: "gemini") {
            let url = URL(fileURLWithPath: shellPath)
            if fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func shellBinaryPath(named name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private func parseOAuthClientCredentials(from content: String) -> OAuthClientCredentials? {
        let clientIDPattern = #"(?:var|const)?\s*OAUTH_CLIENT_ID\s*=\s*['"]([\w\-\.]+)['"]\s*;"#
        let secretPattern = #"(?:var|const)?\s*OAUTH_CLIENT_SECRET\s*=\s*['"]([\w\-]+)['"]\s*;"#

        guard
            let clientRegex = try? NSRegularExpression(pattern: clientIDPattern),
            let secretRegex = try? NSRegularExpression(pattern: secretPattern)
        else {
            return nil
        }

        let range = NSRange(content.startIndex..., in: content)
        if let clientMatch = clientRegex.firstMatch(in: content, range: range),
           let clientRange = Range(clientMatch.range(at: 1), in: content),
           let secretMatch = secretRegex.firstMatch(in: content, range: range),
           let secretRange = Range(secretMatch.range(at: 1), in: content) {
            return OAuthClientCredentials(
                clientID: String(content[clientRange]),
                clientSecret: String(content[secretRange])
            )
        }

        let fallbackIDPattern = #"[0-9]{6,}-[A-Za-z0-9_\-]+\.apps\.googleusercontent\.com"#
        let fallbackSecretPattern = #"GOCSPX-[A-Za-z0-9_\-]+"#
        guard
            let fallbackIDRegex = try? NSRegularExpression(pattern: fallbackIDPattern),
            let fallbackSecretRegex = try? NSRegularExpression(pattern: fallbackSecretPattern),
            let fallbackIDMatch = fallbackIDRegex.firstMatch(in: content, range: range),
            let fallbackIDRange = Range(fallbackIDMatch.range(at: 0), in: content),
            let fallbackSecretMatch = fallbackSecretRegex.firstMatch(in: content, range: range),
            let fallbackSecretRange = Range(fallbackSecretMatch.range(at: 0), in: content)
        else {
            return nil
        }

        return OAuthClientCredentials(
            clientID: String(content[fallbackIDRange]),
            clientSecret: String(content[fallbackSecretRange])
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

    private func parseUsage(
        _ data: Data,
        claims: TokenClaims,
        codeAssistStatus: CodeAssistStatus
    ) throws -> GeminiUsageResponse {
        let response = try JSONDecoder().decode(QuotaResponse.self, from: data)
        guard let buckets = response.buckets, !buckets.isEmpty else {
            throw APIError.parseError
        }

        var quotaByModel: [String: (remaining: Double, resetTime: String?)] = [:]
        for bucket in buckets {
            guard let modelID = bucket.modelId, let remaining = bucket.remainingFraction else { continue }
            if let existing = quotaByModel[modelID] {
                // 같은 모델에 여러 quota window가 있을 때 활성 window를 선택:
                // resetTime이 더 최근인 bucket 우선, 같으면 remaining이 큰 것 우선
                let existingDate = parseResetDate(existing.resetTime)
                let newDate = parseResetDate(bucket.resetTime)
                let shouldReplace: Bool
                if let ed = existingDate, let nd = newDate {
                    shouldReplace = nd > ed || (nd == ed && remaining > existing.remaining)
                } else if newDate != nil {
                    shouldReplace = true
                } else {
                    shouldReplace = remaining > existing.remaining
                }
                if shouldReplace {
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

        let accountPlan: String? = switch (codeAssistStatus.tier, claims.hostedDomain) {
        case (.standard, _):
            "Paid"
        case (.free, .some):
            "Workspace"
        case (.free, .none):
            "Free"
        case (.legacy, _):
            "Legacy"
        case (.none, .some):
            "Workspace"
        case (.none, .none):
            "OAuth"
        }

        return GeminiUsageResponse(
            accountEmail: claims.email,
            accountPlan: accountPlan,
            primaryWindow: primary,
            secondaryWindow: secondary,
            tertiaryWindow: tertiary
        )
    }

    private func parseResetDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
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

    private func loadCodeAssistStatus(accessToken: String) async -> CodeAssistStatus {
        var request = URLRequest(url: loadCodeAssistEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"metadata\":{\"ideType\":\"GEMINI_CLI\",\"pluginType\":\"GEMINI\"}}".utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .empty
        }

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return .empty
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }

        let rawProjectID: String? = {
            if let project = json["cloudaicompanionProject"] as? String {
                return project
            }
            if let project = json["cloudaicompanionProject"] as? [String: Any] {
                return (project["id"] as? String) ?? (project["projectId"] as? String)
            }
            return nil
        }()

        let trimmedProjectID = rawProjectID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectID = (trimmedProjectID?.isEmpty == false) ? trimmedProjectID : nil
        let tier = ((json["currentTier"] as? [String: Any])?["id"] as? String)
            .flatMap(GeminiUserTierID.init(rawValue:))

        return CodeAssistStatus(tier: tier, projectID: projectID)
    }

    private func discoverGeminiProjectID(accessToken: String) async throws -> String? {
        var request = URLRequest(url: projectsEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknownError("Invalid Gemini projects response")
        }
        guard httpResponse.statusCode == 200 else {
            return nil
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let projects = json["projects"] as? [[String: Any]]
        else {
            return nil
        }

        for project in projects {
            guard let projectID = project["projectId"] as? String else { continue }
            if projectID.hasPrefix("gen-lang-client") {
                return projectID
            }
            if let labels = project["labels"] as? [String: String],
               labels["generative-language"] != nil {
                return projectID
            }
        }

        return nil
    }
}
