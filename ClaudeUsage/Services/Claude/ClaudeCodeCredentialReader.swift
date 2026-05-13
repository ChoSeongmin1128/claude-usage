import Foundation

struct ClaudeCodeOAuthCredential: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    /// 어디서 읽혔는지를 식별. refresh 결과를 적절한 위치에 다시 쓸지 결정할 때 사용.
    /// 현재는 정보 용도(in-memory 캐시만 유지)지만 추후 파일 갱신 등 확장 여지.
    let source: Source

    enum Source: Equatable, Sendable {
        case file(URL)
        case keychain(service: String)
        case refreshed
    }

    nonisolated init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        source: Source = .refreshed
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.source = source
    }

    nonisolated var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt.addingTimeInterval(-300)
    }

    /// access token 이 만료되어도 refresh token 으로 갱신 가능한 상태인가.
    nonisolated var canAttemptRefresh: Bool {
        guard let refreshToken else { return false }
        return !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct ClaudeCodeSecurityCommandResult: Equatable, Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

actor ClaudeCodeCredentialReader {
    typealias PreflightChecker = @Sendable (_ service: String, _ account: String?) -> KeychainAccessPreflight.Outcome
    typealias SecurityCommandRunner = @Sendable (_ arguments: [String], _ timeout: TimeInterval) async throws -> ClaudeCodeSecurityCommandResult?

    private let homeDirectory: URL
    private let profileMetadataStore: ClaudeProfileMetadataStore?
    private let preflightChecker: PreflightChecker
    private let securityCommandRunner: SecurityCommandRunner
    private let tokenRefresher: ClaudeOAuthTokenRefresher
    private var discoveredServiceNames: [String] = []
    private var didDiscoverServiceNames = false
    private var cachedCredential: ClaudeCodeOAuthCredential?

    init(
        homeDirectory: URL = FileManager.default.realHomeDirectory,
        profileMetadataStore: ClaudeProfileMetadataStore? = nil,
        tokenRefresher: ClaudeOAuthTokenRefresher = ClaudeOAuthTokenRefresher(),
        preflightChecker: @escaping PreflightChecker = { service, account in
            KeychainAccessPreflight.checkGenericPassword(service: service, account: account)
        },
        securityCommandRunner: @escaping SecurityCommandRunner = { arguments, timeout in
            try await ClaudeCodeCredentialReader.runSecurityCommand(arguments: arguments, timeout: timeout)
        }
    ) {
        self.homeDirectory = homeDirectory
        self.profileMetadataStore = profileMetadataStore
        self.tokenRefresher = tokenRefresher
        self.preflightChecker = preflightChecker
        self.securityCommandRunner = securityCommandRunner
    }

    func readAccessToken() async throws -> String? {
        try await readCredential()?.accessToken
    }

    /// 401 등으로 캐시된 토큰이 거부됐을 때 외부에서 호출해 즉시 refresh 를 시도하게 한다.
    /// 성공하면 새 access token, 실패하면 nil (caller 가 적절히 폴백).
    func forceRefreshAccessToken() async -> String? {
        let credential: ClaudeCodeOAuthCredential?
        if let cached = cachedCredential {
            credential = cached
        } else {
            credential = try? await readCredential()
        }
        guard let credential, credential.canAttemptRefresh else { return nil }
        do {
            let refreshed = try await tokenRefresher.refresh(credential)
            cachedCredential = refreshed
            return refreshed.accessToken
        } catch {
            Logger.warning("OAuth refresh 강제 시도 실패: \(error.localizedDescription)")
            return nil
        }
    }

    func readCredential() async throws -> ClaudeCodeOAuthCredential? {
        if let cachedCredential, !cachedCredential.isExpired {
            return cachedCredential
        }
        // 캐시는 만료됐지만 refresh token 이 살아있으면 refresh 한 번 시도.
        if let cached = cachedCredential, cached.canAttemptRefresh {
            if let refreshed = await attemptRefresh(of: cached) {
                cachedCredential = refreshed
                return refreshed
            }
        }
        cachedCredential = nil

        if let credential = await readCredentialFromFiles() {
            if let usable = await ensureUsable(credential) {
                cachedCredential = usable
                return usable
            }
        }

        let primaryService = "Claude Code-credentials"
        let preflightResult = preflightChecker(primaryService, NSUserName())
        if case .interactionRequired = preflightResult {
            Logger.info("키체인 접근 시 UI 프롬프트 필요 — 파일 기반 인증만 사용")
            return nil
        }

        if let payload = try? await readKeychainPayload(serviceName: primaryService),
           let credential = await decodeCredential(
               from: payload,
               source: .keychain(service: primaryService),
               sourceDescription: "키체인 서비스: \(primaryService)"),
           let usable = await ensureUsable(credential)
        {
            cachedCredential = usable
            return usable
        }

        let discoveredServices = await getDiscoveredServiceNames().filter { $0 != primaryService }
        if !discoveredServices.isEmpty {
            Logger.debug("OAuth 토큰 조회: 추가 키체인 서비스 \(discoveredServices.count)개 후보")
        }
        for service in discoveredServices {
            guard let payload = try? await readKeychainPayload(serviceName: service),
                  let credential = await decodeCredential(
                      from: payload,
                      source: .keychain(service: service),
                      sourceDescription: "키체인 서비스: \(service)"),
                  let usable = await ensureUsable(credential)
            else { continue }
            cachedCredential = usable
            return usable
        }

        Logger.warning("OAuth 토큰 조회 실패 (파일/키체인 모두 실패)")
        return nil
    }

    /// decodeCredential 단계에서 expired 토큰도 반환되므로(refresh 가능 여부 판단을 위해)
    /// 이 단계에서 만료 토큰이면 refresh 시도해 정상 토큰을 반환한다.
    /// refresh 가 불가/실패면 nil 을 돌려 caller 가 다른 source 로 폴백하도록 한다.
    private func ensureUsable(_ credential: ClaudeCodeOAuthCredential) async -> ClaudeCodeOAuthCredential? {
        if !credential.isExpired { return credential }
        return await attemptRefresh(of: credential)
    }

    private func attemptRefresh(of credential: ClaudeCodeOAuthCredential) async -> ClaudeCodeOAuthCredential? {
        guard credential.canAttemptRefresh else { return nil }
        do {
            let refreshed = try await tokenRefresher.refresh(credential)
            return refreshed
        } catch {
            Logger.warning("OAuth refresh 실패: \(error.localizedDescription)")
            return nil
        }
    }

    private func readCredentialFromFiles() async -> ClaudeCodeOAuthCredential? {
        let candidates = [
            homeDirectory.appendingPathComponent(".claude/.credentials.json"),
            homeDirectory.appendingPathComponent(".claude/credentials.json")
        ]

        for fileURL in candidates {
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8),
                  !text.isEmpty else { continue }

            if let credential = await decodeCredential(
                from: text,
                source: .file(fileURL),
                sourceDescription: "파일: \(fileURL.lastPathComponent)")
            {
                return credential
            }
        }

        Logger.debug("OAuth 토큰 파일 조회 실패 (~/.claude)")
        return nil
    }

    private func readKeychainPayload(serviceName: String) async throws -> String? {
        guard let result = try await securityCommandRunner(
            [
                "find-generic-password",
                "-s", serviceName,
                "-a", NSUserName(),
                "-w"
            ],
            2.5
        ) else {
            Logger.warning("키체인 조회 타임아웃(service: \(serviceName))")
            return nil
        }

        if result.status == 44 {
            return nil
        }

        guard result.status == 0 else {
            let errorMessage = result.stderr.isEmpty ? "unknown error" : result.stderr
            throw APIError.unknownError("시스템 키체인 오류(code: \(result.status), service: \(serviceName)): \(errorMessage)")
        }

        let credentials = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return credentials.isEmpty ? nil : credentials
    }

    private func getDiscoveredServiceNames() async -> [String] {
        if didDiscoverServiceNames {
            return discoveredServiceNames
        }
        didDiscoverServiceNames = true
        discoveredServiceNames = await discoverServiceNames()
        return discoveredServiceNames
    }

    private func discoverServiceNames() async -> [String] {
        guard let result = try? await securityCommandRunner(["dump-keychain"], 1.0) else {
            Logger.debug("키체인 서비스 탐색 타임아웃")
            return []
        }

        guard result.status == 0, !result.stdout.isEmpty else {
            return []
        }

        let pattern = #""svce"<blob>="(Claude Code-credentials[^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let output = result.stdout
        let nsrange = NSRange(output.startIndex..<output.endIndex, in: output)
        return regex.matches(in: output, range: nsrange).compactMap { match in
            guard match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: output) else { return nil }
            return String(output[range])
        }
    }

    private func decodeCredential(
        from credentialsText: String,
        source: ClaudeCodeOAuthCredential.Source,
        sourceDescription: String
    ) async -> ClaudeCodeOAuthCredential? {
        guard let credential = parseCredential(from: credentialsText, source: source) else {
            return nil
        }

        if let profileMetadataStore {
            _ = await profileMetadataStore.update(from: credentialsText)
        }

        if credential.isExpired {
            // 만료된 토큰이라도 refresh 가능하면 caller 가 refresh 를 시도할 수 있도록 반환한다.
            // refresh token 이 없을 때만 nil 처리해 caller 가 즉시 폴백하게 한다.
            if credential.canAttemptRefresh {
                Logger.info("OAuth access token 만료 — refresh 시도 가능 (\(sourceDescription))")
                return credential
            }
            Logger.warning("OAuth 토큰이 만료되어 건너뜀 (\(sourceDescription))")
            return nil
        }

        Logger.info("OAuth 토큰 조회 성공 (\(sourceDescription))")
        return credential
    }

    private func parseCredential(
        from credentialsText: String,
        source: ClaudeCodeOAuthCredential.Source
    ) -> ClaudeCodeOAuthCredential? {
        if let data = credentialsText.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = json["claudeAiOauth"] as? [String: Any] {
            let token = firstNonEmptyString(oauth["accessToken"], json["accessToken"])
            let refreshToken = firstNonEmptyString(oauth["refreshToken"], json["refreshToken"])
            let expiresAt = firstDateValue(oauth["expiresAt"], json["expiresAt"])
            if let token, !token.isEmpty {
                return ClaudeCodeOAuthCredential(
                    accessToken: token,
                    refreshToken: refreshToken,
                    expiresAt: expiresAt,
                    source: source)
            }
        }

        if let token = extractAccessTokenByRegex(from: credentialsText) {
            return ClaudeCodeOAuthCredential(
                accessToken: token,
                refreshToken: nil,
                expiresAt: nil,
                source: source)
        }
        return nil
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

    private func firstNonEmptyString(_ values: Any?...) -> String? {
        for value in values {
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private func firstDateValue(_ values: Any?...) -> Date? {
        for value in values {
            if let string = value as? String {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = iso.date(from: string) {
                    return date
                }
                iso.formatOptions = [.withInternetDateTime]
                if let date = iso.date(from: string) {
                    return date
                }
            }
            if let timestamp = value as? TimeInterval {
                return Date(timeIntervalSince1970: timestamp)
            }
            if let intTimestamp = value as? Int {
                return Date(timeIntervalSince1970: TimeInterval(intTimestamp))
            }
        }
        return nil
    }

    static func runSecurityCommand(arguments: [String], timeout: TimeInterval) async throws -> ClaudeCodeSecurityCommandResult? {
        final class LockedDataBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var storage = Data()

            func append(_ data: Data) {
                lock.lock()
                storage.append(data)
                lock.unlock()
            }

            func stringValue() -> String {
                lock.lock()
                let snapshot = storage
                lock.unlock()
                return String(data: snapshot, encoding: .utf8) ?? ""
            }
        }

        final class ContinuationGate: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false

            func resume(_ action: () -> Void) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                action()
            }
        }

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

        return try await withCheckedThrowingContinuation { continuation in
            let stdoutBuffer = LockedDataBuffer()
            let stderrBuffer = LockedDataBuffer()
            let gate = ContinuationGate()

            func resumeOnce(with result: Result<ClaudeCodeSecurityCommandResult?, Error>) {
                gate.resume {
                    continuation.resume(with: result)
                }
            }

            let timeoutWork = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                } else {
                    stdoutBuffer.append(data)
                }
            }

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                } else {
                    stderrBuffer.append(data)
                }
            }

            process.terminationHandler = { terminatedProcess in
                timeoutWork.cancel()

                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil

                    guard terminatedProcess.terminationReason != .uncaughtSignal else {
                        resumeOnce(with: .success(nil))
                        return
                    }

                    resumeOnce(
                        with: .success(
                            ClaudeCodeSecurityCommandResult(
                                status: terminatedProcess.terminationStatus,
                                stdout: stdoutBuffer.stringValue(),
                                stderr: stderrBuffer.stringValue()
                            )
                        )
                    )
                }
            }
        }
    }
}
