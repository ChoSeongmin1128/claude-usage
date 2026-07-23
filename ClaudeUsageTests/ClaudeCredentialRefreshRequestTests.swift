import XCTest
@testable import ClaudeUsage

final class ClaudeCredentialRefreshRequestTests: XCTestCase {
    func testStrongerSameAccountRequestSatisfiesWeakerObserverRequest() {
        let active = ClaudeCredentialRefreshRequest(
            accountID: "claude-code-cli",
            refreshOAuthCredentialInventory: true,
            requireUsageValidation: true
        )
        let observer = ClaudeCredentialRefreshRequest(
            accountID: "claude-code-cli",
            refreshOAuthCredentialInventory: false,
            requireUsageValidation: false
        )

        XCTAssertTrue(active.satisfies(observer))
    }

    func testWeakerRequestDoesNotSuppressInventoryRefreshOrValidation() {
        let active = ClaudeCredentialRefreshRequest(
            accountID: "claude-code-cli",
            refreshOAuthCredentialInventory: false,
            requireUsageValidation: false
        )

        XCTAssertFalse(
            active.satisfies(
                ClaudeCredentialRefreshRequest(
                    accountID: "claude-code-cli",
                    refreshOAuthCredentialInventory: true,
                    requireUsageValidation: false
                )
            )
        )
        XCTAssertFalse(
            active.satisfies(
                ClaudeCredentialRefreshRequest(
                    accountID: "claude-code-cli",
                    refreshOAuthCredentialInventory: false,
                    requireUsageValidation: true
                )
            )
        )
    }

    func testRequestNeverCoalescesAcrossAccountBoundary() {
        let active = ClaudeCredentialRefreshRequest(
            accountID: "browser-a",
            refreshOAuthCredentialInventory: true,
            requireUsageValidation: true
        )
        let nextAccount = ClaudeCredentialRefreshRequest(
            accountID: "browser-b",
            refreshOAuthCredentialInventory: false,
            requireUsageValidation: false
        )

        XCTAssertFalse(active.satisfies(nextAccount))
    }

    func testEnteringClaudeCodeAccountRefreshesOAuthInventory() {
        let cli = ClaudeAccount(
            id: ClaudeAccountStore.claudeCodeExternalAccountID,
            kind: .claudeCodeExternal,
            displayName: "Claude Code",
            identity: ClaudeAccountIdentity(),
            source: .claudeCodeCLI,
            sourceDetail: nil,
            preferredOrganizationID: "",
            createdAt: Date(),
            lastUsedAt: Date(),
            lastValidationState: .detected
        )

        XCTAssertTrue(
            ClaudeCredentialRefreshRequest.shouldRefreshOAuthInventory(
                explicitlyRequested: false,
                previousAccountID: "browser-a",
                activeAccount: cli
            )
        )
        XCTAssertFalse(
            ClaudeCredentialRefreshRequest.shouldRefreshOAuthInventory(
                explicitlyRequested: false,
                previousAccountID: cli.id,
                activeAccount: cli
            )
        )
    }

    func testBootstrapDoesNotRefreshOAuthInventoryForBrowserAccount() {
        let browser = ClaudeAccount(
            id: "browser-a",
            kind: .webSession,
            displayName: "Chrome",
            identity: ClaudeAccountIdentity(),
            source: .chromeProfile,
            sourceDetail: nil,
            preferredOrganizationID: "",
            createdAt: Date(),
            lastUsedAt: Date(),
            lastValidationState: .verified
        )

        XCTAssertFalse(
            ClaudeCredentialRefreshRequest.shouldRefreshOAuthInventoryAtBootstrap(
                activeAccount: browser
            )
        )
        XCTAssertFalse(
            ClaudeCredentialRefreshRequest.shouldRefreshOAuthInventoryAtBootstrap(
                activeAccount: nil
            )
        )
    }

    func testBootstrapRefreshesOAuthInventoryForActiveClaudeCodeAccount() {
        let cli = ClaudeAccount(
            id: ClaudeAccountStore.claudeCodeExternalAccountID,
            kind: .claudeCodeExternal,
            displayName: "Claude Code",
            identity: ClaudeAccountIdentity(),
            source: .claudeCodeCLI,
            sourceDetail: nil,
            preferredOrganizationID: "",
            createdAt: Date(),
            lastUsedAt: Date(),
            lastValidationState: .detected
        )

        XCTAssertTrue(
            ClaudeCredentialRefreshRequest.shouldRefreshOAuthInventoryAtBootstrap(
                activeAccount: cli
            )
        )
    }

    func testActiveAccountAttemptsUsageEvenWhenCredentialInventoryIsEmpty() {
        let cli = ClaudeAccount(
            id: ClaudeAccountStore.claudeCodeExternalAccountID,
            kind: .claudeCodeExternal,
            displayName: "Claude Code",
            identity: ClaudeAccountIdentity(),
            source: .claudeCodeCLI,
            sourceDetail: nil,
            preferredOrganizationID: "",
            createdAt: Date(),
            lastUsedAt: Date(),
            lastValidationState: .detected
        )

        XCTAssertTrue(
            ClaudeCredentialRefreshRequest.shouldAttemptUsage(
                activeAccount: cli,
                providerEnabled: true,
                requireUsageValidation: false
            )
        )
        XCTAssertTrue(
            ClaudeCredentialRefreshRequest.shouldAttemptUsage(
                activeAccount: cli,
                providerEnabled: false,
                requireUsageValidation: true
            )
        )
    }

    func testUsageAttemptRequiresActiveAccountAndEnabledOrExplicitValidation() {
        XCTAssertFalse(
            ClaudeCredentialRefreshRequest.shouldAttemptUsage(
                activeAccount: nil,
                providerEnabled: true,
                requireUsageValidation: true
            )
        )

        let browser = ClaudeAccount(
            id: "browser-a",
            kind: .webSession,
            displayName: "Chrome",
            identity: ClaudeAccountIdentity(),
            source: .chromeProfile,
            sourceDetail: nil,
            preferredOrganizationID: "",
            createdAt: Date(),
            lastUsedAt: Date(),
            lastValidationState: .detected
        )
        XCTAssertFalse(
            ClaudeCredentialRefreshRequest.shouldAttemptUsage(
                activeAccount: browser,
                providerEnabled: false,
                requireUsageValidation: false
            )
        )
    }
}
