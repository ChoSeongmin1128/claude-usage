//
//  KeychainManager.swift
//  ClaudeUsage
//
//  세션 키 저장 (Keychain 기반)
//  기존 UserDefaults 저장값은 최초 로드 시 Keychain으로 마이그레이션
//

import Foundation

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

    private init() {}

    nonisolated func save(_ sessionKey: String) throws {
        guard !sessionKey.isEmpty else {
            throw KeychainError.invalidData
        }
        do {
            try self.keychainStore.saveString(sessionKey)
        } catch {
            throw KeychainError.storageFailed(error.localizedDescription)
        }
        UserDefaults.standard.removeObject(forKey: self.storageKey)
        Logger.info("세션 키 저장 완료")
    }

    nonisolated func load() -> String? {
        if let existing = try? self.keychainStore.loadString() {
            if !existing.isEmpty {
                return existing
            }
        }

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
        do {
            try self.keychainStore.delete()
        } catch {
            throw KeychainError.storageFailed(error.localizedDescription)
        }
        UserDefaults.standard.removeObject(forKey: self.storageKey)
    }

    nonisolated var hasSessionKey: Bool {
        guard let key = load(), !key.isEmpty else { return false }
        return true
    }
}
