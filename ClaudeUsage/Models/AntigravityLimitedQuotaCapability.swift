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

// 2.9.0까지의 독립 앱 RPC가 남긴 기록을 읽기 위한 형식만 남긴다.
nonisolated enum AntigravityLocalRPCMethod:
    String,
    CaseIterable,
    Sendable
{
    case retrieveUserQuotaSummary = "RetrieveUserQuotaSummary"
    case getUserStatus = "GetUserStatus"
    case getCommandModelConfigs = "GetCommandModelConfigs"

    private static let servicePath =
        "/exa.language_server_pb.LanguageServerService/"

    var path: String {
        Self.servicePath + rawValue
    }

    /// Deterministic request bytes keep the undocumented local contract narrow.
    /// No caller may supply an arbitrary RPC method or body.
    var requestBody: Data {
        switch self {
        case .retrieveUserQuotaSummary:
            return Data(#"{"forceRefresh":true}"#.utf8)
        case .getUserStatus, .getCommandModelConfigs:
            return Data(
                #"{"metadata":{"extensionName":"antigravity","ideName":"antigravity","ideVersion":"unknown","locale":"en"}}"#
                    .utf8
            )
        }
    }
}

nonisolated enum AntigravityLegacyFallbackReason:
    Equatable,
    Sendable
{
    case unsupportedHTTPStatus(Int)
    case connectUnimplemented
    case groupedQuotaUnavailable
}

nonisolated struct AntigravityLegacyCapabilityEvidence:
    Equatable,
    Sendable
{
    let method: AntigravityLocalRPCMethod
    let identity: ProviderAccountIdentity?
    let plan: String?
    let modelConfigCount: Int
}
