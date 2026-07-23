import CryptoKit
import Foundation

nonisolated struct ClaudeCodeOAuthCredential: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    /// 어디서 읽혔는지를 식별. 회전형 refresh token을 어느 저장소에
    /// write-back할지 결정하는 credential 경계다.
    let source: Source

    enum Source: Equatable, Sendable {
        case file(URL)
        case keychain(service: String)
        case appManagedVault
        case unversionedVaultMirror
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
    func forceRefreshAccessToken() async throws -> String?
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

nonisolated enum ClaudeOAuthCredentialReadError: LocalizedError, Sendable {
    case reauthenticationRequired
    case reconnectRequired

    var errorDescription: String? {
        switch self {
        case .reauthenticationRequired:
            return "Claude Code refresh token이 거부되어 다시 로그인이 필요합니다."
        case .reconnectRequired:
            return "Claude Code 로그인은 유지되고 있지만 ClaudeUsage 연결 정보를 다시 확인해야 합니다."
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
    private var lastReadError: ClaudeOAuthCredentialReadError?

    private struct CachedResult: Sendable {
        let credential: ClaudeCodeOAuthCredential?
        let storedAt: Date
    }

    private enum CredentialFileLookup {
        case missing
        case unavailable
        case credential(ClaudeCodeOAuthCredential)
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
        let credential = try await readCredential()
        if let credential {
            return credential.accessToken
        }
        if let lastReadError {
            throw lastReadError
        }
        return nil
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
        } else {
            do {
                if let payload = try appCredentialVault.loadPayload() {
                    previousAccessToken = parseCredential(
                        from: payload,
                        source: Self.vaultSource(for: payload)
                    )?.accessToken
                } else {
                    previousAccessToken = nil
                }
            } catch {
                lastReadError = .reconnectRequired
                Logger.warning("credential inventory 전에 앱 OAuth vault를 읽지 못했습니다")
                throw ClaudeOAuthCredentialReadError.reconnectRequired
            }
        }
        invalidateCache()

        return try await loadFileThenVaultInventoryFallback(
            previousAccessToken: previousAccessToken
        )
    }

    /// 401 등으로 캐시된 토큰이 거부됐을 때 외부에서 호출해 즉시 refresh 를 시도하게 한다.
    /// 성공하면 새 access token, 실패하면 nil (caller 가 적절히 폴백).
    func forceRefreshAccessToken() async throws -> String? {
        let vaultCredential: ClaudeCodeOAuthCredential?
        do {
            vaultCredential = try await loadVaultCredentialCandidate()
        } catch {
            lastReadError = .reconnectRequired
            Logger.warning("OAuth 강제 갱신 전에 앱 OAuth vault를 읽지 못했습니다")
            throw ClaudeOAuthCredentialReadError.reconnectRequired
        }
        if let appManaged = cachedResult?.credential,
           appManaged.source == .appManagedVault {
            return try await finishForcedRefresh(of: appManaged)
        }
        if let vaultCredential, vaultCredential.source == .appManagedVault {
            return try await finishForcedRefresh(of: vaultCredential)
        }

        switch await lookupCredentialFromFiles() {
        case .credential(let fileCredential):
            if let vaultCredential,
               Self.shouldPreferVaultCredential(vaultCredential, over: fileCredential),
               !vaultCredential.isExpired {
                // Keychain에서 명시적으로 가져온 mirror가 더 최신이면 stale 파일의
                // refresh token을 소비하지 않는다. mirror 자체도 CLI와 공유하므로
                // 앱이 독립적으로 회전하지 않고 재연결을 요구한다.
                lastReadError = .reconnectRequired
                throw ClaudeOAuthCredentialReadError.reconnectRequired
            }
            return try await finishForcedRefresh(of: fileCredential)
        case .missing, .unavailable:
            if vaultCredential != nil {
                lastReadError = .reconnectRequired
                throw ClaudeOAuthCredentialReadError.reconnectRequired
            }
            Logger.warning("OAuth 강제 갱신에 사용할 소유 credential을 찾지 못했습니다")
            return nil
        }
    }

    private func finishForcedRefresh(
        of credential: ClaudeCodeOAuthCredential
    ) async throws -> String? {
        guard credential.canAttemptRefresh else { return nil }
        guard let refreshed = await attemptRefresh(of: credential) else {
            if let lastReadError {
                throw lastReadError
            }
            return nil
        }
        cachedResult = CachedResult(credential: refreshed, storedAt: now())
        return refreshed.accessToken
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
    /// method. Claude Code 2.1.x can rotate or replace credentials in Keychain
    /// while leaving `.credentials.json` stale, so an explicit import reads the
    /// exact active-config Keychain item once and resolves both candidates by
    /// token expiry. Automatic paths remain prompt-free.
    func importActiveCLICredential() async -> ClaudeOAuthCredentialImportResult {
        invalidateCache()

        let vaultCredential: ClaudeCodeOAuthCredential?
        do {
            vaultCredential = try await loadVaultCredentialCandidate()
        } catch {
            return .failed("앱 OAuth 저장소를 읽지 못했습니다.")
        }

        let fileLookup = await lookupCredentialFromFiles()
        let fileCredential: ClaudeCodeOAuthCredential?
        switch fileLookup {
        case .credential(let credential):
            fileCredential = credential
        case .missing, .unavailable:
            fileCredential = nil
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
            let keychainCredential = parseCredential(
                from: payload,
                source: .keychain(service: service)
            )

            if let keychainCredential,
               Self.shouldPreferKeychainCredential(
                   keychainCredential,
                   over: fileCredential
               ),
               !keychainCredential.isExpired {
                return await finishExplicitImport(
                    keychainCredential,
                    replacing: vaultCredential,
                    metadataPayload: payload
                )
            }

            if let fileResult = await importFileCredential(
                fileLookup,
                replacing: vaultCredential
            ) {
                return fileResult
            }

            if let keychainCredential, !keychainCredential.isExpired {
                return await finishExplicitImport(
                    keychainCredential,
                    replacing: vaultCredential,
                    metadataPayload: payload
                )
            }
            return .failed("Claude Code 로그인 정보가 유효하지 않습니다. 터미널에서 다시 로그인해 주세요.")
        case .notFound:
            if let fileResult = await importFileCredential(
                fileLookup,
                replacing: vaultCredential
            ) {
                return fileResult
            }
            return existingVaultResult(vaultCredential, fallback: .notFound)
        case .cancelled:
            return .cancelled
        case .interactionRequired:
            if let fileResult = await importFileCredential(
                fileLookup,
                replacing: vaultCredential
            ) {
                return fileResult
            }
            return .failed("macOS Keychain 인증을 시작하지 못했습니다.")
        case .invalidData:
            if let fileResult = await importFileCredential(
                fileLookup,
                replacing: vaultCredential
            ) {
                return fileResult
            }
            return .failed("Claude Code Keychain 데이터가 유효하지 않습니다.")
        case .failure(let status):
            if let fileResult = await importFileCredential(
                fileLookup,
                replacing: vaultCredential
            ) {
                return fileResult
            }
            return .failed("macOS Keychain 오류가 발생했습니다(code: \(status)).")
        }
    }

    private static func shouldPreferKeychainCredential(
        _ keychainCredential: ClaudeCodeOAuthCredential,
        over fileCredential: ClaudeCodeOAuthCredential?
    ) -> Bool {
        guard let fileCredential else { return true }

        switch (fileCredential.expiresAt, keychainCredential.expiresAt) {
        case let (fileExpiry?, keychainExpiry?):
            // A tie belongs to Keychain: it is Claude Code's authoritative
            // store on current macOS releases.
            return keychainExpiry >= fileExpiry
        case (_?, nil):
            // An unexpired file with a known deadline is safer than a
            // truncated/legacy Keychain payload with no expiry. An expired
            // file must not shadow a freshly logged-in Keychain credential.
            return fileCredential.isExpired
        case (nil, _?):
            return true
        case (nil, nil):
            return true
        }
    }

    private func importFileCredential(
        _ lookup: CredentialFileLookup,
        replacing vaultCredential: ClaudeCodeOAuthCredential?
    ) async -> ClaudeOAuthCredentialImportResult? {
        switch lookup {
        case .credential(let credential):
            guard let usable = await ensureUsable(credential) else {
                return nil
            }
            return await finishExplicitImport(usable, replacing: vaultCredential)
        case .missing:
            return nil
        case .unavailable:
            return .failed("활성 Claude Code 로그인 파일을 읽거나 해석하지 못했습니다. 터미널에서 다시 로그인해 주세요.")
        }
    }

    private func finishExplicitImport(
        _ credential: ClaudeCodeOAuthCredential,
        replacing vaultCredential: ClaudeCodeOAuthCredential?,
        metadataPayload: String? = nil
    ) async -> ClaudeOAuthCredentialImportResult {
        guard let payload = Self.vaultPayload(
            for: credential,
            ownership: .cliMirror
        ) else {
            return .failed("Claude Code 로그인 정보를 앱 저장소 형식으로 만들지 못했습니다.")
        }
        do {
            try appCredentialVault.savePayload(payload)
            guard let verifiedPayload = try appCredentialVault.loadPayload(),
                  let verifiedCredential = parseCredential(
                      from: verifiedPayload,
                      source: Self.vaultSource(for: verifiedPayload)
                  ),
                  verifiedCredential.accessToken == credential.accessToken,
                  ClaudeOAuthCredentialVaultPayload.ownership(of: verifiedPayload) == .cliMirror
            else {
                return .failed("Claude Code 로그인 정보를 앱 저장소에 검증하지 못했습니다.")
            }
        } catch {
            return .failed("Claude Code 로그인 정보를 앱 저장소에 저장하지 못했습니다.")
        }

        if let metadataPayload, let profileMetadataStore {
            _ = await profileMetadataStore.update(from: metadataPayload)
        }
        lastReadError = nil
        cachedResult = CachedResult(credential: credential, storedAt: now())
        return .imported(
            credentialChanged: vaultCredential != nil
                && vaultCredential?.accessToken != credential.accessToken
        )
    }

    private func existingVaultResult(
        _ vaultCredential: ClaudeCodeOAuthCredential?,
        fallback: ClaudeOAuthCredentialImportResult
    ) -> ClaudeOAuthCredentialImportResult {
        guard let vaultCredential, !vaultCredential.isExpired else { return fallback }
        cachedResult = CachedResult(credential: vaultCredential, storedAt: now())
        return .available
    }

    private func loadVaultCredentialCandidate() async throws -> ClaudeCodeOAuthCredential? {
        guard let payload = try appCredentialVault.loadPayload() else { return nil }
        return await decodeCredential(
            from: payload,
            source: Self.vaultSource(for: payload),
            sourceDescription: "앱 OAuth vault"
        )
    }

    private func performCredentialLookup() async throws -> ClaudeCodeOAuthCredential? {
        let fileLookup = await lookupCredentialFromFiles()
        let vaultCredential: ClaudeCodeOAuthCredential?
        do {
            vaultCredential = try await loadVaultCredentialCandidate()
        } catch {
            Logger.warning("앱 OAuth vault 조회 실패")
            lastReadError = .reconnectRequired
            throw ClaudeOAuthCredentialReadError.reconnectRequired
        }

        // 이전 버전에서 앱이 이미 회전시킨 credential은 CLI mirror와 다른
        // 독립 lineage다. stale CLI 파일이 이를 덮지 않도록 먼저 사용한다.
        if let vaultCredential, vaultCredential.source == .appManagedVault {
            return await ensureUsable(vaultCredential)
        }

        // CLI mirror인 경우에는 활성 credential 파일이 계정 경계다. 현재
        // Claude Code 2.1.x는 Keychain만 갱신하고 파일을 오래된 상태로 남길 수
        // 있으므로, 명시적 연결에서 저장한 vault mirror와 파일의 만료 시각을
        // 비교한다. 이 비교는 외부 Keychain을 다시 읽지 않는다.
        switch fileLookup {
        case .credential(let credential):
            if let vaultCredential,
               Self.shouldPreferVaultCredential(vaultCredential, over: credential),
               !vaultCredential.isExpired {
                return vaultCredential
            }
            return await ensureUsable(credential)
        case .unavailable:
            Logger.warning("활성 Claude Code credential 파일이 있으나 읽거나 해석할 수 없습니다")
            return nil
        case .missing:
            break
        }

        if let vaultCredential {
            guard !vaultCredential.isExpired else {
                Logger.warning("앱 OAuth vault mirror가 만료되어 활성 CLI credential 연결이 필요합니다")
                return nil
            }
            return vaultCredential
        }

        Logger.warning("OAuth 토큰 조회 실패 (활성 config 파일/앱 vault 모두 실패)")
        return nil
    }

    private func loadFileThenVaultInventoryFallback(
        previousAccessToken: String?
    ) async throws -> ClaudeOAuthCredentialInventoryRefresh {
        let fileLookup = await lookupCredentialFromFiles()
        let vaultCredential: ClaudeCodeOAuthCredential?
        do {
            vaultCredential = try await loadVaultCredentialCandidate()
        } catch {
            Logger.warning("credential inventory에서 앱 OAuth vault를 읽지 못했습니다")
            lastReadError = .reconnectRequired
            throw ClaudeOAuthCredentialReadError.reconnectRequired
        }

        if let vaultCredential, vaultCredential.source == .appManagedVault {
            let usable = await ensureUsable(vaultCredential)
            cachedResult = CachedResult(credential: usable, storedAt: now())
            return ClaudeOAuthCredentialInventoryRefresh(
                accessToken: usable?.accessToken,
                credentialChanged: previousAccessToken != nil
                    && previousAccessToken != usable?.accessToken
            )
        }

        switch fileLookup {
        case .credential(let credential):
            if let vaultCredential,
               Self.shouldPreferVaultCredential(vaultCredential, over: credential),
               !vaultCredential.isExpired {
                cachedResult = CachedResult(credential: vaultCredential, storedAt: now())
                return ClaudeOAuthCredentialInventoryRefresh(
                    accessToken: vaultCredential.accessToken,
                    credentialChanged: previousAccessToken != nil
                        && previousAccessToken != vaultCredential.accessToken
                )
            }
            guard let usable = await ensureUsable(credential) else {
                cachedResult = CachedResult(credential: nil, storedAt: now())
                return ClaudeOAuthCredentialInventoryRefresh(
                    accessToken: nil,
                    credentialChanged: false
                )
            }
            await persistCredentialToVault(usable)
            cachedResult = CachedResult(credential: usable, storedAt: now())
            return ClaudeOAuthCredentialInventoryRefresh(
                accessToken: usable.accessToken,
                credentialChanged: previousAccessToken != nil
                    && previousAccessToken != usable.accessToken
            )
        case .unavailable:
            cachedResult = CachedResult(credential: nil, storedAt: now())
            return ClaudeOAuthCredentialInventoryRefresh(
                accessToken: nil,
                credentialChanged: false
            )
        case .missing:
            break
        }

        guard let vaultCredential, !vaultCredential.isExpired else {
            if vaultCredential?.isExpired == true {
                Logger.warning("credential inventory의 CLI mirror가 만료되었습니다")
            }
            cachedResult = CachedResult(credential: nil, storedAt: now())
            return ClaudeOAuthCredentialInventoryRefresh(
                accessToken: nil,
                credentialChanged: false
            )
        }
        cachedResult = CachedResult(credential: vaultCredential, storedAt: now())
        return ClaudeOAuthCredentialInventoryRefresh(
            accessToken: vaultCredential.accessToken,
            credentialChanged: previousAccessToken != nil
                && previousAccessToken != vaultCredential.accessToken
        )
    }

    private static func shouldPreferVaultCredential(
        _ vaultCredential: ClaudeCodeOAuthCredential,
        over fileCredential: ClaudeCodeOAuthCredential
    ) -> Bool {
        if vaultCredential.source == .unversionedVaultMirror {
            // marker 없는 개발/legacy payload에는 어떤 CLI 계정에서 가져왔는지
            // 증명할 provenance가 없다. 만료 시각만으로 다른 계정의 vault를
            // 활성 파일보다 우선하지 않는다.
            return false
        }
        return shouldPreferKeychainCredential(vaultCredential, over: fileCredential)
    }

    /// decodeCredential 단계에서 expired 토큰도 반환되므로(refresh 가능 여부 판단을 위해)
    /// 이 단계에서 만료 토큰이면 source의 소유권 규칙에 따라 갱신한다.
    private func ensureUsable(_ credential: ClaudeCodeOAuthCredential) async -> ClaudeCodeOAuthCredential? {
        if !credential.isExpired {
            lastReadError = nil
            return credential
        }
        return await attemptRefresh(of: credential)
    }

    private func attemptRefresh(of credential: ClaudeCodeOAuthCredential) async -> ClaudeCodeOAuthCredential? {
        guard credential.canAttemptRefresh else { return nil }
        switch credential.source {
        case .file(let fileURL):
            return await attemptFileRefresh(of: credential, fileURL: fileURL)
        case .appManagedVault:
            return await attemptAppManagedVaultRefresh(of: credential)
        case .keychain, .unversionedVaultMirror, .refreshed:
            Logger.warning("CLI mirror credential의 독립 refresh를 건너뜁니다")
            return nil
        }
    }

    private func attemptFileRefresh(
        of credential: ClaudeCodeOAuthCredential,
        fileURL: URL
    ) async -> ClaudeCodeOAuthCredential? {
        guard FileManager.default.isWritableFile(atPath: fileURL.path) else {
            Logger.warning("Claude Code credential 파일에 갱신 결과를 기록할 수 없어 refresh를 건너뜁니다")
            return nil
        }
        guard let originalPayload = try? String(contentsOf: fileURL, encoding: .utf8),
              let currentCredential = parseCredential(
                from: originalPayload,
                source: .file(fileURL)
              ),
              currentCredential.refreshToken == credential.refreshToken
        else {
            Logger.info("OAuth refresh 전에 Claude Code credential이 바뀌어 이전 요청을 폐기합니다")
            return nil
        }

        do {
            let refreshed = try await tokenRefresher.refresh(credential)
            guard let latestPayload = try? String(contentsOf: fileURL, encoding: .utf8),
                  let latestCredential = parseCredential(
                    from: latestPayload,
                    source: .file(fileURL)
                  ),
                  latestCredential.refreshToken == credential.refreshToken
            else {
                Logger.warning("OAuth refresh 도중 Claude Code credential이 변경되어 write-back을 폐기합니다")
                return nil
            }
            let sourceCredential = ClaudeCodeOAuthCredential(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken,
                expiresAt: refreshed.expiresAt,
                source: .file(fileURL)
            )
            guard let mergedPayload = Self.mergeCredential(
                sourceCredential,
                into: latestPayload
            ) else {
                Logger.warning("OAuth refresh 결과를 Claude Code credential 형식으로 병합하지 못했습니다")
                return nil
            }

            // Refresh token은 회전형이다. 성공한 새 lineage를 CLI 원본 파일에 먼저
            // 되돌려 놓아야 ClaudeUsage와 Claude Code가 같은 token을 계속 사용한다.
            do {
                try Data(mergedPayload.utf8).write(to: fileURL, options: [.atomic])
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: fileURL.path
                )
            } catch {
                // 새 refresh token을 잃지 않도록 vault에는 보존한다. 현재 앱
                // 세션은 복구되지만 CLI 파일 write-back 실패는 명확히 기록한다.
                await persistCredentialToVault(sourceCredential)
                lastReadError = nil
                Logger.error("OAuth refresh 성공 후 Claude Code credential 파일 write-back 실패")
                return sourceCredential
            }

            await persistCredentialToVault(sourceCredential)
            lastReadError = nil
            Logger.info("OAuth refresh 결과를 활성 Claude Code credential 파일에 동기화했습니다")
            return sourceCredential
        } catch ClaudeOAuthTokenRefresher.RefreshError.invalidGrant {
            // Claude Code가 같은 시점에 먼저 token을 회전했거나 사용자가 다시
            // 로그인했을 수 있다. 원본 파일 lineage가 실제로 바뀌었다면 서버
            // 오류를 재로그인 요구로 오판하지 않고 새 credential을 채택한다.
            if case .credential(let latestCredential) = await lookupCredentialFromFiles(),
               latestCredential.refreshToken != credential.refreshToken,
               let usable = await ensureUsable(latestCredential) {
                Logger.info("OAuth refresh 충돌 후 Claude Code가 갱신한 새 credential을 채택했습니다")
                return usable
            }
            lastReadError = .reauthenticationRequired
            Logger.warning("OAuth refresh invalid_grant — 활성 CLI credential 갱신 필요")
            return nil
        } catch {
            Logger.warning("OAuth refresh 실패: \(error.localizedDescription)")
            return nil
        }
    }

    private func attemptAppManagedVaultRefresh(
        of credential: ClaudeCodeOAuthCredential
    ) async -> ClaudeCodeOAuthCredential? {
        guard let originalPayload = try? appCredentialVault.loadPayload(),
              ClaudeOAuthCredentialVaultPayload.ownership(of: originalPayload) == .appManaged,
              let currentCredential = parseCredential(
                  from: originalPayload,
                  source: .appManagedVault
              ),
              currentCredential.refreshToken == credential.refreshToken
        else {
            Logger.info("OAuth refresh 전에 앱 소유 credential이 바뀌어 이전 요청을 폐기합니다")
            return nil
        }

        do {
            let refreshed = try await tokenRefresher.refresh(credential)
            guard let latestPayload = try? appCredentialVault.loadPayload(),
                  ClaudeOAuthCredentialVaultPayload.ownership(of: latestPayload) == .appManaged,
                  let latestCredential = parseCredential(
                      from: latestPayload,
                      source: .appManagedVault
                  ),
                  latestCredential.refreshToken == credential.refreshToken
            else {
                Logger.warning("OAuth refresh 도중 앱 소유 credential이 변경되어 write-back을 폐기합니다")
                return nil
            }

            let sourceCredential = ClaudeCodeOAuthCredential(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken,
                expiresAt: refreshed.expiresAt,
                source: .appManagedVault
            )
            guard await persistCredentialToVault(
                sourceCredential,
                ownership: .appManaged,
                verify: true
            ) else {
                Logger.error("앱 소유 OAuth refresh 성공 후 vault write-back에 실패했습니다")
                // 회전된 새 refresh token을 현재 프로세스에서는 계속 사용해
                // 사용량 조회를 복구한다. 다음 실행에는 재연결이 필요할 수 있다.
                lastReadError = nil
                return sourceCredential
            }
            lastReadError = nil
            Logger.info("앱 소유 OAuth credential을 refresh하고 vault에 동기화했습니다")
            return sourceCredential
        } catch ClaudeOAuthTokenRefresher.RefreshError.invalidGrant {
            if let latestPayload = try? appCredentialVault.loadPayload(),
               ClaudeOAuthCredentialVaultPayload.ownership(of: latestPayload) == .appManaged,
               let latestCredential = parseCredential(
                   from: latestPayload,
                   source: .appManagedVault
               ),
               latestCredential.refreshToken == credential.refreshToken {
                try? appCredentialVault.deletePayload()
            }
            lastReadError = .reauthenticationRequired
            Logger.warning("앱 소유 OAuth refresh invalid_grant — Claude Code 재연결 필요")
            return nil
        } catch {
            Logger.warning("앱 소유 OAuth refresh 실패: \(error.localizedDescription)")
            return nil
        }
    }

    /// 활성 CLI credential을 앱 vault에 mirror로 저장한다. 이 refresh token은
    /// CLI 원본과 공유하므로 vault 단독 갱신에는 사용하지 않는다.
    private func persistCredentialToVault(_ credential: ClaudeCodeOAuthCredential) async {
        _ = await persistCredentialToVault(credential, ownership: .cliMirror)
    }

    private func persistCredentialToVault(
        _ credential: ClaudeCodeOAuthCredential,
        ownership: ClaudeOAuthCredentialVaultOwnership,
        verify: Bool = false
    ) async -> Bool {
        guard let payload = Self.vaultPayload(for: credential, ownership: ownership) else {
            Logger.warning("OAuth credential을 vault payload로 직렬화하지 못했습니다")
            return false
        }
        guard await persistPayloadToVault(payload) else { return false }
        guard verify else { return true }

        do {
            guard let verifiedPayload = try appCredentialVault.loadPayload(),
                  ClaudeOAuthCredentialVaultPayload.ownership(of: verifiedPayload) == ownership,
                  let verifiedCredential = parseCredential(
                      from: verifiedPayload,
                      source: Self.vaultSource(for: verifiedPayload)
                  ),
                  verifiedCredential.accessToken == credential.accessToken,
                  verifiedCredential.refreshToken == credential.refreshToken
            else {
                return false
            }
            return true
        } catch {
            Logger.warning("OAuth credential vault 저장 검증 실패")
            return false
        }
    }

    private func persistPayloadToVault(_ payload: String) async -> Bool {
        do {
            try appCredentialVault.savePayload(payload)
            return true
        } catch {
            Logger.warning("OAuth refresh 캐시 저장 실패")
            return false
        }
    }

    private static func vaultPayload(
        for credential: ClaudeCodeOAuthCredential,
        ownership: ClaudeOAuthCredentialVaultOwnership
    ) -> String? {
        ClaudeOAuthCredentialVaultPayload.encode(
            credentialPayload: serializeCredentialAsAuthJSON(credential),
            ownership: ownership
        )
    }

    private static func vaultSource(for payload: String) -> ClaudeCodeOAuthCredential.Source {
        switch ClaudeOAuthCredentialVaultPayload.ownership(of: payload) {
        case .appManaged:
            return .appManagedVault
        case .cliMirror:
            return ClaudeOAuthCredentialVaultPayload.isVersioned(payload)
                ? .refreshed
                : .unversionedVaultMirror
        }
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

    /// 기존 Claude Code payload의 scope, subscription, MCP OAuth 등 알 수 없는
    /// 필드를 그대로 보존하면서 회전된 OAuth 값만 교체한다.
    private static func mergeCredential(
        _ credential: ClaudeCodeOAuthCredential,
        into existingPayload: String
    ) -> String? {
        guard let data = existingPayload.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        var oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = credential.accessToken
        if let refreshToken = credential.refreshToken, !refreshToken.isEmpty {
            oauth["refreshToken"] = refreshToken
        }
        if let expiresAt = credential.expiresAt {
            oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)
        }
        root["claudeAiOauth"] = oauth

        guard let mergedData = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys]
        ) else {
            return nil
        }
        return String(data: mergedData, encoding: .utf8)
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

    private func lookupCredentialFromFiles() async -> CredentialFileLookup {
        let candidates = [
            claudeConfigDirectory.appendingPathComponent(".credentials.json"),
            claudeConfigDirectory.appendingPathComponent("credentials.json")
        ]

        for candidateURL in candidates {
            // `.credentials.json` 또는 상위 config 디렉터리가 symlink인 환경에서
            // atomic write가 symlink 자체를 교체하지 않도록 실제 target을 source로
            // 보존한다.
            let fileURL = candidateURL.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                continue
            }
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8),
                  !text.isEmpty else {
                return .unavailable
            }

            if let credential = await decodeCredential(
                from: text,
                source: .file(fileURL),
                sourceDescription: "파일: \(fileURL.lastPathComponent)")
            {
                return .credential(credential)
            }
            return .unavailable
        }

        Logger.debug("OAuth 토큰 파일 조회 실패 (\(claudeConfigDirectory.lastPathComponent))")
        return .missing
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
