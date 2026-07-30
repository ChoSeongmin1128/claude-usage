import XCTest
@testable import ClaudeUsage

final class AntigravityDisplayAdapterTests:
    XCTestCase
{
    private let now = Date(
        timeIntervalSince1970: 1_800_000_000
    )

    func testKnownLanesAreEditableBeforeFirstPayload() {
        let items = AntigravityDisplayAdapter
            .editorItems(
                settings: .default,
                presentation: nil,
                surface: .compact
            )

        XCTAssertEqual(
            items.map(\.id),
            AntigravityDisplaySettings.builtInLaneIDs
        )
        XCTAssertTrue(items.allSatisfy(\.isVisible))
        XCTAssertTrue(
            items.allSatisfy { !$0.isAvailable }
        )
    }

    func testObservedUnknownAndStoredMissingLanesArePreserved() {
        let observedUnknown = AntigravityQuotaLaneID(
            rawValue: "agent.daily"
        )
        let storedMissing = AntigravityQuotaLaneID(
            rawValue: "removed.monthly"
        )
        var settings = AntigravityDisplaySettings.default
        settings.compact.orderedLaneIDs.append(
            storedMissing
        )
        settings.compact.hiddenLaneIDs.insert(
            storedMissing
        )
        let presentation = makePresentation(
            lanes: [
                makeLane(
                    id: observedUnknown,
                    scope: .unknown(
                        id: "agent",
                        label: "Agent"
                    ),
                    cadence: .unknown(
                        rawValue: "daily"
                    ),
                    remaining: 0.4
                ),
            ],
            settings: settings
        )

        let items = AntigravityDisplayAdapter
            .editorItems(
                settings: settings,
                presentation: presentation,
                surface: .compact
            )

        XCTAssertEqual(
            items.first {
                $0.id == observedUnknown
            }?.title,
            "Agent · daily"
        )
        XCTAssertEqual(
            items.first {
                $0.id == observedUnknown
            }?.isAvailable,
            true
        )
        XCTAssertEqual(
            items.first {
                $0.id == observedUnknown
            }?.isVisible,
            true
        )
        XCTAssertEqual(
            items.first {
                $0.id == storedMissing
            }?.isAvailable,
            false
        )
        XCTAssertEqual(
            items.first {
                $0.id == storedMissing
            }?.isVisible,
            false
        )
    }

    func testVisibilityAndMoveProduceValidTypedSettings() {
        let original = AntigravityDisplaySettings.default
        let hidden = AntigravityDisplayAdapter
            .settingVisibility(
                false,
                for: .geminiWeekly,
                surface: .compact,
                presentation: nil,
                in: original
            )
        let moved = AntigravityDisplayAdapter.moving(
            .thirdPartyWeekly,
            offset: -3,
            surface: .compact,
            presentation: nil,
            in: hidden
        )

        XCTAssertTrue(
            moved.compact.hiddenLaneIDs.contains(
                .geminiWeekly
            )
        )
        XCTAssertEqual(
            moved.compact.orderedLaneIDs.first,
            .thirdPartyWeekly
        )
        XCTAssertEqual(
            moved.compact.orderingPolicy,
            .manual
        )
        XCTAssertTrue(moved.isCurrentAndValid)
    }

    func testAllHiddenProducesExplicitEmptyCompactPresentation() {
        var settings = AntigravityDisplaySettings.default
        settings.compact.hiddenLaneIDs = Set(
            AntigravityDisplaySettings.builtInLaneIDs
        )
        let presentation = makePresentation(
            lanes: [
                makeLane(
                    id: .geminiFiveHour,
                    scope: .gemini,
                    cadence: .fiveHour,
                    remaining: 0.5
                ),
                makeLane(
                    id: .thirdPartyWeekly,
                    scope: .thirdPartyModels,
                    cadence: .weekly,
                    remaining: 0.2
                ),
            ],
            settings: settings
        )

        XCTAssertTrue(
            presentation.compact.metrics.isEmpty
        )
        XCTAssertEqual(
            presentation.compact.unavailableText,
            "확인 가능한 사용량 한도 없음"
        )
        XCTAssertEqual(
            presentation.menuBar.selectedLaneID,
            .thirdPartyWeekly
        )
    }

    func testStandardVisibilityAndOrderDriveGroupedPresentation() {
        var settings = AntigravityDisplaySettings.default
        settings.standard = .init(
            orderedLaneIDs: [
                .thirdPartyWeekly,
                .thirdPartyFiveHour,
                .geminiFiveHour,
                .geminiWeekly,
            ],
            hiddenLaneIDs: [.geminiWeekly],
            orderingPolicy: .manual
        )
        let presentation = makePresentation(
            lanes: [
                makeLane(
                    id: .geminiFiveHour,
                    scope: .gemini,
                    cadence: .fiveHour,
                    remaining: 0.7
                ),
                makeLane(
                    id: .geminiWeekly,
                    scope: .gemini,
                    cadence: .weekly,
                    remaining: 0.6
                ),
                makeLane(
                    id: .thirdPartyFiveHour,
                    scope: .thirdPartyModels,
                    cadence: .fiveHour,
                    remaining: 0.5
                ),
                makeLane(
                    id: .thirdPartyWeekly,
                    scope: .thirdPartyModels,
                    cadence: .weekly,
                    remaining: 0.4
                ),
            ],
            settings: settings
        )

        XCTAssertEqual(
            presentation.groups.map(\.title),
            ["Claude · GPT", "Gemini"]
        )
        XCTAssertEqual(
            presentation.groups.flatMap(\.lanes)
                .map(\.id),
            [
                .thirdPartyWeekly,
                .thirdPartyFiveHour,
                .geminiFiveHour,
            ]
        )
        XCTAssertEqual(
            presentation.allGroups.flatMap(\.lanes)
                .count,
            4
        )
    }

    private func makePresentation(
        lanes: [AntigravityQuotaLane],
        settings: AntigravityDisplaySettings
    ) -> AntigravityQuotaPresentation {
        AntigravityQuotaPresentationMapper.map(
            snapshot: AntigravityQuotaSnapshot(
                identity: nil,
                plan: nil,
                lanes: lanes,
                decodeIssues: [],
                provenance:
                    AntigravityQuotaProvenance(
                        transport: .borrowedAGYRPC,
                        endpointOwner: .borrowed,
                        accountIdentity: nil,
                        capability:
                            .groupedQuotaSummary,
                        processIdentity: nil
                    ),
                fetchedAt: now
            ),
            settings: settings,
            now: now,
            timeZone:
                TimeZone(secondsFromGMT: 0)!
        )
    }

    private func makeLane(
        id: AntigravityQuotaLaneID,
        scope: AntigravityQuotaScope,
        cadence: AntigravityQuotaCadence,
        remaining: Double
    ) -> AntigravityQuotaLane {
        AntigravityQuotaLane(
            id: id,
            upstreamGroupID: id.rawValue,
            upstreamBucketID: id.rawValue,
            scope: scope,
            cadence: cadence,
            remainingFraction: remaining,
            resetAt: nil,
            resetDescription: nil,
            availability: .available
        )
    }
}
