//
//  KeychainManager.swift
//  ClaudeUsage
//
//  세션 키 저장 (UserDefaults 기반)
//  개발 중 코드 서명 변경으로 인한 키체인 비밀번호 팝업 방지
//

import Foundation

enum KeychainError: Error, LocalizedError {
    case invalidData

    nonisolated var errorDescription: String? {
        switch self {
        case .invalidData:
            return "유효하지 않은 데이터"
        }
    }
}

final class KeychainManager: @unchecked Sendable {
    nonisolated static let shared = KeychainManager()

    private nonisolated let storageKey = "claude-session-key"

    private init() {}

    nonisolated func save(_ sessionKey: String) throws {
        guard !sessionKey.isEmpty else {
            throw KeychainError.invalidData
        }
        UserDefaults.standard.set(sessionKey, forKey: storageKey)
        Logger.info("세션 키 저장 완료")
    }

    nonisolated func load() -> String? {
        UserDefaults.standard.string(forKey: storageKey)
    }

    nonisolated func delete() throws {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    nonisolated var hasSessionKey: Bool {
        guard let key = load(), !key.isEmpty else { return false }
        return true
    }
}
