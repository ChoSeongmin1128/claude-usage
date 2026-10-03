import Foundation
import Security

/// 지금 쓰지 않는 계정을 조회한다. 활성 계정 조회(ClaudeAPIService, CodexAPIService)의 상태와
/// 캐시를 건드리지 않도록 따로 둔다. 토큰 갱신은 각 제품의 공식 CLI에 맡긴다.
enum UsageAccountFetchError: Error, Equatable {
    case loginExpired
    case needsPermission
    case unavailable
    case server(Int)
}

// MARK: - Claude 웹 로그인

enum ClaudeWebAccountFetcher {
    struct Result: Sendable {
        let identity: UsageAccountIdentity
        let usage: ClaudeUsageResponse
    }

    nonisolated static func fetch(
        sessionKey: String, preferredOrganizationID: String?, session: URLSession = .shared
    ) async throws -> Result {
        let account = try await json(path: "/api/account", sessionKey: sessionKey, session: session)
        let memberships = (account["memberships"] as? [[String: Any]] ?? []).compactMap {
            $0["organization"] as? [String: Any]
        }
        let organizations = memberships.compactMap { org -> ClaudeAPIService.OrganizationSummary? in
            guard let id = org["uuid"] as? String else { return nil }
            return .init(
                id: id, name: org["name"] as? String, billingType: org["billing_type"] as? String,
                rateLimitTier: org["rate_limit_tier"] as? String, capabilities: org["capabilities"] as? [String])
        }
        let chosen =
            organizations.first { $0.id == preferredOrganizationID }
            ?? ClaudeAutomaticOrganizationSelectionPolicy.selectBest(
                from: organizations.map { .init(organization: $0, overage: nil) })?.organization
            ?? organizations.first
        guard let organization = chosen else { throw UsageAccountFetchError.unavailable }
        let data = try await request(
            path: "/api/organizations/\(organization.id)/usage?cedar_ember=1", sessionKey: sessionKey, session: session)
        guard let usage = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: data) else {
            throw UsageAccountFetchError.unavailable
        }
        return Result(
            identity: UsageAccountIdentity(
                accountID: account["uuid"] as? String, organizationID: organization.id,
                email: account["email_address"] as? String, organizationName: organization.name),
            usage: usage)
    }

    private nonisolated static func json(path: String, sessionKey: String, session: URLSession) async throws
        -> [String: Any]
    {
        let data = try await request(path: path, sessionKey: sessionKey, session: session)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageAccountFetchError.unavailable
        }
        return object
    }

    private nonisolated static func request(path: String, sessionKey: String, session: URLSession) async throws -> Data
    {
        guard let url = URL(string: "https://claude.ai\(path)") else { throw UsageAccountFetchError.unavailable }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageAccountFetchError.loginExpired }
        guard (200...299).contains(status) else { throw UsageAccountFetchError.server(status) }
        return data
    }
}

// MARK: - 다른 폴더의 Claude Code 로그인

enum ClaudeCodeDirectoryAccount {
    enum TokenRead: Equatable {
        case token(String, expiresAt: Date?)
        case needsPermission
        case missing
    }

    /// `~/.claude-이름`처럼 기본 폴더 옆에 둔 CLAUDE_CONFIG_DIR 폴더. 로그인 기록이 있는 것만 본다.
    nonisolated static func discoverDirectories(home: URL = FileManager.default.realHomeDirectory) -> [URL] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: home, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        return entries.filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(".claude-") || name.hasPrefix(".claude_") else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && identity(configDirectory: url) != nil
        }
        .sorted { $0.path < $1.path }
    }

    /// 기본 폴더의 계정 정보는 홈의 `.claude.json`, 따로 지정한 폴더는 그 폴더 안의 `.claude.json`에 있다.
    nonisolated static func identity(configDirectory: URL?, home: URL = FileManager.default.realHomeDirectory)
        -> UsageAccountIdentity?
    {
        let file =
            configDirectory?.appendingPathComponent(".claude.json") ?? home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: file),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let account = object["oauthAccount"] as? [String: Any]
        else { return nil }
        return UsageAccountIdentity(
            accountID: account["accountUuid"] as? String, organizationID: account["organizationUuid"] as? String,
            email: account["emailAddress"] as? String, organizationName: account["organizationName"] as? String)
    }

    /// 파일 로그인을 먼저 보고, 없으면 그 폴더의 Keychain 항목을 Claude Code와 같은 `security` 도구로 읽는다.
    /// 그 도구로 못 읽을 때만 직접 읽으며, 확인 창은 사용자가 누를 때(interactive)만 띄운다.
    nonisolated static func readToken(configDirectory: URL, interactive: Bool) async -> TokenRead {
        for name in [".credentials.json", "credentials.json"] {
            if let data = try? Data(contentsOf: configDirectory.appendingPathComponent(name)),
                let token = parse(data)
            {
                return token
            }
        }
        let service = ClaudeCodeCredentialReader.keychainServiceName(
            for: configDirectory, homeDirectory: FileManager.default.realHomeDirectory,
            usesExplicitConfigDirectory: true)
        switch await ClaudeCodeKeychainCLI.read(service: service) {
        case .payload(let payload): return parse(Data(payload.utf8)) ?? .missing
        case .notFound: return .missing
        case .failed: break
        }
        let outcome =
            interactive
            ? KeychainAccessPreflight.readGenericPasswordInteractively(
                service: service, account: nil, localizedReason: "다른 Claude Code 계정의 사용량을 확인합니다.")
            : KeychainAccessPreflight.readGenericPasswordWithoutUI(service: service, account: nil)
        switch outcome {
        case .value(let payload): return parse(Data(payload.utf8)) ?? .missing
        case .interactionRequired, .cancelled: return .needsPermission
        case .notFound, .invalidData, .failure: return .missing
        }
    }

    nonisolated static func parse(_ data: Data) -> TokenRead? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = object["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return .token(token, expiresAt: expiresAt)
    }

    /// 토큰이 곧 끝나면 그 폴더의 Claude Code가 스스로 갱신하게 한다. `/usage`는 모델을 부르지 않는다.
    /// 로그인되지 않은 폴더에서도 `/usage`는 성공으로 끝나므로 먼저 `auth status`로 확인한다.
    /// configDirectory가 nil이면 기본 로그인이다. 기본 폴더를 CLAUDE_CONFIG_DIR로 주면 Keychain 이름이 달라진다.
    nonisolated static func refreshViaCLI(configDirectory: URL?, workDirectory: URL) async -> Bool {
        guard let claude = executable() else { return false }
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let environment = cliEnvironment(configDirectory: configDirectory)
        guard let status = await run(claude, ["auth", "status", "--json"], environment, workDirectory),
            let object = try? JSONSerialization.jsonObject(with: status) as? [String: Any],
            object["loggedIn"] as? Bool == true
        else { return false }
        return await run(claude, ["-p", "/usage", "--no-session-persistence"], environment, workDirectory) != nil
    }

    /// Claude Code는 Keychain 항목을 USER 계정 이름으로 찾는다. USER가 없으면 로그인돼 있어도 로그아웃으로 본다.
    nonisolated static func cliEnvironment(configDirectory: URL?) -> [String: String] {
        var environment = [
            "HOME": FileManager.default.realHomeDirectory.path, "USER": NSUserName(), "LOGNAME": NSUserName(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
        ]
        if let configDirectory { environment["CLAUDE_CONFIG_DIR"] = configDirectory.path }
        return environment
    }

    nonisolated static func fetchUsage(accessToken: String, session: URLSession = .shared) async throws
        -> ClaudeUsageResponse
    {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1") else {
            throw UsageAccountFetchError.unavailable
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.1.5", forHTTPHeaderField: "User-Agent")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageAccountFetchError.loginExpired }
        guard (200...299).contains(status) else { throw UsageAccountFetchError.server(status) }
        guard let usage = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: data) else {
            throw UsageAccountFetchError.unavailable
        }
        return usage
    }

    nonisolated static func executable(home: URL = FileManager.default.realHomeDirectory) -> URL? {
        let candidates = [
            home.appendingPathComponent(".local/bin/claude"), home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        return candidates.lazy.map { $0.resolvingSymlinksInPath() }.first {
            var info = stat()
            return stat($0.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o022 == 0
                && (info.st_uid == getuid() || info.st_uid == 0) && access($0.path, X_OK) == 0
        }
    }

    private nonisolated static func run(
        _ executable: URL, _ arguments: [String], _ environment: [String: String],
        _ workDirectory: URL
    ) async -> Data? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = workDirectory
            process.qualityOfService = .utility
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let deadline = Date().addingTimeInterval(30)
            while process.isRunning, Date() < deadline { usleep(100_000) }
            if process.isRunning {
                process.terminate()
                return nil
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return process.terminationStatus == 0 ? data : nil
        }.value
    }
}

// MARK: - 다른 폴더의 Codex 로그인

enum CodexHomeAccount {
    /// `~/.codex-이름`처럼 둔 CODEX_HOME 폴더와 앱이 만든 폴더. auth.json이 있는 것만 본다.
    nonisolated static func discoverHomes(home: URL = FileManager.default.realHomeDirectory, managedRoot: URL) -> [URL]
    {
        let siblings = ((try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(".codex-") || $0.lastPathComponent.hasPrefix(".codex_") }
        let managed =
            (try? FileManager.default.contentsOfDirectory(at: managedRoot, includingPropertiesForKeys: nil)) ?? []
        return (siblings.sorted { $0.path < $1.path } + managed.sorted { $0.path < $1.path }).filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("auth.json").path)
        }
    }

    nonisolated static var managedRoot: URL {
        AntigravityStoragePaths.canonicalStateDirectoryURL().deletingLastPathComponent()
            .appendingPathComponent("codex-accounts", isDirectory: true)
    }

    /// 표시용으로만 id_token의 이메일을 읽는다. 서명 확인은 하지 않는다.
    nonisolated static func identity(home: URL) -> UsageAccountIdentity? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = object["tokens"] as? [String: Any]
        else { return nil }
        let accountID = tokens["account_id"] as? String
        let claims = (tokens["id_token"] as? String).flatMap(jwtClaims)
        let email = claims?["email"] as? String
        return UsageAccountIdentity(accountID: email, organizationID: accountID, email: email)
    }

    nonisolated static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// 폴더마다 공식 app-server로 사용량을 읽는다. 토큰 갱신도 app-server가 한다.
    nonisolated static func fetchUsage(home: URL, owner: CodexOwnerCLI = CodexOwnerCLI()) async throws
        -> CodexUsageResponse
    {
        let expected = identity(home: home)?.organizationID ?? ""
        do {
            let snapshot = try await owner.readRateLimits(
                sourceURL: home.appendingPathComponent("auth.json"), expectedAccountID: expected,
                budget: CodexRequestBudget(timeout: 20))
            return try usageResponse(fromAppServer: snapshot)
        } catch CodexOwnerError.rejected {
            throw UsageAccountFetchError.loginExpired
        } catch CodexOwnerError.unavailable {
            throw UsageAccountFetchError.unavailable
        }
    }

    /// app-server 응답을 웹 사용량 응답 모양으로 옮겨 기존 해석을 그대로 쓴다.
    nonisolated static func usageResponse(fromAppServer quota: [String: Any]) throws -> CodexUsageResponse {
        let buckets = quota["rateLimitsByLimitId"] as? [String: [String: Any]]
        let limits = buckets?["codex"] ?? quota["rateLimits"] as? [String: Any] ?? [:]
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
