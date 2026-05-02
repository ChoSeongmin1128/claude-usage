import Foundation

struct ClaudeCodeOAuthCredential: Equatable, Sendable {
    let accessToken: String
    let expiresAt: Date?

    nonisolated var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt.addingTimeInterval(-300)
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
    private var discoveredServiceNames: [String] = []
    private var didDiscoverServiceNames = false
    private var cachedCredential: ClaudeCodeOAuthCredential?

    init(
        homeDirectory: URL = FileManager.default.realHomeDirectory,
        profileMetadataStore: ClaudeProfileMetadataStore? = nil,
        preflightChecker: @escaping PreflightChecker = { service, account in
            KeychainAccessPreflight.checkGenericPassword(service: service, account: account)
        },
        securityCommandRunner: @escaping SecurityCommandRunner = { arguments, timeout in
            try await ClaudeCodeCredentialReader.runSecurityCommand(arguments: arguments, timeout: timeout)
        }
    ) {
        self.homeDirectory = homeDirectory
        self.profileMetadataStore = profileMetadataStore
        self.preflightChecker = preflightChecker
        self.securityCommandRunner = securityCommandRunner
    }

    func readAccessToken() async throws -> String? {
        try await readCredential()?.accessToken
    }

    func readCredential() async throws -> ClaudeCodeOAuthCredential? {
        if let cachedCredential, !cachedCredential.isExpired {
            return cachedCredential
        }
        cachedCredential = nil

        if let credential = await readCredentialFromFiles() {
            cachedCredential = credential
            return credential
        }

        let primaryService = "Claude Code-credentials"
        let preflightResult = preflightChecker(primaryService, NSUserName())
        if case .interactionRequired = preflightResult {
            Logger.info("키체인 접근 시 UI 프롬프트 필요 — 파일 기반 인증만 사용")
            return nil
        }

        if let payload = try? await readKeychainPayload(serviceName: primaryService),
           let credential = await decodeCredential(from: payload, sourceDescription: "키체인 서비스: \(primaryService)") {
            cachedCredential = credential
            return credential
        }

        let discoveredServices = await getDiscoveredServiceNames().filter { $0 != primaryService }
        if !discoveredServices.isEmpty {
            Logger.debug("OAuth 토큰 조회: 추가 키체인 서비스 \(discoveredServices.count)개 후보")
        }
        for service in discoveredServices {
            guard let payload = try? await readKeychainPayload(serviceName: service),
                  let credential = await decodeCredential(from: payload, sourceDescription: "키체인 서비스: \(service)")
            else { continue }
            cachedCredential = credential
            return credential
        }

        Logger.warning("OAuth 토큰 조회 실패 (파일/키체인 모두 실패)")
        return nil
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

            if let credential = await decodeCredential(from: text, sourceDescription: "파일: \(fileURL.lastPathComponent)") {
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

    private func decodeCredential(from credentialsText: String, sourceDescription: String) async -> ClaudeCodeOAuthCredential? {
        guard let credential = parseCredential(from: credentialsText) else {
            return nil
        }

        if let profileMetadataStore {
            _ = await profileMetadataStore.update(from: credentialsText)
        }

        if credential.isExpired {
            Logger.warning("OAuth 토큰이 만료되어 건너뜀 (\(sourceDescription))")
            return nil
        }

        Logger.info("OAuth 토큰 조회 성공 (\(sourceDescription))")
        return credential
    }

    private func parseCredential(from credentialsText: String) -> ClaudeCodeOAuthCredential? {
        if let data = credentialsText.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = json["claudeAiOauth"] as? [String: Any] {
            let token = firstNonEmptyString(oauth["accessToken"], json["accessToken"])
            let expiresAt = firstDateValue(oauth["expiresAt"], json["expiresAt"])
            if let token, !token.isEmpty {
                return ClaudeCodeOAuthCredential(accessToken: token, expiresAt: expiresAt)
            }
        }

        if let token = extractAccessTokenByRegex(from: credentialsText) {
            return ClaudeCodeOAuthCredential(accessToken: token, expiresAt: nil)
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
