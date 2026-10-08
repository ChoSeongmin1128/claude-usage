import Foundation

/// 성공 payload의 identity/profile이 계정 표시의 기준이다. 기본 CLI slot의 health는 다른 사용자일 수 있다.
struct ClaudeUsageAccountPresentation {
    let identity: ClaudeAccountIdentity
    let sourceAlias: String?

    var label: String? { identity.primaryLabel ?? sourceAlias }
    var compactLabel: String? { identity.email ?? identity.organizationName }

    static func resolve(
        metadata: RuntimeProviderFetchMetadata?, storedAccounts: [ClaudeAccount]
    ) -> Self? {
        guard let metadata, let candidate = metadata.account else { return nil }
        let namespace = candidate.identity.organizationID
        let storedWeb: ClaudeAccount?
        if candidate.source.role == .web, candidate.source.reference == metadata.accountID,
            let namespace, !namespace.isEmpty
        {
            storedWeb = storedAccounts.first {
                $0.kind == .webSession && $0.id == candidate.source.reference
                    && $0.identity.organizationID == namespace
            }
        } else {
            storedWeb = nil
        }
        let profile = metadata.withClaudeProfileMetadata(metadata.claudeProfileMetadata).claudeProfileMetadata
        let identity = ClaudeAccountIdentity(
            email: candidate.identity.email ?? storedWeb?.identity.email,
            organizationName: candidate.identity.organizationName ?? storedWeb?.identity.organizationName,
            organizationID: namespace,
            planLabel: profile?.subscriptionType ?? profile?.rateLimitTier ?? storedWeb?.identity.planLabel)
        return Self(identity: identity, sourceAlias: storedWeb?.displayName)
    }
}
