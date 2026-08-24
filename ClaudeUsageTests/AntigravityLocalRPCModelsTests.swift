import XCTest
@testable import ClaudeUsage

final class AntigravityLocalRPCModelsTests: XCTestCase {
    func testRPCMethodCatalogIsClosedAndUsesExactConnectPathsAndBodies() {
        XCTAssertEqual(AntigravityLocalRPCMethod.allCases, [
            .retrieveUserQuotaSummary,
            .getUserStatus,
            .getCommandModelConfigs,
        ])
        XCTAssertEqual(
            AntigravityLocalRPCMethod.retrieveUserQuotaSummary.path,
            "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
        )
        XCTAssertEqual(
            String(
                decoding: AntigravityLocalRPCMethod.retrieveUserQuotaSummary.requestBody,
                as: UTF8.self
            ),
            #"{"forceRefresh":true}"#
        )
        XCTAssertFalse(
            AntigravityLocalRPCMethod.allCases
                .map(\.path)
                .contains { $0.localizedCaseInsensitiveContains("unleash") }
        )
    }

    func testIdentityMethodsUseDeterministicMetadataBody() {
        let expected =
            #"{"metadata":{"extensionName":"antigravity","ideName":"antigravity","ideVersion":"unknown","locale":"en"}}"#

        XCTAssertEqual(
            String(
                decoding: AntigravityLocalRPCMethod.getUserStatus.requestBody,
                as: UTF8.self
            ),
            expected
        )
        XCTAssertEqual(
            AntigravityLocalRPCMethod.getCommandModelConfigs.requestBody,
            AntigravityLocalRPCMethod.getUserStatus.requestBody
        )
    }

    func testResponseValidatorAcceptsSuccessfulPayloadAndNormalizesHeaders() throws {
        let response = AntigravityLocalRPCResponse(
            statusCode: 200,
            headers: [
                "Grpc-Status": "0",
                "Content-Type": "application/json",
            ],
            body: Data(#"{"response":{"groups":[]}}"#.utf8)
        )

        XCTAssertEqual(response.headers["grpc-status"], "0")
        XCTAssertNoThrow(try AntigravityLocalRPCResponseValidator.validate(response))
    }

    func testResponseValidatorClassifiesAuthenticationRateLimitAndServerFailures() {
        assertValidationError(status: 401, equals: .authenticationRejected)
        assertValidationError(status: 403, equals: .authenticationRejected)
        assertValidationError(status: 429, equals: .rateLimited)
        assertValidationError(status: 500, equals: .serverRejected)
    }

    func testResponseValidatorClassifiesConnectErrorsFromHeadersAndBody() {
        assertValidationError(
            status: 200,
            headers: ["grpc-status": "12"],
            equals: .remoteRejected(.unimplemented)
        )
        assertValidationError(
            status: 200,
            body: #"{"code":"unimplemented","message":"unsupported"}"#,
            equals: .remoteRejected(.unimplemented)
        )
        assertValidationError(
            status: 200,
            body: #"{"code":16}"#,
            equals: .authenticationRejected
        )
        assertValidationError(
            status: 200,
            body: #"{"code":"resource_exhausted"}"#,
            equals: .rateLimited
        )
        assertValidationError(
            status: 200,
            headers: ["grpc-status": "2"],
            equals: .remoteRejected(.unknown)
        )
        assertValidationError(
            status: 200,
            body: #"{"error":{"code":16,"message":"denied"}}"#,
            equals: .authenticationRejected
        )
        assertValidationError(
            status: 200,
            body: #"{"error":"unknown upstream failure"}"#,
            equals: .remoteRejected(.unknown)
        )
    }

    func testConnectEnvelopeTakesPrecedenceOverFallbackLookingHTTPStatus() {
        assertValidationError(
            status: 501,
            body: #"{"code":"unauthenticated"}"#,
            equals: .authenticationRejected
        )
        assertValidationError(
            status: 501,
            headers: ["grpc-status": "16"],
            equals: .authenticationRejected
        )
        assertValidationError(
            status: 504,
            body: #"{"code":"deadline_exceeded"}"#,
            equals: .deadlineExceeded
        )
        assertValidationError(
            status: 499,
            body: #"{"code":"cancelled"}"#,
            equals: .cancelled
        )
        assertValidationError(
            status: 501,
            body: #"{"code":"unimplemented"}"#,
            equals: .remoteRejected(.unimplemented)
        )
    }

    func testConflictingCapabilitySignalsFailClosed() {
        assertValidationError(
            status: 401,
            body: #"{"code":"unimplemented"}"#,
            equals: .authenticationRejected
        )
        assertValidationError(
            status: 429,
            headers: ["grpc-status": "12"],
            equals: .rateLimited
        )
        assertValidationError(
            status: 501,
            headers: [
                "grpc-status": "12",
                "connect-error-code": "unauthenticated",
            ],
            equals: .authenticationRejected
        )
        assertValidationError(
            status: 501,
            headers: ["grpc-status": "12"],
            body: #"{"code":"permission_denied"}"#,
            equals: .authenticationRejected
        )
        assertValidationError(
            status: 500,
            body: #"{"code":"unimplemented"}"#,
            equals: .serverRejected
        )
    }

    func testLegacyFallbackPolicyAllowsOnlyCapabilityEvidence() {
        XCTAssertEqual(
            AntigravityLegacyFallbackPolicy.reason(
                for: .unsupportedHTTPStatus(404)
            ),
            .unsupportedHTTPStatus(404)
        )
        XCTAssertEqual(
            AntigravityLegacyFallbackPolicy.reason(
                for: .unsupportedHTTPStatus(405)
            ),
            .unsupportedHTTPStatus(405)
        )
        XCTAssertEqual(
            AntigravityLegacyFallbackPolicy.reason(
                for: .unsupportedHTTPStatus(501)
            ),
            .unsupportedHTTPStatus(501)
        )
        XCTAssertEqual(
            AntigravityLegacyFallbackPolicy.reason(
                for: .remoteRejected(.unimplemented)
            ),
            .connectUnimplemented
        )
        XCTAssertEqual(
            AntigravityLegacyFallbackPolicy.reason(
                for: .groupedQuotaUnavailable
            ),
            .groupedQuotaUnavailable
        )
    }

    func testLegacyFallbackPolicyRejectsOperationalAndSecurityFailures() {
        let denied: [AntigravityLocalRPCError] = [
            .cancelled,
            .deadlineExceeded,
            .invalidEndpoint,
            .endpointOwnershipChanged,
            .tlsRejected,
            .redirectRejected,
            .responseTooLarge(limit: 1),
            .transportFailure,
            .invalidHTTPResponse,
            .unsupportedHTTPStatus(400),
            .authenticationRejected,
            .rateLimited,
            .serverRejected,
            .malformedPayload,
            .remoteRejected(.unavailable),
        ]

        for error in denied {
            XCTAssertNil(
                AntigravityLegacyFallbackPolicy.reason(for: error),
                "\(error) must not enable legacy fallback"
            )
        }
    }

    func testIdentityDecoderTrimsEmailPrefersUserTierAndDoesNotInventStableID() throws {
        let result = try AntigravityLocalIdentityDecoder.decode(Data("""
        {
          "response": {
            "userStatus": {
              "email": "  nathan@example.com  ",
              "userTier": { "id": "do-not-use", "name": "  Teams  " },
              "planStatus": {
                "planInfo": { "planDisplayName": "Fallback Plan" }
              }
            }
          }
        }
        """.utf8))

        XCTAssertEqual(result.identity?.email, "nathan@example.com")
        XCTAssertNil(result.identity?.stableAccountID)
        XCTAssertEqual(result.plan, "Teams")
    }

    func testIdentityDecoderFallsBackToPlanInfoAndRejectsMissingUserStatus() throws {
        let result = try AntigravityLocalIdentityDecoder.decode(Data("""
        {
          "userStatus": {
            "email": " ",
            "planStatus": {
              "planInfo": { "displayName": "  Individual Pro  " }
            }
          }
        }
        """.utf8))

        XCTAssertNil(result.identity)
        XCTAssertEqual(result.plan, "Individual Pro")
        XCTAssertThrowsError(
            try AntigravityLocalIdentityDecoder.decode(Data(#"{"response":{}}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? AntigravityLocalRPCError, .malformedPayload)
        }
    }

    func testLegacyCapabilityDecoderReportsEvidenceWithoutCreatingQuotaLanes() throws {
        let status = try AntigravityLegacyCapabilityDecoder.decode(
            Data("""
            {
              "userStatus": {
                "email": "nathan@example.com",
                "userTier": { "name": "Pro" },
                "cascadeModelConfigData": {
                  "clientModelConfigs": [{ "id": "model-a" }, { "id": "model-b" }]
                }
              }
            }
            """.utf8),
            method: .getUserStatus
        )
        let configs = try AntigravityLegacyCapabilityDecoder.decode(
            Data(#"{"clientModelConfigs":[{"id":"model-a"}]}"#.utf8),
            method: .getCommandModelConfigs
        )

        XCTAssertEqual(status.identity?.email, "nathan@example.com")
        XCTAssertEqual(status.plan, "Pro")
        XCTAssertEqual(status.modelConfigCount, 2)
        XCTAssertEqual(configs.modelConfigCount, 1)
    }

    func testRequestBuilderUsesHTTPSConnectHeadersAndAppTokenOnlyForApp() throws {
        let token = try XCTUnwrap(AntigravityCSRFToken("secret"))
        let appEndpoint = try makeEndpoint(
            role: .appLanguageServer,
            transport: .antigravityApp,
            authentication: .appCSRF(token)
        )
        let cliEndpoint = try makeEndpoint(
            role: .agyCLI,
            transport: .agyCLI,
            authentication: .cliTokenless
        )

        let appRequest = try AntigravityLocalRPCRequestBuilder.request(
            for: .retrieveUserQuotaSummary,
            endpoint: appEndpoint,
            timeout: 3
        )
        let cliRequest = try AntigravityLocalRPCRequestBuilder.request(
            for: .retrieveUserQuotaSummary,
            endpoint: cliEndpoint,
            timeout: 3
        )

        XCTAssertEqual(appRequest.url?.scheme, "https")
        XCTAssertEqual(appRequest.url?.host, "127.0.0.1")
        XCTAssertEqual(appRequest.url?.port, 54_321)
        XCTAssertEqual(appRequest.httpMethod, "POST")
        XCTAssertEqual(
            appRequest.value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
        XCTAssertEqual(
            appRequest.value(forHTTPHeaderField: "Connect-Protocol-Version"),
            "1"
        )
        XCTAssertEqual(
            appRequest.value(forHTTPHeaderField: "X-Codeium-Csrf-Token"),
            "secret"
        )
        XCTAssertNil(
            cliRequest.value(forHTTPHeaderField: "X-Codeium-Csrf-Token")
        )
    }

    func testEndpointRevalidatorRequiresSameProcessAndOwnedPort() async throws {
        let endpoint = try makeEndpoint(
            role: .agyCLI,
            transport: .agyCLI,
            authentication: .cliTokenless
        )
        let processInspector = RuntimeProcessInspectorStub(isValid: true)
        let portInspector = PortOwnershipInspectorStub(
            endpoints: [
                endpoint.processIdentity.processID: [
                    AntigravityOwnedListeningEndpoint(
                        host: endpoint.host,
                        port: endpoint.port
                    ),
                ],
            ]
        )
        let revalidator = AntigravityRuntimeEndpointRevalidator(
            processInspector: processInspector,
            portInspector: portInspector
        )

        try await revalidator.revalidate(
            endpoint,
            deadline: AntigravityRPCDeadline()
        )
        processInspector.isValid = false
        await XCTAssertThrowsErrorAsync(
            try await revalidator.revalidate(
                endpoint,
                deadline: AntigravityRPCDeadline()
            )
        ) { error in
            XCTAssertEqual(
                error as? AntigravityLocalRPCError,
                .endpointOwnershipChanged
            )
        }
    }

    func testEndpointRevalidatorRejectsQuarantinedOwnership()
        async throws
    {
        let endpoint = try makeEndpoint(
            role: .agyCLI,
            transport: .agyCLI,
            authentication: .cliTokenless
        )
        let processInspector =
            RuntimeProcessInspectorStub(isValid: true)
        let portInspector = PortOwnershipInspectorStub(
            endpoints: [
                endpoint.processIdentity.processID: [
                    AntigravityOwnedListeningEndpoint(
                        host: endpoint.host,
                        port: endpoint.port
                    ),
                ],
            ]
        )
        let registry = AntigravityManagedRuntimeRegistry()
        await registry.quarantine(endpoint.processIdentity)
        let revalidator =
            AntigravityRuntimeEndpointRevalidator(
                processInspector: processInspector,
                portInspector: portInspector,
                ownershipResolver: registry
            )

        await XCTAssertThrowsErrorAsync(
            try await revalidator.revalidate(
                endpoint,
                deadline: AntigravityRPCDeadline()
            )
        ) { error in
            XCTAssertEqual(
                error as? AntigravityLocalRPCError,
                .endpointOwnershipChanged
            )
        }
    }

    func testClientUsesOneConnectionForQuotaAndBestEffortIdentity() async throws {
        let connection = LocalRPCConnectionStub(outcomes: [
            .response(groupedQuotaResponse()),
            .response(identityResponse()),
        ])
        let factory = LocalRPCConnectionFactoryStub(connection: connection)
        let endpoint = try makeEndpoint(
            role: .agyCLI,
            transport: .agyCLI,
            authentication: .cliTokenless
        )
        let client = AntigravityLocalRPCClient(
            connectionFactory: factory,
            now: { Date(timeIntervalSince1970: 100) }
        )

        let result = try await client.fetch(
            from: endpoint,
            deadline: AntigravityRPCDeadline()
        )
        guard case let .grouped(snapshot, identityIssue) = result else {
            return XCTFail("Expected grouped quota")
        }

        XCTAssertEqual(factory.makeConnectionCount, 1)
        XCTAssertEqual(connection.methods, [
            .retrieveUserQuotaSummary,
            .getUserStatus,
        ])
        XCTAssertTrue(connection.wasInvalidated)
        XCTAssertNil(identityIssue)
        XCTAssertEqual(snapshot.identity?.email, "nathan@example.com")
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.lanes.map(\.id), [.geminiFiveHour])
        XCTAssertEqual(snapshot.provenance.transport, .borrowedAGYRPC)
        XCTAssertEqual(snapshot.provenance.endpointOwner, .borrowed)
        XCTAssertEqual(
            snapshot.provenance.processIdentity?.executablePath,
            "/usr/local/bin/agy"
        )
    }

    func testClientKeepsGroupedQuotaWhenIdentityPayloadIsNormallyUnavailable() async throws {
        let connection = LocalRPCConnectionStub(outcomes: [
            .response(groupedQuotaResponse()),
            .response(AntigravityLocalRPCResponse(
                statusCode: 200,
                body: Data(#"{"response":{}}"#.utf8)
            )),
        ])
        let client = AntigravityLocalRPCClient(
            connectionFactory: LocalRPCConnectionFactoryStub(
                connection: connection
            ),
            identityAttemptLimit: 1
        )
        let endpoint = try makeEndpoint(
            role: .agyCLI,
            transport: .agyCLI,
            authentication: .cliTokenless
        )

        let result = try await client.fetch(from: endpoint)
        guard case let .grouped(snapshot, identityIssue) = result else {
            return XCTFail("Expected grouped quota")
        }

        XCTAssertNil(snapshot.identity)
        XCTAssertEqual(identityIssue?.error, .malformedPayload)
        XCTAssertTrue(connection.wasInvalidated)
    }

    func testClientKeepsGroupedQuotaWhenBestEffortIdentityTimesOut() async throws {
        let connection = LocalRPCConnectionStub(outcomes: [
            .response(groupedQuotaResponse()),
            .failure(.deadlineExceeded),
        ])
        let client = AntigravityLocalRPCClient(
            connectionFactory: LocalRPCConnectionFactoryStub(
                connection: connection
            ),
            identityAttemptLimit: 1
        )
        let endpoint = try makeEndpoint(
            role: .agyCLI,
            transport: .agyCLI,
            authentication: .cliTokenless
        )

        let result = try await client.fetch(from: endpoint)
        guard case let .grouped(snapshot, identityIssue) = result else {
            return XCTFail("Expected grouped quota")
        }
        XCTAssertEqual(snapshot.lanes.count, 1)
        XCTAssertNil(snapshot.identity)
        XCTAssertEqual(identityIssue?.error, .deadlineExceeded)
        XCTAssertEqual(connection.methods, [
            .retrieveUserQuotaSummary,
            .getUserStatus,
        ])
        XCTAssertTrue(connection.wasInvalidated)
    }

    func testClientRetriesPreAuthenticationIdentityUntilItAppears()
        async throws
    {
        let connection = LocalRPCConnectionStub(outcomes: [
            .response(groupedQuotaResponse()),
            .response(preAuthenticationIdentityResponse()),
            .response(identityResponse()),
        ])
        let client = AntigravityLocalRPCClient(
            connectionFactory: LocalRPCConnectionFactoryStub(
                connection: connection
            ),
            identityRetryDelay: .zero
        )
        let endpoint = try makeEndpoint(
            role: .agyCLI,
            transport: .agyCLI,
            authentication: .cliTokenless
        )

        let result = try await client.fetch(from: endpoint)
        guard case let .grouped(snapshot, identityIssue) = result else {
            return XCTFail("Expected grouped quota")
        }

        XCTAssertNil(identityIssue)
        XCTAssertEqual(snapshot.identity?.email, "nathan@example.com")
        XCTAssertEqual(connection.methods, [
            .retrieveUserQuotaSummary,
            .getUserStatus,
            .getUserStatus,
        ])
    }

    func testClientKeepsPlanEvidenceWhenIdentityStaysPreAuthentication()
        async throws
    {
        let connection = LocalRPCConnectionStub(outcomes: [
            .response(groupedQuotaResponse()),
            .response(preAuthenticationIdentityResponse()),
            .response(preAuthenticationIdentityResponse()),
        ])
        let client = AntigravityLocalRPCClient(
            connectionFactory: LocalRPCConnectionFactoryStub(
                connection: connection
            ),
            identityAttemptLimit: 2,
            identityRetryDelay: .zero
        )
        let endpoint = try makeEndpoint(
            role: .agyCLI,
            transport: .agyCLI,
            authentication: .cliTokenless
        )

        let result = try await client.fetch(from: endpoint)
        guard case let .grouped(snapshot, identityIssue) = result else {
            return XCTFail("Expected grouped quota")
        }

        XCTAssertNil(snapshot.identity)
        XCTAssertNil(identityIssue)
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(connection.methods, [
            .retrieveUserQuotaSummary,
            .getUserStatus,
            .getUserStatus,
        ])
    }

    func testClientRetriesBestEffortIdentityBeforeReturningGroupedQuota()
        async throws
    {
        let connection = LocalRPCConnectionStub(outcomes: [
            .response(groupedQuotaResponse()),
            .failure(.deadlineExceeded),
            .response(identityResponse()),
        ])
        let client = AntigravityLocalRPCClient(
            connectionFactory: LocalRPCConnectionFactoryStub(
                connection: connection
            ),
            identityRetryDelay: .zero
        )
        let endpoint = try makeEndpoint(
            role: .agyCLI,
            transport: .agyCLI,
            authentication: .cliTokenless
        )

        let result = try await client.fetch(from: endpoint)
        guard case let .grouped(snapshot, identityIssue) = result else {
            return XCTFail("Expected grouped quota")
        }

        XCTAssertEqual(snapshot.identity?.email, "nathan@example.com")
        XCTAssertNil(identityIssue)
        XCTAssertEqual(connection.methods, [
            .retrieveUserQuotaSummary,
            .getUserStatus,
            .getUserStatus,
        ])
        XCTAssertTrue(connection.wasInvalidated)
    }

    func testTransportPreservesCancellationCompletedBeforeRegistration() async throws {
        let endpoint = try makeEndpoint(
            role: .agyCLI,
            transport: .agyCLI,
            authentication: .cliTokenless
        )
        let delegate = AntigravityLocalRPCSessionDelegate(
            endpoint: endpoint,
            endpointRevalidator: AcceptingEndpointRevalidator()
        )
        let session = URLSession(configuration: .ephemeral)
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://127.0.0.1:54321"))
        )
        let task = session.dataTask(with: request)
        defer { session.invalidateAndCancel() }

        delegate.cancel(task, with: .cancelled)
        delegate.urlSession(
            session,
            task: task,
            didCompleteWithError: URLError(.cancelled)
        )

        do {
            _ = try await delegate.execute(
                task,
                maximumResponseBytes: 1_024,
                deadline: AntigravityRPCDeadline(
                    totalTimeout: .seconds(1)
                )
            )
            XCTFail("Expected the original cancellation to be preserved")
        } catch let error as AntigravityLocalRPCError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testClientPropagatesIdentitySecurityFailureAndInvalidatesConnection() async throws {
        let connection = LocalRPCConnectionStub(outcomes: [
            .response(groupedQuotaResponse()),
            .failure(.endpointOwnershipChanged),
        ])
        let client = AntigravityLocalRPCClient(
            connectionFactory: LocalRPCConnectionFactoryStub(
                connection: connection
            )
        )
        let endpoint = try makeEndpoint(
            role: .agyCLI,
            transport: .agyCLI,
            authentication: .cliTokenless
        )

        await XCTAssertThrowsErrorAsync(
            try await client.fetch(from: endpoint)
        ) { error in
            XCTAssertEqual(
                error as? AntigravityLocalRPCError,
                .endpointOwnershipChanged
            )
        }
        XCTAssertTrue(connection.wasInvalidated)
    }

    func testClientUsesLimitedCapabilityWithoutTurningModelConfigsIntoLanes() async throws {
        let connection = LocalRPCConnectionStub(outcomes: [
            .response(AntigravityLocalRPCResponse(
                statusCode: 404,
                body: Data()
            )),
            .response(identityResponse()),
        ])
        let client = AntigravityLocalRPCClient(
            connectionFactory: LocalRPCConnectionFactoryStub(
                connection: connection
            ),
            now: { Date(timeIntervalSince1970: 100) }
        )
        let endpoint = try makeEndpoint(
            role: .agyCLI,
            transport: .agyCLI,
            authentication: .cliTokenless
        )

        let result = try await client.fetch(from: endpoint)
        guard case let .limited(limited) = result else {
            return XCTFail("Expected limited capability")
        }

        XCTAssertEqual(connection.methods, [
            .retrieveUserQuotaSummary,
            .getUserStatus,
        ])
        XCTAssertEqual(
            limited.reason,
            .localLegacy(.unsupportedHTTPStatus(404))
        )
        XCTAssertEqual(limited.evidence.identity?.email, "nathan@example.com")
        XCTAssertEqual(limited.evidence.modelCount, 0)
        XCTAssertEqual(limited.provenance.capability, .limitedQuota)
        guard case .localLegacy(let localEvidence) =
                limited.evidence
        else {
            return XCTFail("Expected typed local legacy evidence")
        }
        XCTAssertEqual(localEvidence.method, .getUserStatus)
        XCTAssertTrue(connection.wasInvalidated)
    }

    func testClientFallsBackFromUnsupportedUserStatusToCommandConfigsOnly() async throws {
        let connection = LocalRPCConnectionStub(outcomes: [
            .response(AntigravityLocalRPCResponse(
                statusCode: 501,
                body: Data()
            )),
            .response(AntigravityLocalRPCResponse(
                statusCode: 404,
                body: Data()
            )),
            .response(AntigravityLocalRPCResponse(
                statusCode: 200,
                body: Data(
                    #"{"clientModelConfigs":[{"id":"model-a"}]}"#.utf8
                )
            )),
        ])
        let client = AntigravityLocalRPCClient(
            connectionFactory: LocalRPCConnectionFactoryStub(
                connection: connection
            )
        )
        let endpoint = try makeEndpoint(
            role: .agyCLI,
            transport: .agyCLI,
            authentication: .cliTokenless
        )

        let result = try await client.fetch(from: endpoint)
        guard case let .limited(limited) = result else {
            return XCTFail("Expected limited capability")
        }

        XCTAssertEqual(connection.methods, [
            .retrieveUserQuotaSummary,
            .getUserStatus,
            .getCommandModelConfigs,
        ])
        guard case .localLegacy(let localEvidence) =
                limited.evidence
        else {
            return XCTFail("Expected typed local legacy evidence")
        }
        XCTAssertEqual(
            localEvidence.method,
            .getCommandModelConfigs
        )
        XCTAssertEqual(limited.evidence.modelCount, 1)
    }

    func testClientDoesNotFallbackWhenGroupedPayloadIsMalformed() async throws {
        let connection = LocalRPCConnectionStub(outcomes: [
            .response(AntigravityLocalRPCResponse(
                statusCode: 200,
                body: Data("not-json".utf8)
            )),
        ])
        let client = AntigravityLocalRPCClient(
            connectionFactory: LocalRPCConnectionFactoryStub(
                connection: connection
            )
        )
        let endpoint = try makeEndpoint(
            role: .agyCLI,
            transport: .agyCLI,
            authentication: .cliTokenless
        )

        await XCTAssertThrowsErrorAsync(
            try await client.fetch(from: endpoint)
        ) { error in
            XCTAssertEqual(
                error as? AntigravityLocalRPCError,
                .malformedPayload
            )
        }
        XCTAssertEqual(connection.methods, [.retrieveUserQuotaSummary])
        XCTAssertTrue(connection.wasInvalidated)
    }

    func testClientDoesNotFallbackFromErrorEnvelopeWithoutQuotaGroups() async throws {
        let connection = LocalRPCConnectionStub(outcomes: [
            .response(AntigravityLocalRPCResponse(
                statusCode: 200,
                body: Data(
                    #"{"error":{"message":"upstream failure"}}"#.utf8
                )
            )),
        ])
        let client = AntigravityLocalRPCClient(
            connectionFactory: LocalRPCConnectionFactoryStub(
                connection: connection
            )
        )
        let endpoint = try makeEndpoint(
            role: .agyCLI,
            transport: .agyCLI,
            authentication: .cliTokenless
        )

        await XCTAssertThrowsErrorAsync(
            try await client.fetch(from: endpoint)
        ) { error in
            XCTAssertEqual(
                error as? AntigravityLocalRPCError,
                .remoteRejected(.unknown)
            )
        }
        XCTAssertEqual(connection.methods, [.retrieveUserQuotaSummary])
    }

    private func groupedQuotaResponse() -> AntigravityLocalRPCResponse {
        AntigravityLocalRPCResponse(
            statusCode: 200,
            body: Data("""
            {
              "response": {
                "groups": [
                  {
                    "groupId": "gemini",
                    "buckets": [
                      {
                        "bucketId": "gemini-5h",
                        "window": "5h",
                        "remainingFraction": 0.5
                      }
                    ]
                  }
                ]
              }
            }
            """.utf8)
        )
    }

    private func identityResponse() -> AntigravityLocalRPCResponse {
        AntigravityLocalRPCResponse(
            statusCode: 200,
            body: Data("""
            {
              "userStatus": {
                "email": "nathan@example.com",
                "userTier": { "name": "Pro" }
              }
            }
            """.utf8)
        )
    }

    /// The real body shape AGY answers with while its keyring
    /// authentication is still completing (observed 2026-08-24): HTTP 200,
    /// `userStatus` present, no account identity.
    private func preAuthenticationIdentityResponse()
        -> AntigravityLocalRPCResponse
    {
        AntigravityLocalRPCResponse(
            statusCode: 200,
            body: Data("""
            {
              "userStatus": {
                "userTier": { "name": "Pro" },
                "cascadeModelConfigData": {
                  "errorMessage": "error getting token source: You are not logged into Antigravity."
                }
              }
            }
            """.utf8)
        )
    }

    private func makeEndpoint(
        role: AntigravityExecutableRole,
        transport: AntigravityRuntimeTransport,
        authentication: AntigravityRuntimeEndpointAuthentication,
        host: AntigravityLoopbackHost = .ipv4
    ) throws -> AntigravityVerifiedRuntimeEndpoint {
        let executable: AntigravityCanonicalExecutable
        switch role {
        case .appLanguageServer:
            let bundle = AntigravityAppBundleIdentity(
                canonicalRootURL: URL(
                    fileURLWithPath: "/Applications/Antigravity.app"
                ),
                bundleIdentifier:
                    AntigravityAppBundleIdentity.requiredBundleIdentifier
            )
            executable = AntigravityCanonicalExecutable(
                canonicalURL: bundle.canonicalRootURL.appendingPathComponent(
                    "Contents/Resources/bin/language_server"
                ),
                role: role,
                appBundle: bundle
            )
        case .agyCLI:
            executable = AntigravityCanonicalExecutable(
                canonicalURL: URL(fileURLWithPath: "/usr/local/bin/agy"),
                role: role
            )
        }
        let startedAt = try XCTUnwrap(AntigravityProcessStartTime(
            seconds: 1_700_000_000,
            microseconds: 0
        ))
        let process = try XCTUnwrap(AntigravityVerifiedProcessIdentity(
            processID: 42,
            effectiveUserID: AntigravityUserID(rawValue: 501),
            realUserID: AntigravityUserID(rawValue: 501),
            startedAt: startedAt,
            executable: executable
        ))
        return try XCTUnwrap(AntigravityVerifiedRuntimeEndpoint(
            processIdentity: process,
            host: host,
            port: try XCTUnwrap(AntigravityTCPPort(54_321)),
            transport: transport,
            ownership: role == .appLanguageServer ? .external : .borrowed,
            authentication: authentication
        ))
    }

    private func assertValidationError(
        status: Int,
        headers: [String: String] = [:],
        body: String = "{}",
        equals expected: AntigravityLocalRPCError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try AntigravityLocalRPCResponseValidator.validate(
                AntigravityLocalRPCResponse(
                    statusCode: status,
                    headers: headers,
                    body: Data(body.utf8)
                )
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? AntigravityLocalRPCError,
                expected,
                file: file,
                line: line
            )
        }
    }
}

private final class RuntimeProcessInspectorStub:
    AntigravityRuntimeProcessInspecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedIsValid: Bool

    init(isValid: Bool) {
        self.storedIsValid = isValid
    }

    var isValid: Bool {
        get { lock.withLock { storedIsValid } }
        set { lock.withLock { storedIsValid = newValue } }
    }

    func discoverProcesses(
        timeout: TimeInterval
    ) async throws -> [AntigravityRuntimeProcessCandidate] {
        []
    }

    func revalidate(
        _ identity: AntigravityVerifiedProcessIdentity
    ) async -> Bool {
        isValid
    }
}

private struct AcceptingEndpointRevalidator:
    AntigravityRuntimeEndpointRevalidating
{
    func revalidate(
        _ endpoint: AntigravityVerifiedRuntimeEndpoint,
        deadline: AntigravityRPCDeadline
    ) async throws {}
}

private final class PortOwnershipInspectorStub:
    AntigravityPortOwnershipInspecting,
    @unchecked Sendable
{
    let endpoints:
        [Int32: Set<AntigravityOwnedListeningEndpoint>]

    init(
        endpoints:
            [Int32: Set<AntigravityOwnedListeningEndpoint>]
    ) {
        self.endpoints = endpoints
    }

    func listeningEndpoints(
        ownedBy processIDs: Set<Int32>,
        timeout: TimeInterval
    ) async throws
        -> [Int32: Set<AntigravityOwnedListeningEndpoint>]
    {
        endpoints.filter { processIDs.contains($0.key) }
    }
}

private enum LocalRPCConnectionOutcome: Sendable {
    case response(AntigravityLocalRPCResponse)
    case failure(AntigravityLocalRPCError)
}

private final class LocalRPCConnectionStub:
    AntigravityLocalRPCConnection,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var outcomes: [LocalRPCConnectionOutcome]
    private var storedMethods: [AntigravityLocalRPCMethod] = []
    private var storedWasInvalidated = false

    init(outcomes: [LocalRPCConnectionOutcome]) {
        self.outcomes = outcomes
    }

    var methods: [AntigravityLocalRPCMethod] {
        lock.withLock { storedMethods }
    }

    var wasInvalidated: Bool {
        lock.withLock { storedWasInvalidated }
    }

    func perform(
        _ method: AntigravityLocalRPCMethod,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityLocalRPCResponse {
        let outcome: LocalRPCConnectionOutcome? = lock.withLock {
            storedMethods.append(method)
            return outcomes.isEmpty ? nil : outcomes.removeFirst()
        }
        guard let outcome else {
            throw AntigravityLocalRPCError.transportFailure
        }
        switch outcome {
        case .response(let response):
            return response
        case .failure(let error):
            throw error
        }
    }

    func invalidate() {
        lock.withLock {
            storedWasInvalidated = true
        }
    }
}

private final class LocalRPCConnectionFactoryStub:
    AntigravityLocalRPCConnectionFactory,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let connection: any AntigravityLocalRPCConnection
    private var storedMakeConnectionCount = 0

    init(connection: any AntigravityLocalRPCConnection) {
        self.connection = connection
    }

    var makeConnectionCount: Int {
        lock.withLock { storedMakeConnectionCount }
    }

    func makeConnection(
        endpoint: AntigravityVerifiedRuntimeEndpoint
    ) throws -> any AntigravityLocalRPCConnection {
        lock.withLock {
            storedMakeConnectionCount += 1
        }
        return connection
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
