import Foundation

actor AntigravityAPIService {
    private enum AntigravityModelFamily {
        case claude
        case geminiPro
        case geminiFlash
        case unknown
    }

    private struct AntigravityProcessInfo {
        let pid: Int
        let csrfToken: String
        let extensionPort: Int?
    }

    private struct AntigravityModelQuota {
        let label: String
        let modelID: String
        let remainingFraction: Double?
        let resetAtISO: String?
    }

    private struct RequestContext {
        let httpsPort: Int
        let httpPort: Int?
        let csrfToken: String
    }

    private struct UserStatusEnvelope: Decodable {
        let code: ResponseCode?
        let userStatus: UserStatusPayload?
    }

    private struct CommandModelConfigEnvelope: Decodable {
        let code: ResponseCode?
        let clientModelConfigs: [ModelConfigPayload]?
    }

    private struct UserStatusPayload: Decodable {
        let email: String?
        let planStatus: PlanStatusPayload?
        let cascadeModelConfigData: CascadeModelConfigDataPayload?
    }

    private struct PlanStatusPayload: Decodable {
        let planInfo: PlanInfoPayload?
    }

    private struct PlanInfoPayload: Decodable {
        let planName: String?
        let planDisplayName: String?
        let displayName: String?
        let productName: String?
        let planShortName: String?

        var preferredName: String? {
            [
                planDisplayName,
                displayName,
                productName,
                planName,
                planShortName,
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        }
    }

    private struct CascadeModelConfigDataPayload: Decodable {
        let clientModelConfigs: [ModelConfigPayload]?
    }

    private struct ModelConfigPayload: Decodable {
        let label: String
        let modelOrAlias: ModelAliasPayload
        let quotaInfo: QuotaInfoPayload?
    }

    private struct ModelAliasPayload: Decodable {
        let model: String
    }

    private struct QuotaInfoPayload: Decodable {
        let remainingFraction: Double?
        let resetTime: String?
    }

    private enum ResponseCode: Decodable {
        case int(Int)
        case string(String)

        var isOK: Bool {
            switch self {
            case .int(let value):
                return value == 0
            case .string(let value):
                let lower = value.lowercased()
                return lower == "ok" || lower == "success" || value == "0"
            }
        }

        var rawValue: String {
            switch self {
            case .int(let value):
                return "\(value)"
            case .string(let value):
                return value
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) {
                self = .int(value)
                return
            }
            if let value = try? container.decode(String.self) {
                self = .string(value)
                return
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported response code")
        }
    }

    private final class InsecureSessionDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            #if canImport(FoundationNetworking)
            completionHandler(.performDefaultHandling, nil)
            #else
            let trust = challenge.protectionSpace.serverTrust
            let credential = trust.map(URLCredential.init(trust:))
            completionHandler(credential == nil ? .performDefaultHandling : .useCredential, credential)
            #endif
        }
    }

    private let timeout: TimeInterval = 8
    private let unleashPath = "/exa.language_server_pb.LanguageServerService/GetUnleashData"
    private let userStatusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    private let commandModelConfigPath = "/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs"

    func fetchUsage() async throws -> AntigravityUsageResponse {
        let processInfo = try detectProcessInfo()
        let listeningPorts = try detectListeningPorts(pid: processInfo.pid, preferredPort: processInfo.extensionPort)
        let connectPort = try await resolveConnectPort(
            ports: listeningPorts,
            csrfToken: processInfo.csrfToken
        )

        let context = RequestContext(
            httpsPort: connectPort,
            httpPort: processInfo.extensionPort,
            csrfToken: processInfo.csrfToken
        )

        do {
            let response = try await makeRequest(
                path: userStatusPath,
                body: defaultRequestBody(),
                context: context
            )
            return try parseUserStatusResponse(response)
        } catch let apiError as APIError {
            if apiError.isDefinitiveAuthFailure {
                throw apiError
            }
        } catch {
            let response = try await makeRequest(
                path: commandModelConfigPath,
                body: defaultRequestBody(),
                context: context
            )
            return try parseCommandModelResponse(response)
        }

        let response = try await makeRequest(
            path: commandModelConfigPath,
            body: defaultRequestBody(),
            context: context
        )
        return try parseCommandModelResponse(response)
    }

    func fetchUsageWithRetry(maxAttempts: Int = 3) async throws -> AntigravityUsageResponse {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await fetchUsage()
            } catch let error as APIError {
                if error.isDefinitiveAuthFailure {
                    throw error
                }
                lastError = error
            } catch {
                lastError = error
            }

            if attempt < maxAttempts {
                let delay = UInt64(pow(2.0, Double(attempt - 1)) * 1_000_000_000)
                try await Task.sleep(nanoseconds: delay)
            }
        }

        if let apiError = lastError as? APIError {
            throw apiError
        }
        throw APIError.unknownError(lastError?.localizedDescription ?? "Antigravity 사용량 조회 실패")
    }

    private func parseUserStatusResponse(_ data: Data) throws -> AntigravityUsageResponse {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(UserStatusEnvelope.self, from: data)
        if let code = envelope.code, !code.isOK {
            throw APIError.unknownError("Antigravity 응답 코드 \(code.rawValue)")
        }
        guard let userStatus = envelope.userStatus else {
            throw APIError.parseError
        }

        let quotas = (userStatus.cascadeModelConfigData?.clientModelConfigs ?? []).compactMap(quota(from:))
        return buildUsageResponse(
            quotas: quotas,
            accountEmail: userStatus.email,
            accountPlan: userStatus.planStatus?.planInfo?.preferredName
        )
    }

    private func parseCommandModelResponse(_ data: Data) throws -> AntigravityUsageResponse {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(CommandModelConfigEnvelope.self, from: data)
        if let code = envelope.code, !code.isOK {
            throw APIError.unknownError("Antigravity 응답 코드 \(code.rawValue)")
        }

        let quotas = (envelope.clientModelConfigs ?? []).compactMap(quota(from:))
        return buildUsageResponse(
            quotas: quotas,
            accountEmail: nil,
            accountPlan: nil
        )
    }

    private func buildUsageResponse(
        quotas: [AntigravityModelQuota],
        accountEmail: String?,
        accountPlan: String?
    ) -> AntigravityUsageResponse {
        let primary = representativeQuota(for: .claude, in: quotas) ?? fallbackQuota(in: quotas)
        let secondary = representativeQuota(for: .geminiPro, in: quotas)
        let tertiary = representativeQuota(for: .geminiFlash, in: quotas)

        return AntigravityUsageResponse(
            accountEmail: accountEmail,
            accountPlan: accountPlan,
            primaryWindow: primary.map(window(from:)),
            secondaryWindow: secondary.map(window(from:)),
            tertiaryWindow: tertiary.map(window(from:))
        )
    }

    private func window(from quota: AntigravityModelQuota) -> AntigravityUsageWindow {
        let remaining = max(0, min(1, quota.remainingFraction ?? 0))
        return AntigravityUsageWindow(
            label: label(for: quota),
            modelID: quota.modelID,
            usedPercent: (1 - remaining) * 100,
            resetAtISO: quota.resetAtISO
        )
    }

    private func label(for quota: AntigravityModelQuota) -> String {
        switch family(for: quota) {
        case .claude:
            return "Claude"
        case .geminiPro:
            return "Gemini Pro"
        case .geminiFlash:
            return "Gemini Flash"
        case .unknown:
            return quota.label
        }
    }

    private func representativeQuota(
        for family: AntigravityModelFamily,
        in quotas: [AntigravityModelQuota]
    ) -> AntigravityModelQuota? {
        let candidates = quotas.filter { self.family(for: $0) == family }
        guard !candidates.isEmpty else { return nil }

        return candidates.min { lhs, rhs in
            let lhsPriority = priority(for: lhs, in: family)
            let rhsPriority = priority(for: rhs, in: family)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            let lhsRemaining = lhs.remainingFraction ?? 1
            let rhsRemaining = rhs.remainingFraction ?? 1
            if lhsRemaining != rhsRemaining {
                return lhsRemaining < rhsRemaining
            }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    private func fallbackQuota(in quotas: [AntigravityModelQuota]) -> AntigravityModelQuota? {
        quotas.min { lhs, rhs in
            let lhsRemaining = lhs.remainingFraction ?? 1
            let rhsRemaining = rhs.remainingFraction ?? 1
            if lhsRemaining != rhsRemaining {
                return lhsRemaining < rhsRemaining
            }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    private func priority(for quota: AntigravityModelQuota, in family: AntigravityModelFamily) -> Int {
        let text = "\(quota.label) \(quota.modelID)".lowercased()
        switch family {
        case .claude:
            return text.contains("thinking") ? 1 : 0
        case .geminiPro:
            return text.contains("pro-low") || (text.contains("pro") && text.contains("low")) ? 0 : 1
        case .geminiFlash:
            return text.contains("flash-lite") || text.contains("lite") ? 1 : 0
        case .unknown:
            return 0
        }
    }

    private func family(for quota: AntigravityModelQuota) -> AntigravityModelFamily {
        let text = "\(quota.label) \(quota.modelID)".lowercased()
        if text.contains("claude") {
            return .claude
        }
        if text.contains("gemini"), text.contains("pro") {
            return .geminiPro
        }
        if text.contains("gemini"), text.contains("flash") {
            return .geminiFlash
        }
        return .unknown
    }

    private func quota(from config: ModelConfigPayload) -> AntigravityModelQuota? {
        guard let quotaInfo = config.quotaInfo else { return nil }
        return AntigravityModelQuota(
            label: config.label,
            modelID: config.modelOrAlias.model,
            remainingFraction: quotaInfo.remainingFraction,
            resetAtISO: normalizedResetTime(quotaInfo.resetTime)
        )
    }

    private func normalizedResetTime(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if ISO8601DateFormatter().date(from: value) != nil {
            return value
        }
        guard let seconds = Double(value) else { return nil }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
    }

    private func detectProcessInfo() throws -> AntigravityProcessInfo {
        guard let process = AntigravityStatusProbe.runningProcess() else {
            throw APIError.networkError("Antigravity language server가 실행 중이 아닙니다")
        }

        guard let csrfToken = process.csrfToken, !csrfToken.isEmpty else {
            throw APIError.networkError("Antigravity는 실행 중이지만 연결 토큰을 찾지 못했습니다")
        }

        return AntigravityProcessInfo(
            pid: process.pid,
            csrfToken: csrfToken,
            extensionPort: process.extensionPort
        )
    }

    private func detectListeningPorts(pid: Int, preferredPort: Int?) throws -> [Int] {
        let lsofCandidates = ["/usr/sbin/lsof", "/usr/bin/lsof"]
        guard let executable = lsofCandidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            if let preferredPort {
                return [preferredPort]
            }
            throw APIError.networkError("lsof가 없습니다")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let raw = String(decoding: data, as: UTF8.self)
        let ports = parseListeningPorts(raw)
        guard !ports.isEmpty else {
            if let preferredPort {
                return [preferredPort]
            }
            throw APIError.networkError("Antigravity는 실행 중이지만 아직 listening port를 열지 않았습니다")
        }
        return ports
    }

    private func parseListeningPorts(_ output: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#) else { return [] }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        var ports = Set<Int>()
        regex.enumerateMatches(in: output, options: [], range: range) { match, _, _ in
            guard let match,
                  let matchRange = Range(match.range(at: 1), in: output),
                  let port = Int(output[matchRange]) else { return }
            ports.insert(port)
        }
        return ports.sorted()
    }

    private func resolveConnectPort(ports: [Int], csrfToken: String) async throws -> Int {
        for port in ports {
            if await isWorkingConnectPort(port: port, csrfToken: csrfToken) {
                return port
            }
        }
        throw APIError.networkError("Antigravity connect 포트를 찾지 못했습니다. 잠시 후 다시 시도해주세요")
    }

    private func isWorkingConnectPort(port: Int, csrfToken: String) async -> Bool {
        let context = RequestContext(httpsPort: port, httpPort: port, csrfToken: csrfToken)
        do {
            _ = try await makeRequest(path: unleashPath, body: unleashRequestBody(), context: context)
            return true
        } catch {
            do {
                _ = try await makeRequest(path: userStatusPath, body: defaultRequestBody(), context: context)
                return true
            } catch {
                return false
            }
        }
    }

    private func defaultRequestBody() -> [String: Any] {
        [
            "metadata": [
                "ideName": "antigravity",
                "extensionName": "antigravity",
                "ideVersion": "unknown",
                "locale": "en",
            ],
        ]
    }

    private func unleashRequestBody() -> [String: Any] {
        [
            "context": [
                "properties": [
                    "devMode": "false",
                    "extensionVersion": "unknown",
                    "hasAnthropicModelAccess": "true",
                    "ide": "antigravity",
                    "ideVersion": "unknown",
                    "installationId": "claudeusage",
                    "language": "UNSPECIFIED",
                    "os": "macos",
                    "requestedModelId": "MODEL_UNSPECIFIED",
                ],
            ],
        ]
    }

    private func makeRequest(path: String, body: [String: Any], context: RequestContext) async throws -> Data {
        do {
            return try await sendRequest(
                scheme: "https",
                port: context.httpsPort,
                path: path,
                body: body,
                csrfToken: context.csrfToken
            )
        } catch {
            let fallbackPorts = [context.httpPort, context.httpsPort]
                .compactMap { $0 }
                .filter { $0 != context.httpsPort } + [context.httpsPort]

            for port in fallbackPorts {
                do {
                    return try await sendRequest(
                        scheme: "http",
                        port: port,
                        path: path,
                        body: body,
                        csrfToken: context.csrfToken
                    )
                } catch {
                    continue
                }
            }

            throw error
        }
    }

    private func sendRequest(
        scheme: String,
        port: Int,
        path: String,
        body: [String: Any],
        csrfToken: String
    ) async throws -> Data {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(path)") else {
            throw APIError.parseError
        }

        let payload = try JSONSerialization.data(withJSONObject: body, options: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(String(payload.count), forHTTPHeaderField: "Content-Length")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: InsecureSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError("Invalid HTTP response")
        }

        switch httpResponse.statusCode {
        case 200:
            return data
        case 401, 403:
            throw APIError.invalidSessionKey
        case 429:
            throw APIError.rateLimited(retryAfter: nil)
        default:
            throw APIError.serverError(httpResponse.statusCode)
        }
    }
}
