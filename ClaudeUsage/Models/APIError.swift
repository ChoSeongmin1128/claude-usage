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
    /// Native credentials are unavailable or the owner CLI cannot restore authentication.
    case codexReauthRequired(reason: String)
    /// access token 은 만료됐지만 refresh 서버/네트워크가 일시 실패한 상태.
    /// 마지막 성공 데이터는 유지하고 백오프 후 자동 재시도해야 한다.
    case codexTokenRefreshTemporary(reason: String)
    /// Claude Code 계정이 활성인데 사용할 수 있는 자격 증명(OAuth 토큰/세션키)이 없는 상태.
    /// 에러 카드 대신 "Claude Code 로그인 확인 또는 Claude.ai 로그인 전환" 안내 카드로 처리된다.
    case claudeCodeCredentialUnavailable
    /// Claude Code credential 파일은 존재하지만 회전형 refresh token이 서버에서
    /// 거부되어 자동 복구할 수 없는 상태.
    case claudeCodeReauthenticationRequired
    /// Claude Code 로그인 자체를 다시 요구할 근거는 없지만, 앱이 보유한 CLI
    /// credential mirror를 명시적으로 다시 가져와야 하는 상태.
    case claudeCodeReconnectRequired
    case rateLimited(retryAfter: Int? = nil)
    case cloudflareBlocked(retryAfter: Int? = nil)
    case networkError(String)
    case permissionDenied(String)
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

        case .codexReauthRequired(let reason):
            if reason == "owner_cli_unavailable" {
                return "Codex CLI를 찾지 못해 로그인을 갱신할 수 없습니다. CLI 설치와 로그인 상태를 확인해 주세요."
            }
            if reason == "account_identity_unavailable" || reason == "credential_unavailable" {
                return "Codex 로그인 정보를 확인할 수 없습니다. CLI에서 로그인 상태를 확인한 뒤 새로고침해 주세요."
            }
            return "Codex 재로그인이 필요합니다. 터미널에서 `codex login` 을 다시 실행하세요."

        case .codexTokenRefreshTemporary(let reason):
            if reason == "credential_changed" || reason == "owner_recovery_exhausted" {
                return "조회 중 Codex 로그인이 변경됐습니다. 새로고침으로 현재 계정을 확인해 주세요."
            }
            if reason == "owner_refresh_failed" {
                return "Codex CLI의 로그인 갱신을 확인하지 못했습니다. CLI 상태를 확인한 뒤 다시 시도해 주세요."
            }
            if reason == "request_timed_out" {
                return "Codex 조회 시간이 초과됐습니다. 잠시 후 다시 시도해 주세요."
            }
            return reason.isEmpty
                ? "Codex 토큰 갱신에 일시 실패했습니다. 마지막 성공 데이터는 유지됩니다."
                : "Codex 토큰 갱신에 일시 실패했습니다: \(reason)"

        case .claudeCodeCredentialUnavailable:
            return "Claude Code 자격 증명을 찾을 수 없습니다. 터미널에서 `claude auth login`을 실행해 주세요."

        case .claudeCodeReauthenticationRequired:
            return "Claude Code 로그인 정보는 있지만 인증 갱신이 거부되었습니다. 터미널에서 `claude auth login`을 다시 실행해 주세요."

        case .claudeCodeReconnectRequired:
            return "Claude Code 로그인은 유지되고 있지만 ClaudeUsage 연결 정보를 다시 확인해야 합니다."

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

        case .permissionDenied(let message):
            return message.isEmpty ? "요청 권한이 없습니다" : "요청 권한이 없습니다: \(message)"

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
        case .rateLimited(_), .cloudflareBlocked(_), .codexTokenRefreshTemporary, .networkError, .parseError:
            return true
        case .serverError(let code):
            return code >= 500
        case .invalidSessionKey, .codexReauthRequired, .claudeCodeCredentialUnavailable, .claudeCodeReauthenticationRequired, .claudeCodeReconnectRequired, .permissionDenied, .unknownError:
            return false
        }
    }

    nonisolated var isDefinitiveAuthFailure: Bool {
        switch self {
        case .invalidSessionKey, .codexReauthRequired, .claudeCodeCredentialUnavailable, .claudeCodeReauthenticationRequired, .claudeCodeReconnectRequired:
            return true
        case .serverError(let code):
            return code == 401 || code == 403
        case .rateLimited, .cloudflareBlocked, .codexTokenRefreshTemporary, .networkError, .permissionDenied, .parseError, .unknownError:
            return false
        }
    }

    nonisolated var isPermissionDenied: Bool {
        if case .permissionDenied = self {
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
