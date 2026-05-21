import XCTest
@testable import ClaudeUsage

final class AntigravityRemoteUsageParsingTests: XCTestCase {
    func testClaimsPreferIDTokenEmailAndHostedDomain() throws {
        let credentials = AntigravityOAuthCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiryDate: nil,
            idToken: try makeIDToken(email: "token@example.com", hostedDomain: "example.com"),
            email: "stored@example.com",
            projectID: nil,
            clientID: nil,
            clientSecret: nil
        )

        let claims = AntigravityRemoteUsageParsing.claims(from: credentials)

        XCTAssertEqual(claims.email, "token@example.com")
        XCTAssertEqual(claims.hostedDomain, "example.com")
    }

    func testPlanUsesWorkspaceForHostedDomainFreeTier() {
        let response = AntigravityCodeAssistResponse(
            planInfo: nil,
            currentTier: AntigravityTierInfo(id: "free-tier", name: "free"),
            paidTier: nil,
            allowedTiers: nil,
            cloudaicompanionProject: nil
        )

        let plan = AntigravityRemoteUsageParsing.plan(
            from: response,
            claims: .init(email: "user@example.com", hostedDomain: "example.com")
        )

        XCTAssertEqual(plan, "Workspace")
    }

    func testQuotaBucketsKeepMostConstrainedDuplicateModel() throws {
        let response = AntigravityRetrieveUserQuotaResponse(buckets: [
            AntigravityRetrieveUserQuotaBucket(
                modelId: "gemini-3-pro",
                remainingFraction: 0.8,
                resetTime: "2026-05-20T10:00:00Z"
            ),
            AntigravityRetrieveUserQuotaBucket(
                modelId: "gemini-3-pro",
                remainingFraction: 0.2,
                resetTime: "2026-05-20T11:00:00Z"
            ),
            AntigravityRetrieveUserQuotaBucket(
                modelId: " ",
                remainingFraction: 0.1,
                resetTime: nil
            ),
        ])

        let quotas = try AntigravityRemoteUsageParsing.quotaBuckets(from: response)

        XCTAssertEqual(quotas.count, 1)
        XCTAssertEqual(quotas.first?.modelID, "gemini-3-pro")
        XCTAssertEqual(quotas.first?.remainingFraction, 0.2)
        XCTAssertEqual(quotas.first?.resetAtISO, "2026-05-20T11:00:00Z")
    }

    func testQuotaBucketsRejectMissingOrEmptyBuckets() {
        XCTAssertThrowsError(
            try AntigravityRemoteUsageParsing.quotaBuckets(
                from: AntigravityRetrieveUserQuotaResponse(buckets: nil)
            )
        )
        XCTAssertThrowsError(
            try AntigravityRemoteUsageParsing.quotaBuckets(
                from: AntigravityRetrieveUserQuotaResponse(buckets: [])
            )
        )
    }

    func testQuotaBucketsRejectBucketsWithoutValidModelIDs() {
        XCTAssertThrowsError(
            try AntigravityRemoteUsageParsing.quotaBuckets(
                from: AntigravityRetrieveUserQuotaResponse(buckets: [
                    AntigravityRetrieveUserQuotaBucket(
                        modelId: " ",
                        remainingFraction: 0.2,
                        resetTime: "2026-05-20T11:00:00Z"
                    ),
                ])
            )
        )
    }

    func testProjectReferenceDecodesStringAndObjectForms() throws {
        let stringData = #"{"cloudaicompanionProject":"project-string"}"#.data(using: .utf8)!
        let objectData = #"{"cloudaicompanionProject":{"projectId":"project-object"}}"#.data(using: .utf8)!

        let stringResponse = try JSONDecoder().decode(AntigravityCodeAssistResponse.self, from: stringData)
        let objectResponse = try JSONDecoder().decode(AntigravityCodeAssistResponse.self, from: objectData)

        XCTAssertEqual(stringResponse.projectID, "project-string")
        XCTAssertEqual(objectResponse.projectID, "project-object")
    }

    func testOnboardTierPrefersDefaultAllowedTier() {
        let response = AntigravityCodeAssistResponse(
            planInfo: nil,
            currentTier: AntigravityTierInfo(id: "free-tier", name: "free"),
            paidTier: AntigravityTierInfo(id: "paid-tier", name: "paid"),
            allowedTiers: [
                AntigravityAllowedTier(id: "first-tier", isDefault: false),
                AntigravityAllowedTier(id: "default-tier", isDefault: true),
            ],
            cloudaicompanionProject: nil
        )

        XCTAssertEqual(AntigravityRemoteUsageParsing.onboardTier(from: response), "default-tier")
    }

    private func makeIDToken(email: String, hostedDomain: String) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "hd": hostedDomain,
        ])
        let encodedPayload = payload
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encodedPayload).signature"
    }
}
