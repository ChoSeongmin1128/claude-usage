import Foundation

struct ClaudeCredentialRefreshRequest: Equatable, Sendable {
    let accountID: String?
    let refreshOAuthCredentialInventory: Bool
    let requireUsageValidation: Bool

    func satisfies(_ request: ClaudeCredentialRefreshRequest) -> Bool {
        guard accountID == request.accountID else { return false }
        if request.refreshOAuthCredentialInventory && !refreshOAuthCredentialInventory {
            return false
        }
        if request.requireUsageValidation && !requireUsageValidation {
            return false
        }
        return true
    }

    static func shouldRefreshOAuthInventory(
        explicitlyRequested: Bool,
        previousAccountID: String?,
        activeAccount: ClaudeAccount?
    ) -> Bool {
        explicitlyRequested
            || (
                previousAccountID != activeAccount?.id
                    && activeAccount?.kind == .claudeCodeExternal
            )
    }

    static func shouldRefreshOAuthInventoryAtBootstrap(
        activeAccount: ClaudeAccount?
    ) -> Bool {
        activeAccount?.kind == .claudeCodeExternal
    }
}
