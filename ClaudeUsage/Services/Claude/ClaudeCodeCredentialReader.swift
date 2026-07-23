import CryptoKit
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

protocol ClaudeOAuthCredentialReading: Sendable {
    func readAccessToken() async throws -> String?
    func refreshCredentialInventoryWithoutUI() async throws -> ClaudeOAuthCredentialInventoryRefresh
    func forceRefreshAccessToken() async -> String?
    func invalidateCache() async
    func importActiveCLICredential() async -> ClaudeOAuthCredentialImportResult
}

nonisolated struct ClaudeOAuthCredentialInventoryRefresh: Equatable, Sendable {
    let accessToken: String?
    let credentialChanged: Bool
}

nonisolated enum ClaudeOAuthCredentialImportResult: Equatable, Sendable {
    case available
    case imported(credentialChanged: Bool)
    case notFound
    case cancelled
    case failed(String)
}

nonisolated enum ClaudeOAuthCredentialImportError: LocalizedError, Sendable {
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "macOS Keychain 인증을 취소했습니다."
        case .failed(let message):
            return message
        }
    }
}

actor ClaudeCodeCredentialReader {
    typealias InteractiveKeychainPayloadReader = @Sendable (
        _ service: String,
        _ account: String?,
        _ localizedReason: String
    ) -> KeychainAccessPreflight.ReadOutcome

    private let homeDirectory: URL
    private let claudeConfigDirectory: URL
    private let usesScopedKeychainService: Bool
    private let profileMetadataStore: ClaudeProfileMetadataStore?
    private let interactiveKeychainPayloadReader: InteractiveKeychainPayloadReader
    private let tokenRefresher: ClaudeOAuthTokenRefresher
    private let appCredentialVault: any ClaudeOAuthCredentialVault
    private let cacheTTL: TimeInterval
    private let now: @Sendable () -> Date
    private var cachedResult: CachedResult?
    private var inFlightRead: Task<ClaudeCodeOAuthCredential?, Error>?
    private var cacheGeneration = 0

    private struct CachedResult: Sendable {
        let credential: ClaudeCodeOAuthCredential?
        let storedAt: Date
    }

    init(
        homeDirectory: URL = FileManager.default.realHomeDirectory,
        claudeConfigDirectory: URL? = nil,
        profileMetadataStore: ClaudeProfileMetadataStore? = nil,
        tokenRefresher: ClaudeOAuthTokenRefresher = ClaudeOAuthTokenRefresher(),
        appCredentialVault: any ClaudeOAuthCredentialVault = KeychainClaudeOAuthCredentialVault.shared,
        cacheTTL: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = Date.init,
        interactiveKeychainPayloadReader: @escaping InteractiveKeychainPayloadReader = { service, account, reason in
            KeychainAccessPreflight.readGenericPasswordInteractively(
                service: service,
                account: account,
                localizedReason: reason
            )
        }
    ) {
        let environmentConfigDirectory = Self.explicitClaudeConfigDirectoryFromEnvironment()
        let resolvedConfigDirectory = claudeConfigDirectory
            ?? environmentConfigDirectory
            ?? homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        self.homeDirectory = homeDirectory
        self.claudeConfigDirectory = resolvedConfigDirectory
        self.usesScopedKeychainService = claudeConfigDirectory != nil
            || environmentConfigDirectory != nil
        self.profileMetadataStore = profileMetadataStore
        self.tokenRefresher = tokenRefresher
        self.appCredentialVault = appCredentialVault
        self.cacheTTL = cacheTTL
        self.now = now
        self.interactiveKeychainPayloadReader = interactiveKeychainPayloadReader
    }

    func readAccessToken() async throws -> String? {
        try await readCredential()?.accessToken
    }

    /// Refreshes the active Claude credential inventory without touching the
    /// Claude CLI-owned Keychain item.
    ///
    /// Classic Keychain ACL items can surface an Allow/Deny password dialog even
    /// when a SecItem query requests no UI. Therefore automatic bootstrap,
    /// account switching, and usage refreshes are restricted to the app vault and
    /// credential files. The CLI Keychain is read only by
    /// `importActiveCLICredential()` after an explicit user action.
    func refreshCredentialInventoryWithoutUI() async throws -> ClaudeOAuthCredentialInventoryRefresh {
        let previousAccessToken: String?
        if let cachedAccessToken = cachedResult?.credential?.accessToken {
            previousAccessToken = cachedAccessToken
        } else if let payload = try appCredentialVault.loadPayload() {
            previousAccessToken = parseCredential(
                from: payload,
                source: .refreshed
            )?.accessToken
        } else {
            previousAccessToken = nil
        }
        invalidateCache()

        return try await loadFileThenVaultInventoryFallback(
            previousAccessToken: previousAccessToken
        )
    }

    /// 401 등으로 캐시된 토큰이 거부됐을 때 외부에서 호출해 즉시 refresh 를 시도하게 한다.
    /// 성공하면 새 access token, 실패하면 nil (caller 가 적절히 폴백).
    func forceRefreshAccessToken() async -> String? {
        let credential: ClaudeCodeOAuthCredential?
        if let cached = cachedResult?.credential {
            credential = cached
        } else {
            credential = try? await readCredential()
        }
        guard let credential, credential.canAttemptRefresh else { return nil }
        do {
            let refreshed = try await tokenRefresher.refresh(credential)
            cachedResult = CachedResult(credential: refreshed, storedAt: now())
            // 영구 저장: 다음 부팅 시 옛 RT 로 호출하지 않도록 우리 캐시 keychain 에 write-back.
            await persistRefreshedCredentialToKeychain(refreshed)
            return refreshed.accessToken
        } catch ClaudeOAuthTokenRefresher.RefreshError.invalidGrant {
            // RT 가 서버에서 invalidate 됨 — 우리 캐시도 의미 없으므로 지운다.
            // 다음 readCredential 호출 시 파일/CLI keychain 으로 자연 폴백.
            await deleteRefreshedCredentialFromKeychain()
            Logger.warning("OAuth refresh invalid_grant — 캐시 삭제 후 file/CLI fallback")
            return nil
        } catch {
            Logger.warning("OAuth refresh 강제 시도 실패: \(error.localizedDescription)")
            return nil
        }
    }

    func readCredential() async throws -> ClaudeCodeOAuthCredential? {
        if let cachedResult,
           now().timeIntervalSince(cachedResult.storedAt) < cacheTTL,
           cachedResult.credential?.isExpired != true
        {
            return cachedResult.credential
        }

        if let inFlightRead {
            return try await inFlightRead.value
        }

        let generation = cacheGeneration
        let task = Task { try await performCredentialLookup() }
        inFlightRead = task
        do {
            let result = try await task.value
            if generation == cacheGeneration {
                cachedResult = CachedResult(credential: result, storedAt: now())
                inFlightRead = nil
            }
            return result
        } catch {
            if generation == cacheGeneration {
                inFlightRead = nil
            }
            throw error
        }
    }

    func invalidateCache() {
        cacheGeneration &+= 1
        inFlightRead?.cancel()
        inFlightRead = nil
        cachedResult = nil
    }

    /// Explicit Claude Code connection flow. Background reads never reach this
    /// method; one exact active-config item may show macOS Keychain UI once.
    func importActiveCLICredential() async -> ClaudeOAuthCredentialImportResult {
        invalidateCache()

        let vaultCredential: ClaudeCodeOAuthCredential?
        do {
            vaultCredential = try await loadVaultCredential()
        } catch {
            return .failed("앱 OAuth 저장소를 읽지 못했습니다.")
        }

        let service = Self.keychainServiceName(
            for: claudeConfigDirectory,
            homeDirectory: homeDirectory,
            usesExplicitConfigDirectory: usesScopedKeychainService
        )
        let outcome = interactiveKeychainPayloadReader(
            service,
            NSUserName(),
            "Claude Code 로그인을 ClaudeUsage에 연결합니다."
        )
        switch outcome {
        case .value(let payload):
            guard let credential = await decodeCredential(
                from: payload,
                source: .keychain(service: service),
                sourceDescription: "Claude Code Keychain"
            ), let usable = await ensureUsable(credential) else {
                return .failed("Claude Code 로그인 정보가 유효하지 않습니다. 터미널에서 다시 로그인해 주세요.")
            }
            do {
                if !credential.isExpired {
                    try appCredentialVault.savePayload(payload)
                }
                guard let verifiedPayload = try appCredentialVault.loadPayload(),
                      parseCredential(from: verifiedPayload, source: .refreshed) != nil else {
                    return .failed("Claude Code 로그인 정보를 앱 저장소에 검증하지 못했습니다.")
                }
            } catch {
                return .failed("Claude Code 로그인 정보를 앱 저장소에 저장하지 못했습니다.")
            }
            cachedResult = CachedResult(credential: usable, storedAt: now())
            return .imported(
                credentialChanged: vaultCredential != nil
                    && vaultCredential?.accessToken != usable.accessToken
            )
        case .notFound:
            if let credential = await readCredentialFromFiles(),
               let usable = await ensureUsable(credential) {
                await persistRefreshedCredentialToKeychain(usable)
                cachedResult = CachedResult(credential: usable, storedAt: now())
                return .imported(
                    credentialChanged: vaultCredential != nil
                        && vaultCredential?.accessToken != usable.accessToken
                )
            }
            guard let vaultCredential else { return .notFound }
            cachedResult = CachedResult(credential: vaultCredential, storedAt: now())
            return .available
        case .cancelled:
            return .cancelled
        case .interactionRequired:
            return .failed("macOS Keychain 인증을 시작하지 못했습니다.")
        case .invalidData:
            return .failed("Claude Code Keychain 데이터가 유효하지 않습니다.")
        case .failure(let status):
            return .failed("macOS Keychain 오류가 발생했습니다(code: \(status)).")
        }
    }

    private func loadVaultCredential() async throws -> ClaudeCodeOAuthCredential? {
        guard let payload = try appCredentialVault.loadPayload() else { return nil }
        guard let credential = await decodeCredential(
            from: payload,
            source: .refreshed,
            sourceDescription: "앱 OAuth vault"
        ) else {
            return nil
        }
        return await ensureUsable(credential)
    }

    private func performCredentialLookup() async throws -> ClaudeCodeOAuthCredential? {
        do {
            if let payload = try appCredentialVault.loadPayload() {
                guard let credential = await decodeCredential(
                    from: payload,
                    source: .refreshed,
                    sourceDescription: "앱 OAuth vault"
                ) else {
                    Logger.warning("앱 OAuth vault payload가 유효하지 않아 외부 credential 조회를 중단합니다")
                    return nil
                }
                return await ensureUsable(credential)
            }
        } catch {
            // A temporarily locked or otherwise unavailable app-owned vault is not
            // equivalent to a cache miss. Falling through could select a different
            // CLI account or trigger classic Keychain ACL UI.
            Logger.warning("앱 OAuth vault 조회 실패 — 외부 credential 조회를 중단합니다")
            return nil
        }

        if let credential = await readCredentialFromFiles(),
           let usable = await ensureUsable(credential) {
            return usable
        }

        Logger.warning("OAuth 토큰 조회 실패 (앱 vault/활성 config 파일 모두 실패)")
        return nil
    }

    private func loadFileThenVaultInventoryFallback(
        previousAccessToken: String?
    ) async throws -> ClaudeOAuthCredentialInventoryRefresh {
        if let credential = await readCredentialFromFiles(),
           let usable = await ensureUsable(credential) {
            await persistRefreshedCredentialToKeychain(usable)
            cachedResult = CachedResult(credential: usable, storedAt: now())
            return ClaudeOAuthCredentialInventoryRefresh(
                accessToken: usable.accessToken,
                credentialChanged: previousAccessToken != nil
                    && previousAccessToken != usable.accessToken
            )
        }

        let fallback = try await loadVaultCredential()
        cachedResult = CachedResult(credential: fallback, storedAt: now())
        return ClaudeOAuthCredentialInventoryRefresh(
            accessToken: fallback?.accessToken,
            credentialChanged: false
        )
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
            // 영구 저장: 다음 부팅 시 옛 RT 로 호출하지 않게 한다.
            await persistRefreshedCredentialToKeychain(refreshed)
            return refreshed
        } catch ClaudeOAuthTokenRefresher.RefreshError.invalidGrant {
            // 캐시가 만료된 RT 의 invalidate 일 수 있으므로 캐시 삭제 후 nil 반환.
            // caller 가 file/CLI keychain 으로 폴백한다.
            await deleteRefreshedCredentialFromKeychain()
            Logger.warning("OAuth refresh invalid_grant — 캐시 삭제 후 file/CLI fallback")
            return nil
        } catch {
            Logger.warning("OAuth refresh 실패: \(error.localizedDescription)")
            return nil
        }
    }

    /// 우리 앱 전용 캐시 keychain item 에 새 credential 을 atomic write-back.
    /// Anthropic CLI 의 `Claude Code-credentials` 는 절대 건드리지 않는다.
    /// 실패해도 in-memory cache 는 살아있어 현재 세션은 정상.
    private func persistRefreshedCredentialToKeychain(_ credential: ClaudeCodeOAuthCredential) async {
        let payload = Self.serializeCredentialAsAuthJSON(credential)
        do {
            try appCredentialVault.savePayload(payload)
        } catch {
            Logger.warning("OAuth refresh 캐시 저장 실패")
        }
    }

    private func deleteRefreshedCredentialFromKeychain() async {
        do {
            try appCredentialVault.deletePayload()
        } catch {
            Logger.warning("OAuth refresh 캐시 삭제 실패")
        }
        cachedResult = nil
    }

    /// `~/.claude/.credentials.json` 과 호환되는 JSON 으로 직렬화.
    /// 이렇게 하면 기존 parseCredential 이 그대로 디코딩할 수 있어 read 측 코드 변경 불필요.
    private static func serializeCredentialAsAuthJSON(_ credential: ClaudeCodeOAuthCredential) -> String {
        var inner: [String: Any] = ["accessToken": credential.accessToken]
        if let refreshToken = credential.refreshToken, !refreshToken.isEmpty {
            inner["refreshToken"] = refreshToken
        }
        if let expiresAt = credential.expiresAt {
            // CLI 호환 ms timestamp
            inner["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)
        }
        let payload: [String: Any] = ["claudeAiOauth": inner]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    nonisolated static func keychainServiceName(
        for configDirectory: URL,
        homeDirectory: URL,
        usesExplicitConfigDirectory: Bool? = nil
    ) -> String {
        let normalizedConfig = configDirectory.standardizedFileURL.path
        let normalizedDefault = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .standardizedFileURL
            .path
        let shouldScope = usesExplicitConfigDirectory ?? (normalizedConfig != normalizedDefault)
        guard shouldScope else {
            return "Claude Code-credentials"
        }

        let digest = SHA256.hash(data: Data(normalizedConfig.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(suffix)"
    }

    private nonisolated static func explicitClaudeConfigDirectoryFromEnvironment() -> URL? {
        if let configuredPath = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredPath.isEmpty {
            return URL(fileURLWithPath: configuredPath, isDirectory: true)
        }
        return nil
    }

    private func readCredentialFromFiles() async -> ClaudeCodeOAuthCredential? {
        let candidates = [
            claudeConfigDirectory.appendingPathComponent(".credentials.json"),
            claudeConfigDirectory.appendingPathComponent("credentials.json")
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

        Logger.debug("OAuth 토큰 파일 조회 실패 (\(claudeConfigDirectory.lastPathComponent))")
        return nil
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
                return Date(timeIntervalSince1970: Self.normalizedEpochSeconds(timestamp))
            }
        }
        return nil
    }

    private nonisolated static func normalizedEpochSeconds(_ value: TimeInterval) -> TimeInterval {
        // Claude Code persists expiresAt in milliseconds. Retain compatibility
        // with sources that already use seconds without relying on JSON number type.
        abs(value) >= 10_000_000_000 ? value / 1_000 : value
    }
}

extension ClaudeCodeCredentialReader: ClaudeOAuthCredentialReading {}
