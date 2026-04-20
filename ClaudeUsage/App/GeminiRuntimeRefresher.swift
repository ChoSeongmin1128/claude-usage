import Foundation

enum GeminiRuntimeRefresher {
    static func refresh(
        apiService: GeminiAPIService
    ) async throws -> GeminiUsageResponse {
        try await apiService.fetchUsageWithRetry()
    }
}
