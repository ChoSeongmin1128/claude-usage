import XCTest
@testable import ClaudeUsage

@MainActor
final class CodexLiveNativeIntegrationTests: XCTestCase {
    func testCurrentNativeAccountReturnsAuthenticatedQuota() async throws {
        guard ProcessInfo.processInfo.environment["CLAUDEUSAGE_RUN_LIVE_CODEX_TESTS"] == "1" else {
            throw XCTSkip("Requires an explicitly enabled, signed-in official Codex CLI")
        }
        let manager = CodexAuthManager(authJsonPath: CodexAuthManager.defaultAuthJsonPath())
        let initial = try await manager.loadSnapshot()
        let initialAccount = try XCTUnwrap(initial.token.accountID)
        try await CodexOwnerCLI().refresh(
            sourceURL: initial.sourceURL, expectedAccountID: initialAccount, budget: CodexRequestBudget()
        )
        let service = CodexAPIService(authManager: manager)
        let result = try await service.fetchUsage()
        let expectedAccount = try XCTUnwrap(result.credential.token.accountID)
        XCTAssertFalse(expectedAccount.isEmpty)
        XCTAssertTrue(
            result.usage.accountID == expectedAccount && expectedAccount == initialAccount, "identity_mismatch")
        let windows = [result.usage.rateLimit?.primaryWindow, result.usage.rateLimit?.secondaryWindow].compactMap { $0 }
        XCTAssertFalse(windows.isEmpty)
        XCTAssertTrue(windows.allSatisfy { $0.usedPercent.isFinite && $0.limitWindowSeconds != nil })
        try await manager.validate(result.credential)
        await service.shutdown()
    }
}
