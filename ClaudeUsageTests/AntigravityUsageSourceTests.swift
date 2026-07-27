import XCTest
@testable import ClaudeUsage

final class AntigravityUsageSourceTests: XCTestCase {
    func testGoogleOAuthSourcePassesCredentialToReadOnlyClientAndReturnsRefreshCandidate() async throws {
        let identity = ProviderAccountIdentity(
            stableAccountID: "subject-a",
            email: "a@example.com"
        )
        let observation = AntigravityIdentityOnlyUsage(
            identity: identity,
            plan: "Pro",
            provenance: AntigravityQuotaProvenance(
                transport: .googleOAuth,
                endpointOwner: .external,
                accountIdentity: identity,
                capability: .groupedQuotaSummary,
                processIdentity: nil
            ),
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let refreshed = AntigravityOAuthCredentials(
            accessToken: "new-access",
            refreshToken: nil,
            expiryDate: Date(timeIntervalSince1970: 200)
        )
        let client = GoogleOAuthQuotaClientDouble(
            result: .identityOnly(
                observation,
                refreshedCredential: refreshed
            )
        )
        let source = AntigravityGoogleOAuthUsageSource(
            client: client
        )
        let accountID = AntigravityAccountID(
            rawValue: "account-a"
        )
        let original = AntigravityOAuthCredentials(
            accessToken: "old-access",
            refreshToken: "refresh",
            expiryDate: nil
        )

        let response = try await source.fetch(
            AntigravityUsageSourceRequest(
                generation: 7,
                accountTarget: .selectedOAuth(accountID),
                expectedIdentity: identity,
                oauthAuthorization:
                    AntigravityOAuthSourceAuthorization(
                        accountID: accountID,
                        repositoryRevision: 3,
                        credentials: original
                    ),
                managedLaunchAuthorization: .disabled,
                deadline: AntigravityRPCDeadline()
            )
        )

        XCTAssertEqual(
            response,
            AntigravityUsageSourceResponse(
                payload: .identityOnly(observation),
                refreshedCredential: refreshed
            )
        )
        let receivedCredentials =
            await client.receivedCredentials()
        XCTAssertEqual(receivedCredentials, [original])
    }

    func testGoogleOAuthSourceRejectsMissingSelectedAuthorization() async {
        let client = GoogleOAuthQuotaClientDouble(
            result: .identityOnly(
                AntigravityIdentityOnlyUsage(
                    identity: ProviderAccountIdentity(
                        email: "a@example.com"
                    ),
                    plan: nil,
                    provenance: AntigravityQuotaProvenance(
                        transport: .googleOAuth,
                        endpointOwner: .external,
                        accountIdentity:
                            ProviderAccountIdentity(
                                email: "a@example.com"
                            ),
                        capability: .groupedQuotaSummary,
                        processIdentity: nil
                    ),
                    fetchedAt: Date(timeIntervalSince1970: 100)
                ),
                refreshedCredential: nil
            )
        )
        let source = AntigravityGoogleOAuthUsageSource(
            client: client
        )

        do {
            _ = try await source.fetch(
                AntigravityUsageSourceRequest(
                    generation: 1,
                    accountTarget: .ambientLocal,
                    expectedIdentity: nil,
                    oauthAuthorization: nil,
                    managedLaunchAuthorization: .disabled,
                    deadline: AntigravityRPCDeadline()
                )
            )
            XCTFail("OAuth authorization 없이 source를 호출하면 안 됩니다")
        } catch let error as AntigravityUsageSourceError {
            XCTAssertEqual(error, .authenticationRequired)
        } catch {
            XCTFail("예상하지 못한 오류: \(error)")
        }
        let received = await client.receivedCredentials()
        XCTAssertTrue(received.isEmpty)
    }

    func testGoogleOAuthLimitedResultKeepsOAuthEvidenceWithoutInventingLocalRPCMethod() async throws {
        let identity = ProviderAccountIdentity(
            stableAccountID: "subject-a",
            email: "a@example.com"
        )
        let capability =
            AntigravityLimitedQuotaCapability.googleOAuth(
                evidence:
                    AntigravityGoogleOAuthLimitedQuotaEvidence(
                        identity: identity,
                        plan: "Pro",
                        modelQuotaCount: 3
                    ),
                provenance: AntigravityQuotaProvenance(
                    transport: .googleOAuth,
                    endpointOwner: .external,
                    accountIdentity: identity,
                    capability: .limitedQuota,
                    processIdentity: nil
                ),
                fetchedAt: Date(timeIntervalSince1970: 100)
            )
        let client = GoogleOAuthQuotaClientDouble(
            result: .limited(
                capability,
                refreshedCredential: nil
            )
        )
        let source = AntigravityGoogleOAuthUsageSource(
            client: client
        )
        let accountID = AntigravityAccountID(
            rawValue: "account-a"
        )

        let response = try await source.fetch(
            AntigravityUsageSourceRequest(
                generation: 1,
                accountTarget: .selectedOAuth(accountID),
                expectedIdentity: identity,
                oauthAuthorization:
                    AntigravityOAuthSourceAuthorization(
                        accountID: accountID,
                        repositoryRevision: 2,
                        credentials:
                            AntigravityOAuthCredentials(
                                accessToken: "access",
                                refreshToken: "refresh",
                                expiryDate: nil
                            )
                    ),
                managedLaunchAuthorization: .disabled,
                deadline: AntigravityRPCDeadline()
            )
        )

        XCTAssertEqual(
            response,
            AntigravityUsageSourceResponse(
                payload: .limited(capability)
            )
        )
        XCTAssertEqual(
            capability.reason,
            .googleOAuth(.modelQuotaOnly)
        )
        XCTAssertEqual(capability.evidence.identity, identity)
        XCTAssertEqual(capability.evidence.plan, "Pro")
        XCTAssertEqual(capability.evidence.modelCount, 3)
        guard case .googleOAuth =
                capability.evidence
        else {
            return XCTFail(
                "OAuth limited result must not carry local RPC evidence"
            )
        }
    }

    func testGoogleOAuthSourceRejectsLocalLegacyEvidenceWithOAuthProvenance() async {
        let identity = ProviderAccountIdentity(
            stableAccountID: "subject-a",
            email: "a@example.com"
        )
        let invalidCapability =
            AntigravityLimitedQuotaCapability.localLegacy(
                evidence:
                    AntigravityLegacyCapabilityEvidence(
                        method: .getUserStatus,
                        identity: identity,
                        plan: "Pro",
                        modelConfigCount: 1
                    ),
                fallbackReason:
                    .groupedQuotaUnavailable,
                provenance: AntigravityQuotaProvenance(
                    transport: .googleOAuth,
                    endpointOwner: .external,
                    accountIdentity: identity,
                    capability: .limitedQuota,
                    processIdentity: nil
                ),
                fetchedAt: Date(timeIntervalSince1970: 100)
            )
        let client = GoogleOAuthQuotaClientDouble(
            result: .limited(
                invalidCapability,
                refreshedCredential: nil
            )
        )
        let source = AntigravityGoogleOAuthUsageSource(
            client: client
        )
        let accountID = AntigravityAccountID(
            rawValue: "account-a"
        )

        do {
            _ = try await source.fetch(
                AntigravityUsageSourceRequest(
                    generation: 1,
                    accountTarget: .selectedOAuth(accountID),
                    expectedIdentity: identity,
                    oauthAuthorization:
                        AntigravityOAuthSourceAuthorization(
                            accountID: accountID,
                            repositoryRevision: 2,
                            credentials:
                                AntigravityOAuthCredentials(
                                    accessToken: "access",
                                    refreshToken: "refresh",
                                    expiryDate: nil
                                )
                        ),
                    managedLaunchAuthorization: .disabled,
                    deadline: AntigravityRPCDeadline()
                )
            )
            XCTFail(
                "OAuth source must reject local RPC evidence"
            )
        } catch let error as AntigravityUsageSourceError {
            XCTAssertEqual(error, .malformedResponse)
        } catch {
            XCTFail("예상하지 못한 오류: \(error)")
        }
    }

    func testLocalEndpointFailureOrderDoesNotChangePreferredUXFailure() async throws {
        let endpoints = [
            try makeLocalAppEndpoint(
                processID: 101,
                startedAtSeconds: 300,
                port: 50_101
            ),
            try makeLocalAppEndpoint(
                processID: 102,
                startedAtSeconds: 200,
                port: 50_102
            ),
            try makeLocalAppEndpoint(
                processID: 103,
                startedAtSeconds: 100,
                port: 50_103
            ),
        ]
        let failureOrders: [[AntigravityLocalRPCError]] = [
            [
                .authenticationRejected,
                .malformedPayload,
                .transportFailure,
            ],
            [
                .transportFailure,
                .malformedPayload,
                .authenticationRejected,
            ],
        ]

        for failureOrder in failureOrders {
            let source = AntigravityDiscoveredLocalUsageSource(
                id: .localApp,
                discovery: RuntimeDiscoveryStub(
                    snapshot: AntigravityRuntimeDiscoverySnapshot(
                        installations: [],
                        processes: [],
                        endpoints: endpoints,
                        observedAt: Date(timeIntervalSince1970: 1)
                    )
                ),
                client: OrderedFailureLocalQuotaClient(
                    failures: failureOrder
                )
            )

            do {
                _ = try await source.fetch(
                    localSourceRequest()
                )
                XCTFail("모든 endpoint가 실패하면 오류를 반환해야 합니다")
            } catch let error as AntigravityUsageSourceError {
                XCTAssertEqual(error, .authenticationRequired)
            } catch {
                XCTFail("예상하지 못한 오류: \(error)")
            }
        }
    }

    func testLocalEndpointFailurePolicyHasExplicitStableSeverity() {
        let ascending: [AntigravityUsageSourceError] = [
            .unavailable,
            .transportFailure,
            .deadlineExceeded,
            .malformedResponse,
            .managedLaunchDisabled,
            .interactionRequired,
            .authenticationRequired,
            .cancelled,
        ]

        for (lower, higher) in zip(
            ascending,
            ascending.dropFirst()
        ) {
            XCTAssertEqual(
                AntigravityUsageSourceFailurePolicy.preferred(
                    lower,
                    higher
                ),
                higher
            )
            XCTAssertEqual(
                AntigravityUsageSourceFailurePolicy.preferred(
                    higher,
                    lower
                ),
                higher
            )
        }
    }
}

private actor GoogleOAuthQuotaClientDouble:
    AntigravityGoogleOAuthQuotaFetching
{
    private let result: AntigravityGoogleOAuthQuotaResult
    private var credentials:
        [AntigravityOAuthCredentials] = []

    init(result: AntigravityGoogleOAuthQuotaResult) {
        self.result = result
    }

    func fetchQuota(
        credentials: AntigravityOAuthCredentials,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityGoogleOAuthQuotaResult {
        self.credentials.append(credentials)
        return result
    }

    func receivedCredentials()
        -> [AntigravityOAuthCredentials]
    {
        credentials
    }
}

private struct RuntimeDiscoveryStub:
    AntigravityManagedRuntimeDiscovering
{
    let snapshot: AntigravityRuntimeDiscoverySnapshot

    func discover(
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityRuntimeDiscoverySnapshot {
        snapshot
    }

    func invalidateCache() async {}
}

private actor OrderedFailureLocalQuotaClient:
    AntigravityLocalQuotaFetching
{
    private let failures: [AntigravityLocalRPCError]
    private var nextIndex = 0

    init(failures: [AntigravityLocalRPCError]) {
        self.failures = failures
    }

    func fetch(
        from endpoint: AntigravityVerifiedRuntimeEndpoint,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityLocalQuotaFetchResult {
        guard nextIndex < failures.count else {
            throw AntigravityLocalRPCError.transportFailure
        }
        let failure = failures[nextIndex]
        nextIndex += 1
        throw failure
    }
}

private func localSourceRequest() -> AntigravityUsageSourceRequest {
    AntigravityUsageSourceRequest(
        generation: 1,
        accountTarget: .ambientLocal,
        expectedIdentity: nil,
        oauthAuthorization: nil,
        managedLaunchAuthorization: .disabled,
        deadline: AntigravityRPCDeadline()
    )
}

private func makeLocalAppEndpoint(
    processID: Int32,
    startedAtSeconds: Int64,
    port: Int
) throws -> AntigravityVerifiedRuntimeEndpoint {
    let bundle = AntigravityAppBundleIdentity(
        canonicalRootURL: URL(
            fileURLWithPath: "/Applications/Antigravity.app"
        ),
        bundleIdentifier:
            AntigravityAppBundleIdentity.requiredBundleIdentifier
    )
    let executable = AntigravityCanonicalExecutable(
        canonicalURL: bundle.canonicalRootURL
            .appendingPathComponent(
                "Contents/Resources/bin/language_server"
            ),
        role: .appLanguageServer,
        appBundle: bundle
    )
    let startedAt = try XCTUnwrap(
        AntigravityProcessStartTime(
            seconds: startedAtSeconds,
            microseconds: 0
        )
    )
    let process = try XCTUnwrap(
        AntigravityVerifiedProcessIdentity(
            processID: processID,
            effectiveUserID: AntigravityUserID(rawValue: 501),
            realUserID: AntigravityUserID(rawValue: 501),
            startedAt: startedAt,
            executable: executable
        )
    )
    return try XCTUnwrap(
        AntigravityVerifiedRuntimeEndpoint(
            processIdentity: process,
            host: .ipv4,
            port: try XCTUnwrap(AntigravityTCPPort(port)),
            transport: .antigravityApp,
            ownership: .external,
            authentication:
                .appCSRF(try XCTUnwrap(AntigravityCSRFToken("csrf")))
        )
    )
}
