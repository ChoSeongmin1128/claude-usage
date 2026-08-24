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
    private let identityAttemptLimit: Int
    private let identityRetryDelay: Duration
    private let sleep:
        @Sendable (Duration) async throws -> Void

    init(
        connectionFactory:
            any AntigravityLocalRPCConnectionFactory,
        now: @escaping @Sendable () -> Date = Date.init,
        // AGY answers GetUserStatus before its asynchronous keyring
        // authentication completes; identity can appear several hundred
        // milliseconds after the RPC listener is reachable, longer when a
        // token refresh needs the network. Keep the retry window wider than
        // that measured gap for borrowed and local-app endpoints too.
        identityAttemptLimit: Int = 5,
        identityRetryDelay: Duration = .milliseconds(200),
        sleep:
            @escaping @Sendable (Duration) async throws -> Void = {
                try await Task.sleep(for: $0)
            }
    ) {
        precondition(identityAttemptLimit > 0)
        precondition(identityRetryDelay >= .zero)
        self.connectionFactory = connectionFactory
        self.now = now
        self.identityAttemptLimit = identityAttemptLimit
        self.identityRetryDelay = identityRetryDelay
        self.sleep = sleep
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
        var lastIssue =
            AntigravityLocalIdentityIssue(
                error: .transportFailure
            )
        // A decodable-but-identity-less body from AGY's keyring window; kept
        // so the final answer still carries the decoded plan when identity
        // never appears within the retry budget.
        var pendingEvidence: AntigravityLocalAccountIdentity?
        attemptLoop: for attempt in 0..<identityAttemptLimit {
            let remaining = parentDeadline.remaining
            guard remaining > .zero else {
                // The grouped quota is already fetched by this point; an
                // exhausted identity budget degrades to an identity issue
                // instead of discarding that snapshot.
                lastIssue =
                    AntigravityLocalIdentityIssue(
                        error: .deadlineExceeded
                    )
                break attemptLoop
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
                try AntigravityLocalRPCResponseValidator.validate(
                    response
                )
                switch AntigravityUserStatusAuthenticationEvidence
                    .classify(response.body)
                {
                case .authenticated(let decoded):
                    return (decoded, nil)
                case .authenticationPending(let decoded):
                    // Keyring authentication has not completed yet;
                    // retry within the budget instead of settling for an
                    // identity-less answer on the first attempt.
                    pendingEvidence = decoded
                case .malformed:
                    lastIssue =
                        AntigravityLocalIdentityIssue(
                            error: .malformedPayload
                        )
                }
            } catch let error as AntigravityLocalRPCError {
                if error == .deadlineExceeded {
                    do {
                        try parentDeadline.check(.request)
                    } catch is CancellationError {
                        throw AntigravityLocalRPCError.cancelled
                    } catch is AntigravityRPCDeadlineError {
                        lastIssue =
                            AntigravityLocalIdentityIssue(
                                error: .deadlineExceeded
                            )
                        break attemptLoop
                    }
                }
                if Self.isFatalIdentityError(error) {
                    throw error
                }
                lastIssue =
                    AntigravityLocalIdentityIssue(error: error)
            } catch is CancellationError {
                throw AntigravityLocalRPCError.cancelled
            } catch is AntigravityRPCDeadlineError {
                do {
                    try parentDeadline.check(.request)
                } catch is CancellationError {
                    throw AntigravityLocalRPCError.cancelled
                } catch is AntigravityRPCDeadlineError {
                    lastIssue =
                        AntigravityLocalIdentityIssue(
                            error: .deadlineExceeded
                        )
                    break attemptLoop
                }
                lastIssue =
                    AntigravityLocalIdentityIssue(
                        error: .deadlineExceeded
                    )
            } catch {
                lastIssue =
                    AntigravityLocalIdentityIssue(
                        error: .malformedPayload
                    )
            }

            guard attempt + 1 < identityAttemptLimit else {
                break attemptLoop
            }
            if identityRetryDelay > .zero {
                do {
                    try await sleep(
                        min(
                            identityRetryDelay,
                            max(.zero, parentDeadline.remaining)
                        )
                    )
                } catch is CancellationError {
                    throw AntigravityLocalRPCError.cancelled
                } catch {
                    throw AntigravityLocalRPCError
                        .transportFailure
                }
            }
        }
        // Grouped quota remains usable as capability evidence, but the
        // coordinator will not bind it to an account without identity. A
        // decoded identity-less body is not an issue; it preserves the
        // pre-authentication plan evidence.
        if let pendingEvidence {
            return (pendingEvidence, nil)
        }
        return (nil, lastIssue)
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
