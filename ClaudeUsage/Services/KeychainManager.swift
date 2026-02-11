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

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "유효하지 않은 데이터"
        }
    }
}

class KeychainManager {
    static let shared = KeychainManager()

    private let key = "claude-session-key"
    private let defaults = UserDefaults.standard

    private init() {}

    func save(_ sessionKey: String) throws {
        guard !sessionKey.isEmpty else {
            throw KeychainError.invalidData
        }
        defaults.set(sessionKey, forKey: key)
        Logger.info("세션 키 저장 완료")
    }

    func load() -> String? {
        defaults.string(forKey: key)
    }

    func delete() throws {
        defaults.removeObject(forKey: key)
    }

    var hasSessionKey: Bool {
        guard let key = load(), !key.isEmpty else { return false }
        return true
    }
}
