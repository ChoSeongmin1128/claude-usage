import Foundation

nonisolated struct AntigravityOAuthSourceAuthorization:
    Sendable,
    Equatable
{
    let accountID: AntigravityAccountID
    let repositoryRevision: UInt64
    let credentials: AntigravityOAuthCredentials
}

/// A source receives only the authorization needed for that exact attempt.
/// Local sources are always invoked with `oauthAuthorization == nil`.
nonisolated struct AntigravityUsageSourceRequest: Sendable {
    let generation: UInt64
    let accountTarget: AntigravityRefreshAccountTarget
    let expectedIdentity: ProviderAccountIdentity?
    let oauthAuthorization: AntigravityOAuthSourceAuthorization?
    let managedLaunchAuthorization:
        AntigravityManagedLaunchAuthorization
    let deadline: AntigravityRPCDeadline
}

nonisolated enum AntigravityUsageSourcePayload:
    Sendable,
    Equatable
{
    case grouped(AntigravityQuotaSnapshot)
    case limited(AntigravityLimitedQuotaCapability)
    case identityOnly(AntigravityIdentityOnlyUsage)
}

/// Refreshed credentials are returned to the coordinator and are never written
/// by a source. A non-OAuth source returning them is a contract violation.
nonisolated struct AntigravityUsageSourceResponse:
    Sendable,
    Equatable
{
    let payload: AntigravityUsageSourcePayload
    let refreshedCredential: AntigravityOAuthCredentials?

    init(
        payload: AntigravityUsageSourcePayload,
        refreshedCredential: AntigravityOAuthCredentials? = nil
    ) {
        self.payload = payload
        self.refreshedCredential = refreshedCredential
    }
}

nonisolated enum AntigravityUsageSourceError:
    Error,
    Sendable,
    Equatable
{
    case unavailable
    case authenticationRequired
    case interactionRequired
    case deadlineExceeded
    case cancelled
    case malformedResponse
    case transportFailure
    case managedLaunchDisabled
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
        case .unavailable:
            .unavailable
        case .transportFailure:
            .transport
        case .deadlineExceeded:
            .deadline
        case .malformedResponse:
            .schema
        case .managedLaunchDisabled:
            .managedLaunchPolicy
        case .interactionRequired:
            .interaction
        case .authenticationRequired:
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
}

nonisolated enum AntigravityGoogleOAuthQuotaResult:
    Sendable,
    Equatable
{
    case grouped(
        AntigravityQuotaSnapshot,
        refreshedCredential: AntigravityOAuthCredentials?
    )
    case limited(
        AntigravityLimitedQuotaCapability,
        refreshedCredential: AntigravityOAuthCredentials?
    )
    case identityOnly(
        AntigravityIdentityOnlyUsage,
        refreshedCredential: AntigravityOAuthCredentials?
    )
}

/// New OAuth HTTP boundary for Stage 8. Implementations fetch and decode only;
/// neither this protocol nor its source adapter receives a repository.
nonisolated protocol AntigravityGoogleOAuthQuotaFetching:
    Sendable
{
    func fetchQuota(
        credentials: AntigravityOAuthCredentials,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityGoogleOAuthQuotaResult
}

/// OAuth source intentionally does not wrap
/// `AntigravityRemoteUsageService`, whose legacy implementation persists
/// refreshed credentials itself.
nonisolated struct AntigravityGoogleOAuthUsageSource:
    AntigravityUsageSource,
    Sendable
{
    let id = AntigravityUsageSourceID.googleOAuth
    private let client:
        any AntigravityGoogleOAuthQuotaFetching

    init(client: any AntigravityGoogleOAuthQuotaFetching) {
        self.client = client
    }

    func fetch(
        _ request: AntigravityUsageSourceRequest
    ) async throws -> AntigravityUsageSourceResponse {
        guard let authorization =
                request.oauthAuthorization,
              case .selectedOAuth(let accountID) =
                request.accountTarget,
              authorization.accountID == accountID,
              request.managedLaunchAuthorization == .disabled
        else {
            throw AntigravityUsageSourceError
                .authenticationRequired
        }

        let result = try await client.fetchQuota(
            credentials: authorization.credentials,
            deadline: request.deadline
        )
        switch result {
        case .grouped(let snapshot, let refreshed):
            return AntigravityUsageSourceResponse(
                payload: .grouped(snapshot),
                refreshedCredential: refreshed
            )
        case .limited(let capability, let refreshed):
            guard case .googleOAuth =
                    capability.evidence,
                  case .googleOAuth =
                    capability.reason,
                  capability.provenance.transport
                    == .googleOAuth,
                  capability.provenance.endpointOwner
                    == .external,
                  capability.provenance.capability
                    == .limitedQuota,
                  capability.provenance.processIdentity == nil
            else {
                throw AntigravityUsageSourceError
                    .malformedResponse
            }
            return AntigravityUsageSourceResponse(
                payload: .limited(capability),
                refreshedCredential: refreshed
            )
        case .identityOnly(let identity, let refreshed):
            return AntigravityUsageSourceResponse(
                payload: .identityOnly(identity),
                refreshedCredential: refreshed
            )
        }
    }
}

nonisolated enum AntigravityRefreshedCredentialMergeError:
    Error,
    Sendable,
    Equatable
{
    case accountBoundaryMismatch
    case clientBoundaryMismatch
    case missingTokenMaterial
}

/// Token refresh responses are commonly partial. Empty or absent fields never
/// erase canonical refresh/account/client material.
nonisolated enum AntigravityRefreshedCredentialMerger {
    static func merge(
        original: AntigravityOAuthCredentials,
        refreshed: AntigravityOAuthCredentials,
        expectedIdentity: ProviderAccountIdentity
    ) throws -> AntigravityOAuthCredentials {
        let canonicalClientID = value(original.clientID)
        if let refreshedClientID = value(refreshed.clientID) {
            guard canonicalClientID == refreshedClientID else {
                // The refresh response may confirm an existing client
                // boundary, but may not create or replace one.
                throw AntigravityRefreshedCredentialMergeError
                    .clientBoundaryMismatch
            }
        }
        if let originalClientSecret =
                value(original.clientSecret),
           let refreshedClientSecret =
                value(refreshed.clientSecret),
           originalClientSecret != refreshedClientSecret
        {
            throw AntigravityRefreshedCredentialMergeError
                .clientBoundaryMismatch
        }

        let originalClaims = claims(from: original.idToken)
        let expectedSubject =
            value(expectedIdentity.stableAccountID)
            ?? originalClaims?.subject
        let fallbackExpectedEmail =
            AntigravityAccountIdentityMatcher
                .normalizedEmail(expectedIdentity.email)
            ?? AntigravityAccountIdentityMatcher
                .normalizedEmail(original.email)
            ?? AntigravityAccountIdentityMatcher
                .normalizedEmail(originalClaims?.email)

        // A stable provider subject is the account boundary. Email is allowed
        // to change for that same subject and is used only when no stable
        // subject exists.
        if expectedSubject == nil,
           let fallbackExpectedEmail,
           let refreshedEmail =
                AntigravityAccountIdentityMatcher
                    .normalizedEmail(refreshed.email),
           fallbackExpectedEmail != refreshedEmail
        {
            throw AntigravityRefreshedCredentialMergeError
                .accountBoundaryMismatch
        }

        var verifiedClaimsEmail: String?
        if let refreshedIDToken = value(refreshed.idToken) {
            guard let refreshedClaims =
                    claims(from: refreshedIDToken)
            else {
                throw AntigravityRefreshedCredentialMergeError
                    .clientBoundaryMismatch
            }
            guard let canonicalClientID else {
                // A refresh response cannot establish its own OAuth client
                // boundary. Imported credentials without a canonical client
                // ID may keep their existing ID token, but cannot replace it.
                throw AntigravityRefreshedCredentialMergeError
                    .clientBoundaryMismatch
            }
            guard refreshedClaims.audiences
                    .contains(canonicalClientID),
                  refreshedClaims.authorizedParty.map({
                      $0 == canonicalClientID
                  }) ?? !refreshedClaims.hasMultipleAudiences
            else {
                throw AntigravityRefreshedCredentialMergeError
                    .clientBoundaryMismatch
            }
            if let expectedSubject {
                guard let subject = refreshedClaims.subject,
                      expectedSubject == subject
                else {
                    throw AntigravityRefreshedCredentialMergeError
                        .accountBoundaryMismatch
                }
                // The stable provider subject is authoritative. Token refresh
                // responses commonly copy the old credential metadata and
                // replace only `id_token`, so a stale `refreshed.email` must
                // not reject a verified same-subject email change.
                verifiedClaimsEmail = refreshedClaims.email
            } else if let fallbackExpectedEmail,
               let claimsEmail =
                    AntigravityAccountIdentityMatcher
                        .normalizedEmail(
                            refreshedClaims.email
                        ),
               fallbackExpectedEmail != claimsEmail
            {
                throw AntigravityRefreshedCredentialMergeError
                    .accountBoundaryMismatch
            }
            if expectedSubject == nil,
               let refreshedEmail =
                    AntigravityAccountIdentityMatcher
                        .normalizedEmail(refreshed.email),
               let claimsEmail =
                    AntigravityAccountIdentityMatcher
                        .normalizedEmail(
                            refreshedClaims.email
                        ),
               refreshedEmail != claimsEmail
            {
                throw AntigravityRefreshedCredentialMergeError
                    .accountBoundaryMismatch
            }
        }

        var merged = original
        merged.accessToken =
            value(refreshed.accessToken) ?? original.accessToken
        merged.refreshToken =
            value(refreshed.refreshToken) ?? original.refreshToken
        merged.expiryDateMilliseconds =
            refreshed.expiryDateMilliseconds
                ?? original.expiryDateMilliseconds
        merged.idToken =
            value(refreshed.idToken) ?? original.idToken
        merged.email =
            value(verifiedClaimsEmail)
                ?? value(refreshed.email)
                ?? original.email
        merged.projectID =
            value(refreshed.projectID) ?? original.projectID
        merged.clientID =
            value(refreshed.clientID) ?? original.clientID
        merged.clientSecret =
            value(refreshed.clientSecret)
                ?? original.clientSecret
        guard merged.hasTokenMaterial else {
            throw AntigravityRefreshedCredentialMergeError
                .missingTokenMaterial
        }
        return merged
    }

    private struct IdentityClaims {
        let subject: String?
        let email: String?
        let audiences: Set<String>
        let audienceCount: Int
        let authorizedParty: String?

        var hasMultipleAudiences: Bool {
            audienceCount > 1
        }
    }

    private static func claims(
        from token: String?
    ) -> IdentityClaims? {
        guard let token = value(token) else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(
                repeating: "=",
                count: 4 - remainder
            )
        }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization
                .jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let audiences: Set<String>
        let audienceCount: Int
        switch object["aud"] {
        case let audience as String:
            guard let audience = value(audience) else {
                return nil
            }
            audiences = [audience]
            audienceCount = 1
        case let audienceArray as [Any]:
            let parsed = audienceArray.compactMap {
                value($0 as? String)
            }
            guard !parsed.isEmpty,
                  parsed.count == audienceArray.count
            else {
                return nil
            }
            audiences = Set(parsed)
            audienceCount = parsed.count
        default:
            return nil
        }

        let authorizedParty: String?
        if let rawAuthorizedParty = object["azp"] {
            guard let parsed =
                    value(rawAuthorizedParty as? String)
            else {
                return nil
            }
            authorizedParty = parsed
        } else {
            authorizedParty = nil
        }

        return IdentityClaims(
            subject: value(object["sub"] as? String),
            email: value(object["email"] as? String),
            audiences: audiences,
            audienceCount: audienceCount,
            authorizedParty: authorizedParty
        )
    }

    private static func value(_ string: String?) -> String? {
        guard let string else { return nil }
        let trimmed = string.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Dormant Stage 7 adapter for an already-running local app or borrowed CLI.
/// It never starts a process and it never reads OAuth credentials.
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

    func fetch(
        _ request: AntigravityUsageSourceRequest
    ) async throws -> AntigravityUsageSourceResponse {
        guard request.oauthAuthorization == nil,
              request.managedLaunchAuthorization == .disabled
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

        var firstSuccessfulResponse:
            AntigravityUsageSourceResponse?
        var preferredFailure:
            AntigravityUsageSourceError = .unavailable

        for endpoint in endpoints {
            do {
                let result = try await client.fetch(
                    from: endpoint,
                    deadline: request.deadline
                )
                let response = Self.response(from: result)
                if firstSuccessfulResponse == nil {
                    firstSuccessfulResponse = response
                }

                guard let expected = request.expectedIdentity else {
                    if Self.observedIdentity(in: response) != nil {
                        return response
                    }
                    continue
                }
                if AntigravityAccountIdentityMatcher.match(
                    expected: expected,
                    received: Self.observedIdentity(in: response)
                ).isMatch {
                    return response
                }
            } catch {
                let mapped = Self.map(error)
                if mapped == .cancelled
                    || mapped == .deadlineExceeded
                {
                    throw mapped
                }
                preferredFailure =
                    AntigravityUsageSourceFailurePolicy.preferred(
                        preferredFailure,
                        mapped
                    )
            }
        }

        if let firstSuccessfulResponse {
            return firstSuccessfulResponse
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

/// The only Stage 7 source allowed to acquire an owned AGY process. The
/// coordinator passes `.userOptIn` only for explicit local-session policy with
/// `allowManagedCLI == true`; every other request fails closed.
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
        guard request.oauthAuthorization == nil,
              case .userOptIn =
                request.managedLaunchAuthorization
        else {
            throw AntigravityUsageSourceError.managedLaunchDisabled
        }

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
            if let error = error as? AntigravityLocalRPCError {
                throw AntigravityDiscoveredLocalUsageSource.map(
                    error
                )
            }
            throw AntigravityUsageSourceError.transportFailure
        }
    }
}
