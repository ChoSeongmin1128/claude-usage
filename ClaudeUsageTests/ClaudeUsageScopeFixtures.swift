import Foundation
@testable import ClaudeUsage

nonisolated func fixtureClaudeMetadata(accountID: String, organizationID: String = "org")
    -> RuntimeProviderFetchMetadata
{
    RuntimeProviderFetchMetadata(
        sourceLabel: "브라우저 로그인", accountID: accountID,
        account: .init(source: .init(role: .web, reference: accountID), identity: .init(organizationID: organizationID))
    )
}
