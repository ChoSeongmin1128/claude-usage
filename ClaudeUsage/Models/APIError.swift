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
    /// refresh_token 이 영구 무효화되어 사용자가 다시 로그인해야 하는 상태.
    /// OAuth 응답에서 `refresh_token_reused`, `invalid_grant` 같은 영구 실패 코드를 받았을 때 사용.
    case codexReauthRequired(reason: String)
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

        case .codexReauthRequired:
            return "Codex 재로그인이 필요합니다. 터미널에서 `codex login` 을 다시 실행하세요."

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
        case .rateLimited(_), .cloudflareBlocked(_), .networkError, .parseError:
            return true
        case .serverError(let code):
            return code >= 500
        case .invalidSessionKey, .codexReauthRequired, .unknownError:
            return false
        }
    }

    nonisolated var isDefinitiveAuthFailure: Bool {
        switch self {
        case .invalidSessionKey, .codexReauthRequired:
            return true
        case .serverError(let code):
            return code == 401 || code == 403
        case .rateLimited, .cloudflareBlocked, .networkError, .parseError, .unknownError:
            return false
        }
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
