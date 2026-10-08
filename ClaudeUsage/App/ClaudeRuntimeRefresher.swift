import Foundation

struct ClaudeRuntimeRefreshSuccess {
    let usage: ClaudeUsageResponse
    let provenance: ClaudeFetchProvenance
    let metadata: RuntimeProviderFetchMetadata
    let supplementalUsage: ClaudeSupplementalRefreshResult
    let sessionContextRevision: Int
    let credentialGeneration: Int?
}

enum ClaudeRuntimeRefresher {
    static func refresh(
        apiService: ClaudeAPIService,
        lastOverageAttemptAt: Date?,
        lastOverageOwnerKey: String? = nil,
        knownIdentities: [String: UsageAccountIdentity] = [:]
    ) async throws -> ClaudeRuntimeRefreshSuccess {
        let contextRevision = await apiService.currentSessionContextRevision()
        let outcome = try await apiService.fetchUsageWithRetryOutcome()
        guard contextRevision == (await apiService.currentSessionContextRevision()) else { throw CancellationError() }
        let metadata = RuntimeProviderFetchMetadata(
            sourceLabel: outcome.provenance.source.displayName, accountID: outcome.provenance.accountID,
            attemptedSourceLabels: outcome.provenance.attemptedSources.map(\.displayName),
            account: ClaudeUsageAccountProvider.runtimeAccount(
                provenance: outcome.provenance, validatedIdentity: outcome.identity,
                resolvedOrganizationID: outcome.identity?.organizationID, knownIdentities: knownIdentities))
        let sameOwner = metadata.supplementalAccountKey != nil && metadata.supplementalAccountKey == lastOverageOwnerKey
        let supplementalUsage = try await ClaudeSupplementalRefreshResult.refresh(
            embeddedUsage: outcome.usage.extraUsage, source: outcome.provenance.source,
            lastAttemptAt: sameOwner ? lastOverageAttemptAt : nil
        ) {
            try await apiService.fetchOverageSpendLimit(
                organizationID: outcome.identity?.organizationID, expectedSessionContextRevision: contextRevision)
        }

        guard contextRevision == (await apiService.currentSessionContextRevision()) else { throw CancellationError() }
        if let generation = outcome.credentialGeneration,
            generation != (await apiService.currentClaudeCodeCredentialGeneration())
        {
            throw CancellationError()
        }
        try Task.checkCancellation()

        return ClaudeRuntimeRefreshSuccess(
            usage: outcome.usage,
            provenance: outcome.provenance,
            metadata: metadata,
            supplementalUsage: supplementalUsage,
            sessionContextRevision: contextRevision, credentialGeneration: outcome.credentialGeneration
        )
    }
}
