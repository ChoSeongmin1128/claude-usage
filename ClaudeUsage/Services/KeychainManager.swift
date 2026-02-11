//
//  KeychainManager.swift
//  ClaudeUsage
//
//  Phase 3: Keychain을 통한 세션 키 보안 저장
//

import Foundation
import Security

enum KeychainError: Error, LocalizedError {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "키체인 저장 실패 (코드: \(status))"
        case .loadFailed(let status):
            return "키체인 로드 실패 (코드: \(status))"
        case .deleteFailed(let status):
            return "키체인 삭제 실패 (코드: \(status))"
        case .invalidData:
            return "유효하지 않은 데이터"
        }
    }
}

class KeychainManager {
    static let shared = KeychainManager()

    private let service = "com.seongmin.ClaudeUsage"
    private let account = "claude-session-key"

    private init() {}

    /// 세션 키를 Keychain에 저장
    func save(_ sessionKey: String) throws {
        guard let data = sessionKey.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        // 기존 항목 삭제
        try? delete()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            Logger.error("키체인 저장 실패: \(status)")
            throw KeychainError.saveFailed(status)
        }

        Logger.info("세션 키 키체인 저장 완료")
    }

    /// Keychain에서 세션 키 로드
    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }

        return key
    }

    /// Keychain에서 세션 키 삭제
    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    /// 세션 키가 저장되어 있는지 확인
    var hasSessionKey: Bool {
        load() != nil
    }
}
