import XCTest
@testable import ClaudeUsage

final class AntigravityCLIUsageReportTests: XCTestCase {
    // MARK: - Captured AGY 1.2.12 output

    func testFiveHourAndWeeklyFixtureMapsAllFourLanes() throws {
        let summary = try AntigravityCLIUsageReportDecoder.decode(
            fixture("agy-1.2.12-print-usage-five-hour-and-weekly.json")
        )

        XCTAssertEqual(
            summary.lanes.map(\.id),
            [
                .geminiWeekly,
                .geminiFiveHour,
                .thirdPartyWeekly,
                .thirdPartyFiveHour,
            ])
        XCTAssertEqual(summary.lanes.map(\.cadence), [.weekly, .fiveHour, .weekly, .fiveHour])
        XCTAssertEqual(summary.lanes.compactMap(\.remainingFraction), [0.75, 0.5, 0.25, 1.0])
        XCTAssertEqual(summary.lanes.map(\.availability), Array(repeating: .available, count: 4))
        XCTAssertEqual(
            summary.lanes.map(\.resetAt),
            [
                "2030-01-07T00:00:00Z",
                "2030-01-01T05:00:00Z",
                "2030-01-07T00:00:00Z",
                "2030-01-01T05:00:00Z",
            ].map { ISO8601DateFormatter().date(from: $0) }
        )
        XCTAssertEqual(
            summary.lanes.first?.resetDescription,
            "Fixture reset description; live timing was removed."
        )
        XCTAssertTrue(summary.decodeIssues.isEmpty)
    }

    func testWeeklyOnlyFixtureDoesNotSynthesizeFiveHourLanes() throws {
        let summary = try AntigravityCLIUsageReportDecoder.decode(
            fixture("agy-1.2.12-print-usage-weekly-only.json")
        )

        XCTAssertEqual(summary.lanes.map(\.id), [.geminiWeekly, .thirdPartyWeekly])
        XCTAssertEqual(summary.lanes.first?.remainingFraction, 0.8720120191574097)
        XCTAssertEqual(summary.lanes.last?.remainingFraction, 1.0)
        XCTAssertTrue(summary.decodeIssues.isEmpty)
    }

    // MARK: - Envelope contract

    func testNonSuccessStatusIsReportFailure() {
        assertDecodeError(
            """
            { "status": "ERROR", "num_turns": 0, "error": "anything" }
            """,
            .reportFailed
        )
    }

    func testModelTurnIsRejectedEvenWhenTheEnvelopeLooksSuccessful() {
        assertDecodeError(
            """
            {
              "status": "SUCCESS",
              "num_turns": 1,
              "command": { "name": "usage", "data": { "groups": [] } }
            }
            """,
            .agentTurnStarted
        )
    }

    func testSpentTokensAreRejectedAsAModelTurn() {
        assertDecodeError(
            """
            {
              "status": "SUCCESS",
              "num_turns": 0,
              "usage": { "total_tokens": 12 },
              "response": "Your quota is ..."
            }
            """,
            .agentTurnStarted
        )
    }

    func testPromptAnswerWithoutCommandIsRejected() {
        assertDecodeError(
            """
            { "status": "SUCCESS", "response": "Here is your usage." }
            """,
            .unexpectedCommand
        )
    }

    func testOtherSlashCommandResultIsRejected() {
        assertDecodeError(
            """
            {
              "status": "SUCCESS",
              "num_turns": 0,
              "command": { "name": "model", "data": { "groups": [] } }
            }
            """,
            .unexpectedCommand
        )
    }

    func testMissingStatusIsRejected() {
        assertDecodeError(
            """
            { "num_turns": 0, "command": { "name": "usage", "data": { "groups": [] } } }
            """,
            .unexpectedCommand
        )
    }

    func testBooleanCountsAreNotReadAsTurns() throws {
        let summary = try AntigravityCLIUsageReportDecoder.decode(
            Data(
                """
                {
                  "status": "SUCCESS",
                  "num_turns": false,
                  "command": {
                    "name": "usage",
                    "data": {
                      "groups": [
                        {
                          "name": "Gemini Models",
                          "buckets": [
                            { "id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.5 }
                          ]
                        }
                      ]
                    }
                  }
                }
                """.utf8))

        XCTAssertEqual(summary.lanes.map(\.id), [.geminiWeekly])
    }

    func testInvalidJSONAndNonObjectRootAreRejected() {
        assertDecodeError("not json", .invalidJSON)
        assertDecodeError("[1, 2, 3]", .invalidJSON)
        assertDecodeError("", .invalidJSON)
    }

    func testQuotaDecoderFailuresAreCarried() {
        assertDecodeError(
            """
            { "status": "SUCCESS", "num_turns": 0, "command": { "name": "usage", "data": {} } }
            """,
            .quotaUnavailable(.missingQuotaGroups)
        )
        assertDecodeError(
            """
            {
              "status": "SUCCESS",
              "num_turns": 0,
              "command": { "name": "usage", "data": { "groups": [] } }
            }
            """,
            .quotaUnavailable(.noIdentifiableQuotaLanes)
        )
    }

    // MARK: - Version gate

    func testVersionIsReadFromCommonVersionOutputs() {
        XCTAssertEqual(AntigravityCLIVersion(versionOutput: "1.2.12\n"), version(1, 2, 12))
        XCTAssertEqual(AntigravityCLIVersion(versionOutput: "agy 1.2.12 (abc123)"), version(1, 2, 12))
        XCTAssertEqual(AntigravityCLIVersion(versionOutput: "v1.1.11"), version(1, 1, 11))
        XCTAssertEqual(AntigravityCLIVersion(versionOutput: "1.3.0-beta.2"), version(1, 3, 0))
        XCTAssertEqual(AntigravityCLIVersion(versionOutput: "1.2.3.4"), version(1, 2, 3))
    }

    func testUnrecognizedVersionOutputIsNil() {
        XCTAssertNil(AntigravityCLIVersion(versionOutput: ""))
        XCTAssertNil(AntigravityCLIVersion(versionOutput: "1.2"))
        XCTAssertNil(AntigravityCLIVersion(versionOutput: "1.2.x"))
        XCTAssertNil(AntigravityCLIVersion(versionOutput: "version unknown"))
        XCTAssertNil(AntigravityCLIVersion(versionOutput: "99999999999999999999.1.1"))
    }

    func testUsageReportRequiresAGY1_1_11OrNewer() {
        XCTAssertFalse(version(1, 1, 10).supportsUsageReport)
        XCTAssertFalse(version(1, 0, 99).supportsUsageReport)
        XCTAssertTrue(version(1, 1, 11).supportsUsageReport)
        XCTAssertTrue(version(1, 2, 0).supportsUsageReport)
        XCTAssertTrue(version(2, 0, 0).supportsUsageReport)
    }

    func testVersionsCompareNumericallyNotLexically() {
        XCTAssertLessThan(version(1, 2, 9), version(1, 2, 12))
        XCTAssertLessThan(version(9, 9, 9), version(10, 0, 0))
        XCTAssertEqual(version(1, 2, 12).description, "1.2.12")
    }

    // MARK: - Helpers

    private func version(_ major: Int, _ minor: Int, _ patch: Int) -> AntigravityCLIVersion {
        AntigravityCLIVersion(major: major, minor: minor, patch: patch)
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/Antigravity/\(name)"))
    }

    private func assertDecodeError(
        _ json: String,
        _ expected: AntigravityCLIUsageReportError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try AntigravityCLIUsageReportDecoder.decode(Data(json.utf8)),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? AntigravityCLIUsageReportError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
