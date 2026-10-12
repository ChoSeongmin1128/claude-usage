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

    /// 만료 직전 토큰으로 요청하다 실패하지 않도록 이만큼 일찍 만료로 본다.
    nonisolated static let expiryMargin: TimeInterval = 300

    nonisolated var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt.addingTimeInterval(-Self.expiryMargin)
    }

    /// access token 이 만료되어도 refresh token 으로 갱신 가능한 상태인가.
    nonisolated var canAttemptRefresh: Bool {
        guard let refreshToken else { return false }
        return !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

nonisolated protocol ClaudeOAuthCredentialReading: Sendable {
    func readAccessToken() async throws -> String?
    func refreshCredentialInventoryWithoutUI() async throws -> ClaudeOAuthCredentialInventoryRefresh
    func forceRefreshAccessToken() async throws -> String?
    func invalidateCache() async
    func importActiveCLICredential() async -> ClaudeOAuthCredentialImportResult
    func beginRecoveryClosing() async
    func drainRecovery() async
    func sealRecoveryWrites() async
    func prepareRecoveryForReset() async -> Bool
}

extension ClaudeOAuthCredentialReading {
    func beginRecoveryClosing() async {}
    func drainRecovery() async {}
    func sealRecoveryWrites() async {}
    func prepareRecoveryForReset() async -> Bool { true }
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
    case executableNotFound
    /// 토큰이 만료됐는데 Claude Code 갱신을 지금 실행하지 못했다. 로그인은 그대로일 수 있다.
    case refreshUnavailable

    var errorDescription: String? {
        switch self {
        case .reauthenticationRequired:
            return "Claude Code refresh token이 거부되어 다시 로그인이 필요합니다."
        case .reconnectRequired:
            return "Claude Code 로그인은 유지되고 있지만 \(AppDistribution.current.appName) 연결 정보를 다시 확인해야 합니다."
        case .executableNotFound:
            return ClaudeCodeCredentialIssue.executableNotFoundExplanation
        case .refreshUnavailable:
            return "Claude Code 로그인을 지금 갱신하지 못했습니다. 잠시 뒤 다시 확인합니다."
        }
    }
}

actor ClaudeCodeCredentialReader {
    typealias CLIKeychainPayloadReader = @Sendable (_ service: String) async -> ClaudeCodeKeychainCLI.Outcome
    /// 인자는 CLAUDE_CONFIG_DIR 원문이다. nil이면 기본 로그인을 갱신한다.
    typealias CLIRefresher = @Sendable (_ configDirectoryValue: String?) async -> ClaudeCodeCLI.RefreshOutcome
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
    private let cliKeychainPayloadReader: CLIKeychainPayloadReader
    private let cliRefresher: CLIRefresher
    private let tokenRefresher: ClaudeOAuthTokenRefresher
    private let appCredentialVault: any ClaudeOAuthCredentialVault
    private let cacheTTL: TimeInterval
    private let now: @Sendable () -> Date
    private let recoveryCoordinator: CredentialRecoveryCoordinator
    private var activeWorkCount = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var cachedResult: CachedResult?
    private var inFlightRead: Task<ClaudeCodeOAuthCredential?, Error>?
    private var cacheGeneration = 0
    private var lastReadError: ClaudeOAuthCredentialReadError?
    @TaskLocal private static var recoveryReadLease: CredentialRecoveryReadLease?
    @TaskLocal private static var managedCredentialAllowed = true
    @TaskLocal private static var recoveredCredential: ClaudeCodeOAuthCredential?
    @TaskLocal private static var importOperation: ImportOperation?

    private struct ImportOperation: Sendable {
        let id: UUID
        let originalPayload: String?
        let generation: Int
    }

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
        },
        cliKeychainPayloadReader: CLIKeychainPayloadReader? = nil,
        cliRefresher: CLIRefresher? = nil,
        recoveryCoordinator: CredentialRecoveryCoordinator? = nil
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
        self.recoveryCoordinator =
            recoveryCoordinator
            ?? (AppRuntimeEnvironment.isRunningUnitTests
                ? CredentialRecoveryCoordinator.isolated(appVault: appCredentialVault) : .shared)
        self.cacheTTL = cacheTTL
        self.now = now
        self.interactiveKeychainPayloadReader = interactiveKeychainPayloadReader
        // Keychain은 홈 폴더가 아니라 사용자 단위라, 다른 홈을 쓰는 reader나 테스트가 실제 사용자의
        // Claude Code 로그인을 읽지 않게 한다.
        let readsUserKeychain =
            !AppRuntimeEnvironment.isRunningUnitTests
            && homeDirectory.standardizedFileURL.path
                == FileManager.default.realHomeDirectory.standardizedFileURL.path
        let userKeychainReader: CLIKeychainPayloadReader = { @Sendable service in
            await ClaudeCodeKeychainCLI.read(service: service)
        }
        let noKeychainReader: CLIKeychainPayloadReader = { @Sendable _ in .failed }
        self.cliKeychainPayloadReader =
            cliKeychainPayloadReader ?? (readsUserKeychain ? userKeychainReader : noKeychainReader)
        // Claude Code 실행도 같은 이유로 실제 사용자의 홈을 읽을 때만 한다.
        let userRefresher: CLIRefresher = { @Sendable value in
            await ClaudeCodeCLI.refreshLogin(configDirectoryValue: value)
        }
        let noRefresher: CLIRefresher = { @Sendable _ in .unavailable }
        self.cliRefresher = cliRefresher ?? (readsUserKeychain ? userRefresher : noRefresher)
    }

    func beginRecoveryClosing() { recoveryCoordinator.beginClosing() }

    func drainRecovery() async {
        if activeWorkCount > 0 { await withCheckedContinuation { drainWaiters.append($0) } }
        await recoveryCoordinator.finishClosing()
    }

    func sealRecoveryWrites() { recoveryCoordinator.sealWrites() }

    func prepareRecoveryForReset() async -> Bool { await recoveryCoordinator.prepareForReset() }

    private func finishWork() {
        activeWorkCount -= 1
        if activeWorkCount == 0 {
            let waiters = drainWaiters
            drainWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    // A mirror of Claude Code's login is never rotated by the app, so Claude Code
    // always holds the same or a newer token and the copy can go. An app-managed
    // copy may hold the only current refresh token after a failed write-back, so
    // it goes only when Claude Code's credential file holds the same token.
    // Claude Code's Keychain item is not read: its classic ACL shows a password
    // prompt even to a no-UI query.
    func canDiscardAppVaultCopy() async -> Bool {
        let storedPayload: String?
        do {
            storedPayload = try appCredentialVault.loadPayload()
        } catch {
            return false
        }
        guard let payload = storedPayload else { return true }
        if ClaudeOAuthCredentialVaultPayload.ownership(of: payload) == .cliMirror { return true }
        guard let vaultCredential = Self.parseCredential(from: payload, source: Self.vaultSource(for: payload)) else {
            return false
        }
        guard let refreshToken = vaultCredential.refreshToken else { return true }
        guard case .credential(let fileCredential) = await lookupCredentialFromFiles() else { return false }
        return fileCredential.refreshToken == refreshToken
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

    /// Refreshes the active Claude credential inventory without any password dialog.
    ///
    /// Classic Keychain ACL items can surface an Allow/Deny password dialog even
    /// when a SecItem query requests no UI, so automatic paths never query the
    /// CLI-owned item through SecItem. They read it only through
    /// `/usr/bin/security`, which the item's ACL trusts because Claude Code
    /// writes it with that tool. The SecItem read stays in
    /// `importActiveCLICredential()` as an explicit fallback.
    func refreshCredentialInventoryWithoutUI() async throws -> ClaudeOAuthCredentialInventoryRefresh {
        activeWorkCount += 1
        defer { finishWork() }
        return try await performInventoryRefresh()
    }

    private func performInventoryRefresh() async throws -> ClaudeOAuthCredentialInventoryRefresh {
        let previousAccessToken: String?
        if let cachedAccessToken = cachedResult?.credential?.accessToken {
            previousAccessToken = cachedAccessToken
        } else {
            do {
                if let payload = try appCredentialVault.loadPayload() {
                    previousAccessToken =
                        Self.parseCredential(
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

        let inventory = try await withReadLease {
            try await self.loadFileThenVaultInventoryFallback(previousAccessToken: previousAccessToken)
        }
        try Task.checkCancellation()
        if inventory.accessToken == nil, let lastReadError,
            lastReadError == .executableNotFound || lastReadError == .refreshUnavailable
        {
            throw lastReadError
        }
        return inventory
    }

    /// 401 등으로 캐시된 토큰이 거부됐을 때 외부에서 호출해 즉시 refresh 를 시도하게 한다.
    /// 성공하면 새 access token, 실패하면 nil (caller 가 적절히 폴백).
    func forceRefreshAccessToken() async throws -> String? {
        activeWorkCount += 1
        defer { finishWork() }
        return try await withReadLease { try await self.performForcedRefresh() }
    }

    private func performForcedRefresh() async throws -> String? {
        if let recovered = Self.recoveredCredential, !recovered.isExpired { return recovered.accessToken }
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

        let previousAccessToken = cachedResult?.credential?.accessToken ?? vaultCredential?.accessToken
        switch await lookupCredentialFromFiles() {
        case .credential(let fileCredential):
            if let native = await keychainCredential(fresherThan: fileCredential), !native.credential.isExpired,
                native.credential.accessToken != previousAccessToken
            {
                await adopt(native.credential, payload: native.payload, replacing: vaultCredential)
                return native.credential.accessToken
            }
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
        case .missing:
            if let native = await currentCLIKeychainCredential(replacing: vaultCredential),
                native.accessToken != previousAccessToken
            {
                return native.accessToken
            }
            if vaultCredential != nil {
                lastReadError = .reconnectRequired
                throw ClaudeOAuthCredentialReadError.reconnectRequired
            }
            Logger.warning("OAuth 강제 갱신에 사용할 소유 credential을 찾지 못했습니다")
            return nil
        case .unavailable:
            if vaultCredential != nil {
                lastReadError = .reconnectRequired
                throw ClaudeOAuthCredentialReadError.reconnectRequired
            }
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
        storeCachedResult(refreshed, at: now())
        return refreshed.accessToken
    }

    func readCredential() async throws -> ClaudeCodeOAuthCredential? {
        activeWorkCount += 1
        defer { finishWork() }
        try Task.checkCancellation()
        if let inFlightRead { return try await inFlightRead.value }
        let generation = cacheGeneration
        let task = Task { try await self.withReadLease { try await self.performCredentialLookup() } }
        inFlightRead = task
        do {
            let result = try await task.value
            try Task.checkCancellation()
            if generation == cacheGeneration {
                storeCachedResult(result, at: now())
                inFlightRead = nil
            }
            return result
        } catch {
            if generation == cacheGeneration { inFlightRead = nil }
            throw error
        }
    }

    private func withReadLease<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        var allowManaged = true
        var recovered: ClaudeCodeOAuthCredential?
        do {
            if let payload = try await recoveryCoordinator.recoveredRefreshPayload(),
                let credential = Self.parseCredential(from: payload, source: .appManagedVault)
            {
                storeCachedResult(credential, at: now())
                recovered = credential
            }
            allowManaged = await recoveryCoordinator.status(provider: .claude) == .ready
        } catch {
            allowManaged = false
            lastReadError = .reconnectRequired
        }
        let lease = try await recoveryCoordinator.beginRead()
        return try await Self.$recoveryReadLease.withValue(lease) {
            try await Self.$managedCredentialAllowed.withValue(allowManaged) {
                try await Self.$recoveredCredential.withValue(recovered) { try await operation() }
            }
        }
    }

    private func storeCachedResult(_ credential: ClaudeCodeOAuthCredential?, at date: Date) {
        guard !Task.isCancelled else { return }
        if let operation = Self.importOperation {
            guard operation.generation == cacheGeneration else { return }
        }
        if let lease = Self.recoveryReadLease {
            guard recoveryCoordinator.isReadCurrent(lease) else { return }
        }
        cachedResult = CachedResult(credential: credential, storedAt: date)
    }

    func invalidateCache() {
        recoveryCoordinator.invalidateReadOperations()
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
        activeWorkCount += 1
        defer { finishWork() }
        guard !Task.isCancelled else { return .cancelled }
        invalidateCache()
        let id: UUID
        let original: String?
        do {
            id = try await recoveryCoordinator.beginImport()
        } catch { return .failed("보존된 로그인 복구 자료를 확인하지 못했습니다.") }
        do { original = try appCredentialVault.loadPayload() } catch {
            await recoveryCoordinator.cancelImport(id)
            return .failed("앱 OAuth 저장소를 읽지 못했습니다.")
        }
        let operation = ImportOperation(id: id, originalPayload: original, generation: cacheGeneration)
        let result = await Self.$importOperation.withValue(operation) { await self.performExplicitImport() }
        await recoveryCoordinator.cancelImport(id)
        return result
    }

    private func currentImportIsValid() async -> Bool {
        guard !Task.isCancelled, let operation = Self.importOperation,
            operation.generation == cacheGeneration
        else { return false }
        do { try await recoveryCoordinator.validateImport(operation.id); return true } catch { return false }
    }

    private func performExplicitImport() async -> ClaudeOAuthCredentialImportResult {

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
        guard await currentImportIsValid() else { return .cancelled }
        let cliOutcome = await cliKeychainPayloadReader(service)
        guard await currentImportIsValid() else { return .cancelled }
        let outcome: KeychainAccessPreflight.ReadOutcome
        switch cliOutcome {
        case .payload(let payload):
            outcome = .value(payload)
        case .notFound:
            outcome = .notFound
        case .failed:
            guard await currentImportIsValid() else { return .cancelled }
            outcome = interactiveKeychainPayloadReader(
                service,
                NSUserName(),
                "Claude Code 로그인을 \(AppDistribution.current.appName)에 연결합니다."
            )
        }
        guard await currentImportIsValid() else { return .cancelled }
        switch outcome {
        case .value(let payload):
            let keychainCredential = Self.parseCredential(
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
            return .failed("Claude Code 로그인이 올바르지 않습니다. 터미널에서 다시 로그인하세요.")
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

    nonisolated static func shouldPreferKeychainCredential(
        _ keychainCredential: ClaudeCodeOAuthCredential,
        over fileCredential: ClaudeCodeOAuthCredential?
    ) -> Bool {
        guard let fileCredential else { return true }
        if !keychainCredential.isExpired { return true }

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
        guard await currentImportIsValid() else { return .cancelled }
        switch lookup {
        case .credential(let credential):
            guard let usable = await ensureUsable(credential) else {
                return nil
            }
            return await finishExplicitImport(usable, replacing: vaultCredential)
        case .missing:
            return nil
        case .unavailable:
            return .failed("Claude Code 로그인 파일을 읽지 못했습니다. 터미널에서 다시 로그인하세요.")
        }
    }

    private func finishExplicitImport(
        _ credential: ClaudeCodeOAuthCredential,
        replacing vaultCredential: ClaudeCodeOAuthCredential?,
        metadataPayload: String? = nil
    ) async -> ClaudeOAuthCredentialImportResult {
        let originalCLI: String?
        if let metadataPayload {
            originalCLI = metadataPayload
        } else if case .file(let file) = credential.source {
            originalCLI = try? String(contentsOf: file, encoding: .utf8)
        } else {
            originalCLI = nil
        }
        let raw =
            originalCLI.flatMap {
                ClaudeOAuthCredentialVaultPayload.encode(credentialPayload: $0, ownership: .cliMirror)
            } ?? Self.vaultPayload(for: credential, ownership: .cliMirror)
        guard let payload = raw,
            let encoded = Self.parseCredential(from: payload, source: .refreshed),
            encoded.accessToken == credential.accessToken, encoded.refreshToken == credential.refreshToken
        else { return .failed("Claude Code 로그인 정보를 앱 저장소 형식으로 만들지 못했습니다.") }
        do {
            if let operation = Self.importOperation {
                guard await currentImportIsValid() else { return .cancelled }
                try Task.checkCancellation()
                try await recoveryCoordinator.saveImport(
                    payload, operationID: operation.id, expectedPayload: operation.originalPayload)
                guard await currentImportIsValid() else { return .cancelled }
            } else {
                guard let lease = Self.recoveryReadLease, !Task.isCancelled else { return .cancelled }
                try await recoveryCoordinator.saveMirror(payload, lease: lease)
            }
        } catch {
            if Task.isCancelled { return .cancelled }
            return .failed("Claude Code 로그인 정보를 앱 저장소에 저장하지 못했습니다.")
        }
        if let metadataPayload, let profileMetadataStore {
            if Self.importOperation != nil, !(await currentImportIsValid()) { return .cancelled }
            _ = profileMetadataStore
            await updateProfileMetadata(from: metadataPayload)
        }
        if Self.importOperation != nil, !(await currentImportIsValid()) { return .cancelled }
        lastReadError = nil
        storeCachedResult(credential, at: now())
        return .imported(
            credentialChanged: vaultCredential != nil && vaultCredential?.accessToken != credential.accessToken)
    }

    private func existingVaultResult(
        _ vaultCredential: ClaudeCodeOAuthCredential?,
        fallback: ClaudeOAuthCredentialImportResult
    ) -> ClaudeOAuthCredentialImportResult {
        guard let vaultCredential, !vaultCredential.isExpired else { return fallback }
        storeCachedResult(vaultCredential, at: now())
        return .available
    }

    private func loadVaultCredentialCandidate() async throws -> ClaudeCodeOAuthCredential? {
        guard let payload = try appCredentialVault.loadPayload() else { return nil }
        let credential = await decodeCredential(
            from: payload, source: Self.vaultSource(for: payload), sourceDescription: "앱 OAuth vault")
        if credential != nil { await updateProfileMetadata(from: payload) }
        return credential
    }

    private func performCredentialLookup() async throws -> ClaudeCodeOAuthCredential? {
        if let recovered = Self.recoveredCredential, !recovered.isExpired { return recovered }
        if let cachedResult, now().timeIntervalSince(cachedResult.storedAt) < cacheTTL {
            if let cached = cachedResult.credential, !cached.isExpired,
                Self.managedCredentialAllowed || cached.source != .appManagedVault
            {
                return cached
            }
            if cachedResult.credential == nil, Self.managedCredentialAllowed { return nil }
        }
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
            if Self.managedCredentialAllowed { return await ensureUsable(vaultCredential) }
            return await nativeReadOnlyCredential(fileLookup)
        }

        // CLI mirror인 경우에는 활성 credential 파일이 계정 경계다. 현재
        // Claude Code 2.1.x는 Keychain만 갱신하고 파일을 오래된 상태로 남길 수
        // 있으므로, 명시적 연결에서 저장한 vault mirror와 파일의 만료 시각을
        // 비교한다. 이 비교는 외부 Keychain을 다시 읽지 않는다.
        switch fileLookup {
        case .credential(let credential):
            if let current = await adoptKeychainCredential(fresherThan: credential, replacing: vaultCredential) {
                return current
            }
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

        if let current = await currentCLIKeychainCredential(replacing: vaultCredential) {
            return current
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
        if let recovered = Self.recoveredCredential, !recovered.isExpired {
            storeCachedResult(recovered, at: now())
            return ClaudeOAuthCredentialInventoryRefresh(
                accessToken: recovered.accessToken,
                credentialChanged: previousAccessToken != nil && previousAccessToken != recovered.accessToken)
        }
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
            let usable =
                Self.managedCredentialAllowed
                ? await ensureUsable(vaultCredential) : await nativeReadOnlyCredential(fileLookup)
            storeCachedResult(usable, at: now())
            return ClaudeOAuthCredentialInventoryRefresh(
                accessToken: usable?.accessToken,
                credentialChanged: previousAccessToken != nil
                    && previousAccessToken != usable?.accessToken
            )
        }

        switch fileLookup {
        case .credential(let credential):
            if let current = await adoptKeychainCredential(fresherThan: credential, replacing: vaultCredential) {
                return ClaudeOAuthCredentialInventoryRefresh(
                    accessToken: current.accessToken,
                    credentialChanged: previousAccessToken != nil
                        && previousAccessToken != current.accessToken
                )
            }
            if let vaultCredential,
               Self.shouldPreferVaultCredential(vaultCredential, over: credential),
               !vaultCredential.isExpired {
                storeCachedResult(vaultCredential, at: now())
                return ClaudeOAuthCredentialInventoryRefresh(
                    accessToken: vaultCredential.accessToken,
                    credentialChanged: previousAccessToken != nil
                        && previousAccessToken != vaultCredential.accessToken
                )
            }
            guard let usable = await ensureUsable(credential) else {
                storeCachedResult(nil, at: now())
                return ClaudeOAuthCredentialInventoryRefresh(
                    accessToken: nil,
                    credentialChanged: false
                )
            }
            await persistCredentialToVault(usable)
            storeCachedResult(usable, at: now())
            return ClaudeOAuthCredentialInventoryRefresh(
                accessToken: usable.accessToken,
                credentialChanged: previousAccessToken != nil
                    && previousAccessToken != usable.accessToken
            )
        case .unavailable:
            storeCachedResult(nil, at: now())
            return ClaudeOAuthCredentialInventoryRefresh(
                accessToken: nil,
                credentialChanged: false
            )
        case .missing:
            break
        }

        if let current = await currentCLIKeychainCredential(replacing: vaultCredential) {
            return ClaudeOAuthCredentialInventoryRefresh(
                accessToken: current.accessToken,
                credentialChanged: previousAccessToken != nil
                    && previousAccessToken != current.accessToken
            )
        }

        guard let vaultCredential, !vaultCredential.isExpired else {
            if vaultCredential?.isExpired == true {
                Logger.warning("credential inventory의 CLI mirror가 만료되었습니다")
            }
            storeCachedResult(nil, at: now())
            return ClaudeOAuthCredentialInventoryRefresh(
                accessToken: nil,
                credentialChanged: false
            )
        }
        storeCachedResult(vaultCredential, at: now())
        return ClaudeOAuthCredentialInventoryRefresh(
            accessToken: vaultCredential.accessToken,
            credentialChanged: previousAccessToken != nil
                && previousAccessToken != vaultCredential.accessToken
        )
    }

    /// 자격 증명 파일이 없으면 Claude Code의 현재 Keychain 로그인을 확인 창 없이 읽어 앱 사본을 맞춘다.
    /// 토큰이 만료돼 있으면 앱이 직접 갱신하지 않고(Claude Code의 refresh token이 바뀜) Claude Code가
    /// 스스로 갱신하게 한 뒤 다시 읽는다. 읽지 못하면 nil을 돌려주고 기존 앱 사본 규칙을 따른다.
    private func currentCLIKeychainCredential(
        replacing vaultCredential: ClaudeCodeOAuthCredential?
    ) async -> ClaudeCodeOAuthCredential? {
        let service = cliKeychainService
        guard case .payload(var payload) = await cliKeychainPayloadReader(service),
            var credential = Self.parseCredential(from: payload, source: .keychain(service: service))
        else { return nil }
        if credential.isExpired {
            guard !Task.isCancelled, await recoveryCoordinator.canRefreshCLIGeneration(credential) else {
                lastReadError = .reconnectRequired
                return nil
            }
            lastReadError = nil
            switch await cliRefresher(usesScopedKeychainService ? claudeConfigDirectory.path : nil) {
            case .refreshed:
                if case .payload(let refreshedPayload) = await cliKeychainPayloadReader(service),
                    let refreshed = Self.parseCredential(from: refreshedPayload, source: .keychain(service: service))
                {
                    payload = refreshedPayload
                    credential = refreshed
                }
            case .notLoggedIn:
                lastReadError = .reauthenticationRequired
            case .executableNotFound:
                lastReadError = .executableNotFound
            case .unavailable:
                lastReadError = .refreshUnavailable
            }
        }
        guard !credential.isExpired else { return nil }
        await adopt(credential, payload: payload, replacing: vaultCredential)
        return credential
    }

    private var cliKeychainService: String {
        Self.keychainServiceName(
            for: claudeConfigDirectory,
            homeDirectory: homeDirectory,
            usesExplicitConfigDirectory: usesScopedKeychainService
        )
    }

    /// 파일이 있어도 Keychain을 확인 창 없이 읽어 더 늦게 만료되는 쪽을 찾는다. Claude Code 2.1.x는
    /// Keychain만 갱신하고 파일을 낡은 채로 둘 수 있다.
    private func keychainCredential(
        fresherThan file: ClaudeCodeOAuthCredential
    ) async -> (credential: ClaudeCodeOAuthCredential, payload: String)? {
        let service = cliKeychainService
        guard case .payload(let payload) = await cliKeychainPayloadReader(service),
            let credential = Self.parseCredential(from: payload, source: .keychain(service: service)),
            Self.shouldPreferKeychainCredential(credential, over: file)
        else { return nil }
        return (credential, payload)
    }

    private func adoptKeychainCredential(
        fresherThan file: ClaudeCodeOAuthCredential, replacing vaultCredential: ClaudeCodeOAuthCredential?
    ) async -> ClaudeCodeOAuthCredential? {
        guard let fresher = await keychainCredential(fresherThan: file), !fresher.credential.isExpired else {
            return nil
        }
        await adopt(fresher.credential, payload: fresher.payload, replacing: vaultCredential)
        return fresher.credential
    }

    private func adopt(
        _ credential: ClaudeCodeOAuthCredential, payload: String, replacing vaultCredential: ClaudeCodeOAuthCredential?
    ) async {
        if vaultCredential?.accessToken == credential.accessToken {
            lastReadError = nil
            storeCachedResult(credential, at: now())
        } else {
            _ = await finishExplicitImport(credential, replacing: vaultCredential, metadataPayload: payload)
        }
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
        case .file:
            return await refreshThroughClaudeCode(of: credential)
        case .appManagedVault:
            return await attemptAppManagedVaultRefresh(of: credential)
        case .keychain, .unversionedVaultMirror, .refreshed:
            Logger.warning("CLI mirror credential의 독립 refresh를 건너뜁니다")
            return nil
        }
    }

    /// Claude Code 로그인은 앱이 직접 갱신하지 않는다. 앱이 refresh token을 쓰면 Claude Code가 가진 토큰이
    /// 무효가 되므로 Claude Code에 갱신을 맡기고 다시 읽는다.
    private func refreshThroughClaudeCode(of credential: ClaudeCodeOAuthCredential) async -> ClaudeCodeOAuthCredential?
    {
        guard !Task.isCancelled, await recoveryCoordinator.canRefreshCLIGeneration(credential) else {
            lastReadError = .reconnectRequired
            return nil
        }
        lastReadError = nil
        switch await cliRefresher(usesScopedKeychainService ? claudeConfigDirectory.path : nil) {
        case .refreshed: break
        case .notLoggedIn:
            lastReadError = .reauthenticationRequired
            return nil
        case .executableNotFound:
            lastReadError = .executableNotFound
            return nil
        case .unavailable:
            lastReadError = .refreshUnavailable
            return nil
        }
        guard case .credential(let file) = await lookupCredentialFromFiles() else { return nil }
        let current = await keychainCredential(fresherThan: file)?.credential ?? file
        guard !current.isExpired else { return nil }
        lastReadError = nil
        await persistCredentialToVault(current)
        return current
    }

    private func attemptAppManagedVaultRefresh(
        of credential: ClaudeCodeOAuthCredential
    ) async -> ClaudeCodeOAuthCredential? {
        let originalPayload: String
        let id: UUID
        do {
            guard !Task.isCancelled,
                let loaded = try appCredentialVault.loadPayload(),
                ClaudeOAuthCredentialVaultPayload.ownership(of: loaded) == .appManaged,
                Self.parseCredential(from: loaded, source: .appManagedVault)?.refreshToken == credential.refreshToken
            else { lastReadError = .reconnectRequired; return nil }
            originalPayload = loaded
            id = try await recoveryCoordinator.beginRefresh(originalPayload: loaded, accountID: nil)
        } catch { lastReadError = .reconnectRequired; return nil }
        do {
            let recovery = recoveryCoordinator
            let refreshed = try await tokenRefresher.refresh(
                credential,
                beforeSending: {
                    try Task.checkCancellation()
                    try await recovery.markRefreshStarted(id)
                })
            guard let payload = Self.mergingRefreshedCredential(refreshed, into: originalPayload) else {
                await recoveryCoordinator.releaseRefresh(id)
                lastReadError = .reconnectRequired
                return nil
            }
            // Preserve first, even when the source changed, the caller was
            // cancelled, or shutdown has stopped new active-vault writes.
            do { try await recoveryCoordinator.preserveSuccessor(payload, operationID: id) } catch {
                let usable = try? await recoveryCoordinator.usableRefreshSuccessor(id)
                await recoveryCoordinator.releaseRefresh(id)
                if let usable, !Task.isCancelled {
                    lastReadError = nil
                    return Self.parseCredential(from: usable, source: .appManagedVault)
                }
                lastReadError = .reconnectRequired
                return nil
            }
            do {
                let applied = try await recoveryCoordinator.applyRefreshSuccessor(id)
                lastReadError = nil
                return Self.parseCredential(from: applied, source: .appManagedVault)
            } catch {
                let usable = try? await recoveryCoordinator.usableRefreshSuccessor(id)
                await recoveryCoordinator.releaseRefresh(id)
                if let usable, !Task.isCancelled {
                    lastReadError = nil
                    return Self.parseCredential(from: usable, source: .appManagedVault)
                }
                lastReadError = .reconnectRequired
                return nil
            }
        } catch ClaudeOAuthTokenRefresher.RefreshError.notSent {
            try? await recoveryCoordinator.finishRefreshWithoutSending(id)
            await recoveryCoordinator.releaseRefresh(id)
            lastReadError = .refreshUnavailable
            return nil
        } catch ClaudeOAuthTokenRefresher.RefreshError.missingRefreshToken {
            try? await recoveryCoordinator.finishRefreshWithoutSending(id)
            await recoveryCoordinator.releaseRefresh(id)
            lastReadError = .reconnectRequired
            return nil
        } catch ClaudeOAuthTokenRefresher.RefreshError.invalidGrant {
            try? await recoveryCoordinator.retainRejectedRefresh(id)
            await recoveryCoordinator.releaseRefresh(id)
            lastReadError = .reauthenticationRequired
            return nil
        } catch {
            // Transport failure/invalid response after POST is uncertain. The
            // durable started record prevents any old-generation retry.
            await recoveryCoordinator.releaseRefresh(id)
            lastReadError = .reconnectRequired
            return nil
        }
    }

    private static func mergingRefreshedCredential(
        _ credential: ClaudeCodeOAuthCredential, into original: String
    ) -> String? {
        guard let data = original.data(using: .utf8),
            var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            var oauth = root["claudeAiOauth"] as? [String: Any]
        else { return nil }
        oauth["accessToken"] = credential.accessToken
        oauth["refreshToken"] = credential.refreshToken
        oauth["expiresAt"] = credential.expiresAt.map { Int($0.timeIntervalSince1970 * 1000) }
        root["claudeAiOauth"] = oauth
        guard let output = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
            let payload = String(data: output, encoding: .utf8)
        else { return nil }
        return ClaudeOAuthCredentialVaultPayload.encode(credentialPayload: payload, ownership: .appManaged)
    }

    private func nativeReadOnlyCredential(_ lookup: CredentialFileLookup) async -> ClaudeCodeOAuthCredential? {
        if case .payload(let payload) = await cliKeychainPayloadReader(cliKeychainService),
            let credential = Self.parseCredential(from: payload, source: .keychain(service: cliKeychainService)),
            !credential.isExpired
        {
            return credential
        }
        if case .credential(let credential) = lookup, !credential.isExpired { return credential }
        lastReadError = .reconnectRequired
        return nil
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
                let verifiedCredential = Self.parseCredential(
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
            guard !Task.isCancelled, let lease = Self.recoveryReadLease else { return false }
            try await recoveryCoordinator.saveMirror(payload, lease: lease)
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

    nonisolated static let defaultKeychainService = "Claude Code-credentials"
    nonisolated static let credentialFileNames = [".credentials.json", "credentials.json"]

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
            return defaultKeychainService
        }

        return scopedKeychainServiceName(configDirectoryValue: normalizedConfig)
    }

    /// CLAUDE_CONFIG_DIR을 준 Claude Code가 쓰는 Keychain 이름. Claude Code는 변수 원문을 NFC로만 바꿔
    /// 해시하고 경로를 정리하지 않는다(2.1.288 확인). 그래서 끝 '/'나 링크 경로처럼 표기가 다르면 이름도 다르다.
    nonisolated static func scopedKeychainServiceName(configDirectoryValue: String) -> String {
        let digest = SHA256.hash(data: Data(configDirectoryValue.precomposedStringWithCanonicalMapping.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(defaultKeychainService)-\(suffix)"
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
        let candidates = Self.credentialFileNames.map { claudeConfigDirectory.appendingPathComponent($0) }

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
                await updateProfileMetadata(from: text)
                return .credential(credential)
            }
            return .unavailable
        }

        Logger.debug("OAuth 토큰 파일 조회 실패 (\(claudeConfigDirectory.lastPathComponent))")
        return .missing
    }

    private func updateProfileMetadata(from payload: String) async {
        guard !Task.isCancelled, let profileMetadataStore else { return }
        let lease: CredentialRecoveryReadLease
        if Self.importOperation != nil {
            guard await currentImportIsValid(), let current = try? await recoveryCoordinator.beginRead(),
                await currentImportIsValid()
            else { return }
            lease = current
        } else {
            guard let current = Self.recoveryReadLease else { return }
            lease = current
        }
        _ = await profileMetadataStore.update(from: payload, guardedBy: recoveryCoordinator, lease: lease)
    }

    private func decodeCredential(
        from credentialsText: String,
        source: ClaudeCodeOAuthCredential.Source,
        sourceDescription: String
    ) async -> ClaudeCodeOAuthCredential? {
        guard let credential = Self.parseCredential(from: credentialsText, source: source) else {
            return nil
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

    nonisolated static func parseCredential(
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

    private nonisolated static func extractAccessTokenByRegex(from text: String) -> String? {
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

    private nonisolated static func firstNonEmptyString(_ values: Any?...) -> String? {
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

    private nonisolated static func firstDateValue(_ values: Any?...) -> Date? {
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
