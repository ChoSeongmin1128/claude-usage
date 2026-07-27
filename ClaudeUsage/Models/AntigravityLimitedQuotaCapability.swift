import Foundation

nonisolated struct AntigravityGoogleOAuthLimitedQuotaEvidence:
    Sendable,
    Equatable
{
    let identity: ProviderAccountIdentity?
    let plan: String?
    let modelQuotaCount: Int
}

/// Source-specific evidence remains typed, while consumers use the common
/// identity/plan/count projection without inventing a local RPC method for an
/// OAuth response.
nonisolated enum AntigravityLimitedQuotaEvidence:
    Sendable,
    Equatable
{
    case localLegacy(AntigravityLegacyCapabilityEvidence)
    case googleOAuth(
        AntigravityGoogleOAuthLimitedQuotaEvidence
    )

    var identity: ProviderAccountIdentity? {
        switch self {
        case .localLegacy(let evidence):
            evidence.identity
        case .googleOAuth(let evidence):
            evidence.identity
        }
    }

    var plan: String? {
        switch self {
        case .localLegacy(let evidence):
            evidence.plan
        case .googleOAuth(let evidence):
            evidence.plan
        }
    }

    var modelCount: Int {
        switch self {
        case .localLegacy(let evidence):
            evidence.modelConfigCount
        case .googleOAuth(let evidence):
            evidence.modelQuotaCount
        }
    }
}

nonisolated enum AntigravityGoogleOAuthLimitedQuotaReason:
    Sendable,
    Equatable
{
    case modelQuotaOnly
}

nonisolated enum AntigravityLimitedQuotaReason:
    Sendable,
    Equatable
{
    case localLegacy(AntigravityLegacyFallbackReason)
    case googleOAuth(
        AntigravityGoogleOAuthLimitedQuotaReason
    )
}

nonisolated struct AntigravityLimitedQuotaCapability:
    Sendable,
    Equatable
{
    let evidence: AntigravityLimitedQuotaEvidence
    let reason: AntigravityLimitedQuotaReason
    let provenance: AntigravityQuotaProvenance
    let fetchedAt: Date

    private init(
        evidence: AntigravityLimitedQuotaEvidence,
        reason: AntigravityLimitedQuotaReason,
        provenance: AntigravityQuotaProvenance,
        fetchedAt: Date
    ) {
        self.evidence = evidence
        self.reason = reason
        self.provenance = provenance
        self.fetchedAt = fetchedAt
    }

    static func localLegacy(
        evidence: AntigravityLegacyCapabilityEvidence,
        fallbackReason: AntigravityLegacyFallbackReason,
        provenance: AntigravityQuotaProvenance,
        fetchedAt: Date
    ) -> Self {
        Self(
            evidence: .localLegacy(evidence),
            reason: .localLegacy(fallbackReason),
            provenance: provenance,
            fetchedAt: fetchedAt
        )
    }

    static func googleOAuth(
        evidence:
            AntigravityGoogleOAuthLimitedQuotaEvidence,
        reason:
            AntigravityGoogleOAuthLimitedQuotaReason =
                .modelQuotaOnly,
        provenance: AntigravityQuotaProvenance,
        fetchedAt: Date
    ) -> Self {
        Self(
            evidence: .googleOAuth(evidence),
            reason: .googleOAuth(reason),
            provenance: provenance,
            fetchedAt: fetchedAt
        )
    }
}
