import Foundation

actor AntigravityAPIService {
    private final class ContinuationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false

        func resume(_ action: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            action()
        }

        func hasFinished() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }
    }

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
        let extensionCsrfToken: String?
        let httpsServerPort: Int?
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
        let effectiveCsrfToken = processInfo.csrfToken

        Logger.info("[Antigravity] process pid=\(processInfo.pid) httpsHint=\(processInfo.httpsServerPort.map(String.init) ?? "-") extHint=\(processInfo.extensionPort.map(String.init) ?? "-")")

        // CodexBar 방식: 프로세스 플래그(https_server_port/extension_server_port)와 lsof 결과를
        // 모두 합친 후보 포트 리스트를 만들고, 각 포트에 GetUnleashData probe로 working 포트를 찾음.
        // https_server_port만 쓰는 shortcut은 해당 포트가 닫혔을 때 전체 실패하므로 제거.
        var candidatePorts: [Int] = []
        if let https = processInfo.httpsServerPort { candidatePorts.append(https) }
        if let ext = processInfo.extensionPort { candidatePorts.append(ext) }

        // lsof로 실제 LISTEN 포트를 전부 수집 (실패해도 위의 hint만으로 시도)
        let lsofPorts = (try? await detectListeningPortsAsync(pid: processInfo.pid)) ?? []
        candidatePorts.append(contentsOf: lsofPorts)
        candidatePorts = uniqueOrdered(candidatePorts)
        Logger.info("[Antigravity] candidate ports = \(candidatePorts)")

        guard !candidatePorts.isEmpty else {
            AntigravityStatusProbe.invalidateCache()
            throw APIError.networkError("Antigravity 앱 연결을 확인하지 못했습니다. 앱을 다시 열고 잠시 후 다시 시도해 주세요")
        }

        let connectPort = try await resolveConnectPort(ports: candidatePorts, csrfToken: effectiveCsrfToken)
        Logger.info("[Antigravity] selected working port = \(connectPort)")

        let context = RequestContext(
            httpsPort: connectPort,
            httpPort: processInfo.extensionPort,
            csrfToken: effectiveCsrfToken
        )

        do {
            let response = try await makeRequest(
                path: userStatusPath,
                body: defaultRequestBody(),
                context: context
            )
            return try parseUserStatusResponse(response)
        } catch let apiError as APIError where apiError.isDefinitiveAuthFailure {
            // 401/403: 세션 만료. 캐시 날리고 다음 호출에서 재감지.
            AntigravityStatusProbe.invalidateCache()
            Logger.warning("[Antigravity] auth failure — cache invalidated")
            throw apiError
        } catch {
            Logger.warning("[Antigravity] GetUserStatus 실패: \(error.localizedDescription). GetCommandModelConfigs fallback")
            let response = try await makeRequest(
                path: commandModelConfigPath,
                body: defaultRequestBody(),
                context: context
            )
            return try parseCommandModelResponse(response)
        }
    }

    private func uniqueOrdered(_ values: [Int]) -> [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        for v in values where seen.insert(v).inserted {
            result.append(v)
        }
        return result
    }

    func fetchUsageWithRetry(maxAttempts: Int = 3) async throws -> AntigravityUsageResponse {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await fetchUsage()
            } catch let error as APIError {
                if error.isDefinitiveAuthFailure {
                    // 이미 fetchUsage 내에서 cache invalidate됨
                    throw error
                }
                lastError = error
            } catch {
                lastError = error
            }

            if attempt < maxAttempts {
                // 재시도 전 프로세스 정보를 강제로 재탐지 — 포트/CSRF가 바뀌었을 가능성
                AntigravityStatusProbe.invalidateCache()
                Logger.info("[Antigravity] attempt \(attempt) 실패, cache invalidate 후 재시도")
                let delay = UInt64(pow(2.0, Double(attempt - 1)) * 500_000_000) // 0.5s, 1s
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
            extensionPort: process.extensionPort,
            extensionCsrfToken: process.extensionCsrfToken,
            httpsServerPort: process.httpsServerPort
        )
    }

    /// App Sandbox 제거 후 lsof를 항상 실행합니다. CodexBar와 동일 전략.
    /// 결과가 비어있어도 throw하지 않고 빈 배열을 반환하도록 조정했습니다 —
    /// 호출자가 프로세스 플래그 힌트와 병합해서 사용하도록.
    private func detectListeningPortsAsync(pid: Int) async throws -> [Int] {
        let lsofCandidates = ["/usr/sbin/lsof", "/usr/bin/lsof"]
        guard let executable = lsofCandidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            Logger.warning("[Antigravity] lsof 바이너리 없음")
            return []
        }

        let output = try await runSubprocessAsync(
            executable: executable,
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)],
            timeout: 3.0,
            label: "antigravity-lsof"
        )
        let ports = parseListeningPorts(output)
        Logger.info("[Antigravity] lsof 발견 포트 = \(ports)")
        return ports
    }

    /// `Process` 호출을 termination handler 기반 async로 래핑합니다.
    /// waitUntilExit()의 main thread RunLoop 재진입 이슈를 회피하고 timeout을 강제합니다.
    private func runSubprocessAsync(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        label: String
    ) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            // 동시에 여러 번 resume되지 않도록 보호
            let gate = ContinuationGate()

            process.terminationHandler = { proc in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    gate.resume { continuation.resume(returning: text) }
                } else {
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let errText = String(data: errData, encoding: .utf8) ?? ""
                    gate.resume {
                        continuation.resume(throwing: APIError.networkError(
                            "\(label) exit=\(proc.terminationStatus) stderr=\(errText.prefix(200))"
                        ))
                    }
                }
            }

            do {
                try process.run()
            } catch {
                gate.resume { continuation.resume(throwing: APIError.networkError("\(label) 실행 실패: \(error.localizedDescription)")) }
                return
            }

            // timeout watchdog
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard !gate.hasFinished() else { return }
                if process.isRunning {
                    Logger.warning("[Antigravity] \(label) 타임아웃(\(timeout)s) — terminate")
                    process.terminate()
                }
                gate.resume { continuation.resume(throwing: APIError.networkError("\(label) 타임아웃")) }
            }
        }
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
        // 모든 포트 probe 실패 — 프로세스 정보가 stale할 가능성이 높음
        AntigravityStatusProbe.invalidateCache()
        Logger.warning("[Antigravity] 모든 후보 포트 probe 실패 \(ports) — 캐시 무효화")
        throw APIError.networkError("Antigravity 앱 연결을 확인하지 못했습니다. 앱을 다시 열고 잠시 후 다시 시도해 주세요")
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
            } catch let apiError as APIError where apiError.isDefinitiveAuthFailure {
                // 401/403은 "포트는 살아있지만 토큰이 stale"한 상황.
                // working 포트로 인정하고 상위에서 auth 에러로 처리하도록 한다.
                Logger.info("[Antigravity] port \(port) 응답 있음(auth 실패) — 포트는 OK")
                return true
            } catch {
                Logger.debug("[Antigravity] port \(port) probe 실패: \(error.localizedDescription)")
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
            // 세션/토큰 만료: 호출자가 cache invalidate 할 수 있도록 isDefinitiveAuthFailure로 분류됨
            Logger.warning("[Antigravity] HTTP \(httpResponse.statusCode) — session/token expired (\(scheme)://127.0.0.1:\(port)\(path))")
            throw APIError.invalidSessionKey
        case 429:
            Logger.warning("[Antigravity] HTTP 429 rate limited (\(scheme)://127.0.0.1:\(port)\(path))")
            throw APIError.rateLimited(retryAfter: nil)
        default:
            Logger.warning("[Antigravity] HTTP \(httpResponse.statusCode) (\(scheme)://127.0.0.1:\(port)\(path))")
            throw APIError.serverError(httpResponse.statusCode)
        }
    }
}
