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

    /// 활성 계정이 있으면 credential inventory가 비어 있어도 실제 fetch를 한 번
    /// 실행해야 한다. 그래야 "없음", "만료", "refresh 거부"를 동일한 로그인
    /// 필요 상태로 축약하지 않고 APIError의 정확한 복구 안내를 UI에 남길 수 있다.
    static func shouldAttemptUsage(
        activeAccount: ClaudeAccount?,
        providerEnabled: Bool,
        requireUsageValidation: Bool
    ) -> Bool {
        activeAccount != nil && (providerEnabled || requireUsageValidation)
    }
}
