import Foundation

enum AntigravityRuntimeRefresher {
    static func refresh(
        apiService: AntigravityAPIService
    ) async throws -> AntigravityUsageResponse {
        try await apiService.fetchUsageWithRetry()
    }
}
