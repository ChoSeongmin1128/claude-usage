import Foundation
import XCTest
@testable import ClaudeUsage

final class AntigravityGoogleOAuthQuotaClientTests:
    XCTestCase
{
    private let primary = URL(
        string: "https://cloudcode-pa.googleapis.com"
    )!
    private let daily = URL(
        string: "https://daily-cloudcode-pa.googleapis.com"
    )!
    private let fixedNow = Date(
        timeIntervalSince1970: 2_000_000_000
    )

    func testAvailableModelsReturnsSourceNeutralLimitedEvidenceAndProjectCandidate() async throws {
        let transport = GoogleOAuthTransportStub()
        await transport.enqueue(
            host: "cloudcode-pa.googleapis.com",
            path: "/v1internal:loadCodeAssist",
            statusCode: 200,
            json: """
            {
              "planInfo": { "planType": "Paid" },
              "cloudaicompanionProject": {
                "projectId": "project-new"
              }
            }
            """
        )
        await transport.enqueue(
            host: "cloudcode-pa.googleapis.com",
            path: "/v1internal:fetchAvailableModels",
            statusCode: 200,
            json: """
            {
              "models": {
                "gemini-pro": {
                  "quotaInfo": {
                    "remainingFraction": 0.5
                  }
                },
                "claude-sonnet": {
                  "quotaInfo": {}
                },
                "no-quota": {}
              }
            }
            """
        )
        let client = makeClient(
            transport: transport,
            baseURLs: [primary]
        )

        let result = try await client.fetchQuota(
            credentials: credentials(
                projectID: nil
            ),
            deadline: AntigravityRPCDeadline()
        )

        guard case .limited(
            let capability,
            let refreshed
        ) = result else {
            return XCTFail(
                "Remote model evidence must not synthesize grouped lanes"
            )
        }
        XCTAssertEqual(capability.evidence.modelCount, 2)
        XCTAssertEqual(
            capability.evidence.identity,
            ProviderAccountIdentity(
                stableAccountID: "subject-a",
                email: "user@example.com"
            )
        )
        XCTAssertEqual(capability.evidence.plan, "Paid")
        XCTAssertEqual(
            capability.provenance.transport,
            .googleOAuth
        )
        XCTAssertEqual(
            capability.provenance.capability,
            .limitedQuota
        )
        XCTAssertNil(
            capability.provenance.processIdentity
        )
        XCTAssertEqual(
            refreshed?.projectID,
            "project-new"
        )
        XCTAssertEqual(
            refreshed?.accessToken,
            "access-old"
        )
        XCTAssertNil(refreshed?.refreshToken)

        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.map(\.path),
            [
                "/v1internal:loadCodeAssist",
                "/v1internal:fetchAvailableModels",
            ]
        )
        XCTAssertFalse(
            requests.map(\.path).contains {
                $0.localizedCaseInsensitiveContains("onboard")
            }
        )
        XCTAssertEqual(
            requests[0].authorization,
            "Bearer access-old"
        )
        XCTAssertEqual(
            try jsonString(
                requests[1].body,
                key: "project"
            ),
            "project-new"
        )
    }

    func testPermissionDeniedModelEndpointUsesDistinctLegacyBucketCount() async throws {
        let transport = GoogleOAuthTransportStub()
        await enqueueCodeAssist(
            on: transport,
            host: "cloudcode-pa.googleapis.com",
            projectID: "stored-project"
        )
        await transport.enqueue(
            host: "cloudcode-pa.googleapis.com",
            path: "/v1internal:fetchAvailableModels",
            statusCode: 403,
            json: "{}"
        )
        await transport.enqueue(
            host: "cloudcode-pa.googleapis.com",
            path: "/v1internal:retrieveUserQuota",
            statusCode: 200,
            json: """
            {
              "buckets": [
                { "modelId": "claude-sonnet" },
                { "modelId": "claude-sonnet" },
                { "modelId": "gemini-pro" },
                { "modelId": "  " }
              ]
            }
            """
        )
        let client = makeClient(
            transport: transport,
            baseURLs: [primary]
        )

        let result = try await client.fetchQuota(
            credentials: credentials(
                projectID: "stored-project"
            ),
            deadline: AntigravityRPCDeadline()
        )

        guard case .limited(
            let capability,
            let refreshed
        ) = result else {
            return XCTFail("Expected limited evidence")
        }
        XCTAssertEqual(capability.evidence.modelCount, 2)
        XCTAssertNil(refreshed)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.map(\.path),
            [
                "/v1internal:loadCodeAssist",
                "/v1internal:fetchAvailableModels",
                "/v1internal:retrieveUserQuota",
            ]
        )
    }

    func testCodeAssistReplacesStaleStoredProjectOnlyThroughReturnedCandidate() async throws {
        let transport = GoogleOAuthTransportStub()
        await enqueueCodeAssist(
            on: transport,
            host: "cloudcode-pa.googleapis.com",
            projectID: "project-current"
        )
        await transport.enqueue(
            host: "cloudcode-pa.googleapis.com",
            path: "/v1internal:fetchAvailableModels",
            statusCode: 200,
            json: """
            {
              "models": {
                "gemini-pro": { "quotaInfo": {} }
              }
            }
            """
        )
        let client = makeClient(
            transport: transport,
            baseURLs: [primary]
        )

        let result = try await client.fetchQuota(
            credentials: credentials(
                projectID: "project-stale"
            ),
            deadline: AntigravityRPCDeadline()
        )

        guard case .limited(_, let candidate) = result else {
            return XCTFail("Expected limited evidence")
        }
        XCTAssertEqual(
            candidate?.projectID,
            "project-current"
        )
        XCTAssertEqual(
            candidate?.accessToken,
            "access-old"
        )
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            try jsonString(
                requests[1].body,
                key: "project"
            ),
            "project-current"
        )
    }

    func testIdentityOnlyTriesPrimaryThenDailyWithoutInventingQuota() async throws {
        let transport = GoogleOAuthTransportStub()
        for host in [
            "cloudcode-pa.googleapis.com",
            "daily-cloudcode-pa.googleapis.com",
        ] {
            await transport.enqueue(
                host: host,
                path: "/v1internal:loadCodeAssist",
                statusCode: 200,
                json: """
                {
                  "currentTier": {
                    "id": "free-tier",
                    "name": "Free"
                  }
                }
                """
            )
            await transport.enqueue(
                host: host,
                path: "/v1internal:fetchAvailableModels",
                statusCode: 200,
                json: #"{"models":{}}"#
            )
            await transport.enqueue(
                host: host,
                path: "/v1internal:retrieveUserQuota",
                statusCode: 403,
                json: "{}"
            )
        }
        let hostedIdentity = credentials(
            idToken: makeIDToken(
                subject: "subject-a",
                email: "user@example.com",
                hostedDomain: "workspace.example"
            )
        )
        let client = makeClient(
            transport: transport
        )

        let result = try await client.fetchQuota(
            credentials: hostedIdentity,
            deadline: AntigravityRPCDeadline()
        )

        guard case .identityOnly(
            let observation,
            let refreshed
        ) = result else {
            return XCTFail("Expected identity-only result")
        }
        XCTAssertEqual(observation.plan, "Workspace")
        XCTAssertEqual(
            observation.identity.stableAccountID,
            "subject-a"
        )
        XCTAssertEqual(
            observation.provenance.capability,
            .limitedQuota
        )
        XCTAssertNil(refreshed)

        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.map(\.host),
            [
                "cloudcode-pa.googleapis.com",
                "cloudcode-pa.googleapis.com",
                "cloudcode-pa.googleapis.com",
                "daily-cloudcode-pa.googleapis.com",
                "daily-cloudcode-pa.googleapis.com",
                "daily-cloudcode-pa.googleapis.com",
            ]
        )
    }

    func testPrimaryTransportFailureFallsBackToDaily() async throws {
        let transport = GoogleOAuthTransportStub()
        await transport.enqueue(
            host: "cloudcode-pa.googleapis.com",
            path: "/v1internal:loadCodeAssist",
            statusCode: 500,
            json: "{}"
        )
        await enqueueCodeAssist(
            on: transport,
            host: "daily-cloudcode-pa.googleapis.com",
            projectID: "project-daily"
        )
        await transport.enqueue(
            host: "daily-cloudcode-pa.googleapis.com",
            path: "/v1internal:fetchAvailableModels",
            statusCode: 200,
            json: """
            {
              "models": {
                "gemini-pro": { "quotaInfo": {} }
              }
            }
            """
        )
        let client = makeClient(transport: transport)

        let result = try await client.fetchQuota(
            credentials: credentials(projectID: nil),
            deadline: AntigravityRPCDeadline()
        )

        guard case .limited(let capability, _) = result else {
            return XCTFail("Expected daily limited result")
        }
        XCTAssertEqual(capability.evidence.modelCount, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.map(\.host),
            [
                "cloudcode-pa.googleapis.com",
                "daily-cloudcode-pa.googleapis.com",
                "daily-cloudcode-pa.googleapis.com",
            ]
        )
    }

    func testNearExpiryRefreshesOnceAndReturnsCredentialCandidateWithoutPersisting() async throws {
        let transport = GoogleOAuthTransportStub()
        let refreshedIDToken = makeIDToken(
            subject: "subject-a",
            email: "renamed@example.com"
        )
        await transport.enqueue(
            host: "oauth2.googleapis.com",
            path: "/token",
            statusCode: 200,
            json: """
            {
              "access_token": "access-new",
              "refresh_token": "refresh-rotated",
              "expires_in": 3600,
              "id_token": "\(refreshedIDToken)"
            }
            """
        )
        await enqueueCodeAssist(
            on: transport,
            host: "cloudcode-pa.googleapis.com",
            projectID: "project-new"
        )
        await transport.enqueue(
            host: "cloudcode-pa.googleapis.com",
            path: "/v1internal:fetchAvailableModels",
            statusCode: 200,
            json: """
            {
              "models": {
                "gemini-pro": { "quotaInfo": {} }
              }
            }
            """
        )
        let client = makeClient(
            transport: transport,
            baseURLs: [primary]
        )
        let expiring = credentials(
            accessToken: "access-old",
            refreshToken: "refresh-old",
            expiryDate: fixedNow.addingTimeInterval(30),
            projectID: nil,
            clientID: "client-id",
            clientSecret: "client-secret"
        )

        let result = try await client.fetchQuota(
            credentials: expiring,
            deadline: AntigravityRPCDeadline()
        )

        guard case .limited(
            let capability,
            let candidate
        ) = result else {
            return XCTFail("Expected refreshed limited result")
        }
        XCTAssertEqual(
            capability.evidence.identity?.email,
            "renamed@example.com"
        )
        XCTAssertEqual(candidate?.accessToken, "access-new")
        XCTAssertEqual(
            candidate?.refreshToken,
            "refresh-rotated"
        )
        XCTAssertEqual(candidate?.idToken, refreshedIDToken)
        XCTAssertEqual(candidate?.projectID, "project-new")
        XCTAssertNil(candidate?.clientID)
        XCTAssertNil(candidate?.clientSecret)
        XCTAssertEqual(
            try XCTUnwrap(candidate?.expiryDate),
            fixedNow.addingTimeInterval(3_600)
        )

        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.map(\.path),
            [
                "/token",
                "/v1internal:loadCodeAssist",
                "/v1internal:fetchAvailableModels",
            ]
        )
        XCTAssertEqual(
            requests[1].authorization,
            "Bearer access-new"
        )
        let form = try formValues(requests[0].body)
        XCTAssertEqual(form["client_id"], "client-id")
        XCTAssertEqual(
            form["client_secret"],
            "client-secret"
        )
        XCTAssertEqual(
            form["refresh_token"],
            "refresh-old"
        )
        XCTAssertEqual(form["grant_type"], "refresh_token")
    }

    func testUnauthorizedRefreshesAndRetriesWholeEndpointTransactionOnce() async throws {
        let transport = GoogleOAuthTransportStub()
        await transport.enqueue(
            host: "cloudcode-pa.googleapis.com",
            path: "/v1internal:loadCodeAssist",
            statusCode: 401,
            json: "{}"
        )
        await transport.enqueue(
            host: "oauth2.googleapis.com",
            path: "/token",
            statusCode: 200,
            json: """
            {
              "access_token": "access-new",
              "expires_in": 3600
            }
            """
        )
        await enqueueCodeAssist(
            on: transport,
            host: "cloudcode-pa.googleapis.com",
            projectID: "project-a"
        )
        await transport.enqueue(
            host: "cloudcode-pa.googleapis.com",
            path: "/v1internal:fetchAvailableModels",
            statusCode: 200,
            json: """
            {
              "models": {
                "gemini-pro": { "quotaInfo": {} }
              }
            }
            """
        )
        let client = makeClient(
            transport: transport,
            baseURLs: [primary]
        )

        _ = try await client.fetchQuota(
            credentials: credentials(
                refreshToken: "refresh-old",
                clientID: "client-id"
            ),
            deadline: AntigravityRPCDeadline()
        )

        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.map(\.path),
            [
                "/v1internal:loadCodeAssist",
                "/token",
                "/v1internal:loadCodeAssist",
                "/v1internal:fetchAvailableModels",
            ]
        )
        XCTAssertEqual(
            requests[0].authorization,
            "Bearer access-old"
        )
        XCTAssertEqual(
            requests[2].authorization,
            "Bearer access-new"
        )
    }

    func testSecondUnauthorizedDoesNotRefreshMoreThanOnce() async {
        let transport = GoogleOAuthTransportStub()
        await transport.enqueue(
            host: "cloudcode-pa.googleapis.com",
            path: "/v1internal:loadCodeAssist",
            statusCode: 401,
            json: "{}"
        )
        await transport.enqueue(
            host: "oauth2.googleapis.com",
            path: "/token",
            statusCode: 200,
            json: """
            {
              "access_token": "access-new",
              "expires_in": 3600
            }
            """
        )
        await transport.enqueue(
            host: "cloudcode-pa.googleapis.com",
            path: "/v1internal:loadCodeAssist",
            statusCode: 401,
            json: "{}"
        )
        let client = makeClient(
            transport: transport,
            baseURLs: [primary]
        )

        await assertSourceError(.authenticationRequired) {
            _ = try await client.fetchQuota(
                credentials: credentials(
                    refreshToken: "refresh-old",
                    clientID: "client-id"
                ),
                deadline: AntigravityRPCDeadline()
            )
        }

        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.map(\.path),
            [
                "/v1internal:loadCodeAssist",
                "/token",
                "/v1internal:loadCodeAssist",
            ]
        )
        XCTAssertEqual(
            requests.filter { $0.path == "/token" }.count,
            1
        )
    }

    func testAlreadyRefreshedNearExpiryDoesNotRefreshAgainAfterUnauthorized() async {
        let transport = GoogleOAuthTransportStub()
        await transport.enqueue(
            host: "oauth2.googleapis.com",
            path: "/token",
            statusCode: 200,
            json: """
            {
              "access_token": "access-new",
              "expires_in": 3600
            }
            """
        )
        await transport.enqueue(
            host: "cloudcode-pa.googleapis.com",
            path: "/v1internal:loadCodeAssist",
            statusCode: 401,
            json: "{}"
        )
        let client = makeClient(
            transport: transport,
            baseURLs: [primary]
        )

        await assertSourceError(.authenticationRequired) {
            _ = try await client.fetchQuota(
                credentials: credentials(
                    refreshToken: "refresh-old",
                    expiryDate:
                        fixedNow.addingTimeInterval(30),
                    clientID: "client-id"
                ),
                deadline: AntigravityRPCDeadline()
            )
        }

        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.map(\.path),
            [
                "/token",
                "/v1internal:loadCodeAssist",
            ]
        )
    }

    func testRefreshRequiresCredentialOwnedClientAndRefreshToken() async {
        for incomplete in [
            credentials(
                accessToken: nil,
                refreshToken: "refresh",
                clientID: nil
            ),
            credentials(
                accessToken: nil,
                refreshToken: nil,
                clientID: "client-id"
            ),
        ] {
            let transport = GoogleOAuthTransportStub()
            let client = makeClient(
                transport: transport,
                baseURLs: [primary]
            )

            await assertSourceError(.authenticationRequired) {
                _ = try await client.fetchQuota(
                    credentials: incomplete,
                    deadline: AntigravityRPCDeadline()
                )
            }
            let requests = await transport.recordedRequests()
            XCTAssertTrue(
                requests.isEmpty
            )
        }
    }

    func testEndpointAndTokenURLAllowlistFailClosedBeforeTransport() async {
        let quotaTransport = GoogleOAuthTransportStub()
        let quotaClient = makeClient(
            transport: quotaTransport,
            baseURLs: [
                URL(string: "https://example.com")!,
            ]
        )
        await assertSourceError(.transportFailure) {
            _ = try await quotaClient.fetchQuota(
                credentials: credentials(),
                deadline: AntigravityRPCDeadline()
            )
        }
        let quotaRequests =
            await quotaTransport.recordedRequests()
        XCTAssertTrue(
            quotaRequests.isEmpty
        )

        let tokenTransport = GoogleOAuthTransportStub()
        let tokenClient = makeClient(
            transport: tokenTransport,
            baseURLs: [primary],
            tokenURL: URL(
                string: "https://example.com/token"
            )!
        )
        await assertSourceError(.transportFailure) {
            _ = try await tokenClient.fetchQuota(
                credentials: credentials(
                    accessToken: nil,
                    refreshToken: "refresh",
                    clientID: "client-id"
                ),
                deadline: AntigravityRPCDeadline()
            )
        }
        let tokenRequests =
            await tokenTransport.recordedRequests()
        XCTAssertTrue(
            tokenRequests.isEmpty
        )
    }

    func testExpiredDeadlineAndTransportCancellationKeepTypedFailure() async {
        let expiredTransport = GoogleOAuthTransportStub()
        let expiredClient = makeClient(
            transport: expiredTransport,
            baseURLs: [primary]
        )
        let clock = ContinuousClock()
        let expired = AntigravityRPCDeadline(
            startedAt: clock.now,
            totalTimeout: .zero,
            discoveryTimeout: .zero,
            now: { clock.now }
        )
        await assertSourceError(.deadlineExceeded) {
            _ = try await expiredClient.fetchQuota(
                credentials: credentials(),
                deadline: expired
            )
        }
        let expiredRequests =
            await expiredTransport.recordedRequests()
        XCTAssertTrue(
            expiredRequests.isEmpty
        )

        let cancelledTransport = GoogleOAuthTransportStub()
        await cancelledTransport.enqueue(
            host: "cloudcode-pa.googleapis.com",
            path: "/v1internal:loadCodeAssist",
            error: .cancelled
        )
        let cancelledClient = makeClient(
            transport: cancelledTransport,
            baseURLs: [primary]
        )
        await assertSourceError(.cancelled) {
            _ = try await cancelledClient.fetchQuota(
                credentials: credentials(),
                deadline: AntigravityRPCDeadline()
            )
        }
    }

    func testResponseCapAndRedirectFailuresAreNotRetriedAsSuccess() async {
        let oversizedTransport = GoogleOAuthTransportStub()
        await oversizedTransport.enqueue(
            host: "cloudcode-pa.googleapis.com",
            path: "/v1internal:loadCodeAssist",
            error: .responseTooLarge
        )
        let oversizedClient = makeClient(
            transport: oversizedTransport,
            baseURLs: [primary]
        )
        await assertSourceError(.malformedResponse) {
            _ = try await oversizedClient.fetchQuota(
                credentials: credentials(),
                deadline: AntigravityRPCDeadline()
            )
        }

        let redirectTransport = GoogleOAuthTransportStub()
        await redirectTransport.enqueue(
            host: "cloudcode-pa.googleapis.com",
            path: "/v1internal:loadCodeAssist",
            statusCode: 200,
            json: "{}",
            responseURL: URL(
                string:
                    "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
            )!
        )
        let redirectClient = makeClient(
            transport: redirectTransport,
            baseURLs: [primary]
        )
        await assertSourceError(.transportFailure) {
            _ = try await redirectClient.fetchQuota(
                credentials: credentials(),
                deadline: AntigravityRPCDeadline()
            )
        }
    }

    func testProductionConfigurationIsEphemeralAndStateFree() {
        let configuration =
            AntigravityGoogleOAuthURLSessionTransport
                .configuration(resourceTimeout: 7)

        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(
            configuration.connectionProxyDictionary?.count,
            0
        )
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertEqual(
            configuration.httpMaximumConnectionsPerHost,
            1
        )
        XCTAssertEqual(
            configuration.timeoutIntervalForRequest,
            7
        )
        XCTAssertEqual(
            configuration.timeoutIntervalForResource,
            7
        )
        XCTAssertEqual(
            AntigravityGoogleOAuthURLSessionTransport
                .defaultMaximumResponseBytes,
            2 * 1_024 * 1_024
        )
    }

    private func makeClient(
        transport: GoogleOAuthTransportStub,
        baseURLs: [URL]? = nil,
        tokenURL: URL? = nil
    ) -> AntigravityGoogleOAuthQuotaClient {
        let currentTime = fixedNow
        return AntigravityGoogleOAuthQuotaClient(
            transport: transport,
            baseURLs: baseURLs ?? [primary, daily],
            oauthTokenURL: tokenURL
                ?? URL(
                    string:
                        "https://oauth2.googleapis.com/token"
                )!,
            now: { currentTime }
        )
    }

    private func credentials(
        accessToken: String? = "access-old",
        refreshToken: String? = nil,
        expiryDate: Date? = nil,
        idToken: String? = nil,
        email: String? = "user@example.com",
        projectID: String? = "project-a",
        clientID: String? = nil,
        clientSecret: String? = nil
    ) -> AntigravityOAuthCredentials {
        AntigravityOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiryDate: expiryDate,
            idToken: idToken
                ?? makeIDToken(
                    subject: "subject-a",
                    email: "user@example.com"
                ),
            email: email,
            projectID: projectID,
            clientID: clientID,
            clientSecret: clientSecret
        )
    }

    private func enqueueCodeAssist(
        on transport: GoogleOAuthTransportStub,
        host: String,
        projectID: String
    ) async {
        await transport.enqueue(
            host: host,
            path: "/v1internal:loadCodeAssist",
            statusCode: 200,
            json: """
            {
              "planInfo": { "planType": "Paid" },
              "cloudaicompanionProject": {
                "projectId": "\(projectID)"
              }
            }
            """
        )
    }

    private func assertSourceError(
        _ expected: AntigravityUsageSourceError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as AntigravityUsageSourceError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func jsonString(
        _ data: Data?,
        key: String
    ) throws -> String? {
        let data = try XCTUnwrap(data)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )
        return object[key] as? String
    }

    private func formValues(
        _ data: Data?
    ) throws -> [String: String] {
        let data = try XCTUnwrap(data)
        let body = try XCTUnwrap(
            String(data: data, encoding: .utf8)
        )
        var components = URLComponents()
        components.percentEncodedQuery = body
        return Dictionary(
            uniqueKeysWithValues:
                (components.queryItems ?? []).compactMap {
                    item in
                    guard let value = item.value else {
                        return nil
                    }
                    return (item.name, value)
                }
        )
    }
}

private actor GoogleOAuthTransportStub:
    AntigravityGoogleOAuthHTTPTransport
{
    private struct Stub: Sendable {
        let host: String
        let path: String
        let statusCode: Int?
        let body: Data
        let responseURL: URL?
        let error:
            AntigravityGoogleOAuthHTTPTransportError?
    }

    private var stubs: [Stub] = []
    private var requests: [GoogleOAuthRecordedRequest] = []

    func enqueue(
        host: String,
        path: String,
        statusCode: Int,
        json: String,
        responseURL: URL? = nil
    ) {
        stubs.append(
            Stub(
                host: host,
                path: path,
                statusCode: statusCode,
                body: Data(json.utf8),
                responseURL: responseURL,
                error: nil
            )
        )
    }

    func enqueue(
        host: String,
        path: String,
        error: AntigravityGoogleOAuthHTTPTransportError
    ) {
        stubs.append(
            Stub(
                host: host,
                path: path,
                statusCode: nil,
                body: Data(),
                responseURL: nil,
                error: error
            )
        )
    }

    func response(
        for request: URLRequest,
        deadline: AntigravityRPCDeadline
    ) async throws -> AntigravityGoogleOAuthHTTPResponse {
        try deadline.check(.request)
        guard let url = request.url,
              !stubs.isEmpty
        else {
            throw AntigravityGoogleOAuthHTTPTransportError
                .transportFailure
        }
        let stub = stubs.removeFirst()
        guard url.host == stub.host,
              url.path == stub.path
        else {
            throw AntigravityGoogleOAuthHTTPTransportError
                .transportFailure
        }
        requests.append(
            GoogleOAuthRecordedRequest(
                host: url.host ?? "",
                path: url.path,
                authorization:
                    request.value(
                        forHTTPHeaderField: "Authorization"
                    ),
                contentType:
                    request.value(
                        forHTTPHeaderField: "Content-Type"
                    ),
                body: request.httpBody
            )
        )
        if let error = stub.error {
            throw error
        }
        guard let statusCode = stub.statusCode else {
            throw AntigravityGoogleOAuthHTTPTransportError
                .transportFailure
        }
        return AntigravityGoogleOAuthHTTPResponse(
            statusCode: statusCode,
            body: stub.body,
            url: stub.responseURL ?? url
        )
    }

    func recordedRequests()
        -> [GoogleOAuthRecordedRequest]
    {
        requests
    }
}

private struct GoogleOAuthRecordedRequest: Sendable {
    let host: String
    let path: String
    let authorization: String?
    let contentType: String?
    let body: Data?
}

private func makeIDToken(
    subject: String,
    email: String,
    hostedDomain: String? = nil
) -> String {
    var payload: [String: Any] = [
        "sub": subject,
        "email": email,
        "aud": "client-id",
    ]
    if let hostedDomain {
        payload["hd"] = hostedDomain
    }
    let data = try! JSONSerialization.data(
        withJSONObject: payload,
        options: [.sortedKeys]
    )
    let encoded = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "e30.\(encoded).signature"
}
