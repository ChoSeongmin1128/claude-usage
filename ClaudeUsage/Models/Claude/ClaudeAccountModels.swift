import CryptoKit
import Foundation

nonisolated enum ClaudeAccountKind: String, Codable, CaseIterable, Sendable {
    case webSession = "web_session"
    case claudeCodeExternal = "claude_code_external"

    nonisolated var displayName: String {
        switch self {
        case .webSession:
            return "브라우저 로그인"
        case .claudeCodeExternal:
            return "Claude Code 로그인"
        }
    }
}

nonisolated enum ClaudeAccountSource: String, Codable, Sendable, Equatable {
    case chromeProfile = "chrome_profile"
    case embeddedWebLogin = "embedded_web_login"
    case manualInput = "manual_input"
    case legacyMigration = "legacy_migration"
    case claudeCodeCLI = "claude_code_cli"
}

nonisolated struct ClaudeAccountIdentity: Codable, Equatable, Sendable {
    var email: String?
    var organizationName: String?
    var organizationID: String?
    var planLabel: String?
    var fingerprint: String?

    nonisolated init(
        email: String? = nil,
        organizationName: String? = nil,
        organizationID: String? = nil,
        planLabel: String? = nil,
        fingerprint: String? = nil
    ) {
        self.email = Self.normalized(email)
        self.organizationName = Self.normalized(organizationName)
        self.organizationID = Self.normalized(organizationID)
        self.planLabel = Self.normalized(planLabel)
        self.fingerprint = Self.normalized(fingerprint)
    }

    /// 새 값이 있는 항목만 바꾼다. 로그인이 바뀐 경우는 `replaceIdentity`로 비운 뒤 채운다.
    nonisolated func merging(_ newer: ClaudeAccountIdentity) -> ClaudeAccountIdentity {
        ClaudeAccountIdentity(
            email: newer.email ?? email,
            organizationName: newer.organizationName ?? organizationName,
            organizationID: newer.organizationID ?? organizationID,
            planLabel: newer.planLabel ?? planLabel,
            fingerprint: newer.fingerprint ?? fingerprint
        )
    }

    nonisolated var primaryLabel: String? {
        // Stable IDs belong in diagnostics/detail rows, never in the primary
        // user-facing account label. OAuth inventory can temporarily know only
        // an organization UUID plus a readable plan name while profile refresh
        // is still in flight.
        email ?? organizationName ?? planLabel
    }

    nonisolated static func == (lhs: ClaudeAccountIdentity, rhs: ClaudeAccountIdentity) -> Bool {
        lhs.email == rhs.email
            && lhs.organizationName == rhs.organizationName
            && lhs.organizationID == rhs.organizationID
            && lhs.planLabel == rhs.planLabel
            && lhs.fingerprint == rhs.fingerprint
    }

    private nonisolated static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated struct ClaudeAccount: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var kind: ClaudeAccountKind
    var displayName: String
    var identity: ClaudeAccountIdentity
    var source: ClaudeAccountSource?
    var sourceDetail: String?
    var browserSource: ClaudeBrowserSource?
    var preferredOrganizationID: String
    /// nil은 이 필드가 생기기 전 버전이 자동 선택 결과를 preference로 저장한
    /// legacy 상태다. true인 경우에만 런타임에서 사용자 직접 선택으로 취급한다.
    var preferredOrganizationWasUserSelected: Bool?
    var createdAt: Date
    var lastUsedAt: Date
    var lastValidationState: ClaudeCredentialValidationState

    nonisolated init(
        id: String,
        kind: ClaudeAccountKind,
        displayName: String,
        identity: ClaudeAccountIdentity = ClaudeAccountIdentity(),
        source: ClaudeAccountSource? = nil,
        sourceDetail: String? = nil,
        browserSource: ClaudeBrowserSource? = nil,
        preferredOrganizationID: String = "",
        preferredOrganizationWasUserSelected: Bool? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        lastValidationState: ClaudeCredentialValidationState = .detected
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? kind.displayName
            : displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.identity = identity
        self.source = source
        self.sourceDetail = sourceDetail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.browserSource = browserSource
        let normalizedPreferredOrganizationID = preferredOrganizationID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.preferredOrganizationID = normalizedPreferredOrganizationID
        self.preferredOrganizationWasUserSelected = preferredOrganizationWasUserSelected
            ?? !normalizedPreferredOrganizationID.isEmpty
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.lastValidationState = lastValidationState
    }

    nonisolated var isWebSession: Bool {
        kind == .webSession
    }

    nonisolated var displaySubtitle: String {
        identity.primaryLabel ?? kind.displayName
    }

    /// 직접 선택 marker가 있는 값만 강제 preference로 사용한다. 이전 버전이
    /// 자동으로 저장한 ID는 nil marker라서 새 자동 선택 정책의 평가 대상이 된다.
    nonisolated var userSelectedPreferredOrganizationID: String? {
        guard preferredOrganizationWasUserSelected == true,
              !preferredOrganizationID.isEmpty else {
            return nil
        }
        return preferredOrganizationID
    }

    nonisolated static func == (lhs: ClaudeAccount, rhs: ClaudeAccount) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.displayName == rhs.displayName
            && lhs.identity == rhs.identity
            && lhs.source == rhs.source
            && lhs.sourceDetail == rhs.sourceDetail
            && lhs.browserSource == rhs.browserSource
            && lhs.preferredOrganizationID == rhs.preferredOrganizationID
            && lhs.preferredOrganizationWasUserSelected == rhs.preferredOrganizationWasUserSelected
            && lhs.createdAt == rhs.createdAt
            && lhs.lastUsedAt == rhs.lastUsedAt
            && lhs.lastValidationState == rhs.lastValidationState
    }
}

nonisolated protocol ClaudeSessionKeyVault: Sendable {
    nonisolated func saveString(_ value: String, account: String) throws
    nonisolated func loadString(account: String) throws -> String?
    nonisolated func delete(account: String) throws
}

nonisolated struct ClaudeAccountState: Equatable, Sendable {
    var accounts: [ClaudeAccount]
    var activeAccountID: String?

    nonisolated var activeAccount: ClaudeAccount? {
        guard let activeAccountID else { return nil }
        return accounts.first(where: { $0.id == activeAccountID })
    }

    nonisolated static func == (lhs: ClaudeAccountState, rhs: ClaudeAccountState) -> Bool {
        lhs.accounts == rhs.accounts && lhs.activeAccountID == rhs.activeAccountID
    }
}

nonisolated struct ClaudeWebSessionUpsertResult: Sendable {
    let account: ClaudeAccount
    var wasStored = true
}

final class ClaudeAccountStore: @unchecked Sendable {
    nonisolated static let shared = ClaudeAccountStore(
        legacySandboxCredentialStore: AppRuntimeEnvironment.isRunningUnitTests
            || !AppDistribution.current.ownsProductionLegacyLocations
            ? nil
            : ClaudeLegacySandboxCredentialStore.shared
    )

    nonisolated static let accountsDefaultsKey = AppIdentifiers.defaultsKey("claudeAccounts.v1")
    nonisolated static let activeAccountDefaultsKey = AppIdentifiers.defaultsKey("activeClaudeAccountID")
    nonisolated static let migrationVersionDefaultsKey = AppIdentifiers.defaultsKey("claudeAccountsMigrationVersion")
    nonisolated static let legacySessionKeyDefaultsKey = "claude-session-key"
    nonisolated static let legacyPreferredOrganizationDefaultsKey = "preferredOrganizationID"
    nonisolated static let currentMigrationVersion = 4
    nonisolated static let claudeCodeExternalAccountID = "claude-code-external"

    private nonisolated(unsafe) let defaults: UserDefaults
    private let keychainVault: any ClaudeSessionKeyVault
    private let legacySandboxCredentialStore: (any ClaudeLegacySandboxCredentialStoring)?
    private let lock = NSLock()
    private let postsNotifications: Bool

    nonisolated init(
        defaults: UserDefaults = .standard,
        keychainVault: any ClaudeSessionKeyVault = ClaudeKeychainStore.shared,
        legacySandboxCredentialStore: (any ClaudeLegacySandboxCredentialStoring)? = nil,
        postsNotifications: Bool = true
    ) {
        self.defaults = defaults
        self.keychainVault = keychainVault
        self.legacySandboxCredentialStore = legacySandboxCredentialStore
        self.postsNotifications = postsNotifications
    }

    nonisolated func state() -> ClaudeAccountState {
        ensureLegacyMigrationIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return rawState()
    }

    nonisolated func accounts() -> [ClaudeAccount] {
        state().accounts
    }

    nonisolated func activeAccount() -> ClaudeAccount? {
        state().activeAccount
    }

    nonisolated func activeWebAccount() -> ClaudeAccount? {
        guard let account = activeAccount(), account.kind == .webSession else { return nil }
        return account
    }

    nonisolated func setActiveAccountID(_ id: String) {
        ensureLegacyMigrationIfNeeded()
        lock.lock()
        let state = rawState()
        guard state.accounts.contains(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        var accounts = state.accounts
        if let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index].lastUsedAt = Date()
        }
        let activeAccountChanged = state.activeAccountID != id
        let saved = saveRaw(accounts: accounts, activeAccountID: id, replacingProtectedActive: true)
        lock.unlock()
        if saved { postAccountNotifications(activeAccountChanged: activeAccountChanged) }
    }

    @discardableResult
    nonisolated func upsertWebSessionAccount(
        sessionKey: String,
        preferredOrganizationID: String? = nil,
        identity: ClaudeAccountIdentity = ClaudeAccountIdentity(),
        displayName: String? = nil,
        source: ClaudeAccountSource? = nil,
        sourceDetail: String? = nil,
        lastValidationState: ClaudeCredentialValidationState = .detected,
        setActive: Bool = true
    ) -> ClaudeAccount {
        upsertWebSessionAccountResult(
            sessionKey: sessionKey,
            preferredOrganizationID: preferredOrganizationID,
            identity: identity,
            displayName: displayName,
            source: source,
            sourceDetail: sourceDetail,
            lastValidationState: lastValidationState,
            setActive: setActive
        ).account
    }

    /// Adding a connection never removes older credentials. Verified replacement
    /// uses replaceWebConnection after the actual account and organization match.
    @discardableResult
    nonisolated func upsertWebSessionAccountWithResult(
        sessionKey: String,
        preferredOrganizationID: String? = nil,
        identity: ClaudeAccountIdentity = ClaudeAccountIdentity(),
        displayName: String? = nil,
        source: ClaudeAccountSource? = nil,
        sourceDetail: String? = nil,
        lastValidationState: ClaudeCredentialValidationState = .detected,
        setActive: Bool = true
    ) -> ClaudeWebSessionUpsertResult {
        upsertWebSessionAccountResult(
            sessionKey: sessionKey,
            preferredOrganizationID: preferredOrganizationID,
            identity: identity,
            displayName: displayName,
            source: source,
            sourceDetail: sourceDetail,
            lastValidationState: lastValidationState,
            setActive: setActive
        )
    }

    private nonisolated func upsertWebSessionAccountResult(
        sessionKey: String,
        preferredOrganizationID: String?,
        identity: ClaudeAccountIdentity,
        displayName: String?,
        source: ClaudeAccountSource?,
        sourceDetail: String?,
        lastValidationState: ClaudeCredentialValidationState,
        setActive: Bool
    ) -> ClaudeWebSessionUpsertResult {
        ensureLegacyMigrationIfNeeded()
        let fingerprint = Self.fingerprint(for: sessionKey)
        let accountID = Self.webSessionAccountID(fingerprint: fingerprint)
        let requestedPreferredOrganizationID = preferredOrganizationID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedPreferenceWasUserSelected = requestedPreferredOrganizationID.map { !$0.isEmpty }
        let now = Date()

        lock.lock()
        let state = rawState()
        var accounts = state.accounts
        let resolvedIdentity = ClaudeAccountIdentity(
            email: identity.email,
            organizationName: identity.organizationName,
            organizationID: identity.organizationID,
            planLabel: identity.planLabel,
            fingerprint: identity.fingerprint ?? fingerprint
        )
        let requestedDisplayName = displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedSourceDetail = sourceDetail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        let account: ClaudeAccount
        if let index = accounts.firstIndex(where: { $0.id == accountID }) {
            let resolvedPreferredOrganizationID: String
            let resolvedPreferenceWasUserSelected: Bool?
            if requestedPreferenceWasUserSelected == true {
                resolvedPreferredOrganizationID = requestedPreferredOrganizationID ?? ""
                resolvedPreferenceWasUserSelected = true
            } else {
                resolvedPreferredOrganizationID = requestedPreferredOrganizationID
                    ?? accounts[index].preferredOrganizationID
                resolvedPreferenceWasUserSelected = requestedPreferenceWasUserSelected
            }
            let resolvedDisplayName: String
            if let requestedDisplayName, !requestedDisplayName.isEmpty {
                resolvedDisplayName = requestedDisplayName
            } else {
                resolvedDisplayName = resolvedIdentity.primaryLabel ?? accounts[index].displayName
            }
            accounts[index].displayName = resolvedDisplayName
            accounts[index].identity = resolvedIdentity
            accounts[index].source = source ?? accounts[index].source ?? .embeddedWebLogin
            accounts[index].sourceDetail = requestedSourceDetail ?? accounts[index].sourceDetail
            accounts[index].preferredOrganizationID = resolvedPreferredOrganizationID
            if let resolvedPreferenceWasUserSelected {
                accounts[index].preferredOrganizationWasUserSelected = resolvedPreferenceWasUserSelected
            }
            accounts[index].lastUsedAt = now
            accounts[index].lastValidationState = lastValidationState
            account = accounts[index]
        } else {
            let resolvedPreferredOrganizationID: String
            let resolvedPreferenceWasUserSelected: Bool?
            if requestedPreferenceWasUserSelected == true {
                resolvedPreferredOrganizationID = requestedPreferredOrganizationID ?? ""
                resolvedPreferenceWasUserSelected = true
            } else {
                resolvedPreferredOrganizationID = requestedPreferredOrganizationID
                    ?? legacyPreferredOrganizationID()
                resolvedPreferenceWasUserSelected = requestedPreferenceWasUserSelected
                    ?? !resolvedPreferredOrganizationID.isEmpty
            }
            let resolvedDisplayName: String
            if let requestedDisplayName, !requestedDisplayName.isEmpty {
                resolvedDisplayName = requestedDisplayName
            } else {
                resolvedDisplayName = resolvedIdentity.primaryLabel ?? "브라우저 계정"
            }
            account = ClaudeAccount(
                id: accountID,
                kind: .webSession,
                displayName: resolvedDisplayName,
                identity: resolvedIdentity,
                source: source ?? .embeddedWebLogin,
                sourceDetail: requestedSourceDetail,
                preferredOrganizationID: resolvedPreferredOrganizationID,
                preferredOrganizationWasUserSelected: resolvedPreferenceWasUserSelected,
                createdAt: now,
                lastUsedAt: now,
                lastValidationState: lastValidationState
            )
            accounts.append(account)
        }

        let activeID: String
        if setActive {
            activeID = accountID
        } else {
            activeID = state.activeAccountID ?? accountID
        }
        let saved = saveRaw(accounts: accounts, activeAccountID: activeID)
        lock.unlock()
        if saved { postAccountNotifications(activeAccountChanged: activeID != state.activeAccountID) }
        return ClaudeWebSessionUpsertResult(
            account: account,
            wasStored: saved
        )
    }

    @discardableResult
    nonisolated func upsertClaudeCodeExternalAccount(
        identity: ClaudeAccountIdentity = ClaudeAccountIdentity(),
        validationState: ClaudeCredentialValidationState = .detected,
        setActiveIfMissing: Bool = true
    ) -> ClaudeAccount {
        ensureLegacyMigrationIfNeeded()
        lock.lock()
        let state = rawState()
        var accounts = state.accounts
        let now = Date()
        let accountID = Self.claudeCodeExternalAccountID
        let account: ClaudeAccount
        var didChange = false

        if let index = accounts.firstIndex(where: { $0.id == accountID }) {
            // 일부만 아는 값(조직만 아는 경우 등)이 이미 아는 이메일을 지우지 않게 합친다.
            let merged = accounts[index].identity.merging(identity)
            let resolvedDisplayName = merged.primaryLabel ?? accounts[index].displayName
            if accounts[index].displayName != resolvedDisplayName {
                accounts[index].displayName = resolvedDisplayName
                didChange = true
            }
            if !Self.identity(accounts[index].identity, equals: merged) {
                accounts[index].identity = merged
                didChange = true
            }
            if accounts[index].source != .claudeCodeCLI {
                accounts[index].source = .claudeCodeCLI
                didChange = true
            }
            if accounts[index].lastValidationState != validationState {
                accounts[index].lastValidationState = validationState
                didChange = true
            }
            account = accounts[index]
        } else {
            account = ClaudeAccount(
                id: accountID,
                kind: .claudeCodeExternal,
                displayName: identity.primaryLabel ?? "Claude Code 계정",
                identity: identity,
                source: .claudeCodeCLI,
                lastUsedAt: now,
                lastValidationState: validationState
            )
            accounts.append(account)
            didChange = true
        }

        let activeID = (setActiveIfMissing && state.activeAccountID == nil) ? accountID : state.activeAccountID
        if activeID != state.activeAccountID {
            didChange = true
        }
        guard didChange else {
            lock.unlock()
            return account
        }
        saveRaw(accounts: accounts, activeAccountID: activeID)
        lock.unlock()
        postAccountNotifications(activeAccountChanged: activeID != state.activeAccountID)
        return account
    }

    nonisolated func deleteAccount(id: String) {
        ensureLegacyMigrationIfNeeded()
        lock.lock()
        var state = rawState()
        guard let removed = state.accounts.first(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        state.accounts.removeAll { $0.id == id }
        let activeID: String?
        if state.activeAccountID == id {
            activeID = state.accounts.first(where: { $0.kind == .webSession })?.id
                ?? state.accounts.first?.id
        } else {
            activeID = state.activeAccountID
        }
        guard saveRaw(accounts: state.accounts, activeAccountID: activeID) else {
            lock.unlock()
            return
        }
        lock.unlock()

        var deletedSessionCredential = false
        if removed.kind == .webSession {
            do {
                try keychainVault.delete(account: ClaudeKeychainStore.accountName(for: removed.id))
                deletedSessionCredential = true
            } catch {
                Logger.warning("Claude 브라우저 credential 삭제 실패")
            }
        }
        ClaudeAccountLocalData.remove(accountID: removed.id)
        postAccountNotifications(activeAccountChanged: state.activeAccountID == id)
        if deletedSessionCredential {
            postSessionCredentialNotification(accountID: removed.id)
        }
    }

    nonisolated func updatePreferredOrganizationID(_ organizationID: String, for accountID: String) {
        updateAccount(id: accountID) { account in
            guard account.kind == .webSession else { return }
            let normalized = organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
            account.preferredOrganizationID = normalized
            account.preferredOrganizationWasUserSelected = !normalized.isEmpty
        }
    }

    nonisolated func setBrowserSource(_ source: ClaudeBrowserSource?, for accountID: String) {
        updateAccount(id: accountID) { $0.browserSource = source }
    }

    nonisolated func mergeIdentity(_ identity: ClaudeAccountIdentity, for accountID: String) {
        updateAccount(id: accountID) { account in
            account.identity = account.identity.merging(identity)
        }
    }

    nonisolated func replaceIdentity(_ identity: ClaudeAccountIdentity, for accountID: String) {
        updateAccount(id: accountID) { account in
            account.identity = identity
        }
    }

    nonisolated func updateValidationState(_ state: ClaudeCredentialValidationState, for accountID: String) {
        updateAccount(id: accountID) { account in
            account.lastValidationState = state
            if state == .verified {
                account.lastUsedAt = Date()
            }
        }
    }

    nonisolated func ensureLegacyMigrationIfNeeded() {
        lock.lock()
        var migrationVersion = defaults.integer(forKey: Self.migrationVersionDefaultsKey)
        guard migrationVersion < Self.currentMigrationVersion else {
            lock.unlock()
            return
        }

        let stored = loadStoredAccounts()
        guard stored != nil || defaults.object(forKey: Self.accountsDefaultsKey) == nil else {
            lock.unlock()
            return
        }
        let protectedIDs = stored?.protectedIDs ?? []
        let migrationBlocked = !protectedIDs.isEmpty
        var state = rawState()
        let previousActiveAccountID = state.activeAccountID
        var shouldDeleteLegacyKeychainAccount = false
        var didChangeAccounts = false

        if migrationVersion < 1 {
            let legacyKeychainAccount = ClaudeKeychainStore.defaultAccount
            let keychainValue = try? keychainVault.loadString(account: legacyKeychainAccount)
            let defaultsValue = defaults.string(forKey: Self.legacySessionKeyDefaultsKey)
            let legacySessionKey = [keychainValue, defaultsValue]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })

            if let legacySessionKey,
                !protectedIDs.contains(Self.webSessionAccountID(fingerprint: Self.fingerprint(for: legacySessionKey)))
            {
                let fingerprint = Self.fingerprint(for: legacySessionKey)
                let accountID = Self.webSessionAccountID(fingerprint: fingerprint)
                let scopedAccountName = ClaudeKeychainStore.accountName(for: accountID)
                do {
                    try keychainVault.saveString(legacySessionKey, account: scopedAccountName)
                } catch {
                    Logger.warning("Claude 계정 마이그레이션 실패: \(error.localizedDescription)")
                    lock.unlock()
                    return
                }

                if !state.accounts.contains(where: { $0.id == accountID }) {
                    let preferredOrganizationID = legacyPreferredOrganizationID()
                    state.accounts.append(
                        ClaudeAccount(
                            id: accountID,
                            kind: .webSession,
                            displayName: "브라우저 계정",
                            identity: ClaudeAccountIdentity(fingerprint: fingerprint),
                            source: .legacyMigration,
                            preferredOrganizationID: preferredOrganizationID
                        )
                    )
                    didChangeAccounts = true
                }

                if state.activeAccountID == nil
                    || state.accounts.contains(where: { $0.id == state.activeAccountID }) == false
                {
                    state.activeAccountID = accountID
                    didChangeAccounts = true
                }
                shouldDeleteLegacyKeychainAccount = true
            } else if state.activeAccountID == nil {
                state.activeAccountID = state.accounts.first(where: { $0.kind == .webSession })?.id
                    ?? state.accounts.first?.id
                didChangeAccounts = state.activeAccountID != nil
            }

            migrationVersion = 1
        }

        if migrationVersion < 2 { migrationVersion = 2 }

        if migrationVersion < 3 {
            let defaultsValue = defaults.string(forKey: Self.legacySessionKeyDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let legacySessionKey = defaultsValue, !legacySessionKey.isEmpty {
                let fingerprint = Self.fingerprint(for: legacySessionKey)
                let accountID = Self.webSessionAccountID(fingerprint: fingerprint)
                guard !protectedIDs.contains(accountID) else {
                    saveRaw(accounts: state.accounts, activeAccountID: state.activeAccountID)
                    lock.unlock()
                    return
                }
                let scopedAccountName = ClaudeKeychainStore.accountName(for: accountID)
                do {
                    if try keychainVault.loadString(account: scopedAccountName) != legacySessionKey {
                        try keychainVault.saveString(legacySessionKey, account: scopedAccountName)
                    }
                    guard try keychainVault.loadString(account: scopedAccountName)
                        == legacySessionKey
                    else {
                        throw ClaudeKeychainStoreError.unexpectedStatus(errSecNotAvailable)
                    }
                } catch {
                    // 평문 원본은 scoped Keychain 저장이 확인되기 전에는 삭제하지
                    // 않는다. migration version도 올리지 않아 다음 실행에서 재시도한다.
                    Logger.warning("잔존 Claude credential 보안 마이그레이션 실패")
                    saveRaw(accounts: state.accounts, activeAccountID: state.activeAccountID)
                    lock.unlock()
                    return
                }

                if !state.accounts.contains(where: { $0.id == accountID }) {
                    state.accounts.append(
                        ClaudeAccount(
                            id: accountID,
                            kind: .webSession,
                            displayName: "브라우저 계정",
                            identity: ClaudeAccountIdentity(fingerprint: fingerprint),
                            source: .legacyMigration
                        )
                    )
                    didChangeAccounts = true
                }
                if state.activeAccountID == nil
                    || state.accounts.contains(where: { $0.id == state.activeAccountID }) == false
                {
                    state.activeAccountID = accountID
                    didChangeAccounts = true
                }
            }

            // 값이 없거나 scoped Keychain 저장이 검증된 경우에만 평문을 제거한다.
            defaults.removeObject(forKey: Self.legacySessionKeyDefaultsKey)
            migrationVersion = 3
        }

        if migrationVersion < 4 {
            do {
                let legacySandboxSessionKey = try legacySandboxCredentialStore?
                    .loadLegacySessionKey()?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if let legacySandboxSessionKey, !legacySandboxSessionKey.isEmpty {
                    let hasSecuredWebCredential = state.accounts
                        .filter { $0.kind == .webSession }
                        .contains { account in
                            let scopedAccount = ClaudeKeychainStore.accountName(for: account.id)
                            do {
                                guard let value = try keychainVault.loadString(account: scopedAccount) else {
                                    return false
                                }
                                return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                            } catch {
                                return false
                            }
                        }

                    if !hasSecuredWebCredential {
                        let fingerprint = Self.fingerprint(for: legacySandboxSessionKey)
                        let accountID = Self.webSessionAccountID(fingerprint: fingerprint)
                        guard !protectedIDs.contains(accountID) else {
                            saveRaw(accounts: state.accounts, activeAccountID: state.activeAccountID)
                            lock.unlock()
                            return
                        }
                        let scopedAccount = ClaudeKeychainStore.accountName(for: accountID)
                        if try keychainVault.loadString(account: scopedAccount) != legacySandboxSessionKey {
                            try keychainVault.saveString(legacySandboxSessionKey, account: scopedAccount)
                        }
                        guard try keychainVault.loadString(account: scopedAccount)
                            == legacySandboxSessionKey
                        else {
                            throw ClaudeKeychainStoreError.unexpectedStatus(errSecNotAvailable)
                        }

                        if !state.accounts.contains(where: { $0.id == accountID }) {
                            state.accounts.append(
                                ClaudeAccount(
                                    id: accountID,
                                    kind: .webSession,
                                    displayName: "브라우저 계정",
                                    identity: ClaudeAccountIdentity(fingerprint: fingerprint),
                                    source: .legacyMigration
                                )
                            )
                            didChangeAccounts = true
                        }
                        if state.activeAccountID == nil
                            || state.accounts.contains(where: { $0.id == state.activeAccountID }) == false
                        {
                            state.activeAccountID = accountID
                            didChangeAccounts = true
                        }

                        // plaintext를 지우기 전에 복구 가능한 Keychain/account 상태를
                        // 먼저 영속화한다. 이 사이에 프로세스가 종료되어도 다음 실행은
                        // scoped credential과 inventory를 기준으로 정리를 재시도할 수 있다.
                        guard saveRaw(accounts: state.accounts, activeAccountID: state.activeAccountID) else {
                            throw ClaudeKeychainStoreError.unexpectedStatus(errSecNotAvailable)
                        }
                    }

                    try legacySandboxCredentialStore?.deleteLegacySessionKey()
                }
            } catch {
                Logger.warning("legacy sandbox credential 보안 마이그레이션 실패")
                saveRaw(accounts: state.accounts, activeAccountID: state.activeAccountID)
                lock.unlock()
                if didChangeAccounts {
                    postAccountNotifications(activeAccountChanged: previousActiveAccountID != state.activeAccountID)
                }
                return
            }

            migrationVersion = 4
        }

        guard saveRaw(accounts: state.accounts, activeAccountID: state.activeAccountID) else {
            lock.unlock()
            return
        }
        if !migrationBlocked {
            defaults.set(migrationVersion, forKey: Self.migrationVersionDefaultsKey)
            defaults.removeObject(forKey: Self.legacySessionKeyDefaultsKey)
        }
        lock.unlock()

        if shouldDeleteLegacyKeychainAccount {
            try? keychainVault.delete(account: ClaudeKeychainStore.defaultAccount)
        }
        if didChangeAccounts {
            postAccountNotifications(activeAccountChanged: previousActiveAccountID != state.activeAccountID)
        }
    }

    nonisolated func replaceWebConnection(
        expected: ClaudeAccount, replacement: ClaudeAccount,
        expectedPreferences: UsageAccountPreferences, preferences: UsageAccountPreferences,
        expectedActiveAccountID: String? = nil
    ) -> Bool {
        lock.lock()
        let state = rawState()
        guard state.activeAccountID == (expectedActiveAccountID ?? expected.id),
            state.accounts.first(where: { $0.id == expected.id }) == expected,
            UsageAccountPreferences.load(from: defaults) == expectedPreferences,
            canUseAccountID(replacement.id)
        else { lock.unlock(); return false }
        let originalAccounts = defaults.object(forKey: Self.accountsDefaultsKey)
        let originalActive = defaults.object(forKey: Self.activeAccountDefaultsKey)
        let originalPreferences = defaults.object(forKey: UsageAccountPreferences.key)
        var accounts = state.accounts.filter { $0.id != expected.id && $0.id != replacement.id }
        accounts.append(replacement)
        var updated = preferences
        let activeID = state.activeAccountID == expected.id ? replacement.id : state.activeAccountID
        let saved = saveRaw(accounts: accounts, activeAccountID: activeID,
            originalAccountIDs: [replacement.id: expected.id])
        guard saved, updated.commit(to: defaults, intent: .automatic).accepted else {
            PreferencePersistenceContext.restore(originalAccounts, to: defaults, key: Self.accountsDefaultsKey)
            PreferencePersistenceContext.restore(originalActive, to: defaults, key: Self.activeAccountDefaultsKey)
            PreferencePersistenceContext.restore(originalPreferences, to: defaults, key: UsageAccountPreferences.key)
            lock.unlock()
            return false
        }
        lock.unlock()
        postAccountNotifications(activeAccountChanged: state.activeAccountID != activeID)
        return true
    }

    nonisolated static func webSessionAccountID(fingerprint: String) -> String {
        "web-\(fingerprint.prefix(16))"
    }

    nonisolated static func fingerprint(for sessionKey: String) -> String {
        let digest = SHA256.hash(data: Data(sessionKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated func updateAccount(id: String, update: (inout ClaudeAccount) -> Void) {
        ensureLegacyMigrationIfNeeded()
        lock.lock()
        var state = rawState()
        guard let index = state.accounts.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let previousAccount = state.accounts[index]
        update(&state.accounts[index])
        guard state.accounts[index] != previousAccount else {
            lock.unlock()
            return
        }
        var ignoringUseTime = state.accounts[index]
        ignoringUseTime.lastUsedAt = previousAccount.lastUsedAt
        saveRaw(accounts: state.accounts, activeAccountID: state.activeAccountID)
        lock.unlock()
        // 마지막 사용 시각만 바뀌었으면 알리지 않는다. 알리면 조회가 성공할 때마다 계정을 다시 찾는다.
        if ignoringUseTime != previousAccount { postAccountNotifications() }
    }

    private nonisolated func legacyPreferredOrganizationID() -> String {
        defaults.string(forKey: Self.legacyPreferredOrganizationDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private nonisolated func rawState() -> ClaudeAccountState {
        let accounts = loadRawAccounts()
        let activeID = defaults.string(forKey: Self.activeAccountDefaultsKey)
        let validActiveID = activeID.flatMap { id in
            accounts.contains(where: { $0.id == id }) ? id : nil
        }
        return ClaudeAccountState(accounts: accounts, activeAccountID: validActiveID)
    }

    private nonisolated func loadRawAccounts() -> [ClaudeAccount] {
        loadStoredAccounts()?.elements ?? []
    }

    /// 읽지 못한 계정(새 버전이 추가한 값)도 함께 돌려준다. 계정별 자료 정리가 그 계정을 지우지 않게 한다.
    nonisolated func storedAccountIDs() -> Set<String> {
        guard let stored = loadStoredAccounts() else { return [] }
        let unreadable = stored.unreadable.compactMap { ($0 as? [String: Any])?["id"] as? String }
        return Set(stored.elements.map(\.id) + unreadable)
    }

    private nonisolated struct StoredAccounts {
        var elements: [ClaudeAccount] = []
        var unreadable: [Any] = []
        var originals: [String: [String: Any]] = [:]
        var conflictingIDs: Set<String> = []
        var protectedIDs: Set<String> = []
    }

    /// Authentication callers must check this before writing a credential for an inventory ID.
    nonisolated func canUseAccountID(_ id: String) -> Bool {
        guard let stored = loadStoredAccounts() else {
            return defaults.object(forKey: Self.accountsDefaultsKey) == nil
        }
        return !stored.protectedIDs.contains(id)
    }

    nonisolated var canPruneAccountData: Bool {
        loadStoredAccounts() != nil || defaults.object(forKey: Self.accountsDefaultsKey) == nil
    }

    private nonisolated func loadStoredAccounts() -> StoredAccounts? {
        guard let data = defaults.data(forKey: Self.accountsDefaultsKey),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return nil }
        let groups = Dictionary(grouping: raw.compactMap { $0 as? [String: Any] }) { $0["id"] as? String }
        var result = StoredAccounts()
        for (id, records) in groups {
            guard let id, records.count > 1 else { continue }
            let encodings = records.compactMap {
                try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
            }
            if Set(encodings).count != 1 || encodings.count != records.count { result.conflictingIDs.insert(id) }
        }
        var seen = Set<String>()
        for item in raw {
            let record = item as? [String: Any]
            let id = record?["id"] as? String
            if let id, result.conflictingIDs.contains(id) {
                result.unreadable.append(item)
                result.protectedIDs.insert(id)
                continue
            }
            if let record,
                let bytes = try? JSONSerialization.data(withJSONObject: record),
                let account = try? JSONDecoder().decode(ClaudeAccount.self, from: bytes)
            {
                // Only full raw-equivalent duplicates reach this branch. Coalesce their execution entry.
                if seen.insert(account.id).inserted {
                    result.elements.append(account)
                    result.originals[account.id] = record
                }
            } else {
                result.unreadable.append(item)
                if let id { result.protectedIDs.insert(id) }
            }
        }
        return result
    }

    @discardableResult
    private nonisolated func saveRaw(
        accounts: [ClaudeAccount], activeAccountID: String?,
        replacingProtectedActive: Bool = false,
        originalAccountIDs: [String: String] = [:]
    ) -> Bool {
        let stored = loadStoredAccounts()
        guard stored != nil || defaults.object(forKey: Self.accountsDefaultsKey) == nil else { return false }
        let protected = stored?.protectedIDs ?? []
        guard accounts.allSatisfy({ !protected.contains($0.id) }) else { return false }
        let before = Dictionary(uniqueKeysWithValues: (stored?.elements ?? []).map { ($0.id, $0) })
        var rows: [Any] = []
        for account in accounts {
            guard let encoded = try? JSONEncoder().encode(account),
                let after = try? JSONSerialization.jsonObject(with: encoded)
            else { return false }
            let originalID = originalAccountIDs[account.id] ?? account.id
            if let original = stored?.originals[originalID], let previous = before[originalID],
                let data = try? JSONEncoder().encode(previous),
                let previousJSON = try? JSONSerialization.jsonObject(with: data)
            {
                rows.append(PreservingJSONFields.replacing(in: original, previous: previousJSON, updated: after))
            } else {
                rows.append(after)
            }
        }
        rows += stored?.unreadable ?? []
        guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return false }
        let original = defaults.object(forKey: Self.accountsDefaultsKey)
        defaults.set(data, forKey: Self.accountsDefaultsKey)
        guard defaults.data(forKey: Self.accountsDefaultsKey) == data else {
            PreferencePersistenceContext.restore(original, to: defaults, key: Self.accountsDefaultsKey)
            return false
        }
        if !replacingProtectedActive,
            let current = defaults.string(forKey: Self.activeAccountDefaultsKey), protected.contains(current)
        {
            return true
        }
        if let activeAccountID, accounts.contains(where: { $0.id == activeAccountID }) {
            defaults.set(activeAccountID, forKey: Self.activeAccountDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.activeAccountDefaultsKey)
        }
        return true
    }

    private nonisolated func postAccountNotifications(activeAccountChanged: Bool = false) {
        guard postsNotifications else { return }

        if Thread.isMainThread {
            Self.postAccountNotificationsOnCurrentThread(activeAccountChanged: activeAccountChanged)
        } else {
            DispatchQueue.main.async {
                Self.postAccountNotificationsOnCurrentThread(activeAccountChanged: activeAccountChanged)
            }
        }
    }

    private nonisolated func postSessionCredentialNotification(accountID: String) {
        guard postsNotifications else { return }
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .claudeSessionKeyDidChange, object: accountID)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .claudeSessionKeyDidChange, object: accountID)
            }
        }
    }

    private nonisolated static func postAccountNotificationsOnCurrentThread(activeAccountChanged: Bool) {
        NotificationCenter.default.post(name: .claudeAccountsDidChange, object: nil)
        if activeAccountChanged {
            NotificationCenter.default.post(name: .claudeAccountDidChange, object: nil)
        }
    }

    private nonisolated static func identity(_ lhs: ClaudeAccountIdentity, equals rhs: ClaudeAccountIdentity) -> Bool {
        lhs.email == rhs.email
            && lhs.organizationName == rhs.organizationName
            && lhs.organizationID == rhs.organizationID
            && lhs.planLabel == rhs.planLabel
            && lhs.fingerprint == rhs.fingerprint
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
