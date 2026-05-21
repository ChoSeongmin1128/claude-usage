import Foundation

nonisolated protocol AntigravityRemoteUsageHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

private nonisolated struct URLSessionAntigravityRemoteUsageHTTPClient: AntigravityRemoteUsageHTTPClient {
    nonisolated func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

actor AntigravityRemoteUsageService {
    private struct EndpointSet: Sendable, Equatable {
        let baseURL: URL

        var loadCodeAssistEndpoint: URL { endpoint(path: "/v1internal:loadCodeAssist") }
        var onboardUserEndpoint: URL { endpoint(path: "/v1internal:onboardUser") }
        var fetchAvailableModelsEndpoint: URL { endpoint(path: "/v1internal:fetchAvailableModels") }
        var retrieveUserQuotaEndpoint: URL { endpoint(path: "/v1internal:retrieveUserQuota") }

        private func endpoint(path: String) -> URL {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            components.path = path
            components.query = nil
            components.fragment = nil
            return components.url!
        }
    }

    private static let defaultBaseURL = URL(string: "https://daily-cloudcode-pa.googleapis.com")!
    private static let legacyBaseURL = URL(string: "https://cloudcode-pa.googleapis.com")!
    private static let allowedRemoteHosts: Set<String> = [
        "daily-cloudcode-pa.googleapis.com",
        "cloudcode-pa.googleapis.com",
    ]
    private static let refreshSafetyWindow: TimeInterval = 60

    private let requestTimeout: TimeInterval = 20
    private let httpClient: any AntigravityRemoteUsageHTTPClient
    private let credentialProvider: (@Sendable () throws -> AntigravityOAuthCredentials)?
    private let credentialProviderLabel: String
    private let oauthClientProvider: @Sendable () -> AntigravityOAuthClient?
    private let endpointBaseURLProvider: @Sendable () -> [URL]

    init(
        httpClient: any AntigravityRemoteUsageHTTPClient = URLSessionAntigravityRemoteUsageHTTPClient(),
        credentialProvider: (@Sendable () throws -> AntigravityOAuthCredentials)? = nil,
        credentialProviderLabel: String = "test",
        oauthClientProvider: @escaping @Sendable () -> AntigravityOAuthClient? = {
            AntigravityOAuthConfig.resolvedClient()
        },
        endpointBaseURLProvider: @escaping @Sendable () -> [URL] = {
            AntigravityRemoteUsageService.defaultEndpointBaseURLCandidates(
                runningProcess: AntigravityStatusProbe.cachedRunningProcess()
            )
        }
    ) {
        self.httpClient = httpClient
        self.credentialProvider = credentialProvider
        self.credentialProviderLabel = credentialProviderLabel
        self.oauthClientProvider = oauthClientProvider
        self.endpointBaseURLProvider = endpointBaseURLProvider
    }

    private struct CredentialSource {
        let credentials: AntigravityOAuthCredentials
        let store: AntigravityOAuthCredentialsStore?
        let label: String
    }

    private struct RefreshResult {
        let accessToken: String
        let credentials: AntigravityOAuthCredentials
    }

    func fetchUsage() async throws -> AntigravityUsageResponse {
        let source = try resolveCredentialSource()
        var credentials = source.credentials
        var accessToken = credentials.accessToken?.trimmedNonEmpty
        var refreshedForThisRequest = false

        if accessToken == nil || shouldRefresh(expiryDate: credentials.expiryDate, now: Date()) {
            guard let refreshToken = credentials.refreshToken?.trimmedNonEmpty else {
                throw APIError.invalidSessionKey
            }
            let refreshed = try await refreshAccessToken(
                credentials: credentials,
                refreshToken: refreshToken,
                sourceStore: source.store
            )
            accessToken = refreshed.accessToken
            credentials = refreshed.credentials
            refreshedForThisRequest = true
        }
        guard let accessToken else {
            throw APIError.invalidSessionKey
        }

        do {
            return try await fetchUsage(
                credentials: credentials,
                accessToken: accessToken,
                source: source
            )
        } catch let error as APIError {
            guard case .invalidSessionKey = error,
                  !refreshedForThisRequest,
                  let refreshToken = credentials.refreshToken?.trimmedNonEmpty
            else {
                throw error
            }

            let refreshed = try await refreshAccessToken(
                credentials: credentials,
                refreshToken: refreshToken,
                sourceStore: source.store
            )
            return try await fetchUsage(
                credentials: refreshed.credentials,
                accessToken: refreshed.accessToken,
                source: source
            )
        }
    }

    nonisolated static func defaultEndpointBaseURLCandidates(
        runningProcess: AntigravityProcessSnapshot? = AntigravityStatusProbe.runningProcess()
    ) -> [URL] {
        uniqueEndpointBaseURLs([
            normalizedAllowedBaseURL(runningProcess?.cloudCodeEndpoint),
            defaultBaseURL,
            legacyBaseURL,
        ].compactMap { $0 })
    }

    nonisolated private static func normalizedAllowedBaseURL(_ rawValue: String?) -> URL? {
        guard let rawValue = rawValue?.trimmedNonEmpty,
              let url = URL(string: rawValue),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedRemoteHosts.contains(host)
        else {
            return nil
        }
        return URL(string: "https://\(host)")
    }

    nonisolated private static func uniqueEndpointBaseURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls {
            guard let host = url.host?.lowercased(), seen.insert(host).inserted else { continue }
            result.append(url)
        }
        return result
    }

    private func fetchUsage(
        credentials initialCredentials: AntigravityOAuthCredentials,
        accessToken: String,
        source: CredentialSource
    ) async throws -> AntigravityUsageResponse {
        var credentials = initialCredentials
        let claims = AntigravityRemoteUsageParsing.claims(from: credentials)
        let endpoints = endpointBaseURLProvider().map(EndpointSet.init(baseURL:))
        var lastError: Error?

        for endpointSet in endpoints {
            do {
                let codeAssist = try await loadCodeAssist(
                    accessToken: accessToken,
                    endpointSet: endpointSet
                )
                let projectID = try await resolveProjectID(
                    accessToken: accessToken,
                    storedProjectID: credentials.projectID?.trimmedNonEmpty,
                    initialResponse: codeAssist,
                    endpointSet: endpointSet
                )

                if let projectID, credentials.projectID?.trimmedNonEmpty != projectID {
                    credentials.projectID = projectID
                    persistIfOwned(credentials, sourceStore: source.store)
                }

                let quotas = try await fetchModelQuotas(
                    accessToken: accessToken,
                    projectID: projectID,
                    endpointSet: endpointSet
                )

                Logger.info("[Antigravity] remote usage fetched via \(source.label) endpoint=\(endpointSet.baseURL.host ?? "-")")
                return AntigravityUsageMapper.buildResponse(
                    quotas: quotas,
                    accountEmail: claims.email ?? credentials.email?.trimmedNonEmpty,
                    accountPlan: AntigravityRemoteUsageParsing.plan(from: codeAssist, claims: claims),
                    source: .googleOAuth
                )
            } catch {
                lastError = error
                guard shouldTryNextEndpoint(after: error) else {
                    throw error
                }
                Logger.info("[Antigravity] remote endpoint \(endpointSet.baseURL.host ?? "-") 조회 실패, 다음 endpoint 시도: \(error.localizedDescription)")
            }
        }

        throw lastError ?? APIError.networkError("Antigravity 원격 endpoint가 없습니다")
    }

    func fetchUsageWithRetry(maxAttempts: Int = 2) async throws -> AntigravityUsageResponse {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await fetchUsage()
            } catch let error as APIError {
                if error.isDefinitiveAuthFailure || error.isPermissionDenied {
                    throw error
                }
                lastError = error
            } catch {
                lastError = error
            }

            if attempt < maxAttempts {
                let delay = UInt64(pow(2.0, Double(attempt - 1)) * 500_000_000)
                try await Task.sleep(nanoseconds: delay)
            }
        }

        if let apiError = lastError as? APIError {
            throw apiError
        }
        throw APIError.unknownError(lastError?.localizedDescription ?? "Antigravity 원격 사용량 조회 실패")
    }

    private func resolveCredentialSource() throws -> CredentialSource {
        if let credentialProvider {
            let credentials = try credentialProvider()
            guard credentials.hasTokenMaterial else {
                throw APIError.invalidSessionKey
            }
            return CredentialSource(credentials: credentials, store: nil, label: credentialProviderLabel)
        }

        let environment = ProcessInfo.processInfo.environment
        if let value = environment[AntigravityOAuthCredentialsStore.environmentCredentialsKey] {
            guard let credentials = AntigravityOAuthCredentialsStore.credentials(fromEnvironmentValue: value),
                  credentials.hasTokenMaterial
            else {
                throw APIError.parseError
            }
            return CredentialSource(credentials: credentials, store: nil, label: "environment")
        }

        let home = FileManager.default.realHomeDirectory
        let store = AntigravityOAuthCredentialsStore(
            fileURL: AntigravityOAuthCredentialsStore.defaultURL(home: home)
        )
        if let credentials = try? store.load(), credentials.hasTokenMaterial {
            return CredentialSource(credentials: credentials, store: store, label: "ClaudeUsage")
        }

        let accountStore = AntigravityOAuthAccountStore(activeCredentialStore: store)
        if let active = accountStore.state().activeAccount, active.credentials.hasTokenMaterial {
            try? store.save(active.credentials)
            return CredentialSource(credentials: active.credentials, store: store, label: "ClaudeUsage")
        }

        throw APIError.invalidSessionKey
    }

    private func shouldRefresh(expiryDate: Date?, now: Date) -> Bool {
        guard let expiryDate else { return false }
        return expiryDate.timeIntervalSince(now) <= Self.refreshSafetyWindow
    }

    private func refreshAccessToken(
        credentials: AntigravityOAuthCredentials,
        refreshToken: String,
        sourceStore: AntigravityOAuthCredentialsStore?
    ) async throws -> RefreshResult {
        let client = try refreshOAuthClient(from: credentials)
        var lastInvalidClient = false
        var attemptedSecrets: Set<String> = []
        for clientSecret in client.clientSecretCandidates {
            attemptedSecrets.insert(clientSecret)
            do {
                return try await refreshAccessToken(
                    credentials: credentials,
                    refreshToken: refreshToken,
                    clientID: client.clientID,
                    clientSecret: clientSecret,
                    sourceStore: sourceStore
                )
            } catch AntigravityTokenRefreshError.invalidClient {
                lastInvalidClient = true
                continue
            }
        }
        if lastInvalidClient, let fallbackClient = fallbackOAuthClient(for: client) {
            for clientSecret in fallbackClient.clientSecretCandidates where !attemptedSecrets.contains(clientSecret) {
                do {
                    return try await refreshAccessToken(
                        credentials: credentials,
                        refreshToken: refreshToken,
                        clientID: fallbackClient.clientID,
                        clientSecret: clientSecret,
                        sourceStore: sourceStore
                    )
                } catch AntigravityTokenRefreshError.invalidClient {
                    continue
                }
            }
        }
        if lastInvalidClient {
            throw APIError.invalidSessionKey
        }
        throw APIError.invalidSessionKey
    }

    private func refreshAccessToken(
        credentials: AntigravityOAuthCredentials,
        refreshToken: String,
        clientID: String,
        clientSecret: String,
        sourceStore: AntigravityOAuthCredentialsStore?
    ) async throws -> RefreshResult {
        var request = URLRequest(url: AntigravityOAuthConfig.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])

        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.unknownError("Invalid refresh response")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401, tokenError(from: data) == "invalid_client" {
                throw AntigravityTokenRefreshError.invalidClient
            }
            throw APIError.invalidSessionKey
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else {
            throw APIError.parseError
        }

        var updated = updatedCredentials(credentials, refreshResponse: json)
        updated.clientID = updated.clientID ?? clientID
        updated.clientSecret = clientSecret
        persistIfOwned(updated, sourceStore: sourceStore)
        return RefreshResult(accessToken: accessToken, credentials: updated)
    }

    private func refreshOAuthClient(from credentials: AntigravityOAuthCredentials) throws -> AntigravityOAuthClient {
        if let clientID = credentials.clientID?.trimmedNonEmpty,
           let clientSecret = credentials.clientSecret?.trimmedNonEmpty {
            return AntigravityOAuthClient(clientID: clientID, clientSecret: clientSecret)
        }
        guard let client = oauthClientProvider() else {
            throw APIError.unknownError(AntigravityOAuthConfig.missingCredentialsMessage)
        }
        return client
    }

    private func fallbackOAuthClient(for client: AntigravityOAuthClient) -> AntigravityOAuthClient? {
        guard let discovered = oauthClientProvider(), discovered.clientID == client.clientID else {
            return nil
        }
        return discovered
    }

    private func updatedCredentials(
        _ credentials: AntigravityOAuthCredentials,
        refreshResponse: [String: Any]
    ) -> AntigravityOAuthCredentials {
        var updated = credentials
        if let accessToken = refreshResponse["access_token"] as? String {
            updated.accessToken = accessToken
        }
        if let idToken = refreshResponse["id_token"] as? String {
            updated.idToken = idToken
        }
        if let expiresIn = refreshResponse["expires_in"] as? Double {
            updated.expiryDateMilliseconds = (Date().timeIntervalSince1970 + expiresIn) * 1000
        } else if let expiresIn = refreshResponse["expires_in"] as? Int {
            updated.expiryDateMilliseconds = (Date().timeIntervalSince1970 + Double(expiresIn)) * 1000
        }
        return updated
    }

    private func persistIfOwned(_ credentials: AntigravityOAuthCredentials, sourceStore: AntigravityOAuthCredentialsStore?) {
        guard let sourceStore else { return }
        do {
            try sourceStore.save(credentials)
            _ = try? AntigravityOAuthAccountStore(activeCredentialStore: sourceStore).upsert(credentials, makeActive: true)
        } catch {
            Logger.warning("[Antigravity] OAuth credentials 저장 실패: \(error.localizedDescription)")
        }
    }

    private func loadCodeAssist(
        accessToken: String,
        endpointSet: EndpointSet
    ) async throws -> AntigravityCodeAssistResponse {
        let body: [String: Any] = [
            "metadata": [
                "ideType": "ANTIGRAVITY",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            ],
        ]
        return try await sendRequest(
            endpoint: endpointSet.loadCodeAssistEndpoint,
            accessToken: accessToken,
            body: body
        )
    }

    private func resolveProjectID(
        accessToken: String,
        storedProjectID: String?,
        initialResponse: AntigravityCodeAssistResponse,
        endpointSet: EndpointSet
    ) async throws -> String? {
        if let storedProjectID {
            return storedProjectID
        }
        if let projectID = initialResponse.projectID {
            return projectID
        }
        guard let tierID = AntigravityRemoteUsageParsing.onboardTier(from: initialResponse) else {
            return nil
        }

        let onboardBody: [String: Any] = [
            "tierId": tierID,
            "metadata": [
                "ideType": "ANTIGRAVITY",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            ],
        ]

        do {
            let onboard: AntigravityOnboardResponse = try await sendRequest(
                endpoint: endpointSet.onboardUserEndpoint,
                accessToken: accessToken,
                body: onboardBody
            )
            if let projectID = onboard.projectID {
                return projectID
            }
        } catch {
            Logger.warning("[Antigravity] remote onboardUser 실패: \(error.localizedDescription)")
        }

        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let refreshed = try await loadCodeAssist(
                accessToken: accessToken,
                endpointSet: endpointSet
            )
            if let projectID = refreshed.projectID {
                return projectID
            }
        }
        return nil
    }

    private func fetchModelQuotas(
        accessToken: String,
        projectID: String?,
        endpointSet: EndpointSet
    ) async throws -> [AntigravityModelQuota] {
        do {
            let response: AntigravityFetchAvailableModelsResponse = try await sendRequest(
                endpoint: endpointSet.fetchAvailableModelsEndpoint,
                accessToken: accessToken,
                body: AntigravityRemoteUsageParsing.projectBody(projectID)
            )
            let quotas = AntigravityRemoteUsageParsing.modelQuotas(from: response)
            guard quotas.contains(where: { $0.remainingFraction != nil }) else {
                Logger.info("[Antigravity] fetchAvailableModels quota 값 없음, retrieveUserQuota fallback 시도")
                return try await retrieveUserQuotaFallback(
                    accessToken: accessToken,
                    projectID: projectID,
                    endpointSet: endpointSet,
                    permissionDeniedFallback: quotas
                )
            }
            return quotas
        } catch let error as APIError {
            guard case .permissionDenied = error else {
                throw error
            }
            Logger.info("[Antigravity] fetchAvailableModels 권한 거부, retrieveUserQuota fallback: \(error.localizedDescription)")
            return try await retrieveUserQuotaFallback(
                accessToken: accessToken,
                projectID: projectID,
                endpointSet: endpointSet,
                permissionDeniedFallback: []
            )
        }
    }

    private func retrieveUserQuotaFallback(
        accessToken: String,
        projectID: String?,
        endpointSet: EndpointSet,
        permissionDeniedFallback: [AntigravityModelQuota]
    ) async throws -> [AntigravityModelQuota] {
        do {
            let response: AntigravityRetrieveUserQuotaResponse = try await sendRequest(
                endpoint: endpointSet.retrieveUserQuotaEndpoint,
                accessToken: accessToken,
                body: AntigravityRemoteUsageParsing.projectBody(projectID)
            )
            return try AntigravityRemoteUsageParsing.quotaBuckets(from: response)
        } catch let quotaError as APIError {
            guard case .permissionDenied = quotaError else {
                throw quotaError
            }
            Logger.info("[Antigravity] 원격 quota endpoint 권한 없음: \(quotaError.localizedDescription)")
            return permissionDeniedFallback
        }
    }

    private func shouldTryNextEndpoint(after error: Error) -> Bool {
        guard let apiError = error as? APIError else {
            return true
        }
        switch apiError {
        case .invalidSessionKey, .rateLimited:
            return false
        case .codexReauthRequired,
             .claudeOAuthPathRetired,
             .cloudflareBlocked,
             .networkError,
             .permissionDenied,
             .parseError,
             .serverError,
             .unknownError:
            return true
        }
    }

    private func sendRequest<Response: Decodable>(
        endpoint: URL,
        accessToken: String,
        body: [String: Any]
    ) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.unknownError("Invalid HTTP response")
        }
        switch http.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                Logger.warning("[Antigravity] remote decode 실패: \(error.localizedDescription)")
                throw APIError.parseError
            }
        case 401, 403:
            if http.statusCode == 401 {
                throw APIError.invalidSessionKey
            }
            let message = String(data: data, encoding: .utf8)?.trimmedNonEmpty ?? "HTTP 403"
            throw APIError.permissionDenied(message)
        case 429:
            throw APIError.rateLimited(retryAfter: nil)
        default:
            throw APIError.serverError(http.statusCode)
        }
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await httpClient.data(for: request)
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }
    }

    private func tokenError(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["error"] as? String)?.trimmedNonEmpty
    }

    private func formBody(_ values: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = values.map { key, value in
            URLQueryItem(name: key, value: value)
        }
        return components.query?.data(using: .utf8)
    }
}

private nonisolated enum AntigravityTokenRefreshError: Error {
    case invalidClient
}

private extension String {
    nonisolated var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
