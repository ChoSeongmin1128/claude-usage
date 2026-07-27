import XCTest
@testable import ClaudeUsage

final class AntigravityQuotaSummaryDecoderTests: XCTestCase {
    func testSanitizedAGY117FixtureMapsObservedFourLanes() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Antigravity/agy-1.1.7-quota-summary.json")
        let summary = try AntigravityQuotaSummaryDecoder.decode(Data(contentsOf: fixtureURL))

        XCTAssertEqual(summary.lanes.map(\.id), [
            .geminiWeekly,
            .geminiFiveHour,
            .thirdPartyWeekly,
            .thirdPartyFiveHour,
        ])
        XCTAssertEqual(summary.lanes.map(\.scope), [
            .gemini,
            .gemini,
            .thirdPartyModels,
            .thirdPartyModels,
        ])
        XCTAssertEqual(summary.lanes.map(\.cadence), [
            .weekly,
            .fiveHour,
            .weekly,
            .fiveHour,
        ])
        XCTAssertEqual(summary.lanes.compactMap(\.remainingFraction), [0.75, 0.5, 0.25, 1.0])
        XCTAssertEqual(
            summary.lanes[2].resetDescription,
            "Fixture reset description; live timing was removed."
        )
        XCTAssertTrue(summary.lanes.allSatisfy { $0.resetAt != nil })
        XCTAssertTrue(summary.decodeIssues.isEmpty)
    }

    func testCanonicalGroupCadenceLanesPreserveFractionPrecision() throws {
        let summary = try decode("""
        {
          "response": {
            "description": "Grouped quota",
            "groups": [
              {
                "groupId": "gemini",
                "displayName": "Gemini Models",
                "buckets": [
                  {
                    "bucketId": "gemini-5h",
                    "displayName": "Five Hour Limit",
                    "window": "5h",
                    "remainingFraction": 0.123456789012345,
                    "resetTime": "2026-06-15T11:39:34Z"
                  },
                  {
                    "bucketId": "gemini-weekly",
                    "displayName": "Weekly Limit",
                    "window": "weekly",
                    "remaining": { "remainingFraction": 0.82 }
                  }
                ]
              },
              {
                "groupId": "third-party",
                "displayName": "Claude and GPT models",
                "buckets": [
                  {
                    "bucketId": "3p-5h",
                    "window": "5-hour",
                    "remaining": { "case": "remainingFraction", "value": 0.73 }
                  },
                  {
                    "bucketId": "3p-weekly",
                    "window": "weekly",
                    "remainingFraction": 0.64
                  }
                ]
              }
            ]
          }
        }
        """)

        XCTAssertEqual(summary.description, "Grouped quota")
        XCTAssertEqual(summary.lanes.map(\.id), [
            .geminiFiveHour,
            .geminiWeekly,
            .thirdPartyFiveHour,
            .thirdPartyWeekly,
        ])
        XCTAssertEqual(summary.lanes.map(\.scope), [
            .gemini,
            .gemini,
            .thirdPartyModels,
            .thirdPartyModels,
        ])
        XCTAssertEqual(summary.lanes.map(\.cadence), [
            .fiveHour,
            .weekly,
            .fiveHour,
            .weekly,
        ])
        XCTAssertEqual(
            try XCTUnwrap(summary.lanes[0].remainingFraction),
            0.123456789012345,
            accuracy: 0
        )
        XCTAssertEqual(try XCTUnwrap(summary.lanes[1].remainingFraction), 0.82, accuracy: 0)
        XCTAssertNotNil(summary.lanes[0].resetAt)
        XCTAssertTrue(summary.decodeIssues.isEmpty)
    }

    func testAcceptsRootResponseAndSummaryEnvelopes() throws {
        let payload = """
        {
          "groups": [
            {
              "displayName": "Gemini Models",
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
        """
        let documents = [
            payload,
            #"{"response":\#(payload)}"#,
            #"{"summary":\#(payload)}"#,
            #"{"response":{"summary":\#(payload)}}"#,
        ]

        for document in documents {
            let summary = try decode(document)
            XCTAssertEqual(summary.lanes.map(\.id), [.geminiFiveHour])
        }
    }

    func testWindowTakesPriorityOverConflictingBucketText() throws {
        let summary = try decode("""
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                {
                  "bucketId": "gemini-5h",
                  "displayName": "Five Hour Limit",
                  "window": "weekly",
                  "remainingFraction": 0.4
                }
              ]
            }
          ]
        }
        """)

        XCTAssertEqual(summary.lanes.first?.cadence, .weekly)
        XCTAssertEqual(summary.lanes.first?.id, .geminiWeekly)
    }

    func testFallsBackToBucketIDThenDisplayNameWhenWindowIsAbsent() throws {
        let summary = try decode("""
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                {
                  "bucketId": "gemini-session",
                  "displayName": "Current",
                  "remainingFraction": 0.7
                },
                {
                  "bucketId": "gemini-future",
                  "displayName": "Weekly Limit",
                  "remainingFraction": 0.6
                }
              ]
            }
          ]
        }
        """)

        XCTAssertEqual(summary.lanes.map(\.cadence), [.fiveHour, .weekly])
    }

    func testUnknownGroupAndCadenceArePreservedWithoutSynthesizingKnownLanes() throws {
        let summary = try decode("""
        {
          "groups": [
            {
              "groupId": "experimental-pool",
              "displayName": "Experimental Models",
              "buckets": [
                {
                  "bucketId": "rolling-limit",
                  "window": "rolling-30d",
                  "remainingFraction": 0.3333333333333333
                }
              ]
            }
          ]
        }
        """)

        XCTAssertEqual(
            summary.lanes.first?.scope,
            .unknown(id: "experimental-pool", label: "Experimental Models")
        )
        XCTAssertEqual(summary.lanes.first?.cadence, .unknown(rawValue: "rolling-30d"))
        XCTAssertTrue(summary.lanes.first?.id.rawValue.hasPrefix("unknown.") == true)
        XCTAssertEqual(summary.lanes.count, 1)
    }

    func testUnknownLaneIDDoesNotChangeWhenDisplayLabelChangesButGroupIDIsStable() throws {
        func fixture(label: String) -> String {
            """
            {
              "groups": [
                {
                  "groupId": "experimental-pool",
                  "displayName": "\(label)",
                  "buckets": [
                    {
                      "bucketId": "rolling-limit",
                      "window": "rolling-30d",
                      "remainingFraction": 0.4
                    }
                  ]
                }
              ]
            }
            """
        }

        let before = try decode(fixture(label: "Experimental Models"))
        let after = try decode(fixture(label: "Renamed Experimental Models"))

        XCTAssertEqual(before.lanes.first?.id, after.lanes.first?.id)
    }

    func testExplicitUnknownGroupDoesNotBecomeGeminiFromBucketName() throws {
        let summary = try decode("""
        {
          "groups": [
            {
              "groupId": "experimental",
              "displayName": "Experimental Models",
              "buckets": [
                {
                  "bucketId": "gemini-5h",
                  "remainingFraction": 0.5
                }
              ]
            }
          ]
        }
        """)

        XCTAssertEqual(
            summary.lanes.first?.scope,
            .unknown(id: "experimental", label: "Experimental Models")
        )
        XCTAssertEqual(summary.lanes.first?.cadence, .fiveHour)
    }

    func testDisabledAndMissingFractionRemainDistinctStates() throws {
        let summary = try decode("""
        {
          "groups": [
            {
              "groupId": "experimental",
              "buckets": [
                {
                  "bucketId": "disabled",
                  "window": "disabled-window",
                  "disabled": true
                },
                {
                  "bucketId": "available-missing",
                  "window": "available-window",
                  "disabled": false
                },
                {
                  "bucketId": "unknown-missing",
                  "window": "unknown-window"
                }
              ]
            }
          ]
        }
        """)

        XCTAssertEqual(summary.lanes.map(\.availability), [.disabled, .available, .unknown])
        XCTAssertEqual(
            summary.decodeIssues.filter { $0.kind == .missingRemainingFraction }.count,
            2
        )
        XCTAssertNil(summary.lanes[0].remainingFraction)
        XCTAssertTrue(summary.isPartial)
    }

    func testInvalidDisabledValueDoesNotClaimLaneIsAvailable() throws {
        let summary = try decode("""
        {
          "groups": [
            {
              "groupId": "experimental",
              "buckets": [
                {
                  "bucketId": "invalid-disabled",
                  "window": "custom",
                  "remainingFraction": 0.75,
                  "disabled": "false"
                }
              ]
            }
          ]
        }
        """)

        XCTAssertEqual(summary.lanes.first?.availability, .unknown)
        XCTAssertTrue(summary.decodeIssues.contains { $0.kind == .invalidDisabledValue })
        XCTAssertTrue(summary.isPartial)
    }

    func testMissingResetIsAllowedButInvalidResetProducesPartialIssue() throws {
        let summary = try decode("""
        {
          "groups": [
            {
              "groupId": "experimental",
              "buckets": [
                {
                  "bucketId": "missing-reset",
                  "window": "missing",
                  "remainingFraction": 0.8
                },
                {
                  "bucketId": "invalid-reset",
                  "window": "invalid",
                  "remainingFraction": 0.7,
                  "resetTime": "tomorrow-ish"
                },
                {
                  "bucketId": "epoch-reset",
                  "window": "epoch",
                  "remainingFraction": 0.6,
                  "resetTime": 1781523574
                }
              ]
            }
          ]
        }
        """)

        XCTAssertNil(summary.lanes[0].resetAt)
        XCTAssertNil(summary.lanes[1].resetAt)
        XCTAssertEqual(
            summary.lanes[2].resetAt,
            Date(timeIntervalSince1970: 1_781_523_574)
        )
        XCTAssertEqual(
            summary.decodeIssues.filter { $0.kind == .invalidResetTime }.map(\.upstreamBucketID),
            ["invalid-reset"]
        )
    }

    func testMalformedBucketFieldPreservesOtherLanesAndRecordsDecodeIssues() throws {
        let summary = try decode("""
        {
          "groups": [
            {
              "groupId": "experimental",
              "buckets": [
                {
                  "bucketId": "valid",
                  "window": "valid-window",
                  "remainingFraction": 0.4567890123456789
                },
                {
                  "bucketId": "invalid-fraction",
                  "window": "invalid-window",
                  "remainingFraction": "0.2"
                },
                {
                  "displayName": "Missing ID",
                  "remainingFraction": 0.5
                }
              ]
            }
          ]
        }
        """)

        XCTAssertEqual(summary.lanes.count, 2)
        XCTAssertEqual(
            try XCTUnwrap(summary.lanes.first?.remainingFraction),
            0.4567890123456789,
            accuracy: 0
        )
        XCTAssertNil(summary.lanes[1].remainingFraction)
        XCTAssertTrue(summary.decodeIssues.contains {
            $0.kind == .invalidRemainingFraction && $0.upstreamBucketID == "invalid-fraction"
        })
        XCTAssertTrue(summary.decodeIssues.contains { $0.kind == .missingBucketID })
    }

    func testOutOfRangeFractionsAreInvalidAndNeverClampedToZero() throws {
        let summary = try decode("""
        {
          "groups": [
            {
              "groupId": "experimental",
              "buckets": [
                {
                  "bucketId": "negative",
                  "window": "negative-window",
                  "remainingFraction": -0.0001
                },
                {
                  "bucketId": "over-one",
                  "window": "over-one-window",
                  "remainingFraction": 1.0001
                },
                {
                  "bucketId": "zero-boundary",
                  "window": "zero-window",
                  "remainingFraction": 0
                },
                {
                  "bucketId": "one-boundary",
                  "window": "one-window",
                  "remainingFraction": 1
                }
              ]
            }
          ]
        }
        """)

        let lanes = Dictionary(uniqueKeysWithValues: summary.lanes.map {
            ($0.upstreamBucketID, $0)
        })
        XCTAssertNil(lanes["negative"]?.remainingFraction)
        XCTAssertNil(lanes["over-one"]?.remainingFraction)
        XCTAssertEqual(lanes["negative"]?.availability, .unknown)
        XCTAssertEqual(lanes["over-one"]?.availability, .unknown)
        XCTAssertEqual(lanes["zero-boundary"]?.remainingFraction, 0)
        XCTAssertEqual(lanes["one-boundary"]?.remainingFraction, 1)
        XCTAssertEqual(
            summary.decodeIssues.filter { $0.kind == .invalidRemainingFraction }.count,
            2
        )
    }

    func testMissingAndNonArrayBucketsArePartialWhenAnotherGroupIsValid() throws {
        let summary = try decode("""
        {
          "groups": [
            {
              "groupId": "missing-buckets"
            },
            {
              "groupId": "invalid-buckets",
              "buckets": "not-an-array"
            },
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
        """)

        XCTAssertEqual(summary.lanes.map(\.id), [.geminiFiveHour])
        XCTAssertTrue(summary.decodeIssues.contains { $0.kind == .missingBuckets })
        XCTAssertTrue(summary.decodeIssues.contains { $0.kind == .invalidBucketsShape })
        XCTAssertTrue(summary.isPartial)
    }

    func testInvalidWindowUsesDedicatedIssueAndDoesNotFallBackToBucketText() throws {
        let summary = try decode("""
        {
          "groups": [
            {
              "groupId": "gemini",
              "buckets": [
                {
                  "bucketId": "gemini-weekly",
                  "window": { "value": "5h" },
                  "remainingFraction": 0.5
                }
              ]
            }
          ]
        }
        """)

        XCTAssertEqual(summary.lanes.first?.cadence, .unknown(rawValue: "invalid"))
        XCTAssertNotEqual(summary.lanes.first?.id, .geminiWeekly)
        XCTAssertTrue(summary.decodeIssues.contains { $0.kind == .invalidWindow })
    }

    func testUnsupportedOneofShapeIsPartialInsteadOfZeroUsage() throws {
        let summary = try decode("""
        {
          "groups": [
            {
              "groupId": "experimental",
              "buckets": [
                {
                  "bucketId": "unsupported",
                  "window": "rolling",
                  "remaining": { "case": "resetTime", "value": 0.4 }
                }
              ]
            }
          ]
        }
        """)

        XCTAssertNil(summary.lanes.first?.remainingFraction)
        XCTAssertEqual(summary.lanes.first?.availability, .unknown)
        XCTAssertTrue(summary.decodeIssues.contains {
            $0.kind == .unsupportedRemainingShape
        })
    }

    func testStableIDCollisionKeepsCanonicalBucketAndUsesDeterministicDerivedID() throws {
        let first = try decode(collisionFixture(bucketOrder: ["alias", "canonical"]))
        let second = try decode(collisionFixture(bucketOrder: ["canonical", "alias"]))
        let firstIDs = Dictionary(uniqueKeysWithValues: first.lanes.map {
            ($0.upstreamBucketID, $0.id)
        })
        let secondIDs = Dictionary(uniqueKeysWithValues: second.lanes.map {
            ($0.upstreamBucketID, $0.id)
        })

        XCTAssertEqual(firstIDs, secondIDs)
        XCTAssertEqual(firstIDs["gemini-5h"], .geminiFiveHour)
        XCTAssertTrue(firstIDs["gemini-session"]?.rawValue.hasPrefix(
            "gemini.fiveHour.collision."
        ) == true)
        XCTAssertEqual(Set(first.lanes.map(\.id)).count, 2)
        XCTAssertTrue(first.decodeIssues.contains {
            $0.kind == .stableIDCollision(canonicalID: .geminiFiveHour)
                && $0.upstreamBucketID == "gemini-session"
        })
        XCTAssertEqual(first.decodeIssues, second.decodeIssues)
    }

    func testCollisionAndDuplicateIssueOrderIsStableAcrossReversedBuckets() throws {
        let bucketOrder = [
            "five-hour-alias",
            "weekly-canonical",
            "five-hour-canonical",
            "weekly-alias",
            "weekly-duplicate",
        ]
        let first = try decode(multiCollisionFixture(bucketOrder: bucketOrder))
        let second = try decode(multiCollisionFixture(bucketOrder: bucketOrder.reversed()))

        let firstIDs = Dictionary(uniqueKeysWithValues: first.lanes.map {
            ($0.upstreamBucketID, $0.id)
        })
        let secondIDs = Dictionary(uniqueKeysWithValues: second.lanes.map {
            ($0.upstreamBucketID, $0.id)
        })
        XCTAssertEqual(firstIDs, secondIDs)
        XCTAssertEqual(first.decodeIssues, second.decodeIssues)
        XCTAssertEqual(
            first.decodeIssues.map(\.kind),
            [
                .duplicateUpstreamIdentity,
                .stableIDCollision(canonicalID: .geminiFiveHour),
                .stableIDCollision(canonicalID: .geminiWeekly),
            ]
        )
    }

    func testExactDuplicateUpstreamIdentityIsDeduplicatedWithIssue() throws {
        let summary = try decode("""
        {
          "groups": [
            {
              "groupId": "gemini",
              "buckets": [
                {
                  "bucketId": "gemini-5h",
                  "window": "5h",
                  "remainingFraction": 0.4
                },
                {
                  "bucketId": "gemini-5h",
                  "window": "5h",
                  "remainingFraction": 0.4
                }
              ]
            }
          ]
        }
        """)

        XCTAssertEqual(summary.lanes.count, 1)
        XCTAssertTrue(summary.decodeIssues.contains {
            $0.kind == .duplicateUpstreamIdentity
        })
    }

    func testEmptyGroupsAndCompleteSchemaMismatchFailTyped() {
        assertDecodeError(#"{"groups":[]}"#, expected: .noIdentifiableQuotaLanes)
        assertDecodeError(
            #"{"groups":[{"displayName":"Gemini","buckets":[]}]}"#,
            expected: .noIdentifiableQuotaLanes
        )
        assertDecodeError(#"{"models":[]}"#, expected: .missingQuotaGroups)
        assertDecodeError(#"{"groups":"not-an-array"}"#, expected: .missingQuotaGroups)
        assertDecodeError(#"{"groups":"#, expected: .invalidJSON)
    }

    private func decode(_ json: String) throws -> AntigravityDecodedQuotaSummary {
        try AntigravityQuotaSummaryDecoder.decode(Data(json.utf8))
    }

    private func assertDecodeError(
        _ json: String,
        expected: AntigravityQuotaSummaryDecoderError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try AntigravityQuotaSummaryDecoder.decode(Data(json.utf8)),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? AntigravityQuotaSummaryDecoderError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func collisionFixture(bucketOrder: [String]) -> String {
        let buckets = bucketOrder.map { name -> String in
            switch name {
            case "canonical":
                return """
                {
                  "bucketId": "gemini-5h",
                  "window": "5h",
                  "remainingFraction": 0.8
                }
                """
            default:
                return """
                {
                  "bucketId": "gemini-session",
                  "window": "5h",
                  "remainingFraction": 0.7
                }
                """
            }
        }.joined(separator: ",")

        return """
        {
          "groups": [
            {
              "groupId": "gemini",
              "displayName": "Gemini Models",
              "buckets": [\(buckets)]
            }
          ]
        }
        """
    }

    private func multiCollisionFixture<S: Sequence>(bucketOrder: S) -> String
    where S.Element == String {
        let buckets = bucketOrder.map { name -> String in
            switch name {
            case "five-hour-canonical":
                return """
                {
                  "bucketId": "gemini-5h",
                  "window": "5h",
                  "remainingFraction": 0.8
                }
                """
            case "five-hour-alias":
                return """
                {
                  "bucketId": "gemini-session",
                  "window": "5h",
                  "remainingFraction": 0.7
                }
                """
            case "weekly-canonical":
                return """
                {
                  "bucketId": "gemini-weekly",
                  "window": "weekly",
                  "remainingFraction": 0.6
                }
                """
            default:
                return """
                {
                  "bucketId": "gemini-7d",
                  "window": "weekly",
                  "remainingFraction": 0.5
                }
                """
            }
        }.joined(separator: ",")

        return """
        {
          "groups": [
            {
              "groupId": "gemini",
              "displayName": "Gemini Models",
              "buckets": [\(buckets)]
            }
          ]
        }
        """
    }
}
