import Foundation

/// 메뉴바 계정이 아닌 계정의 사용량 조회. 메뉴바 계정 조회(ClaudeAPIService, CodexAPIService)의 상태와
/// 캐시를 건드리지 않도록 따로 둔다. 토큰 갱신은 각 제품의 공식 CLI에 맡긴다.

// MARK: - Claude

nonisolated enum ClaudeWebUsageFetcher {
    struct Result: Sendable {
        let identity: UsageAccountIdentity
        let usage: ClaudeUsageResponse
    }

    static func fetch(sessionKey: String, organizationID: String?, session: URLSession = .shared) async throws
        -> Result
    {
        let accountData = try await send(webRequest(ClaudeEndpoints.accountURL, sessionKey: sessionKey), session)
        guard let account = try? JSONSerialization.jsonObject(with: accountData) as? [String: Any] else {
            throw UsageAccountFetchError.unavailable
        }
        let organizations = (account["memberships"] as? [[String: Any]] ?? [])
            .compactMap { $0["organization"] as? [String: Any] }
            .compactMap(ClaudeAPIService.OrganizationSummary.init(json:))
        let chosen =
            organizations.first { $0.id == organizationID }
            ?? ClaudeAutomaticOrganizationSelectionPolicy.selectBest(
                from: organizations.map { .init(organization: $0, overage: nil) })?.organization
            ?? organizations.first
        guard let organization = chosen else { throw UsageAccountFetchError.unavailable }
        let usageData = try await send(
            webRequest(ClaudeEndpoints.webUsageURL(organizationID: organization.id), sessionKey: sessionKey), session)
        guard let usage = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: usageData) else {
            throw UsageAccountFetchError.unavailable
        }
        return Result(
            identity: UsageAccountIdentity(
                accountID: account["uuid"] as? String, organizationID: organization.id,
                email: account["email_address"] as? String, organizationName: organization.name),
            usage: usage)
    }

    static func fetchOAuthUsage(accessToken: String, session: URLSession = .shared) async throws
        -> ClaudeUsageResponse
    {
        var request = URLRequest(url: ClaudeEndpoints.oauthUsageURL, timeoutInterval: ClaudeEndpoints.requestTimeout)
        ClaudeEndpoints.applyOAuthHeaders(to: &request, accessToken: accessToken)
        let data = try await send(request, session)
        guard let usage = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: data) else {
            throw UsageAccountFetchError.unavailable
        }
        return usage
    }

    private static func webRequest(_ url: URL, sessionKey: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: ClaudeEndpoints.requestTimeout)
        ClaudeEndpoints.applyWebHeaders(to: &request, sessionKey: sessionKey)
        return request
    }

    private static func send(_ request: URLRequest, _ session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageAccountFetchError.loginExpired }
        guard (200...299).contains(status) else { throw UsageAccountFetchError.server(status) }
        return data
    }
}

// MARK: - Codex

/// CODEX_HOME 폴더 하나의 로그인
nonisolated enum CodexHomeAccount {
    /// app-server 조회 한 번에 쓰는 시간
    static let fetchTimeout: TimeInterval = 20

    static func authFile(in home: URL) -> URL { home.appendingPathComponent("auth.json") }

    /// `~/.codex-이름`처럼 둔 CODEX_HOME 폴더와 앱이 만든 폴더. auth.json이 있는 것만 본다.
    static func discoverHomes(home: URL = FileManager.default.realHomeDirectory, managedRoot: URL) -> [URL] {
        let siblings = ((try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(".codex-") || $0.lastPathComponent.hasPrefix(".codex_") }
        let managed =
            (try? FileManager.default.contentsOfDirectory(at: managedRoot, includingPropertiesForKeys: nil)) ?? []
        return (siblings.sorted { $0.path < $1.path } + managed.sorted { $0.path < $1.path }).filter {
            FileManager.default.fileExists(atPath: authFile(in: $0).path)
        }
    }

    /// 표시용으로만 id_token의 이메일을 읽는다. 서명 확인은 하지 않는다.
    /// 같은 이메일이 여러 워크스페이스에 있으므로 워크스페이스(account_id)까지 합쳐 계정을 가린다.
    static func identity(home: URL) -> UsageAccountIdentity? {
        guard let data = try? Data(contentsOf: authFile(in: home)),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = object["tokens"] as? [String: Any]
        else { return nil }
        let workspace = tokens["account_id"] as? String
        let email = (tokens["id_token"] as? String).flatMap(JWTClaims.decode)?["email"] as? String
        return UsageAccountIdentity(accountID: email, organizationID: workspace, email: email)
    }

    /// 폴더마다 공식 app-server로 사용량을 읽는다. 토큰 갱신도 app-server가 한다.
    static func fetchUsage(home: URL, owner: CodexOwnerCLI = CodexOwnerCLI()) async throws -> CodexUsageResponse {
        let expected = identity(home: home)?.organizationID ?? ""
        do {
            let snapshot = try await owner.readRateLimits(
                sourceURL: authFile(in: home), expectedAccountID: expected,
                budget: CodexRequestBudget(timeout: fetchTimeout))
            return try usageResponse(fromAppServer: snapshot)
        } catch CodexOwnerError.rejected {
            throw UsageAccountFetchError.loginExpired
        } catch CodexOwnerError.unavailable {
            throw UsageAccountFetchError.unavailable
        }
    }

    /// app-server 응답을 웹 사용량 응답 모양으로 옮겨 기존 해석을 그대로 쓴다.
    static func usageResponse(fromAppServer quota: [String: Any]) throws -> CodexUsageResponse {
        let limits = CodexOwnerCLI.codexRateLimits(in: quota) ?? [:]
        func window(_ key: String) -> Any {
            guard let value = limits[key] as? [String: Any], let used = value["usedPercent"] else { return NSNull() }
            var result: [String: Any] = ["used_percent": used]
            if let minutes = (value["windowDurationMins"] as? NSNumber)?.doubleValue {
                result["limit_window_seconds"] = Int(minutes * 60)
            }
            if let reset = value["resetsAt"] { result["reset_at"] = reset }
            return result
        }
        var body: [String: Any] = [
            "account_id": quota["accountId"] ?? NSNull(),
            "rate_limit": ["primary_window": window("primary"), "secondary_window": window("secondary")],
        ]
        if let plan = limits["planType"] { body["plan_type"] = plan }
        if let credits = limits["credits"] as? [String: Any] {
            body["credits"] = [
                "has_credits": credits["hasCredits"] ?? false, "unlimited": credits["unlimited"] ?? false,
                "balance": credits["balance"] ?? NSNull(),
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        var usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        usage.resetCredits = CodexOwnerCLI.resetCredits(from: quota["rateLimitResetCredits"])
        return usage
    }
}
