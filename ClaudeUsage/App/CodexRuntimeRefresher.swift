import Foundation

enum CodexRuntimeRefresher {
    static func refresh(
        apiService: CodexAPIService
    ) async throws -> CodexUsageResponse {
        // permanent refresh 실패는 곧바로 throw → UI 가 "Codex 재로그인 필요" 안내 분기
        _ = try await apiService.refreshTokenIfNeeded()
        return try await apiService.fetchUsageWithRetry()
    }
}
