import XCTest
@testable import ClaudeUsage

final class AntigravityLocalUsageParsingTests: XCTestCase {
    func testUserStatusResponseParsesIdentityPlanAndModelQuotas() throws {
        let response = try AntigravityLocalUsageParsing.userStatusResponse(from: data("""
        {
          "code": "OK",
          "userStatus": {
            "email": " nathan@example.com ",
            "userTier": {
              "displayName": " Antigravity Pro ",
              "name": "fallback"
            },
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {
                  "label": "Claude Sonnet",
                  "modelOrAlias": { "model": "claude-sonnet-4.5" },
                  "quotaInfo": {
                    "remainingFraction": 0.4,
                    "resetTime": "2026-05-20T10:00:00Z"
                  }
                },
                {
                  "label": "Gemini 2.5 Pro",
                  "modelOrAlias": { "model": "gemini-2.5-pro" },
                  "quotaInfo": {
                    "remainingFraction": 0.75,
                    "resetTime": "1779271200"
                  }
                }
              ]
            }
          }
        }
        """))

        XCTAssertEqual(response.source, .localIDE)
        XCTAssertEqual(response.accountEmail, "nathan@example.com")
        XCTAssertEqual(response.accountPlan, "Antigravity Pro")
        XCTAssertEqual(response.primaryWindow?.label, "Gemini 2.5 Pro")
        XCTAssertEqual(response.primaryPercentage, 25, accuracy: 0.001)
        XCTAssertNil(response.secondaryWindow)
        XCTAssertEqual(response.tertiaryWindow?.label, "Claude Sonnet")
        XCTAssertEqual(response.tertiaryPercentage, 60, accuracy: 0.001)
        XCTAssertNotNil(response.primaryWindow?.resetAtISO)
    }

    func testUserStatusResponseFallsBackToPlanInfoName() throws {
        let response = try AntigravityLocalUsageParsing.userStatusResponse(from: data("""
        {
          "code": 0,
          "userStatus": {
            "email": "nathan@example.com",
            "planStatus": {
              "planInfo": {
                "planDisplayName": " Workspace ",
                "planName": "free-tier"
              }
            }
          }
        }
        """))

        XCTAssertEqual(response.accountPlan, "Workspace")
        XCTAssertFalse(response.hasUsageWindows)
    }

    func testCommandModelResponseUsesModelIDWhenLabelIsMissing() throws {
        let response = try AntigravityLocalUsageParsing.commandModelResponse(from: data("""
        {
          "code": "success",
          "clientModelConfigs": [
            {
              "modelOrAlias": { "model": "custom-model" },
              "quotaInfo": {
                "remainingFraction": 0.25,
                "resetTime": ""
              }
            },
            {
              "label": "ignored",
              "quotaInfo": {
                "remainingFraction": 0.1
              }
            }
          ]
        }
        """))

        XCTAssertNil(response.accountEmail)
        XCTAssertNil(response.accountPlan)
        XCTAssertEqual(response.primaryWindow?.label, "custom-model")
        XCTAssertEqual(response.primaryPercentage, 75, accuracy: 0.001)
        XCTAssertNil(response.primaryWindow?.resetAtISO)
    }

    func testResponseCodeAcceptsKnownOKForms() throws {
        for code in ["\"ok\"", "\"success\"", "\"0\"", "0"] {
            XCTAssertNoThrow(try AntigravityLocalUsageParsing.commandModelResponse(from: data("""
            {
              "code": \(code),
              "clientModelConfigs": []
            }
            """)))
        }
    }

    func testNonOKResponseCodeThrowsUnknownError() {
        XCTAssertThrowsError(try AntigravityLocalUsageParsing.userStatusResponse(from: data("""
        {
          "code": "permission_denied",
          "userStatus": {}
        }
        """))) { error in
            guard case APIError.unknownError(let message) = error else {
                return XCTFail("Expected unknownError, got \(error)")
            }
            XCTAssertEqual(message, "Antigravity 응답 코드 permission_denied")
        }
    }

    func testUserStatusWithoutPayloadThrowsParseError() {
        XCTAssertThrowsError(try AntigravityLocalUsageParsing.userStatusResponse(from: data("""
        {
          "code": "ok"
        }
        """))) { error in
            guard case APIError.parseError = error else {
                return XCTFail("Expected parseError, got \(error)")
            }
        }
    }

    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }
}
