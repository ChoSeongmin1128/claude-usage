import Foundation

enum CodexRuntimeRefresher {
    static func refresh(
        apiService: CodexAPIService
    ) async throws -> CodexUsageResponse {
        _ = await apiService.refreshTokenIfNeeded()
        return try await apiService.fetchUsageWithRetry()
    }
}
