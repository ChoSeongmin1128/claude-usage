import Foundation

nonisolated struct AntigravityUsageSourceRequest: Sendable {
    let generation: UInt64
    let managedLaunchAuthorization:
        AntigravityManagedLaunchAuthorization
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
    case managedLaunchDisabled
    case runtimeUnavailable(AntigravityRuntimeFailure)
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
        case managedLaunchPolicy
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
        case .managedLaunchDisabled, .runtimeUnavailable:
            .managedLaunchPolicy
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

    private let discovery:
        any AntigravityManagedRuntimeDiscovering
    private let client: any AntigravityLocalQuotaFetching

    init(
        id: AntigravityUsageSourceID,
        discovery: any AntigravityManagedRuntimeDiscovering,
        client: any AntigravityLocalQuotaFetching
    ) {
        precondition(
            id == .localApp || id == .borrowedCLI,
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
        guard request.managedLaunchAuthorization == .disabled
        else {
            throw AntigravityUsageSourceError.transportFailure
        }

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
                let mapped: AntigravityUsageSourceError
                if error as? AntigravityLocalRPCError == .csrf(.required),
                   endpoint.ownership == .borrowed,
                   endpoint.authentication == .cliTokenless {
                    mapped = .localAuthentication(.unavailable)
                } else {
                    mapped = Self.map(error)
                }
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
        case .borrowedCLI:
            endpoint.transport == .agyCLI
                && endpoint.ownership == .borrowed
        case .managedCLI, .googleOAuth:
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

/// The only source allowed to acquire an owned AGY process. The coordinator
/// passes `.automatic` only after executable trust and managed-runtime recovery
/// have authorized launch for this refresh; every other request fails closed.
nonisolated struct AntigravityManagedCLIUsageSource:
    AntigravityUsageSource,
    Sendable
{
    let id = AntigravityUsageSourceID.managedCLI

    private let session: AntigravityManagedCLISession
    private let executable: AntigravityCanonicalExecutable
    private let client: any AntigravityLocalQuotaFetching

    init(
        session: AntigravityManagedCLISession,
        executable: AntigravityCanonicalExecutable,
        client: any AntigravityLocalQuotaFetching
    ) {
        precondition(executable.role == .agyCLI)
        self.session = session
        self.executable = executable
        self.client = client
    }

    func fetch(
        _ request: AntigravityUsageSourceRequest
    ) async throws -> AntigravityUsageSourceResponse {
        guard case .automatic = request.managedLaunchAuthorization else {
            throw AntigravityUsageSourceError.managedLaunchDisabled
        }

        try checkActive(request)

        // Explicit refresh observes login changes made outside this app. This
        // consumes the same single recreation budget as CSRF recovery.
        if request.refreshAuthentication {
            await session.reset(reason: .userRequested)
            return try await fetchOnce(request)
        }

        do {
            return try await fetchOnce(request)
        } catch AntigravityUsageSourceError.localAuthentication {
            // Only the first rejection is recoverable. The second fetch stays
            // outside this catch, and identity validation remains mandatory in
            // the refresh coordinator for either attempt.
        }

        try checkActive(request)
        await session.reset(reason: .authenticationRequired)
        return try await fetchOnce(request)
    }

    private func checkActive(_ request: AntigravityUsageSourceRequest) throws {
        do {
            try request.deadline.check(.request)
        } catch {
            throw AntigravityDiscoveredLocalUsageSource.map(error)
        }
    }

    private func fetchOnce(
        _ request: AntigravityUsageSourceRequest
    ) async throws -> AntigravityUsageSourceResponse {
        do {
            return try await session.withRuntime(
                authorization:
                    request.managedLaunchAuthorization,
                executable: executable,
                deadline: request.deadline
            ) { runtime in
                let result = try await client.fetch(
                    from: runtime.endpoint,
                    deadline: request.deadline
                )
                return AntigravityDiscoveredLocalUsageSource
                    .response(from: result)
            }
        } catch {
            if error is CancellationError {
                throw AntigravityUsageSourceError.cancelled
            }
            if error is AntigravityRPCDeadlineError {
                throw AntigravityUsageSourceError.deadlineExceeded
            }
            if let error = error as? AntigravityUsageSourceError {
                throw error
            }
            if let error = error as? AntigravityManagedSessionError {
                switch error {
                case .executableNotAllowed, .differentExecutableInUse:
                    throw AntigravityUsageSourceError.runtimeUnavailable(.executableChanged)
                case .launchDisabled:
                    throw AntigravityUsageSourceError
                        .managedLaunchDisabled
                case .cancelled:
                    throw AntigravityUsageSourceError.cancelled
                case .readinessTimedOut:
                    throw AntigravityUsageSourceError.deadlineExceeded
                case .interactionRequired:
                    throw AntigravityUsageSourceError
                        .interactionRequired
                default:
                    throw AntigravityUsageSourceError.transportFailure
                }
            }
            if error is AntigravityLocalRPCError || error is AntigravityLocalRPCAccountBoundaryError {
                throw AntigravityDiscoveredLocalUsageSource.map(
                    error
                )
            }
            throw AntigravityUsageSourceError.transportFailure
        }
    }
}
