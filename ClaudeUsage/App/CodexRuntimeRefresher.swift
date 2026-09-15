import Foundation

enum CodexRuntimeRefresher {
    static func refresh(
        apiService: CodexAPIService,
        credential: CodexCredentialSnapshot,
        budget: CodexRequestBudget
    ) async throws -> CodexUsageSnapshot {
        try await apiService.fetchUsage(snapshot: credential, budget: budget)
    }
}
