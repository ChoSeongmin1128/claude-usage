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

final class KeychainManager: @unchecked Sendable {
    nonisolated static let shared = KeychainManager()

    private nonisolated let storageKey = "claude-session-key"
    private let keychainStore = ClaudeKeychainStore.shared
    private let cacheLock = NSLock()
    private nonisolated(unsafe) var cachedSessionKey: String?

    private init() {}

    nonisolated func save(_ sessionKey: String) throws {
        guard !sessionKey.isEmpty else {
            throw KeychainError.invalidData
        }
        if self.cachedSessionKeyValue() == sessionKey {
            Logger.debug("세션 키 저장 스킵: 동일한 값이 이미 캐시에 있음")
            return
        }
        do {
            try self.keychainStore.saveString(sessionKey)
        } catch {
            throw KeychainError.storageFailed(error.localizedDescription)
        }
        self.setCachedSessionKey(sessionKey)
        UserDefaults.standard.removeObject(forKey: self.storageKey)
        NotificationCenter.default.post(name: .claudeSessionKeyDidChange, object: nil)
        Logger.info("세션 키 저장 완료")
    }

    nonisolated func load() -> String? {
        if let cached = self.cachedSessionKeyValue(), !cached.isEmpty {
            return cached
        }

        if let existing = try? self.keychainStore.loadString() {
            if !existing.isEmpty {
                self.setCachedSessionKey(existing)
                return existing
            }
        }

        guard let legacy = UserDefaults.standard.string(forKey: self.storageKey),
              !legacy.isEmpty else {
            return nil
        }

        do {
            try self.keychainStore.saveString(legacy)
            self.setCachedSessionKey(legacy)
            UserDefaults.standard.removeObject(forKey: self.storageKey)
            Logger.info("레거시 세션 키를 Keychain으로 마이그레이션 완료")
            return legacy
        } catch {
            Logger.warning("레거시 세션 키 마이그레이션 실패: \(error.localizedDescription)")
            return legacy
        }
    }

    nonisolated func delete() throws {
        do {
            try self.keychainStore.delete()
        } catch {
            throw KeychainError.storageFailed(error.localizedDescription)
        }
        self.setCachedSessionKey(nil)
        UserDefaults.standard.removeObject(forKey: self.storageKey)
        NotificationCenter.default.post(name: .claudeSessionKeyDidChange, object: nil)
    }

    nonisolated var hasSessionKey: Bool {
        guard let key = load(), !key.isEmpty else { return false }
        return true
    }

    private nonisolated func cachedSessionKeyValue() -> String? {
        self.cacheLock.lock()
        defer { self.cacheLock.unlock() }
        return self.cachedSessionKey
    }

    private nonisolated func setCachedSessionKey(_ value: String?) {
        self.cacheLock.lock()
        self.cachedSessionKey = value
        self.cacheLock.unlock()
    }
}
