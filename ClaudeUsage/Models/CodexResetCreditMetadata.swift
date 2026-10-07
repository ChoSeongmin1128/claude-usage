import Foundation

nonisolated struct CodexHTTPFailure: Error, Sendable {
    let status: Int
    var apiError: APIError { status == 401 || status == 403 ? .invalidSessionKey : .serverError(status) }
}

nonisolated enum CodexResetCreditFailure: Equatable, Sendable {
    case http(Int), timeout, network, invalidResponse

    static func classify(_ error: Error) -> Self {
        if let http = error as? CodexHTTPFailure { return .http(http.status) }
        if let api = error as? APIError {
            switch api {
            case .codexTokenRefreshTemporary: return .timeout
            case .networkError: return .network
            default: return .invalidResponse
            }
        }
        return .invalidResponse
    }

    var diagnosticCode: String {
        switch self {
        case .http(401): return "httpUnauthorized"
        case .http(403): return "httpForbidden"
        case .http: return "httpFailure"
        case .timeout: return "timeout"
        case .network: return "connectionFailed"
        case .invalidResponse: return "invalidResponse"
        }
    }
}

nonisolated struct CodexResetCreditMetadata: Equatable, Sendable {
    enum Status: Equatable, Sendable { case loading, fresh, cached, partial, failed(CodexResetCreditFailure) }
    let status: Status
    var updatedAt: Date? = nil
    var countIsCurrent = true

    var isCurrent: Bool {
        guard countIsCurrent else { return false }
        switch status {
        case .fresh, .cached, .partial: return true;
        case .loading, .failed: return false
        }
    }

    var notice: String? {
        if !countIsCurrent { return "이전 개수 / 상세 확인 필요" }
        switch status {
        case .loading: return updatedAt == nil ? "상세 확인 중" : "이전 정보 / 상세 확인 중"
        case .partial: return "일부 상세 정보 없음"
        case .failed: return updatedAt == nil ? "상세 조회 지연" : "이전 확인 정보"
        case .fresh, .cached: return nil
        }
    }
}
