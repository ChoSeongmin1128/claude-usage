import Foundation

nonisolated struct AntigravityLocalIdentityIssue:
    Sendable,
    Equatable
{
    let error: AntigravityLocalRPCError
}

nonisolated enum AntigravityLocalQuotaFetchResult:
    Sendable,
    Equatable
{
    case grouped(
        snapshot: AntigravityQuotaSnapshot,
        identityIssue: AntigravityLocalIdentityIssue?
    )
    case limited(AntigravityLimitedQuotaCapability)
}

nonisolated protocol AntigravityLocalQuotaFetching: Sendable {
    func fetch(
        from endpoint: AntigravityVerifiedRuntimeEndpoint,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityLocalQuotaFetchResult
}

/// Executes the local RPC contract without selecting a source or persisting
/// account state. Source policy, account matching, and migration remain the
/// refresh coordinator's responsibility.
nonisolated struct AntigravityLocalRPCClient:
    AntigravityLocalQuotaFetching,
    Sendable
{
    private let connectionFactory:
        any AntigravityLocalRPCConnectionFactory
    private let now: @Sendable () -> Date

    init(
        connectionFactory:
            any AntigravityLocalRPCConnectionFactory,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.connectionFactory = connectionFactory
        self.now = now
    }

    func fetch(
        from endpoint: AntigravityVerifiedRuntimeEndpoint,
        deadline: AntigravityRPCDeadline = AntigravityRPCDeadline()
    ) async throws -> AntigravityLocalQuotaFetchResult {
        let connection = try connectionFactory.makeConnection(
            endpoint: endpoint
        )
        defer { connection.invalidate() }

        do {
            let summary = try await groupedQuota(
                connection: connection,
                deadline: deadline
            )
            let identityResult = try await identity(
                connection: connection,
                parentDeadline: deadline
            )
            let fetchedAt = now()
            let provenance = provenance(
                for: endpoint,
                capability: .groupedQuotaSummary,
                accountIdentity: identityResult.identity?.identity
            )
            let snapshot = AntigravityQuotaSnapshot(
                identity: identityResult.identity?.identity,
                plan: identityResult.identity?.plan,
                lanes: summary.lanes,
                decodeIssues: summary.decodeIssues,
                provenance: provenance,
                fetchedAt: fetchedAt
            )
            return .grouped(
                snapshot: snapshot,
                identityIssue: identityResult.issue
            )
        } catch let error as AntigravityLocalRPCError {
            guard let fallbackReason =
                    AntigravityLegacyFallbackPolicy.reason(for: error)
            else {
                throw error
            }
            return try await limitedCapability(
                connection: connection,
                endpoint: endpoint,
                deadline: deadline,
                fallbackReason: fallbackReason
            )
        } catch is CancellationError {
            throw AntigravityLocalRPCError.cancelled
        } catch is AntigravityRPCDeadlineError {
            throw AntigravityLocalRPCError.deadlineExceeded
        } catch {
            throw AntigravityLocalRPCError.transportFailure
        }
    }

    private func groupedQuota(
        connection: any AntigravityLocalRPCConnection,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityDecodedQuotaSummary {
        let response = try await connection.perform(
            .retrieveUserQuotaSummary,
            deadline: deadline
        )
        try AntigravityLocalRPCResponseValidator.validate(response)

        do {
            return try AntigravityQuotaSummaryDecoder.decode(response.body)
        } catch AntigravityQuotaSummaryDecoderError.missingQuotaGroups {
            throw AntigravityLocalRPCError.groupedQuotaUnavailable
        } catch AntigravityQuotaSummaryDecoderError.noIdentifiableQuotaLanes {
            throw AntigravityLocalRPCError.groupedQuotaUnavailable
        } catch AntigravityQuotaSummaryDecoderError.invalidJSON {
            throw AntigravityLocalRPCError.malformedPayload
        } catch {
            throw AntigravityLocalRPCError.malformedPayload
        }
    }

    private func identity(
        connection: any AntigravityLocalRPCConnection,
        parentDeadline: AntigravityRPCDeadline
    ) async throws -> (
        identity: AntigravityLocalAccountIdentity?,
        issue: AntigravityLocalIdentityIssue?
    ) {
        let remaining = parentDeadline.remaining
        guard remaining > .zero else {
            throw AntigravityLocalRPCError.deadlineExceeded
        }
        let identityDeadline = AntigravityRPCDeadline(
            totalTimeout: min(.seconds(1), remaining),
            discoveryTimeout: .zero
        )

        do {
            let response = try await connection.perform(
                .getUserStatus,
                deadline: identityDeadline
            )
            try AntigravityLocalRPCResponseValidator.validate(response)
            return (
                try AntigravityLocalIdentityDecoder.decode(response.body),
                nil
            )
        } catch let error as AntigravityLocalRPCError {
            if error == .deadlineExceeded {
                do {
                    try parentDeadline.check(.request)
                } catch is CancellationError {
                    throw AntigravityLocalRPCError.cancelled
                } catch is AntigravityRPCDeadlineError {
                    throw AntigravityLocalRPCError.deadlineExceeded
                }
                // The one-second identity budget is deliberately best-effort.
                // A healthy grouped quota response must survive an identity
                // endpoint that is merely slow while the parent transaction
                // still has time remaining.
                return (
                    nil,
                    AntigravityLocalIdentityIssue(error: .deadlineExceeded)
                )
            }
            if Self.isFatalIdentityError(error) {
                throw error
            }
            return (nil, AntigravityLocalIdentityIssue(error: error))
        } catch is CancellationError {
            throw AntigravityLocalRPCError.cancelled
        } catch is AntigravityRPCDeadlineError {
            throw AntigravityLocalRPCError.deadlineExceeded
        } catch {
            return (
                nil,
                AntigravityLocalIdentityIssue(error: .malformedPayload)
            )
        }
    }

    private func limitedCapability(
        connection: any AntigravityLocalRPCConnection,
        endpoint: AntigravityVerifiedRuntimeEndpoint,
        deadline: AntigravityRPCDeadline,
        fallbackReason: AntigravityLegacyFallbackReason
    ) async throws -> AntigravityLocalQuotaFetchResult {
        let evidence: AntigravityLegacyCapabilityEvidence
        do {
            evidence = try await capabilityEvidence(
                method: .getUserStatus,
                connection: connection,
                deadline: deadline
            )
        } catch let error as AntigravityLocalRPCError {
            guard AntigravityLegacyFallbackPolicy.reason(for: error) != nil
            else {
                throw error
            }
            evidence = try await capabilityEvidence(
                method: .getCommandModelConfigs,
                connection: connection,
                deadline: deadline
            )
        }

        let provenance = provenance(
            for: endpoint,
            capability: .limitedQuota,
            accountIdentity: evidence.identity
        )
        return .limited(.localLegacy(
            evidence: evidence,
            fallbackReason: fallbackReason,
            provenance: provenance,
            fetchedAt: now()
        ))
    }

    private func capabilityEvidence(
        method: AntigravityLocalRPCMethod,
        connection: any AntigravityLocalRPCConnection,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityLegacyCapabilityEvidence {
        let response = try await connection.perform(
            method,
            deadline: deadline
        )
        try AntigravityLocalRPCResponseValidator.validate(response)
        return try AntigravityLegacyCapabilityDecoder.decode(
            response.body,
            method: method
        )
    }

    private func provenance(
        for endpoint: AntigravityVerifiedRuntimeEndpoint,
        capability: AntigravityQuotaProvenance.Capability,
        accountIdentity: ProviderAccountIdentity?
    ) -> AntigravityQuotaProvenance {
        let transport: AntigravityQuotaProvenance.Transport
        switch (endpoint.transport, endpoint.ownership) {
        case (.antigravityApp, .external):
            transport = .localAppRPC
        case (.agyCLI, .borrowed):
            transport = .borrowedAGYRPC
        case (.agyCLI, .managed):
            transport = .managedAGYRPC
        default:
            // The verified endpoint initializer already excludes this state.
            preconditionFailure("Invalid verified endpoint ownership")
        }

        let endpointOwner: AntigravityQuotaProvenance.EndpointOwner
        switch endpoint.ownership {
        case .external:
            endpointOwner = .external
        case .borrowed:
            endpointOwner = .borrowed
        case .managed:
            endpointOwner = .managed
        case .quarantined:
            preconditionFailure(
                "Quarantined runtime cannot become an endpoint"
            )
        }

        let startedAt = Date(
            timeIntervalSince1970:
                TimeInterval(endpoint.processIdentity.startedAt.seconds)
                + TimeInterval(
                    endpoint.processIdentity.startedAt.microseconds
                ) / 1_000_000
        )
        return AntigravityQuotaProvenance(
            transport: transport,
            endpointOwner: endpointOwner,
            accountIdentity: accountIdentity,
            capability: capability,
            processIdentity: ProcessIdentity(
                processID: endpoint.processIdentity.processID,
                startedAt: startedAt,
                executablePath:
                    endpoint.processIdentity.executable.canonicalURL.path
            )
        )
    }

    private static func isFatalIdentityError(
        _ error: AntigravityLocalRPCError
    ) -> Bool {
        switch error {
        case .cancelled,
             .invalidEndpoint,
             .endpointOwnershipChanged,
             .tlsRejected,
             .redirectRejected,
             .responseTooLarge:
            return true
        case .deadlineExceeded,
             .transportFailure,
             .invalidHTTPResponse,
             .unsupportedHTTPStatus,
             .authenticationRejected,
             .rateLimited,
             .serverRejected,
             .malformedPayload,
             .remoteRejected,
             .groupedQuotaUnavailable:
            return false
        }
    }
}
