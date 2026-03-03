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
    case rateLimited(retryAfter: Int? = nil)
    case cloudflareBlocked(retryAfter: Int? = nil)
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

        case .rateLimited(let retryAfter):
            if let retryAfter, retryAfter > 0 {
                return "요청이 일시 제한되었습니다(HTTP 429). 약 \(Self.formatRetryAfter(retryAfter)) 후 자동 재시도합니다."
            }
            return "요청이 일시 제한되었습니다(HTTP 429). 자동 재시도 중이며 마지막 성공 데이터는 유지됩니다."

        case .cloudflareBlocked(let retryAfter):
            if let retryAfter, retryAfter > 0 {
                return "Cloudflare 보안 검증으로 일시 차단되었습니다. 약 \(Self.formatRetryAfter(retryAfter)) 후 자동 재시도합니다."
            }
            return "Cloudflare 보안 검증으로 일시 차단되었습니다. 자동 재시도 중이며 마지막 성공 데이터는 유지됩니다."

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
        case .rateLimited(_), .cloudflareBlocked(_), .networkError:
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

    private static func formatRetryAfter(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)초"
        }
        let minutes = seconds / 60
        let remain = seconds % 60
        if remain == 0 {
            return "\(minutes)분"
        }
        return "\(minutes)분 \(remain)초"
    }
}
