import Foundation
import XCTest
@testable import ClaudeUsage

final class AntigravityRemoteUsageServiceTests: XCTestCase {
    func testDefaultEndpointCandidatesPreferCloudCodeWhenRuntimeEndpointIsAbsent() {
        let candidates = AntigravityRemoteUsageService.defaultEndpointBaseURLCandidates(runningProcess: nil)

        XCTAssertEqual(candidates.map(\.host), [
            "cloudcode-pa.googleapis.com",
            "daily-cloudcode-pa.googleapis.com",
        ])
    }

    func testDefaultEndpointCandidatesKeepRuntimeEndpointFirst() {
        let runtimeEndpoint = AntigravityProcessSnapshot(
            pid: 42,
            command: "language_server",
            csrfToken: nil,
            extensionPort: nil,
            extensionCsrfToken: nil,
            httpsServerPort: nil,
            cloudCodeEndpoint: "https://daily-cloudcode-pa.googleapis.com"
        )

        let candidates = AntigravityRemoteUsageService.defaultEndpointBaseURLCandidates(
            runningProcess: runtimeEndpoint
        )

        XCTAssertEqual(candidates.map(\.host), [
            "daily-cloudcode-pa.googleapis.com",
            "cloudcode-pa.googleapis.com",
        ])
    }

    func testFetchUsageUsesStoredOAuthCredentialsAndFetchAvailableModels() async throws {
        let client = FakeAntigravityRemoteHTTPClient()
        await client.enqueue(
            path: "/v1internal:loadCodeAssist",
            statusCode: 200,
            json: """
            {
              "planInfo": { "planType": "Paid" },
              "cloudaicompanionProject": { "projectId": "project-1" }
            }
            """
        )
        await client.enqueue(
            path: "/v1internal:fetchAvailableModels",
            statusCode: 200,
            json: """
            {
              "models": {
                "claude-sonnet-4-5": {
                  "displayName": "Claude Sonnet 4.5",
                  "quotaInfo": {
                    "remainingFraction": 0.25,
                    "resetTime": "2026-05-21T00:00:00Z"
                  }
                },
                "gemini-3-pro-low": {
                  "displayName": "Gemini 3 Pro Low",
                  "quotaInfo": {
                    "remainingFraction": 0.5,
                    "resetTime": "2026-05-21T01:00:00Z"
                  }
                },
                "gemini-3-flash": {
                  "displayName": "Gemini 3 Flash",
                  "quotaInfo": {
                    "remainingFraction": 0.8,
                    "resetTime": "2026-05-21T02:00:00Z"
                  }
                }
              }
            }
            """
        )

        let service = AntigravityRemoteUsageService(
            httpClient: client,
            credentialProvider: {
                AntigravityOAuthCredentials(
                    accessToken: "access-token",
                    refreshToken: nil,
                    expiryDate: Date(timeIntervalSinceNow: 3_600),
                    email: "nathan@example.com"
                )
            },
            credentialProviderLabel: "unit-test"
        )

        let usage = try await service.fetchUsage()
        let requests = await client.recordedRequests()

        XCTAssertEqual(requests.map(\.path), [
            "/v1internal:loadCodeAssist",
            "/v1internal:fetchAvailableModels",
        ])
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer access-token")
        XCTAssertEqual(requests[0].headers["User-Agent"], "antigravity")
        XCTAssertEqual(try jsonBodyValue(requests[1].bodyData, key: "project"), "project-1")
        XCTAssertEqual(usage.source, .googleOAuth)
        XCTAssertEqual(usage.accountEmail, "nathan@example.com")
        XCTAssertEqual(usage.accountPlan, "Paid")
        XCTAssertEqual(usage.primaryWindow?.label, "Gemini 3 Pro Low")
        XCTAssertEqual(usage.primaryPercentage, 50, accuracy: 0.001)
        XCTAssertEqual(usage.secondaryWindow?.label, "Gemini 3 Flash")
        XCTAssertEqual(usage.secondaryPercentage, 20, accuracy: 0.001)
        XCTAssertEqual(usage.tertiaryWindow?.label, "Claude Sonnet 4.5")
        XCTAssertEqual(usage.tertiaryPercentage, 75, accuracy: 0.001)
    }

    func testFetchUsageFallsBackFromDailyEndpointToLegacyEndpointWhenUnavailable() async throws {
        let client = FakeAntigravityRemoteHTTPClient()
        await client.enqueue(
            path: "/v1internal:loadCodeAssist",
            statusCode: 500,
            json: "{}"
        )
        await client.enqueue(
            path: "/v1internal:loadCodeAssist",
            statusCode: 200,
            json: """
            {
              "planInfo": { "planType": "Paid" },
              "cloudaicompanionProject": { "projectId": "project-legacy" }
            }
            """
        )
        await client.enqueue(
            path: "/v1internal:fetchAvailableModels",
            statusCode: 200,
            json: """
            {
              "models": {
                "claude-sonnet-4-5": {
                  "displayName": "Claude Sonnet 4.5",
                  "quotaInfo": {
                    "remainingFraction": 0.25,
                    "resetTime": "2026-05-21T00:00:00Z"
                  }
                }
              }
            }
            """
        )

        let service = AntigravityRemoteUsageService(
            httpClient: client,
            credentialProvider: {
                AntigravityOAuthCredentials(
                    accessToken: "access-token",
                    refreshToken: nil,
                    expiryDate: Date(timeIntervalSinceNow: 3_600),
                    email: "nathan@example.com"
                )
            },
            credentialProviderLabel: "unit-test",
            endpointBaseURLProvider: {
                [
                    URL(string: "https://daily-cloudcode-pa.googleapis.com")!,
                    URL(string: "https://cloudcode-pa.googleapis.com")!,
                ]
            }
        )

        let usage = try await service.fetchUsage()
        let requests = await client.recordedRequests()

        XCTAssertEqual(requests.map(\.host), [
            "daily-cloudcode-pa.googleapis.com",
            "cloudcode-pa.googleapis.com",
            "cloudcode-pa.googleapis.com",
        ])
        XCTAssertEqual(requests.map(\.path), [
            "/v1internal:loadCodeAssist",
            "/v1internal:loadCodeAssist",
            "/v1internal:fetchAvailableModels",
        ])
        XCTAssertEqual(usage.tertiaryPercentage, 75, accuracy: 0.001)
    }

    func testFetchUsageTriesNextEndpointWhenFirstEndpointOnlyReturnsIdentity() async throws {
        let client = FakeAntigravityRemoteHTTPClient()
        await client.enqueue(
            path: "/v1internal:loadCodeAssist",
            statusCode: 200,
            json: """
            {
              "planInfo": { "planType": "Paid" },
              "cloudaicompanionProject": { "projectId": "project-daily" }
            }
            """
        )
        await client.enqueue(
            path: "/v1internal:fetchAvailableModels",
            statusCode: 403,
            json: #"{"error":"permission denied"}"#
        )
        await client.enqueue(
            path: "/v1internal:retrieveUserQuota",
            statusCode: 403,
            json: #"{"error":"permission denied"}"#
        )
        await client.enqueue(
            path: "/v1internal:loadCodeAssist",
            statusCode: 200,
            json: """
            {
              "planInfo": { "planType": "Paid" },
              "cloudaicompanionProject": { "projectId": "project-legacy" }
            }
            """
        )
        await client.enqueue(
            path: "/v1internal:fetchAvailableModels",
            statusCode: 200,
            json: """
            {
              "models": {
                "claude-sonnet-4-5": {
                  "displayName": "Claude Sonnet 4.5",
                  "quotaInfo": {
                    "remainingFraction": 0.25,
                    "resetTime": "2026-05-21T00:00:00Z"
                  }
                }
              }
            }
            """
        )

        let service = AntigravityRemoteUsageService(
            httpClient: client,
            credentialProvider: {
                AntigravityOAuthCredentials(
                    accessToken: "access-token",
                    refreshToken: nil,
                    expiryDate: Date(timeIntervalSinceNow: 3_600),
                    email: "nathan@example.com"
                )
            },
            credentialProviderLabel: "unit-test",
            endpointBaseURLProvider: {
                [
                    URL(string: "https://daily-cloudcode-pa.googleapis.com")!,
                    URL(string: "https://cloudcode-pa.googleapis.com")!,
                ]
            }
        )

        let usage = try await service.fetchUsage()
        let requests = await client.recordedRequests()

        XCTAssertEqual(requests.map(\.host), [
            "daily-cloudcode-pa.googleapis.com",
            "daily-cloudcode-pa.googleapis.com",
            "daily-cloudcode-pa.googleapis.com",
            "cloudcode-pa.googleapis.com",
            "cloudcode-pa.googleapis.com",
        ])
        XCTAssertEqual(requests.map(\.path), [
            "/v1internal:loadCodeAssist",
            "/v1internal:fetchAvailableModels",
            "/v1internal:retrieveUserQuota",
            "/v1internal:loadCodeAssist",
            "/v1internal:fetchAvailableModels",
        ])
        XCTAssertEqual(usage.tertiaryPercentage, 75, accuracy: 0.001)
        XCTAssertTrue(usage.hasUsageWindows)
    }

    func testFetchUsageAllowsIdentityOnlyResponseWhenQuotaModelsAreEmptyAndQuotaFallbackIsPermissionDenied() async throws {
        let client = FakeAntigravityRemoteHTTPClient()
        await client.enqueue(
            path: "/v1internal:loadCodeAssist",
            statusCode: 200,
            json: """
            {
              "planInfo": { "planType": "Paid" },
              "cloudaicompanionProject": { "projectId": "project-identity-only" }
            }
            """
        )
        await client.enqueue(
            path: "/v1internal:fetchAvailableModels",
            statusCode: 200,
            json: #"{"models":{}}"#
        )
        await client.enqueue(
            path: "/v1internal:retrieveUserQuota",
            statusCode: 403,
            json: #"{"error":"permission denied"}"#
        )

        let service = AntigravityRemoteUsageService(
            httpClient: client,
            credentialProvider: {
                AntigravityOAuthCredentials(
                    accessToken: "identity-token",
                    refreshToken: nil,
                    expiryDate: Date(timeIntervalSinceNow: 3_600),
                    email: "nathan@example.com"
                )
            },
            credentialProviderLabel: "unit-test",
            endpointBaseURLProvider: {
                [URL(string: "https://cloudcode-pa.googleapis.com")!]
            }
        )

        let usage = try await service.fetchUsage()
        let requests = await client.recordedRequests()

        XCTAssertEqual(requests.map(\.path), [
            "/v1internal:loadCodeAssist",
            "/v1internal:fetchAvailableModels",
            "/v1internal:retrieveUserQuota",
        ])
        XCTAssertEqual(usage.source, .googleOAuth)
        XCTAssertEqual(usage.accountEmail, "nathan@example.com")
        XCTAssertEqual(usage.accountPlan, "Paid")
        XCTAssertFalse(usage.hasUsageWindows)
        XCTAssertNil(usage.primaryWindow)
        XCTAssertNil(usage.secondaryWindow)
        XCTAssertNil(usage.tertiaryWindow)
    }

    func testFetchUsageFallsBackToRetrieveUserQuotaWhenAvailableModelsHasNoUsableUsageFraction() async throws {
        let client = FakeAntigravityRemoteHTTPClient()
        await client.enqueue(
            path: "/v1internal:loadCodeAssist",
            statusCode: 200,
            json: """
            {
              "planInfo": { "planType": "Paid" },
              "cloudaicompanionProject": { "projectId": "project-no-fraction" }
            }
            """
        )
        await client.enqueue(
            path: "/v1internal:fetchAvailableModels",
            statusCode: 200,
            json: """
            {
              "models": {
                "claude-sonnet-4-5": {
                  "displayName": "Claude Sonnet 4.5",
                  "quotaInfo": {
                    "resetTime": "2026-05-21T00:00:00Z"
                  }
                }
              }
            }
            """
        )
        await client.enqueue(
            path: "/v1internal:retrieveUserQuota",
            statusCode: 200,
            json: """
            {
              "buckets": [
                {
                  "modelId": "claude-sonnet-4-5",
                  "remainingFraction": 0.3,
                  "resetTime": "2026-05-21T00:30:00Z"
                }
              ]
            }
            """
        )

        let service = AntigravityRemoteUsageService(
            httpClient: client,
            credentialProvider: {
                AntigravityOAuthCredentials(
                    accessToken: "fallback-token",
                    refreshToken: nil,
                    expiryDate: Date(timeIntervalSinceNow: 3_600),
                    email: "nathan@example.com"
                )
            },
            credentialProviderLabel: "unit-test"
        )

        let usage = try await service.fetchUsage()
        let requests = await client.recordedRequests()

        XCTAssertEqual(requests.map(\.path), [
            "/v1internal:loadCodeAssist",
            "/v1internal:fetchAvailableModels",
            "/v1internal:retrieveUserQuota",
        ])
        XCTAssertEqual(try jsonBodyValue(requests[2].bodyData, key: "project"), "project-no-fraction")
        XCTAssertEqual(usage.source, .googleOAuth)
        XCTAssertEqual(usage.accountEmail, "nathan@example.com")
        XCTAssertEqual(usage.accountPlan, "Paid")
        XCTAssertNil(usage.primaryWindow)
        XCTAssertEqual(usage.tertiaryWindow?.modelID, "claude-sonnet-4-5")
        XCTAssertEqual(usage.tertiaryPercentage, 70, accuracy: 0.001)
    }

    func testFetchUsageRefreshesWhenOnlyRefreshTokenIsStored() async throws {
        let client = FakeAntigravityRemoteHTTPClient()
        await client.enqueue(
            path: "/token",
            statusCode: 200,
            json: """
            {
              "access_token": "fresh-access-token",
              "expires_in": 3600
            }
            """
        )
        await client.enqueue(
            path: "/v1internal:loadCodeAssist",
            statusCode: 200,
            json: """
            {
              "planInfo": { "planType": "Free" },
              "cloudaicompanionProject": { "projectId": "project-2" }
            }
            """
        )
        await client.enqueue(
            path: "/v1internal:fetchAvailableModels",
            statusCode: 200,
            json: """
            {
              "models": {
                "claude-sonnet-4-5": {
                  "displayName": "Claude Sonnet 4.5",
                  "quotaInfo": {
                    "remainingFraction": 0.7,
                    "resetTime": "2026-05-21T00:00:00Z"
                  }
                }
              }
            }
            """
        )

        let service = AntigravityRemoteUsageService(
            httpClient: client,
            credentialProvider: {
                AntigravityOAuthCredentials(
                    accessToken: nil,
                    refreshToken: "stored-refresh-token",
                    expiryDate: nil,
                    email: "nathan@example.com",
                    projectID: nil,
                    clientID: "client-id",
                    clientSecret: "client-secret"
                )
            },
            credentialProviderLabel: "unit-test"
        )

        let usage = try await service.fetchUsage()
        let requests = await client.recordedRequests()

        XCTAssertEqual(requests.map(\.path), [
            "/token",
            "/v1internal:loadCodeAssist",
            "/v1internal:fetchAvailableModels",
        ])
        XCTAssertTrue(String(data: try XCTUnwrap(requests[0].bodyData), encoding: .utf8)?.contains("refresh_token=stored-refresh-token") == true)
        XCTAssertEqual(requests[1].headers["Authorization"], "Bearer fresh-access-token")
        XCTAssertEqual(try jsonBodyValue(requests[2].bodyData, key: "project"), "project-2")
        XCTAssertEqual(usage.accountEmail, "nathan@example.com")
        XCTAssertEqual(usage.tertiaryPercentage, 30, accuracy: 0.001)
    }

    func testFetchUsageRefreshesAndRetriesWhenStoredAccessTokenIsRejected() async throws {
        let client = FakeAntigravityRemoteHTTPClient()
        await client.enqueue(
            path: "/v1internal:loadCodeAssist",
            statusCode: 401,
            json: #"{"error":"invalid_token"}"#
        )
        await client.enqueue(
            path: "/token",
            statusCode: 200,
            json: """
            {
              "access_token": "fresh-access-token",
              "expires_in": 3600
            }
            """
        )
        await client.enqueue(
            path: "/v1internal:loadCodeAssist",
            statusCode: 200,
            json: """
            {
              "planInfo": { "planType": "Paid" },
              "cloudaicompanionProject": { "projectId": "project-retry" }
            }
            """
        )
        await client.enqueue(
            path: "/v1internal:fetchAvailableModels",
            statusCode: 200,
            json: """
            {
              "models": {
                "claude-sonnet-4-5": {
                  "displayName": "Claude Sonnet 4.5",
                  "quotaInfo": {
                    "remainingFraction": 0.4,
                    "resetTime": "2026-05-21T00:00:00Z"
                  }
                }
              }
            }
            """
        )

        let service = AntigravityRemoteUsageService(
            httpClient: client,
            credentialProvider: {
                AntigravityOAuthCredentials(
                    accessToken: "stale-access-token",
                    refreshToken: "stored-refresh-token",
                    expiryDate: nil,
                    email: "nathan@example.com",
                    projectID: nil,
                    clientID: "client-id",
                    clientSecret: "client-secret"
                )
            },
            credentialProviderLabel: "unit-test"
        )

        let usage = try await service.fetchUsage()
        let requests = await client.recordedRequests()

        XCTAssertEqual(requests.map(\.path), [
            "/v1internal:loadCodeAssist",
            "/token",
            "/v1internal:loadCodeAssist",
            "/v1internal:fetchAvailableModels",
        ])
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer stale-access-token")
        XCTAssertTrue(String(data: try XCTUnwrap(requests[1].bodyData), encoding: .utf8)?.contains("refresh_token=stored-refresh-token") == true)
        XCTAssertEqual(requests[2].headers["Authorization"], "Bearer fresh-access-token")
        XCTAssertEqual(try jsonBodyValue(requests[3].bodyData, key: "project"), "project-retry")
        XCTAssertEqual(usage.source, .googleOAuth)
        XCTAssertEqual(usage.accountPlan, "Paid")
        XCTAssertEqual(usage.tertiaryPercentage, 60, accuracy: 0.001)
    }

    func testFetchUsageRetriesAlternateClientSecretWhenRefreshRejectsFirstSecret() async throws {
        let client = FakeAntigravityRemoteHTTPClient()
        await client.enqueue(
            path: "/token",
            statusCode: 401,
            json: #"{"error":"invalid_client","error_description":"bad secret"}"#
        )
        await client.enqueue(
            path: "/token",
            statusCode: 200,
            json: """
            {
              "access_token": "fresh-access-token",
              "expires_in": 3600
            }
            """
        )
        await client.enqueue(
            path: "/v1internal:loadCodeAssist",
            statusCode: 200,
            json: """
            {
              "planInfo": { "planType": "Free" },
              "cloudaicompanionProject": { "projectId": "project-2" }
            }
            """
        )
        await client.enqueue(
            path: "/v1internal:fetchAvailableModels",
            statusCode: 200,
            json: """
            {
              "models": {
                "claude-sonnet-4-5": {
                  "displayName": "Claude Sonnet 4.5",
                  "quotaInfo": {
                    "remainingFraction": 0.7,
                    "resetTime": "2026-05-21T00:00:00Z"
                  }
                }
              }
            }
            """
        )

        let service = AntigravityRemoteUsageService(
            httpClient: client,
            credentialProvider: {
                AntigravityOAuthCredentials(
                    accessToken: nil,
                    refreshToken: "stored-refresh-token",
                    expiryDate: nil,
                    email: "nathan@example.com"
                )
            },
            credentialProviderLabel: "unit-test",
            oauthClientProvider: {
                AntigravityOAuthClient(
                    clientID: "client-id",
                    clientSecret: "bad-secret",
                    clientSecretCandidates: ["bad-secret", "good-secret"]
                )
            }
        )

        let usage = try await service.fetchUsage()
        let requests = await client.recordedRequests()
        let firstBody = String(data: try XCTUnwrap(requests[0].bodyData), encoding: .utf8)
        let secondBody = String(data: try XCTUnwrap(requests[1].bodyData), encoding: .utf8)

        XCTAssertEqual(requests.map(\.path), [
            "/token",
            "/token",
            "/v1internal:loadCodeAssist",
            "/v1internal:fetchAvailableModels",
        ])
        XCTAssertTrue(firstBody?.contains("client_secret=bad-secret") == true)
        XCTAssertTrue(secondBody?.contains("client_secret=good-secret") == true)
        XCTAssertEqual(requests[2].headers["Authorization"], "Bearer fresh-access-token")
        XCTAssertEqual(usage.tertiaryPercentage, 30, accuracy: 0.001)
    }

    func testFetchUsageTriesPublicClientBeforeBundledSecret() async throws {
        let client = FakeAntigravityRemoteHTTPClient()
        await client.enqueue(
            path: "/token",
            statusCode: 400,
            json: #"{"error":"invalid_request","error_description":"client_secret is missing."}"#
        )
        await client.enqueue(
            path: "/token",
            statusCode: 200,
            json: """
            {
              "access_token": "fresh-access-token",
              "expires_in": 3600
            }
            """
        )
        await client.enqueue(
            path: "/v1internal:loadCodeAssist",
            statusCode: 200,
            json: """
            {
              "planInfo": { "planType": "Free" },
              "cloudaicompanionProject": { "projectId": "project-2" }
            }
            """
        )
        await client.enqueue(
            path: "/v1internal:fetchAvailableModels",
            statusCode: 200,
            json: """
            {
              "models": {
                "claude-sonnet-4-5": {
                  "displayName": "Claude Sonnet 4.5",
                  "quotaInfo": {
                    "remainingFraction": 0.7,
                    "resetTime": "2026-05-21T00:00:00Z"
                  }
                }
              }
            }
            """
        )

        let service = AntigravityRemoteUsageService(
            httpClient: client,
            credentialProvider: {
                AntigravityOAuthCredentials(
                    accessToken: nil,
                    refreshToken: "stored-refresh-token",
                    expiryDate: nil,
                    email: "nathan@example.com"
                )
            },
            credentialProviderLabel: "unit-test",
            oauthClientProvider: {
                AntigravityOAuthClient(
                    clientID: "client-id",
                    clientSecret: "bundled-secret",
                    clientSecretCandidates: ["bundled-secret"],
                    allowsPublicClient: true
                )
            }
        )

        let usage = try await service.fetchUsage()
        let requests = await client.recordedRequests()
        let publicBody = String(data: try XCTUnwrap(requests[0].bodyData), encoding: .utf8)
        let secretBody = String(data: try XCTUnwrap(requests[1].bodyData), encoding: .utf8)

        XCTAssertEqual(requests.map(\.path), [
            "/token",
            "/token",
            "/v1internal:loadCodeAssist",
            "/v1internal:fetchAvailableModels",
        ])
        XCTAssertTrue(publicBody?.contains("client_id=client-id") == true)
        XCTAssertFalse(publicBody?.contains("client_secret=") == true)
        XCTAssertTrue(secretBody?.contains("client_secret=bundled-secret") == true)
        XCTAssertEqual(requests[2].headers["Authorization"], "Bearer fresh-access-token")
        XCTAssertEqual(usage.tertiaryPercentage, 30, accuracy: 0.001)
    }

    func testFetchUsageMergesDiscoveredClientSecretCandidatesForStoredClient() async throws {
        let client = FakeAntigravityRemoteHTTPClient()
        await client.enqueue(
            path: "/token",
            statusCode: 401,
            json: #"{"error":"invalid_client","error_description":"bad secret"}"#
        )
        await client.enqueue(
            path: "/token",
            statusCode: 200,
            json: """
            {
              "access_token": "fresh-access-token",
              "expires_in": 3600
            }
            """
        )
        await client.enqueue(
            path: "/v1internal:loadCodeAssist",
            statusCode: 200,
            json: """
            {
              "planInfo": { "planType": "Free" },
              "cloudaicompanionProject": { "projectId": "project-2" }
            }
            """
        )
        await client.enqueue(
            path: "/v1internal:fetchAvailableModels",
            statusCode: 200,
            json: """
            {
              "models": {
                "claude-sonnet-4-5": {
                  "displayName": "Claude Sonnet 4.5",
                  "quotaInfo": {
                    "remainingFraction": 0.7,
                    "resetTime": "2026-05-21T00:00:00Z"
                  }
                }
              }
            }
            """
        )

        let service = AntigravityRemoteUsageService(
            httpClient: client,
            credentialProvider: {
                AntigravityOAuthCredentials(
                    accessToken: nil,
                    refreshToken: "stored-refresh-token",
                    expiryDate: nil,
                    email: "nathan@example.com",
                    projectID: nil,
                    clientID: "client-id",
                    clientSecret: "stale-secret"
                )
            },
            credentialProviderLabel: "unit-test",
            oauthClientProvider: {
                AntigravityOAuthClient(
                    clientID: "client-id",
                    clientSecret: "current-secret",
                    clientSecretCandidates: ["current-secret"]
                )
            }
        )

        let usage = try await service.fetchUsage()
        let requests = await client.recordedRequests()
        let firstBody = String(data: try XCTUnwrap(requests[0].bodyData), encoding: .utf8)
        let secondBody = String(data: try XCTUnwrap(requests[1].bodyData), encoding: .utf8)

        XCTAssertEqual(requests.map(\.path), [
            "/token",
            "/token",
            "/v1internal:loadCodeAssist",
            "/v1internal:fetchAvailableModels",
        ])
        XCTAssertTrue(firstBody?.contains("client_secret=stale-secret") == true)
        XCTAssertTrue(secondBody?.contains("client_secret=current-secret") == true)
        XCTAssertEqual(requests[2].headers["Authorization"], "Bearer fresh-access-token")
        XCTAssertEqual(usage.tertiaryPercentage, 30, accuracy: 0.001)
    }

    func testFetchUsageFallsBackToRetrieveUserQuotaWhenAvailableModelsIsPermissionDenied() async throws {
        let client = FakeAntigravityRemoteHTTPClient()
        await client.enqueue(
            path: "/v1internal:loadCodeAssist",
            statusCode: 200,
            json: """
            {
              "currentTier": { "id": "free-tier", "name": "Free" }
            }
            """
        )
        await client.enqueue(
            path: "/v1internal:fetchAvailableModels",
            statusCode: 403,
            json: #"{"error":"permission denied"}"#
        )
        await client.enqueue(
            path: "/v1internal:retrieveUserQuota",
            statusCode: 200,
            json: """
            {
              "buckets": [
                {
                  "modelId": "claude-sonnet-4-5",
                  "remainingFraction": 0.9,
                  "resetTime": "2026-05-21T00:00:00Z"
                },
                {
                  "modelId": "claude-sonnet-4-5",
                  "remainingFraction": 0.4,
                  "resetTime": "2026-05-21T00:30:00Z"
                },
                {
                  "modelId": "gemini-3-flash",
                  "remainingFraction": 0.6,
                  "resetTime": "2026-05-21T02:00:00Z"
                }
              ]
            }
            """
        )

        let service = AntigravityRemoteUsageService(
            httpClient: client,
            credentialProvider: {
                AntigravityOAuthCredentials(
                    accessToken: "fallback-token",
                    refreshToken: nil,
                    expiryDate: Date(timeIntervalSinceNow: 3_600),
                    email: nil,
                    projectID: "stored-project"
                )
            },
            credentialProviderLabel: "unit-test"
        )

        let usage = try await service.fetchUsage()
        let requests = await client.recordedRequests()

        XCTAssertEqual(requests.map(\.path), [
            "/v1internal:loadCodeAssist",
            "/v1internal:fetchAvailableModels",
            "/v1internal:retrieveUserQuota",
        ])
        XCTAssertEqual(try jsonBodyValue(requests[1].bodyData, key: "project"), "stored-project")
        XCTAssertEqual(try jsonBodyValue(requests[2].bodyData, key: "project"), "stored-project")
        XCTAssertEqual(usage.source, .googleOAuth)
        XCTAssertEqual(usage.accountPlan, "Free")
        XCTAssertNil(usage.primaryWindow)
        XCTAssertEqual(usage.secondaryWindow?.modelID, "gemini-3-flash")
        XCTAssertEqual(usage.secondaryPercentage, 40, accuracy: 0.001)
        XCTAssertEqual(usage.tertiaryWindow?.modelID, "claude-sonnet-4-5")
        XCTAssertEqual(usage.tertiaryPercentage, 60, accuracy: 0.001)
    }

    func testFetchUsageKeepsIdentityWhenQuotaEndpointsArePermissionDenied() async throws {
        let client = FakeAntigravityRemoteHTTPClient()
        await client.enqueue(
            path: "/v1internal:loadCodeAssist",
            statusCode: 200,
            json: """
            {
              "currentTier": { "id": "free-tier", "name": "Free" },
              "cloudaicompanionProject": { "projectId": "stored-project" }
            }
            """
        )
        await client.enqueue(
            path: "/v1internal:fetchAvailableModels",
            statusCode: 403,
            json: #"{"error":"permission denied"}"#
        )
        await client.enqueue(
            path: "/v1internal:retrieveUserQuota",
            statusCode: 403,
            json: #"{"error":"permission denied"}"#
        )

        let service = AntigravityRemoteUsageService(
            httpClient: client,
            credentialProvider: {
                AntigravityOAuthCredentials(
                    accessToken: "identity-only-token",
                    refreshToken: nil,
                    expiryDate: Date(timeIntervalSinceNow: 3_600),
                    email: "nathan@example.com"
                )
            },
            credentialProviderLabel: "unit-test",
            endpointBaseURLProvider: {
                [URL(string: "https://cloudcode-pa.googleapis.com")!]
            }
        )

        let usage = try await service.fetchUsage()
        let requests = await client.recordedRequests()

        XCTAssertEqual(requests.map(\.path), [
            "/v1internal:loadCodeAssist",
            "/v1internal:fetchAvailableModels",
            "/v1internal:retrieveUserQuota",
        ])
        XCTAssertEqual(usage.source, .googleOAuth)
        XCTAssertEqual(usage.accountEmail, "nathan@example.com")
        XCTAssertEqual(usage.accountPlan, "Free")
        XCTAssertFalse(usage.hasUsageWindows)
    }

    func testFetchUsageDoesNotFallbackToRetrieveUserQuotaForAvailableModelsServerError() async throws {
        let client = FakeAntigravityRemoteHTTPClient()
        await client.enqueue(
            path: "/v1internal:loadCodeAssist",
            statusCode: 200,
            json: """
            {
              "currentTier": { "id": "free-tier", "name": "Free" }
            }
            """
        )
        await client.enqueue(
            path: "/v1internal:fetchAvailableModels",
            statusCode: 500,
            json: "{}"
        )

        let service = AntigravityRemoteUsageService(
            httpClient: client,
            credentialProvider: {
                AntigravityOAuthCredentials(
                    accessToken: "server-error-token",
                    refreshToken: nil,
                    expiryDate: Date(timeIntervalSinceNow: 3_600),
                    email: nil,
                    projectID: "stored-project"
                )
            },
            credentialProviderLabel: "unit-test",
            endpointBaseURLProvider: {
                [URL(string: "https://daily-cloudcode-pa.googleapis.com")!]
            }
        )

        do {
            _ = try await service.fetchUsage()
            XCTFail("Expected server error")
        } catch let error as APIError {
            guard case .serverError(500) = error else {
                return XCTFail("Expected serverError(500), got \(error)")
            }
        }

        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.map(\.path), [
            "/v1internal:loadCodeAssist",
            "/v1internal:fetchAvailableModels",
        ])
    }

    private func jsonBodyValue(_ data: Data?, key: String) throws -> String? {
        let data = try XCTUnwrap(data)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return json[key] as? String
    }
}

private actor FakeAntigravityRemoteHTTPClient: AntigravityRemoteUsageHTTPClient {
    private var responses: [String: [StubResponse]] = [:]
    private var requests: [RecordedRequest] = []

    func enqueue(path: String, statusCode: Int, json: String) {
        let data = Data(json.utf8)
        responses[path, default: []].append(StubResponse(statusCode: statusCode, data: data))
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let path = url.path
        requests.append(RecordedRequest(
            path: path,
            host: url.host,
            headers: request.allHTTPHeaderFields ?? [:],
            bodyData: request.httpBody
        ))

        guard var queue = responses[path], !queue.isEmpty else {
            throw APIError.networkError("Missing fake response for \(path)")
        }
        let response = queue.removeFirst()
        responses[path] = queue
        let http = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: nil
        ))
        return (response.data, http)
    }

    func recordedRequests() -> [RecordedRequest] {
        requests
    }

    private struct StubResponse: Sendable {
        let statusCode: Int
        let data: Data
    }
}

private struct RecordedRequest: Sendable {
    let path: String
    let host: String?
    let headers: [String: String]
    let bodyData: Data?
}
