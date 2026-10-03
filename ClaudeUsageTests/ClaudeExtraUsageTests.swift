import XCTest
@testable import ClaudeUsage

@MainActor
final class ClaudeExtraUsageTests: XCTestCase {
    func testExtraUsageUsesMinorUnitsAndSpendLimitFlag() throws {
        let usage = try decode(
            """
            {
              "five_hour": { "utilization": 10, "resets_at": null },
              "extra_usage": {
                "is_enabled": true, "monthly_limit": "5000", "used_credits": 5000,
                "currency": "USD", "decimal_places": 2, "spend_limit_reached": true
              }
            }
            """)
        let extra = try XCTUnwrap(usage.extraUsage)

        XCTAssertTrue(extra.isEnabled)
        XCTAssertEqual(extra.monthlyCreditLimit, 50)
        XCTAssertEqual(extra.formattedUsageLimitSummary, "$50.00 사용 / $50.00 한도 · 크레딧 소진")
    }

    func testMissingOrMalformedExtraUsageDoesNotBreakUsage() throws {
        XCTAssertNil(
            try decode(#"{ "five_hour": { "utilization": 1, "resets_at": null }, "extra_usage": null }"#).extraUsage)
        let malformed = try decode(#"{ "five_hour": { "utilization": 1, "resets_at": null }, "extra_usage": 3 }"#)
        XCTAssertNil(malformed.extraUsage)
        XCTAssertEqual(malformed.fiveHour?.utilization, 1)
    }

    func testClaudeCodePathTreatsAbsentExtraUsageAsNotEnabled() throws {
        let now = Date()
        let usage = try decode(#"{ "five_hour": { "utilization": 1, "resets_at": null } }"#)

        guard
            case .success(let value, let fetchedAt) = ClaudeRuntimeRefresher.embeddedSupplementalUsage(
                usage, fetchedAt: now)
        else { return XCTFail("expected success") }
        XCTAssertFalse(value.isEnabled)
        XCTAssertEqual(fetchedAt, now)
    }

    private func decode(_ json: String) throws -> ClaudeUsageResponse {
        try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
    }
}
