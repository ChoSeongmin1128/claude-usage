import XCTest
@testable import ClaudeUsage

@MainActor
final class CodexWindowDurationValidationTests: XCTestCase {
    private func decode(primary: String, secondary: String = "604800", credits: Bool = false) throws
        -> CodexUsageResponse
    {
        let creditJSON = credits ? #", "credits":{"has_credits":true,"unlimited":false,"balance":12}"# : ""
        let json =
            #"{"account_id":"fixture","rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":\#(primary)},"secondary_window":{"used_percent":41,"limit_window_seconds":\#(secondary)}}\#(creditJSON)}"#
        return try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
    }

    func testExplicitInvalidDurationDropsOnlyThatHTTPWindow() throws {
        for value in ["0", "-1", "true", "false", #""18000""#, #""bad""#, "1.5", "{}", "[]"] {
            let usage = try decode(primary: value)
            XCTAssertNil(usage.sessionWindow, value)
            XCTAssertEqual(usage.weeklyWindow?.usedPercent, 41, value)
            XCTAssertTrue(usage.rateLimit?.hasMalformedWindow == true, value)
            XCTAssertFalse(UsageLimitCatalog.codex(usage).contains { $0.periodSeconds == 18_000 }, value)
        }
    }

    func testPositiveDurationAndNullKeepExistingClassification() throws {
        XCTAssertEqual(try decode(primary: "18000").sessionWindow?.usedPercent, 20)
        let usage = try decode(primary: "null")
        XCTAssertEqual(usage.sessionWindow?.usedPercent, 20)
        XCTAssertNil(usage.sessionWindow?.limitWindowSeconds)
        XCTAssertFalse(usage.rateLimit?.hasMalformedWindow == true)
        let missing = #"{"account_id":"fixture","rate_limit":{"primary_window":{"used_percent":20}}}"#
        XCTAssertEqual(
            try JSONDecoder().decode(CodexUsageResponse.self, from: Data(missing.utf8)).sessionWindow?.usedPercent, 20)
    }

    func testAllInvalidWindowsStillKeepValidCredits() throws {
        let usage = try decode(primary: "0", secondary: "-1", credits: true)
        XCTAssertNil(usage.sessionWindow)
        XCTAssertNil(usage.weeklyWindow)
        XCTAssertEqual(usage.credits?.balance, 12)
        XCTAssertThrowsError(try decode(primary: "0", secondary: "-1"))
    }

    func testNativeInvalidDurationDoesNotBecomeMissing() throws {
        let values: [Any] = [0, -1, true, false, "300", "bad", [1], ["value": 300], 0.001]
        for value in values {
            let quota: [String: Any] = [
                "rateLimits": [
                    "primary": ["usedPercent": 20, "windowDurationMins": value],
                    "secondary": ["usedPercent": 41, "windowDurationMins": 10_080],
                ]
            ]
            let usage = try CodexHomeAccount.usageResponse(fromAppServer: quota)
            XCTAssertNil(usage.sessionWindow)
            XCTAssertEqual(usage.weeklyWindow?.usedPercent, 41)
            XCTAssertTrue(usage.rateLimit?.hasMalformedWindow == true)
        }
    }

    func testNativeMissingAndNullRemainLegacyCompatible() throws {
        for primary in [["usedPercent": 20], ["usedPercent": 20, "windowDurationMins": NSNull()]] as [[String: Any]] {
            let usage = try CodexHomeAccount.usageResponse(fromAppServer: ["rateLimits": ["primary": primary]])
            XCTAssertEqual(usage.sessionWindow?.usedPercent, 20)
            XCTAssertFalse(usage.rateLimit?.hasMalformedWindow == true)
        }
    }
}
