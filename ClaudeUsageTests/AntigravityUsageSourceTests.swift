import XCTest
@testable import ClaudeUsage

final class AntigravityUsageSourceTests: XCTestCase {
    func testInspectionCollectsAccountsFromEveryEndpointAndRetainsUnknownCandidates() async throws {
        let endpoints = try [
            makeLocalAppEndpoint(processID: 101, startedAtSeconds: 101, port: 50101),
            makeLocalAppEndpoint(processID: 102, startedAtSeconds: 102, port: 50102),
            makeLocalAppEndpoint(processID: 103, startedAtSeconds: 103, port: 50103),
        ]
        let source = AntigravityDiscoveredLocalUsageSource(
            id: .localApp,
            discovery: RuntimeDiscoveryStub(
                snapshot: .init(
                    installations: [], processes: [], endpoints: endpoints, observedAt: Date())),
            client: AccountInspectionQuotaClient())
        let result = try await source.inspectAccounts(localSourceRequest())
        let accounts = result.responses.compactMap { response -> String? in
            guard case .limited(let value) = response.payload else { return nil }
            return value.evidence.identity?.email
        }
        XCTAssertEqual(Set(accounts), ["101@example.com", "102@example.com"])
        XCTAssertTrue(result.hasUnverifiedCandidates)
    }

    func testBorrowedCLIWithoutRequiredTokenReportsUnavailableAuthentication() async throws {
        let identity = try XCTUnwrap(AntigravityVerifiedProcessIdentity(
            processID: 401, effectiveUserID: .init(rawValue: 501), realUserID: .init(rawValue: 501),
            startedAt: AntigravityProcessStartTime(seconds: 100, microseconds: 1)!,
            executable: AntigravityCanonicalExecutable(
                canonicalURL: URL(fileURLWithPath: "/usr/local/bin/agy"), role: .agyCLI)))
        let endpoint = try XCTUnwrap(AntigravityVerifiedRuntimeEndpoint(
            processIdentity: identity, host: .ipv4, port: AntigravityTCPPort(54321)!,
            transport: .agyCLI, ownership: .borrowed, authentication: .cliTokenless))
        let source = AntigravityDiscoveredLocalUsageSource(id: .borrowedCLI,
            discovery: RuntimeDiscoveryStub(snapshot: AntigravityRuntimeDiscoverySnapshot(
                installations: [], processes: [], endpoints: [endpoint], observedAt: Date())),
            client: OrderedFailureLocalQuotaClient(failures: [.csrf(.required)]))
        do {
            _ = try await source.fetch(localSourceRequest())
            XCTFail("A token-required borrowed CLI must fail with an actionable local cause")
        } catch let error as AntigravityUsageSourceError {
            XCTAssertEqual(error, .localAuthentication(.unavailable))
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

private struct AccountInspectionQuotaClient: AntigravityLocalQuotaFetching {
    func fetch(
        from endpoint: AntigravityVerifiedRuntimeEndpoint,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityLocalQuotaFetchResult {
        let pid = endpoint.processIdentity.processID
        if pid == 103 { throw AntigravityLocalRPCError.authenticationRejected }
        let identity = ProviderAccountIdentity(email: "\(pid)@example.com")
        return .limited(
            .localLegacy(
                evidence: .init(method: .getUserStatus, identity: identity, plan: nil, modelConfigCount: 1),
                fallbackReason: .groupedQuotaUnavailable,
                provenance: .init(
                    transport: .localAppRPC, endpointOwner: .external,
                    accountIdentity: identity, capability: .limitedQuota,
                    processIdentity: .init(processID: pid)),
                fetchedAt: Date()))
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
