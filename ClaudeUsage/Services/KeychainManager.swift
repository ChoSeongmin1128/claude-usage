//
//  KeychainManager.swift
//  ClaudeUsage
//
//  세션 키 저장 (Keychain 기반)
//  기존 UserDefaults 저장값은 최초 로드 시 Keychain으로 마이그레이션
//

import Foundation

extension Notification.Name {
    nonisolated static let claudeSessionKeyDidChange = Notification.Name("claudeSessionKeyDidChange")
    nonisolated static let claudeAccountDidChange = Notification.Name("claudeAccountDidChange")
    nonisolated static let claudeAccountsDidChange = Notification.Name("claudeAccountsDidChange")
    nonisolated static let claudeCredentialRefreshRequested = Notification.Name("claudeCredentialRefreshRequested")
    nonisolated static let claudeUsageHealthSnapshotDidChange = Notification.Name("claudeUsageHealthSnapshotDidChange")
}

enum KeychainError: Error, LocalizedError {
    case invalidData
    case storageFailed(String)

    nonisolated var errorDescription: String? {
        switch self {
        case .invalidData:
            return "유효하지 않은 데이터"
        case .storageFailed(let message):
            return message
        }
    }
}

nonisolated final class KeychainManager: @unchecked Sendable {
    nonisolated static let shared = KeychainManager()

    private nonisolated let storageKey = "claude-session-key"
    private let keychainStore = ClaudeKeychainStore.shared
    private let cacheLock = NSLock()
    private var cachedSessionKeys: [String: String] = [:]

    private init() {}

    nonisolated func save(_ sessionKey: String) throws {
        try save(sessionKey, preferredOrganizationID: nil)
    }

    nonisolated func save(_ sessionKey: String, preferredOrganizationID: String?) throws {
        try save(sessionKey, preferredOrganizationID: preferredOrganizationID, displayName: nil)
    }

    nonisolated func save(_ sessionKey: String, preferredOrganizationID: String?, displayName: String?) throws {
        try save(
            sessionKey,
            preferredOrganizationID: preferredOrganizationID,
            displayName: displayName,
            source: .embeddedWebLogin,
            sourceDetail: nil
        )
    }

    nonisolated func save(
        _ sessionKey: String,
        preferredOrganizationID: String?,
        displayName: String?,
        source: ClaudeAccountSource?,
        sourceDetail: String?
    ) throws {
        try save(
            sessionKey,
            preferredOrganizationID: preferredOrganizationID,
            displayName: displayName,
            identity: nil,
            source: source,
            sourceDetail: sourceDetail
        )
    }

    nonisolated func save(
        _ sessionKey: String,
        preferredOrganizationID: String?,
        displayName: String?,
        identity: ClaudeAccountIdentity?,
        source: ClaudeAccountSource?,
        sourceDetail: String?
    ) throws {
        guard !sessionKey.isEmpty else {
            throw KeychainError.invalidData
        }
        let accountID = ClaudeAccountStore.webSessionAccountID(
            fingerprint: ClaudeAccountStore.fingerprint(for: sessionKey)
        )
        let credentialChanged = try save(sessionKey, for: accountID, postsNotification: false)
        let upsertResult = ClaudeAccountStore.shared.upsertWebSessionAccountReplacingRotatedChromeSession(
            sessionKey: sessionKey,
            preferredOrganizationID: preferredOrganizationID,
            identity: identity ?? ClaudeAccountIdentity(),
            displayName: displayName,
            source: source,
            sourceDetail: sourceDetail,
            lastValidationState: .verified,
            setActive: true
        )
        for supersededAccountID in upsertResult.supersededAccountIDs {
            do {
                try delete(for: supersededAccountID, postsNotification: false)
            } catch {
                Logger.warning("교체된 Chrome credential 정리 실패")
            }
        }
        if credentialChanged || !upsertResult.supersededAccountIDs.isEmpty {
            NotificationCenter.default.post(name: .claudeSessionKeyDidChange, object: accountID)
        }
        UserDefaults.standard.removeObject(forKey: self.storageKey)
        Logger.info("세션 키 저장 완료")
    }

    @discardableResult
    nonisolated func save(
        _ sessionKey: String,
        for accountID: String,
        postsNotification: Bool = true
    ) throws -> Bool {
        guard !sessionKey.isEmpty else {
            throw KeychainError.invalidData
        }
        let scopedAccount = ClaudeKeychainStore.accountName(for: accountID)
        // 계정을 지우면 저장소의 항목만 사라지고 이 캐시는 남는다. 캐시가 아니라 저장소 값과 비교해야
        // 같은 키를 다시 추가할 때 저장을 건너뛰지 않는다.
        if (try? self.keychainStore.loadString(account: scopedAccount)) == sessionKey {
            self.setCachedSessionKey(sessionKey, for: accountID)
            Logger.debug("세션 키 저장 스킵: 같은 값이 이미 저장돼 있음")
            return false
        }
        do {
            try self.keychainStore.saveString(sessionKey, account: scopedAccount)
        } catch {
            throw KeychainError.storageFailed(error.localizedDescription)
        }
        self.setCachedSessionKey(sessionKey, for: accountID)
        if postsNotification {
            NotificationCenter.default.post(name: .claudeSessionKeyDidChange, object: accountID)
        }
        return true
    }

    nonisolated func load() -> String? {
        guard let account = ClaudeAccountStore.shared.activeWebAccount() else {
            return loadLegacySessionKeyIfNeeded()
        }
        return load(for: account.id)
    }

    nonisolated func load(for accountID: String) -> String? {
        if let cached = self.cachedSessionKeyValue(for: accountID), !cached.isEmpty {
            return cached
        }

        let scopedAccount = ClaudeKeychainStore.accountName(for: accountID)
        if let existing = try? self.keychainStore.loadString(account: scopedAccount) {
            if !existing.isEmpty {
                self.setCachedSessionKey(existing, for: accountID)
                return existing
            }
        }

        return nil
    }

    private nonisolated func loadLegacySessionKeyIfNeeded() -> String? {
        guard let legacy = UserDefaults.standard.string(forKey: self.storageKey),
              !legacy.isEmpty else {
            return nil
        }

        do {
            try self.keychainStore.saveString(legacy)
            UserDefaults.standard.removeObject(forKey: self.storageKey)
            Logger.info("레거시 세션 키를 Keychain으로 마이그레이션 완료")
            return legacy
        } catch {
            Logger.warning("레거시 세션 키 마이그레이션 실패: \(error.localizedDescription)")
            return legacy
        }
    }

    nonisolated func delete() throws {
        if let account = ClaudeAccountStore.shared.activeWebAccount() {
            try delete(for: account.id, postsNotification: false)
            ClaudeAccountStore.shared.deleteAccount(id: account.id)
            return
        }

        do {
            try self.keychainStore.delete()
        } catch {
            throw KeychainError.storageFailed(error.localizedDescription)
        }
        self.clearCachedSessionKeys()
        UserDefaults.standard.removeObject(forKey: self.storageKey)
        NotificationCenter.default.post(name: .claudeSessionKeyDidChange, object: nil)
    }

    nonisolated func delete(for accountID: String, postsNotification: Bool = true) throws {
        do {
            try self.keychainStore.delete(account: ClaudeKeychainStore.accountName(for: accountID))
        } catch {
            throw KeychainError.storageFailed(error.localizedDescription)
        }
        self.setCachedSessionKey(nil, for: accountID)
        if postsNotification {
            NotificationCenter.default.post(name: .claudeSessionKeyDidChange, object: accountID)
        }
    }

    nonisolated var hasSessionKey: Bool {
        guard let key = load(), !key.isEmpty else { return false }
        return true
    }

    private nonisolated func cachedSessionKeyValue(for accountID: String) -> String? {
        self.cacheLock.lock()
        defer { self.cacheLock.unlock() }
        return self.cachedSessionKeys[accountID]
    }

    private nonisolated func setCachedSessionKey(_ value: String?, for accountID: String) {
        self.cacheLock.lock()
        if let value {
            self.cachedSessionKeys[accountID] = value
        } else {
            self.cachedSessionKeys.removeValue(forKey: accountID)
        }
        self.cacheLock.unlock()
    }

    private nonisolated func clearCachedSessionKeys() {
        self.cacheLock.lock()
        self.cachedSessionKeys.removeAll()
        self.cacheLock.unlock()
    }
}
