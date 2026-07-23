import CryptoKit
import Foundation

enum ClaudeAccountKind: String, Codable, CaseIterable, Sendable {
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

enum ClaudeAccountSource: String, Codable, Sendable, Equatable {
    case chromeProfile = "chrome_profile"
    case embeddedWebLogin = "embedded_web_login"
    case manualInput = "manual_input"
    case legacyMigration = "legacy_migration"
    case claudeCodeCLI = "claude_code_cli"
}

struct ClaudeAccountIdentity: Codable, Equatable, Sendable {
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

    nonisolated var primaryLabel: String? {
        email ?? organizationName ?? organizationID ?? planLabel
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

struct ClaudeAccount: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var kind: ClaudeAccountKind
    var displayName: String
    var identity: ClaudeAccountIdentity
    var source: ClaudeAccountSource?
    var sourceDetail: String?
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
            && lhs.preferredOrganizationID == rhs.preferredOrganizationID
            && lhs.preferredOrganizationWasUserSelected == rhs.preferredOrganizationWasUserSelected
            && lhs.createdAt == rhs.createdAt
            && lhs.lastUsedAt == rhs.lastUsedAt
            && lhs.lastValidationState == rhs.lastValidationState
    }
}

protocol ClaudeSessionKeyVault: Sendable {
    nonisolated func saveString(_ value: String, account: String) throws
    nonisolated func loadString(account: String) throws -> String?
    nonisolated func delete(account: String) throws
}

struct ClaudeAccountState: Equatable, Sendable {
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

final class ClaudeAccountStore: @unchecked Sendable {
    nonisolated static let shared = ClaudeAccountStore()

    nonisolated static let accountsDefaultsKey = "ClaudeUsage.claudeAccounts.v1"
    nonisolated static let activeAccountDefaultsKey = "ClaudeUsage.activeClaudeAccountID"
    nonisolated static let migrationVersionDefaultsKey = "ClaudeUsage.claudeAccountsMigrationVersion"
    nonisolated static let legacySessionKeyDefaultsKey = "claude-session-key"
    nonisolated static let legacyPreferredOrganizationDefaultsKey = "preferredOrganizationID"
    nonisolated static let currentMigrationVersion = 1
    nonisolated static let claudeCodeExternalAccountID = "claude-code-external"

    private nonisolated(unsafe) let defaults: UserDefaults
    private let keychainVault: any ClaudeSessionKeyVault
    private let lock = NSLock()
    private let postsNotifications: Bool

    nonisolated init(
        defaults: UserDefaults = .standard,
        keychainVault: any ClaudeSessionKeyVault = ClaudeKeychainStore.shared,
        postsNotifications: Bool = true
    ) {
        self.defaults = defaults
        self.keychainVault = keychainVault
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
        saveRaw(accounts: accounts, activeAccountID: id)
        lock.unlock()
        postAccountNotifications(activeAccountChanged: activeAccountChanged)
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
            let resolvedPreferredOrganizationID = requestedPreferredOrganizationID
                ?? accounts[index].preferredOrganizationID
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
            if let requestedPreferenceWasUserSelected {
                accounts[index].preferredOrganizationWasUserSelected = requestedPreferenceWasUserSelected
            }
            accounts[index].lastUsedAt = now
            accounts[index].lastValidationState = lastValidationState
            account = accounts[index]
        } else {
            let resolvedPreferredOrganizationID = requestedPreferredOrganizationID
                ?? legacyPreferredOrganizationID()
            let resolvedPreferenceWasUserSelected = requestedPreferenceWasUserSelected
                ?? !resolvedPreferredOrganizationID.isEmpty
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

        let activeID = setActive ? accountID : (state.activeAccountID ?? accountID)
        saveRaw(accounts: accounts, activeAccountID: activeID)
        lock.unlock()
        postAccountNotifications(activeAccountChanged: activeID != state.activeAccountID)
        return account
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
        let resolvedDisplayName = identity.primaryLabel ?? "Claude Code 계정"
        let account: ClaudeAccount
        var didChange = false

        if let index = accounts.firstIndex(where: { $0.id == accountID }) {
            if accounts[index].displayName != resolvedDisplayName {
                accounts[index].displayName = resolvedDisplayName
                didChange = true
            }
            if !Self.identity(accounts[index].identity, equals: identity) {
                accounts[index].identity = identity
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
                displayName: resolvedDisplayName,
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
        saveRaw(accounts: state.accounts, activeAccountID: activeID)
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

    nonisolated func mergeIdentity(_ identity: ClaudeAccountIdentity, for accountID: String) {
        updateAccount(id: accountID) { account in
            account.identity = ClaudeAccountIdentity(
                email: identity.email ?? account.identity.email,
                organizationName: identity.organizationName ?? account.identity.organizationName,
                organizationID: identity.organizationID ?? account.identity.organizationID,
                planLabel: identity.planLabel ?? account.identity.planLabel,
                fingerprint: identity.fingerprint ?? account.identity.fingerprint
            )
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
        let migrationVersion = defaults.integer(forKey: Self.migrationVersionDefaultsKey)
        guard migrationVersion < Self.currentMigrationVersion else {
            lock.unlock()
            return
        }

        var state = rawState()
        let legacyKeychainAccount = ClaudeKeychainStore.defaultAccount
        let keychainValue = try? keychainVault.loadString(account: legacyKeychainAccount)
        let defaultsValue = defaults.string(forKey: Self.legacySessionKeyDefaultsKey)
        let legacySessionKey = [keychainValue, defaultsValue]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })

        guard let legacySessionKey else {
            if state.activeAccountID == nil {
                state.activeAccountID = state.accounts.first(where: { $0.kind == .webSession })?.id
                    ?? state.accounts.first?.id
            }
            saveRaw(accounts: state.accounts, activeAccountID: state.activeAccountID)
            defaults.set(Self.currentMigrationVersion, forKey: Self.migrationVersionDefaultsKey)
            lock.unlock()
            return
        }

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
        }

        if state.activeAccountID == nil || state.accounts.contains(where: { $0.id == state.activeAccountID }) == false {
            state.activeAccountID = accountID
        }

        saveRaw(accounts: state.accounts, activeAccountID: state.activeAccountID)
        try? keychainVault.delete(account: legacyKeychainAccount)
        defaults.removeObject(forKey: Self.legacySessionKeyDefaultsKey)
        defaults.set(Self.currentMigrationVersion, forKey: Self.migrationVersionDefaultsKey)
        lock.unlock()
        postAccountNotifications()
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
        saveRaw(accounts: state.accounts, activeAccountID: state.activeAccountID)
        lock.unlock()
        postAccountNotifications()
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
        guard let data = defaults.data(forKey: Self.accountsDefaultsKey),
              let decoded = try? JSONDecoder().decode([ClaudeAccount].self, from: data) else {
            return []
        }
        return decoded
    }

    private nonisolated func saveRaw(accounts: [ClaudeAccount], activeAccountID: String?) {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: Self.accountsDefaultsKey)
        }
        if let activeAccountID {
            defaults.set(activeAccountID, forKey: Self.activeAccountDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.activeAccountDefaultsKey)
        }
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
