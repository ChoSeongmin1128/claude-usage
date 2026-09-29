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
    /// The AGY usage report finished with a non-success status.
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

nonisolated struct AntigravityDiscoveredLocalUsageSource:
    AntigravityUsageSource,
    Sendable
{
    let id: AntigravityUsageSourceID

    private let discovery: any AntigravityRuntimeDiscovering
    private let client: any AntigravityLocalQuotaFetching

    init(
        id: AntigravityUsageSourceID,
        discovery: any AntigravityRuntimeDiscovering,
        client: any AntigravityLocalQuotaFetching
    ) {
        precondition(
            id == .localApp,
            "Discovered local source must not launch or use OAuth"
        )
        self.id = id
        self.discovery = discovery
        self.client = client
    }

    func fetch(_ request: AntigravityUsageSourceRequest) async throws -> AntigravityUsageSourceResponse {
        let inspection = try await probe(request, collectAll: false)
        guard let response = inspection.responses.first else { throw AntigravityUsageSourceError.unavailable }
        return response
    }

    func inspectAccounts(_ request: AntigravityUsageSourceRequest) async throws -> AntigravityUsageSourceInspection {
        try await probe(request, collectAll: true)
    }

    private func probe(
        _ request: AntigravityUsageSourceRequest, collectAll: Bool
    ) async throws -> AntigravityUsageSourceInspection {
        let snapshot: AntigravityRuntimeDiscoverySnapshot
        do {
            snapshot = try await discovery.discover(
                deadline: request.deadline
            )
        } catch {
            throw Self.map(error)
        }

        let endpoints = snapshot.endpoints
            .filter(matchesSource)
            .sorted(by: Self.endpointOrder)
        guard !endpoints.isEmpty else {
            throw AntigravityUsageSourceError.unavailable
        }

        var responses: [AntigravityUsageSourceResponse] = []
        var hasUnverifiedCandidates = false
        var failedAccount: ProviderAccountIdentity?
        var preferredFailure:
            AntigravityUsageSourceError = .unavailable

        for endpoint in endpoints {
            do {
                let result = try await client.fetch(
                    from: endpoint,
                    deadline: request.deadline
                )
                let response = Self.response(from: result)
                responses.append(response)
                if !collectAll {
                    return AntigravityUsageSourceInspection(responses: [response], hasUnverifiedCandidates: false)
                }
            } catch {
                let mapped = Self.map(error)
                if mapped == .cancelled { throw mapped }
                if case .verifiedAccountFailure(let identity, _) = mapped {
                    if let failedAccount,
                        !AntigravityAccountIdentityMatcher.match(expected: failedAccount, received: identity).isMatch
                    {
                        throw AntigravityUsageSourceError.accountChanged
                    }
                    failedAccount = identity
                }
                hasUnverifiedCandidates = true
                if mapped == .deadlineExceeded {
                    if collectAll, !responses.isEmpty { break }
                    throw mapped
                }
                preferredFailure =
                    AntigravityUsageSourceFailurePolicy.preferred(
                        preferredFailure,
                        mapped
                    )
            }
        }

        if !responses.isEmpty {
            return AntigravityUsageSourceInspection(
                responses: collectAll ? responses : [responses[0]],
                hasUnverifiedCandidates: hasUnverifiedCandidates)
        }
        throw preferredFailure
    }

    private func matchesSource(
        _ endpoint: AntigravityVerifiedRuntimeEndpoint
    ) -> Bool {
        switch id {
        case .localApp:
            endpoint.transport == .antigravityApp
                && endpoint.ownership == .external
        case .cliReport, .googleOAuth:
            false
        }
    }

    private static func endpointOrder(
        _ lhs: AntigravityVerifiedRuntimeEndpoint,
        _ rhs: AntigravityVerifiedRuntimeEndpoint
    ) -> Bool {
        let left = lhs.processIdentity
        let right = rhs.processIdentity
        if left.startedAt != right.startedAt {
            return left.startedAt > right.startedAt
        }
        return left.processID < right.processID
    }

    fileprivate static func response(
        from result: AntigravityLocalQuotaFetchResult
    ) -> AntigravityUsageSourceResponse {
        switch result {
        case .grouped(let snapshot, _):
            AntigravityUsageSourceResponse(
                payload: .grouped(snapshot)
            )
        case .limited(let capability):
            AntigravityUsageSourceResponse(
                payload: .limited(capability)
            )
        }
    }

    private static func observedIdentity(
        in response: AntigravityUsageSourceResponse
    ) -> ProviderAccountIdentity? {
        switch response.payload {
        case .grouped(let snapshot):
            snapshot.provenance.accountIdentity
                ?? snapshot.identity
        case .limited(let capability):
            capability.provenance.accountIdentity
                ?? capability.evidence.identity
        case .identityOnly(let observation):
            observation.identity
        }
    }

    fileprivate static func map(
        _ error: Error
    ) -> AntigravityUsageSourceError {
        if let error = error as? AntigravityLocalRPCAccountBoundaryError {
            switch error {
            case .changedDuringFetch: return .accountChanged
            case .quotaFailed(let identity, let cause): return .verifiedAccountFailure(identity, map(cause))
            }
        }
        if error is CancellationError {
            return .cancelled
        }
        if error is AntigravityRPCDeadlineError {
            return .deadlineExceeded
        }
        guard let error = error as? AntigravityLocalRPCError else {
            return .transportFailure
        }
        switch error {
        case .cancelled:
            return .cancelled
        case .deadlineExceeded:
            return .deadlineExceeded
        case .authenticationRejected:
            return .authenticationRequired
        case .csrf(let problem):
            return .localAuthentication(problem)
        case .malformedPayload:
            return .malformedResponse
        case .invalidEndpoint,
             .endpointOwnershipChanged,
             .tlsRejected,
             .redirectRejected,
             .responseTooLarge,
             .transportFailure,
             .invalidHTTPResponse,
             .unsupportedHTTPStatus,
             .rateLimited,
             .serverRejected,
             .remoteRejected,
             .groupedQuotaUnavailable:
            return .transportFailure
        }
    }
}
