//
//  APIError.swift
//  ClaudeUsage
//
//  Phase 1: API 에러 타입 정의
//

import Foundation

/// Claude API 관련 에러
enum APIError: Error, Sendable {
    case invalidSessionKey
    case rateLimited
    case cloudflareBlocked
    case networkError(String)
    case parseError
    case serverError(Int)
    case unknownError(String)
}

// MARK: - LocalizedError

extension APIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidSessionKey:
            return "세션 키가 유효하지 않습니다"

        case .rateLimited:
            return "요청이 너무 많아 일시적으로 제한되었습니다. 잠시 후 자동으로 다시 시도합니다."

        case .cloudflareBlocked:
            return "Cloudflare 보안 검증으로 일시 차단되었습니다. 잠시 후 자동으로 다시 시도합니다."

        case .networkError(let message):
            return "네트워크 연결 실패: \(message)"

        case .parseError:
            return "응답 데이터 파싱 실패"

        case .serverError(let code):
            if code == 401 || code == 403 {
                return "세션 키가 유효하지 않습니다"
            } else if code >= 500 {
                return "서버 오류 (코드: \(code))"
            } else {
                return "요청 실패 (코드: \(code))"
            }

        case .unknownError(let message):
            return "알 수 없는 오류: \(message)"
        }
    }

    nonisolated var isTemporaryFailure: Bool {
        switch self {
        case .rateLimited, .cloudflareBlocked, .networkError:
            return true
        case .serverError(let code):
            return code >= 500
        case .invalidSessionKey, .parseError, .unknownError:
            return false
        }
    }

    nonisolated var isDefinitiveAuthFailure: Bool {
        if case .invalidSessionKey = self {
            return true
        }
        return false
    }
}
