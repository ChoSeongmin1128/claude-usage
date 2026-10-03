import Foundation

nonisolated struct AntigravityUsageSourceRequest: Sendable {
    let generation: UInt64
    let deadline: AntigravityRPCDeadline
    var refreshAuthentication = false
}

nonisolated enum AntigravityUsageSourcePayload:
    Sendable,
    Equatable
{
    case grouped(AntigravityQuotaSnapshot)
    case limited(AntigravityLimitedQuotaCapability)
    case identityOnly(AntigravityIdentityOnlyUsage)
}

nonisolated struct AntigravityUsageSourceResponse: Sendable, Equatable {
    let payload: AntigravityUsageSourcePayload
}

nonisolated indirect enum AntigravityUsageSourceError:
    Error,
    Sendable,
    Equatable
{
    case unavailable
    case authenticationRequired
    case accountChanged
    case verifiedAccountFailure(ProviderAccountIdentity, AntigravityUsageSourceError)
    case localAuthentication(AntigravityCSRFProblem)
    case interactionRequired
    case deadlineExceeded
    case cancelled
    case malformedResponse
    case transportFailure
    case runtimeUnavailable(AntigravityRuntimeFailure)
    case reportFailed
}

/// Selects one stable user-facing failure when multiple verified local
/// endpoints fail. Array order, process start time, and PID must not determine
/// which recovery action the UI presents.
nonisolated enum AntigravityUsageSourceFailurePolicy {
    static func preferred(
        _ lhs: AntigravityUsageSourceError,
        _ rhs: AntigravityUsageSourceError
    ) -> AntigravityUsageSourceError {
        severity(of: lhs) >= severity(of: rhs) ? lhs : rhs
    }

    private enum Severity: Int, Comparable {
        case unavailable
        case transport
        case deadline
        case schema
        case report
        case runtimePolicy
        case interaction
        case authentication
        case cancellation

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private static func severity(
        of error: AntigravityUsageSourceError
    ) -> Severity {
        switch error {
        case .verifiedAccountFailure(_, let cause):
            severity(of: cause)
        case .unavailable:
            .unavailable
        case .transportFailure:
            .transport
        case .deadlineExceeded:
            .deadline
        case .malformedResponse:
            .schema
        case .reportFailed:
            .report
        case .runtimeUnavailable:
            .runtimePolicy
        case .interactionRequired:
            .interaction
        case .authenticationRequired, .localAuthentication, .accountChanged:
            .authentication
        case .cancelled:
            .cancellation
        }
    }
}

nonisolated protocol AntigravityUsageSource: Sendable {
    var id: AntigravityUsageSourceID { get }

    func fetch(
        _ request: AntigravityUsageSourceRequest
    ) async throws -> AntigravityUsageSourceResponse

    func inspectAccounts(
        _ request: AntigravityUsageSourceRequest
    ) async throws -> AntigravityUsageSourceInspection
}

nonisolated struct AntigravityUsageSourceInspection: Sendable {
    let responses: [AntigravityUsageSourceResponse]
    let hasUnverifiedCandidates: Bool
}

extension AntigravityUsageSource {
    func inspectAccounts(_ request: AntigravityUsageSourceRequest) async throws -> AntigravityUsageSourceInspection {
        AntigravityUsageSourceInspection(responses: [try await fetch(request)], hasUnverifiedCandidates: false)
    }
}
