import AppKit
import XCTest
@testable import ClaudeUsage

final class AntigravityQuotaPresentationMapperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let utc = TimeZone(secondsFromGMT: 0)!

    @MainActor
    func testThreeAntigravityGaugesRenderAndExplicitEmptySelectionHasNoGauge() throws {
        let ids: [AntigravityQuotaLaneID] = [.geminiFiveHour, .thirdPartyWeekly, .geminiWeekly]
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.style = .batteryBar
        settings.menuBar.gaugeLaneIDs = ids
        settings.menuBar.gaugeTitles = [AntigravityQuotaLaneID.geminiWeekly.rawValue: "Gemini 주간"]
        let lanes = [
            makeLane(
                id: AntigravityQuotaLaneID.geminiFiveHour.rawValue, scope: .gemini,
                cadence: .fiveHour, remaining: 0.9),
            makeLane(
                id: AntigravityQuotaLaneID.thirdPartyWeekly.rawValue, scope: .thirdPartyModels,
                cadence: .weekly, remaining: 0.4),
        ]
        let presentation = AntigravityQuotaPresentationMapper.map(
            snapshot: makeSnapshot(lanes: lanes, fetchedAt: now), settings: settings,
            basisOverride: .remaining, now: now)
        let snapshot = try XCTUnwrap(
            MenuBarStatusComposer.antigravitySnapshot(
                presentation: presentation.menuBar, icon: nil, appearance: NSAppearance(named: .darkAqua)))
        let image = try XCTUnwrap(snapshot.styleIcon)
        XCTAssertGreaterThan(image.size.width, BatteryGeometry.Layout.sideBySide.size.width)
        XCTAssertEqual(image.size.height, BatteryGeometry.height)
        let attachment = XCTAttachment(
            image: MenuBarStatusComposer.singleProviderContent(
                snapshot: snapshot, secondaryColor: .secondaryLabelColor,
                appearance: try XCTUnwrap(NSAppearance(named: .darkAqua))
            ).image)
        attachment.name = "AGY-three-gauges-with-missing-slot"
        attachment.lifetime = .keepAlways
        add(attachment)
        settings.menuBar.gaugeLaneIDs = []
        let empty = AntigravityQuotaPresentationMapper.map(
            snapshot: makeSnapshot(lanes: lanes, fetchedAt: now), settings: settings, now: now)
        XCTAssertNil(MenuBarStatusComposer.antigravitySnapshot(presentation: empty.menuBar, icon: nil)?.styleIcon)
    }

    @MainActor
    func testAntigravityGaugeNamesAreOptInAndPreferenceChangesInvalidateRendering() throws {
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.style = .batteryBar
        settings.menuBar.gaugeLaneIDs = [.geminiFiveHour, .geminiWeekly, .thirdPartyWeekly]
        let encoded = try JSONEncoder().encode(settings)
        let oldSettings = try JSONDecoder().decode(AntigravityDisplaySettings.self, from: encoded)
        XCTAssertNil(oldSettings.menuBar.showsGaugeLabels)
        let source = makeSnapshot(
            lanes: [
                makeLane(
                    id: AntigravityQuotaLaneID.geminiFiveHour.rawValue, scope: .gemini,
                    cadence: .fiveHour, remaining: 0.9)
            ], fetchedAt: now)
        let hidden = AntigravityQuotaPresentationMapper.map(snapshot: source, settings: oldSettings, now: now)
        XCTAssertFalse(hidden.menuBar.showsGaugeLabels)
        settings.menuBar.showsGaugeLabels = true
        let reloaded = try JSONDecoder().decode(AntigravityDisplaySettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(reloaded.isCurrentAndValid)
        XCTAssertEqual(reloaded.menuBar.showsGaugeLabels, true)
        let shown = AntigravityQuotaPresentationMapper.map(snapshot: source, settings: reloaded, now: now)
        XCTAssertEqual(shown.menuBar.gauges, hidden.menuBar.gauges)
        XCTAssertEqual(shown.menuBar.accessibilityValue, hidden.menuBar.accessibilityValue)
        let snapshots = try [hidden, shown].map {
            try XCTUnwrap(MenuBarStatusComposer.antigravitySnapshot(presentation: $0.menuBar, icon: nil))
        }
        XCTAssertNotEqual(snapshots[0].renderKey, snapshots[1].renderKey)
        XCTAssertGreaterThan(
            try XCTUnwrap(snapshots[1].styleIcon).size.width,
            try XCTUnwrap(snapshots[0].styleIcon).size.width)
    }

    func testExplicitGaugeListKeepsOrderMissingSlotsAndAccountIndependentValues() throws {
        let ids: [AntigravityQuotaLaneID] = [.geminiFiveHour, .thirdPartyWeekly, .geminiWeekly]
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.style = .batteryBar
        settings.menuBar.gaugeLaneIDs = ids
        settings.menuBar.gaugeTitles = [AntigravityQuotaLaneID.geminiWeekly.rawValue: "Gemini 주간"]
        let lanes = [
            makeLane(
                id: AntigravityQuotaLaneID.geminiFiveHour.rawValue, scope: .gemini,
                cadence: .fiveHour, remaining: 0.9),
            makeLane(
                id: AntigravityQuotaLaneID.thirdPartyWeekly.rawValue, scope: .thirdPartyModels,
                cadence: .weekly, remaining: 0.4),
        ]
        let result = AntigravityQuotaPresentationMapper.map(
            snapshot: makeSnapshot(lanes: lanes, fetchedAt: now), settings: settings,
            basisOverride: .remaining, now: now)
        let gauges = try XCTUnwrap(result.menuBar.gauges)
        XCTAssertEqual(gauges.map { $0.value.id }, ids.map(\.rawValue))
        XCTAssertEqual(gauges[0].value.percentage ?? -1, 90, accuracy: 0.001)
        XCTAssertEqual(gauges[1].value.percentage ?? -1, 40, accuracy: 0.001)
        XCTAssertNil(gauges[2].value.percentage)
        XCTAssertEqual(gauges[2].value.title, "Gemini 주간")
        XCTAssertTrue(result.menuBar.accessibilityValue.contains("Gemini 주간"))
        XCTAssertNil(result.menuBar.gaugePercentage)
        let roundTrip = try JSONDecoder().decode(
            AntigravityDisplaySettings.self,
            from: JSONEncoder().encode(settings))
        XCTAssertEqual(roundTrip.menuBar.gaugeLaneIDs, ids)
        XCTAssertTrue(roundTrip.isCurrentAndValid)
        settings.menuBar.gaugeLaneIDs = []
        let empty = AntigravityQuotaPresentationMapper.map(
            snapshot: makeSnapshot(lanes: lanes, fetchedAt: now), settings: settings, now: now)
        XCTAssertEqual(empty.menuBar.gauges, [])
        XCTAssertNil(empty.menuBar.gaugePercentage)
    }

    @MainActor
    func testFourObservedAntigravityGaugesKeepEachLaneValueAndSelectionOrder() throws {
        let ids: [AntigravityQuotaLaneID] = [.geminiFiveHour, .thirdPartyWeekly, .geminiWeekly, .thirdPartyFiveHour]
        let remaining: [Double] = [0.9, 0.4, 0.7, 0.2]
        let lanes = ids.enumerated().map { index, id in
            makeLane(
                id: id.rawValue, scope: index % 2 == 0 ? .gemini : .thirdPartyModels,
                cadence: index == 0 || index == 3 ? .fiveHour : .weekly, remaining: remaining[index])
        }
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.style = .batteryBar
        settings.menuBar.gaugeLaneIDs = ids
        let result = AntigravityQuotaPresentationMapper.map(
            snapshot: makeSnapshot(lanes: lanes, fetchedAt: now), settings: settings, basisOverride: .remaining,
            now: now)
        let values = try XCTUnwrap(result.menuBar.gauges)
        XCTAssertEqual(values.map { $0.value.id }, ids.map(\.rawValue))
        for (value, expected) in zip(values, remaining) {
            XCTAssertEqual(try XCTUnwrap(value.value.percentage), expected * 100, accuracy: 0.001)
        }
        let image = try XCTUnwrap(
            MenuBarStatusComposer.antigravitySnapshot(presentation: result.menuBar, icon: nil)?.styleIcon)
        XCTAssertEqual(image.size.height, BatteryGeometry.height)
        XCTAssertGreaterThan(image.size.width, BatteryGeometry.Layout.sideBySide.size.width)
    }

    func testCompactPassesRawResetAndCadenceToSharedUsageRow() throws {
        let reset = now.addingTimeInterval(3 * 3600)
        let lanes = [
            makeLane(
                id: "future.daily", scope: .unknown(id: "future", label: "Future model"),
                cadence: .unknown(rawValue: "daily"), remaining: 0.5, resetAt: reset),
            makeLane(
                id: AntigravityQuotaLaneID.geminiWeekly.rawValue, scope: .gemini, cadence: .weekly, remaining: 0.8),
        ]
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.timeFormat = .remaining
        let presentation = AntigravityQuotaPresentationMapper.map(
            snapshot: makeSnapshot(lanes: lanes, fetchedAt: now), settings: settings, now: now, timeZone: utc)
        let timed = try XCTUnwrap(presentation.compact.metrics.first { $0.laneID.rawValue == "future.daily" })
        XCTAssertEqual(timed.resetAt.flatMap(TimeFormatter.parseISO8601), reset)
        XCTAssertEqual(timed.timeFormatStyle, .remaining)
        XCTAssertFalse(timed.isWeekly)
        let weekly = try XCTUnwrap(presentation.compact.metrics.first { $0.laneID == .geminiWeekly })
        XCTAssertNil(weekly.resetAt)
        XCTAssertTrue(weekly.isWeekly)
        XCTAssertEqual(weekly.label, "Gemini")
    }

    func testCompactOmitsRedundantWeeklyLabelButPreservesMultipleCadencesWhenHidden() throws {
        let weekly = makeLane(
            id: AntigravityQuotaLaneID.geminiWeekly.rawValue, scope: .gemini, cadence: .weekly, remaining: 0.8)
        XCTAssertEqual(map([weekly]).compact.metrics.first?.label, "Gemini")
        let hourly = makeLane(
            id: AntigravityQuotaLaneID.geminiFiveHour.rawValue, scope: .gemini, cadence: .fiveHour, remaining: 0.9)
        var settings = AntigravityDisplaySettings.default
        settings.compact.hiddenLaneIDs = [.geminiFiveHour]
        let result = AntigravityQuotaPresentationMapper.map(
            snapshot: makeSnapshot(lanes: [weekly, hourly], fetchedAt: now), settings: settings, now: now, timeZone: utc
        )
        XCTAssertEqual(result.compact.metrics.first?.label, "Gemini 주간")
    }

    func testCommonBasisOverridesLegacyStyleAndKeepsRiskAcrossAllSurfaces() {
        let snapshot = makeSnapshot(
            lanes: [
                makeLane(
                    id: AntigravityQuotaLaneID.geminiWeekly.rawValue, scope: .gemini, cadence: .weekly, remaining: 0.2)
            ], fetchedAt: now)
        for style in AntigravityDisplaySettings.MenuBarPresentationIntent.Style.allCases {
            var settings = AntigravityDisplaySettings.default
            settings.menuBar.style = style
            settings.menuBar.circularValue = .usage
            let remaining = AntigravityQuotaPresentationMapper.map(
                snapshot: snapshot, settings: settings,
                basisOverride: .remaining, now: now)
            let used = AntigravityQuotaPresentationMapper.map(
                snapshot: snapshot, settings: settings,
                basisOverride: .used, now: now)
            XCTAssertEqual(remaining.groups[0].lanes[0].basis, .remaining)
            XCTAssertEqual(remaining.compact.metrics.first?.basis, .remaining)
            XCTAssertEqual(remaining.groups[0].lanes[0].tone, used.groups[0].lanes[0].tone)
            if style != .none {
                XCTAssertEqual(remaining.menuBar.gaugePercentage ?? -1, 20, accuracy: 0.001)
                XCTAssertEqual(used.menuBar.gaugePercentage ?? -1, 80, accuracy: 0.001)
            }
            XCTAssertTrue(remaining.menuBar.regularText?.contains("20%") == true)
            XCTAssertTrue(used.menuBar.regularText?.contains("80%") == true)
        }
    }

    func testStandardPreservesDefaultLaneOrderAndAppendsNewLanesAsDistinctGroupRuns() throws {
        let lanes = [
            makeLane(
                id: "agent.daily",
                scope: .unknown(id: "agent", label: "Agent Mode"),
                cadence: .unknown(rawValue: "daily"),
                remaining: 0.6
            ),
            makeLane(
                id: "gemini.burst",
                scope: .gemini,
                cadence: .unknown(rawValue: "burst"),
                remaining: 0.5
            ),
            makeLane(
                id: AntigravityQuotaLaneID.thirdPartyWeekly.rawValue,
                scope: .thirdPartyModels,
                cadence: .weekly,
                remaining: 0.4
            ),
            makeLane(
                id: AntigravityQuotaLaneID.geminiWeekly.rawValue,
                scope: .gemini,
                cadence: .weekly,
                remaining: 0.7
            ),
            makeLane(
                id: AntigravityQuotaLaneID.thirdPartyFiveHour.rawValue,
                scope: .thirdPartyModels,
                cadence: .fiveHour,
                remaining: 0.8
            ),
            makeLane(
                id: AntigravityQuotaLaneID.geminiFiveHour.rawValue,
                scope: .gemini,
                cadence: .fiveHour,
                remaining: 0.9
            ),
        ]

        let settings = AntigravityDisplaySettings.default
        let presentation = map(lanes, settings: settings)
        let expectedLaneOrder: [AntigravityQuotaLaneID] = [
            .geminiFiveHour,
            .geminiWeekly,
            .thirdPartyFiveHour,
            .thirdPartyWeekly,
            .init(rawValue: "gemini.burst"),
            .init(rawValue: "agent.daily"),
        ]

        // Later observations append after the stable preferred order. The
        // displayed rows must follow the same order the editor shows.
        XCTAssertEqual(presentation.groups.flatMap(\.lanes).map(\.id), expectedLaneOrder)
        XCTAssertEqual(
            AntigravityDisplayAdapter.editorItems(
                settings: settings, presentation: presentation, surface: .standard
            ).map(\.id),
            expectedLaneOrder
        )
        XCTAssertEqual(presentation.groups.map(\.title), ["Gemini", "Claude · GPT", "Gemini", "Agent Mode"])
        XCTAssertEqual(Set(presentation.groups.map(\.id)).count, presentation.groups.count)

        let firstGeminiGroup = try XCTUnwrap(presentation.groups.first { $0.id == .gemini })
        XCTAssertEqual(firstGeminiGroup.lanes.map(\.cadenceTitle), ["5시간", "주간"])
        XCTAssertEqual(firstGeminiGroup.lanes.map(\.standardRowTitle), ["5시간 한도", "주간 한도"])
        XCTAssertFalse(firstGeminiGroup.isUnknownScope)

        let continuationID = AntigravityQuotaGroupPresentationID.continuation(
            scopeID: .gemini, firstLaneID: .init(rawValue: "gemini.burst")
        )
        let resumedGeminiGroup = try XCTUnwrap(presentation.groups.first { $0.id == continuationID })
        XCTAssertEqual(resumedGeminiGroup.lanes.map(\.cadenceTitle), ["burst"])
        XCTAssertFalse(resumedGeminiGroup.isUnknownScope)
        XCTAssertTrue(try XCTUnwrap(resumedGeminiGroup.lanes.first).isUnknownCadence)

        let agentGroup = try XCTUnwrap(
            presentation.groups.first { $0.id == .unknown(upstreamID: "agent", label: "Agent Mode") }
        )
        XCTAssertEqual(agentGroup.lanes.map(\.cadenceTitle), ["daily"])
        XCTAssertTrue(agentGroup.isUnknownScope)

        // The full inventory still classifies scopes and cadences together;
        // only the displayed group runs preserve the user's flat ordering.
        XCTAssertEqual(presentation.allGroups.map(\.title), ["Gemini", "Claude · GPT", "Agent Mode"])
        XCTAssertEqual(presentation.allGroups[0].lanes.map(\.cadenceTitle), ["5시간", "주간", "burst"])
        XCTAssertEqual(presentation.allGroups[1].lanes.map(\.cadenceTitle), ["5시간", "주간"])
        XCTAssertEqual(presentation.observedLaneCount, lanes.count)
    }

    func testResetDetailUsesSharedProviderFormattingRules() {
        let presentation = map([
            makeLane(
                id:
                    AntigravityQuotaLaneID
                        .geminiWeekly.rawValue,
                scope: .gemini,
                cadence: .weekly,
                remaining: 0.6,
                resetAt:
                    now.addingTimeInterval(
                        4 * 24 * 3600
                            + 8 * 3600
                    )
            ),
        ])
        let resetText =
            presentation.groups[0].lanes[0]
                .resetText

        XCTAssertTrue(
            resetText.hasPrefix(
                "4일 8시간 후 · "
            )
        )
        XCTAssertTrue(resetText.contains("월"))
        XCTAssertFalse(resetText.contains("("))
        XCTAssertFalse(resetText.contains(")"))
    }

    func testStandardResetDetailUsesSelectedCommonTimeFormat() {
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.timeFormat = .h12
        let reset = now.addingTimeInterval(8 * 3600)
        let expected = TimeFormatter.formatUsageResetDetail(
            resetAt: reset,
            isWeekly: false,
            style: .h12,
            now: now,
            timeZone: utc,
            label: nil
        )

        let presentation = map(
            [
                makeLane(
                    id: AntigravityQuotaLaneID.geminiFiveHour.rawValue,
                    scope: .gemini,
                    cadence: .fiveHour,
                    remaining: 0.6,
                    resetAt: reset
                )
            ],
            settings: settings
        )

        XCTAssertEqual(
            presentation.groups[0].lanes[0].resetText,
            expected
        )
        XCTAssertEqual(
            presentation.compact.metrics[0].timeFormatStyle,
            .h12
        )
    }

    func testUnknownGroupIDsCannotCollideThroughDelimiterContent() {
        let presentation = map([
            makeLane(
                id: "lane.first",
                scope: .unknown(id: "a.b", label: "c"),
                cadence: .weekly,
                remaining: 0.5
            ),
            makeLane(
                id: "lane.second",
                scope: .unknown(id: "a", label: "b.c"),
                cadence: .weekly,
                remaining: 0.4
            ),
        ])

        XCTAssertEqual(presentation.groups.count, 2)
        XCTAssertEqual(
            Set(presentation.groups.map(\.id)).count,
            2
        )
        XCTAssertNotEqual(
            AntigravityQuotaGroupPresentationID.unknown(
                upstreamID: "a.b",
                label: "c"
            ),
            .unknown(upstreamID: "a", label: "b.c")
        )
    }

    func testSnapshotDecodeIssuesAreVisibleInRailTooltipAndAccessibility() {
        let issue = AntigravityQuotaDecodeIssue(
            kind: .missingRemainingFraction,
            upstreamGroupID: "gemini",
            groupLabel: "Gemini",
            upstreamBucketID: "weekly"
        )
        let snapshot = makeSnapshot(
            lanes: [
                makeLane(
                    id: AntigravityQuotaLaneID.geminiFiveHour.rawValue,
                    scope: .gemini,
                    cadence: .fiveHour,
                    remaining: 0.5
                ),
            ],
            identity: ProviderAccountIdentity(
                stableAccountID: "subject-1",
                email: "user@example.com"
            ),
            fetchedAt: now,
            decodeIssues: [issue]
        )

        let presentation = AntigravityQuotaPresentationMapper.map(
            snapshot: snapshot,
            settings: .default,
            now: now,
            timeZone: utc
        )

        XCTAssertEqual(presentation.context.decodeIssueCount, 1)
        XCTAssertEqual(
            presentation.identityRail.statusLabels,
            ["일부 한도를 읽지 못함"]
        )
        XCTAssertEqual(
            presentation.identityRail.visibleSegments.last,
            "일부 한도를 읽지 못함"
        )
        XCTAssertEqual(presentation.identityRail.tone, .attention)
        XCTAssertTrue(
            presentation.identityRail.tooltip.contains(
                "응답 항목 1건을 완전히 해석하지 못했습니다"
            )
        )
        XCTAssertTrue(
            presentation.identityRail.accessibilityValue.contains(
                "확인된 한도는 계속 표시합니다"
            )
        )
        XCTAssertTrue(
            presentation.menuBar.tooltip.contains(
                "상태: 일부 한도를 읽지 못함"
            )
        )
    }

    func testRuntimeStateOverloadPreservesStaleAndFailureStates() throws {
        let snapshot = makeSnapshot(
            lanes: [
                makeLane(
                    id: AntigravityQuotaLaneID.geminiWeekly.rawValue,
                    scope: .gemini,
                    cadence: .weekly,
                    remaining: 0.4
                ),
            ],
            fetchedAt: now
        )
        let failure = AntigravityFailure.sourceUnavailable(
            .googleOAuth
        )
        let staleState = AntigravityPresentationState.stale(
            snapshot,
            failure: failure
        )

        let staleResult = AntigravityQuotaPresentationMapper.map(
            state: staleState,
            settings: .default,
            now: now,
            timeZone: utc
        )
        guard case .content(let stalePresentation) = staleResult else {
            return XCTFail("stale snapshot should remain presentable")
        }

        XCTAssertEqual(
            stalePresentation.context.phase,
            .stale(failure)
        )
        XCTAssertEqual(
            stalePresentation.identityRail.statusLabels,
            [UsageStatusLabel.previousValue]
        )
        XCTAssertEqual(
            stalePresentation.identityRail.tone,
            .attention
        )
        XCTAssertTrue(
            stalePresentation.identityRail.tooltip.contains(
                "조회에 실패해"
            )
        )

        let failedState = AntigravityPresentationState.failed(
            .noEligibleSource
        )
        XCTAssertEqual(
            AntigravityQuotaPresentationMapper.map(
                state: failedState,
                settings: .default,
                now: now,
                timeZone: utc
            ),
            .unavailable(failedState)
        )

        let identity = ProviderAccountIdentity(
            stableAccountID: "subject-a",
            email: "a@example.com"
        )
        let provenance = AntigravityQuotaProvenance(
            transport: .googleOAuth,
            endpointOwner: .external,
            accountIdentity: identity,
            capability: .limitedQuota,
            processIdentity: nil
        )
        let limitedState = AntigravityPresentationState
            .limited(
                .googleOAuth(
                    evidence:
                        AntigravityGoogleOAuthLimitedQuotaEvidence(
                            identity: identity,
                            plan: "Pro",
                            modelQuotaCount: 2
                        ),
                    provenance: provenance,
                    fetchedAt: now
                )
            )
        XCTAssertEqual(
            AntigravityQuotaPresentationMapper.map(
                state: limitedState,
                settings: .default,
                now: now,
                timeZone: utc
            ),
            .unavailable(limitedState)
        )

        let identityOnlyState = AntigravityPresentationState
            .identityOnly(
                AntigravityIdentityOnlyUsage(
                    identity: identity,
                    plan: "Pro",
                    provenance: AntigravityQuotaProvenance(
                        transport: .googleOAuth,
                        endpointOwner: .external,
                        accountIdentity: identity,
                        capability: .groupedQuotaSummary,
                        processIdentity: nil
                    ),
                    fetchedAt: now
                )
            )
        XCTAssertEqual(
            AntigravityQuotaPresentationMapper.map(
                state: identityOnlyState,
                settings: .default,
                now: now,
                timeZone: utc
            ),
            .unavailable(identityOnlyState)
        )
    }

    func testPercentageKeepsPrecisionUntilFormattingAndResetIsIndependent() throws {
        let lane = makeLane(
            id: AntigravityQuotaLaneID.geminiFiveHour.rawValue,
            scope: .gemini,
            cadence: .fiveHour,
            remaining: 0.876543211,
            resetAt: nil
        )

        let projected = try XCTUnwrap(map([lane]).groups.first?.lanes.first)

        XCTAssertEqual(
            try XCTUnwrap(projected.value.usedPercentage),
            12.3456789,
            accuracy: 0.0000000001
        )
        XCTAssertEqual(
            try XCTUnwrap(projected.value.remainingPercentage),
            87.6543211,
            accuracy: 0.0000000001
        )
        XCTAssertEqual(projected.percentageText, "12.3%")
        XCTAssertEqual(projected.resetText, "갱신 시각 알 수 없음")
        XCTAssertEqual(projected.tone, .healthy)
        XCTAssertTrue(projected.accessibilityValue.contains("12.3퍼센트 사용"))
        XCTAssertTrue(projected.accessibilityValue.contains("87.7퍼센트 남음"))
    }

    func testUnavailableAndDisabledValuesNeverBecomeZeroUsage() throws {
        let disabled = makeLane(
            id: "gemini.disabled",
            scope: .gemini,
            cadence: .fiveHour,
            remaining: 0,
            availability: .disabled
        )
        let unknown = makeLane(
            id: "gemini.unknown",
            scope: .gemini,
            cadence: .weekly,
            remaining: 0,
            availability: .unknown
        )
        let missing = makeLane(
            id: "gemini.missing",
            scope: .gemini,
            cadence: .unknown(rawValue: "monthly"),
            remaining: nil,
            availability: .available
        )

        let lanes = map([disabled, unknown, missing]).groups.flatMap(\.lanes)

        XCTAssertEqual(lanes.count, 3)
        for lane in lanes {
            XCTAssertNil(lane.value.usedPercentage)
            XCTAssertNil(lane.percentageText)
            XCTAssertEqual(lane.tone, .neutral)
        }
        XCTAssertEqual(
            lanes.first(where: { $0.id.rawValue == "gemini.disabled" })?.value,
            .unavailable(.disabled)
        )
        XCTAssertEqual(
            lanes.first(where: { $0.id.rawValue == "gemini.unknown" })?.value,
            .unavailable(.notReported)
        )
        XCTAssertNil(map([disabled, unknown, missing]).compact.metric)
    }

    func testFullyUsedAvailableLaneIsCriticalInsteadOfNeutral() throws {
        let lane = makeLane(
            id: AntigravityQuotaLaneID.geminiWeekly.rawValue,
            scope: .gemini,
            cadence: .weekly,
            remaining: 0
        )

        let projected = try XCTUnwrap(map([lane]).groups.first?.lanes.first)

        XCTAssertEqual(projected.value.usedPercentage, 100)
        XCTAssertEqual(projected.percentageText, "100%")
        XCTAssertEqual(projected.tone, .critical)
    }

    func testCompactShowsAllVisibleLanesMostConstrainedFirstWhileMenuSelectsOne() throws {
        let presentation = map([
            makeLane(
                id: AntigravityQuotaLaneID.geminiFiveHour.rawValue,
                scope: .gemini,
                cadence: .fiveHour,
                remaining: 0.82
            ),
            makeLane(
                id: AntigravityQuotaLaneID.geminiWeekly.rawValue,
                scope: .gemini,
                cadence: .weekly,
                remaining: 0.58
            ),
            makeLane(
                id: AntigravityQuotaLaneID.thirdPartyFiveHour.rawValue,
                scope: .thirdPartyModels,
                cadence: .fiveHour,
                remaining: 0.88
            ),
            makeLane(
                id: AntigravityQuotaLaneID.thirdPartyWeekly.rawValue,
                scope: .thirdPartyModels,
                cadence: .weekly,
                remaining: 0.32
            ),
        ])

        XCTAssertEqual(
            presentation.compact.metrics.map(\.laneID),
            [
                .thirdPartyWeekly,
                .geminiWeekly,
                .geminiFiveHour,
                .thirdPartyFiveHour,
            ]
        )
        let compactMetric = try XCTUnwrap(
            presentation.compact.metrics.first
        )
        XCTAssertEqual(compactMetric.label, "Claude·GPT 주간")
        XCTAssertEqual(compactMetric.usedPercentage, 68, accuracy: 0.0001)
        XCTAssertEqual(compactMetric.percentageText, "68%")
        XCTAssertEqual(presentation.menuBar.selectedLaneID, .thirdPartyWeekly)
        XCTAssertEqual(presentation.menuBar.regularText, "C/G·주 68%")
        XCTAssertEqual(presentation.menuBar.condensedText, "68%")
    }

    func testMenuBarCanShowMultipleUserSelectedLanesWhileGaugeUsesRepresentativeLane() throws {
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.laneSelection =
            .fixed(.geminiFiveHour)
        settings.menuBar.additionalLaneIDs = [
            .geminiWeekly,
            .thirdPartyWeekly,
        ]
        settings.menuBar.style = .circular

        let presentation = map([
            makeLane(
                id: AntigravityQuotaLaneID.geminiFiveHour.rawValue,
                scope: .gemini,
                cadence: .fiveHour,
                remaining: 0.8
            ),
            makeLane(
                id: AntigravityQuotaLaneID.geminiWeekly.rawValue,
                scope: .gemini,
                cadence: .weekly,
                remaining: 0.6
            ),
            makeLane(
                id: AntigravityQuotaLaneID.thirdPartyWeekly.rawValue,
                scope: .thirdPartyModels,
                cadence: .weekly,
                remaining: 0.3
            ),
        ], settings: settings)

        XCTAssertEqual(
            presentation.menuBar.regularText,
            "G·5h 20% · G·주 40% · C/G·주 70%"
        )
        XCTAssertEqual(
            presentation.menuBar.condensedText,
            "20% · 40% · 70%"
        )
        XCTAssertEqual(
            presentation.menuBar.selectedLaneID,
            .geminiFiveHour
        )
        XCTAssertEqual(
            try XCTUnwrap(
                presentation.menuBar.gaugePercentage
            ),
            20,
            accuracy: 0.0001
        )
    }

    func testMostConstrainedTieUsesStableKnownLaneOrder() throws {
        let presentation = map([
            makeLane(
                id: AntigravityQuotaLaneID.geminiWeekly.rawValue,
                scope: .gemini,
                cadence: .weekly,
                remaining: 0.2
            ),
            makeLane(
                id: AntigravityQuotaLaneID.geminiFiveHour.rawValue,
                scope: .gemini,
                cadence: .fiveHour,
                remaining: 0.2
            ),
        ])

        XCTAssertEqual(
            presentation.compact.metrics.map(\.laneID),
            [.geminiFiveHour, .geminiWeekly]
        )
    }

    func testMissingPersistedCompactLaneStaysEmptyWithoutMutatingSettings() throws {
        var settings = AntigravityDisplaySettings.default
        let missingCompactID = AntigravityQuotaLaneID(
            rawValue: "removed.compact"
        )
        let missingMenuID = AntigravityQuotaLaneID(
            rawValue: "removed.menu"
        )
        settings.compact = .init(
            orderedLaneIDs: [missingCompactID]
                + AntigravityDisplaySettings
                    .builtInLaneIDs,
            hiddenLaneIDs: Set(
                AntigravityDisplaySettings
                    .builtInLaneIDs
            ),
            orderingPolicy: .manual
        )
        settings.menuBar.laneSelection = .fixed(missingMenuID)
        let originalSettings = settings
        let availableLane = makeLane(
            id: AntigravityQuotaLaneID.thirdPartyWeekly.rawValue,
            scope: .thirdPartyModels,
            cadence: .weekly,
            remaining: 0.1
        )

        let presentation = map([availableLane], settings: settings)

        XCTAssertEqual(settings, originalSettings)
        XCTAssertTrue(
            presentation.compact.metrics.isEmpty
        )
        XCTAssertEqual(presentation.menuBar.selectedLaneID, .thirdPartyWeekly)
        XCTAssertEqual(
            presentation.notices.map(\.surface),
            [.menuBar]
        )
        XCTAssertEqual(
            presentation.notices.map(\.kind),
            [
                .fixedLaneUnavailable(
                    requestedLaneID: missingMenuID,
                    fallbackLaneID: .thirdPartyWeekly
                ),
            ]
        )
    }

    func testManualCompactVisibilityAndOrderArePreserved() throws {
        var settings = AntigravityDisplaySettings.default
        settings.compact = .init(
            orderedLaneIDs: [
                .geminiFiveHour,
                .thirdPartyWeekly,
                .geminiWeekly,
                .thirdPartyFiveHour,
            ],
            hiddenLaneIDs: [
                .geminiWeekly,
                .thirdPartyFiveHour,
            ],
            orderingPolicy: .manual
        )

        let presentation = map([
            makeLane(
                id: AntigravityQuotaLaneID.geminiFiveHour.rawValue,
                scope: .gemini,
                cadence: .fiveHour,
                remaining: 0.9
            ),
            makeLane(
                id: AntigravityQuotaLaneID.thirdPartyWeekly.rawValue,
                scope: .thirdPartyModels,
                cadence: .weekly,
                remaining: 0.1
            ),
        ], settings: settings)

        XCTAssertEqual(
            presentation.compact.metrics.map(\.laneID),
            [.geminiFiveHour, .thirdPartyWeekly]
        )
        XCTAssertTrue(presentation.notices.isEmpty)
    }

    func testMenuProjectionPreservesDisplayIntentWithoutReinterpretingGauge() throws {
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.showsProviderIcon = false
        settings.menuBar.style = .circular
        settings.menuBar.showsSelectedLanePercentage = false
        settings.menuBar.showsSelectedLaneResetTime = true
        settings.menuBar.timeFormat = .remaining
        settings.menuBar.showsGaugePercentage = false
        settings.menuBar.circularValue = .remaining
        let resetAt = now.addingTimeInterval(
            26 * 3_600
        )

        let presentation = map([
            makeLane(
                id: AntigravityQuotaLaneID.thirdPartyWeekly.rawValue,
                scope: .thirdPartyModels,
                cadence: .weekly,
                remaining: 0.32,
                resetAt: resetAt
            ),
        ], settings: settings)

        XCTAssertFalse(presentation.menuBar.showsProviderIcon)
        XCTAssertEqual(presentation.menuBar.style, .circular)
        XCTAssertEqual(
            presentation.menuBar.regularText,
            "C/G·주 1d 2h"
        )
        XCTAssertEqual(
            presentation.menuBar.condensedText,
            "1d 2h"
        )
        XCTAssertEqual(
            try XCTUnwrap(presentation.menuBar.gaugePercentage),
            32,
            accuracy: 0.0001
        )
        XCTAssertFalse(presentation.menuBar.showsGaugePercentage)
    }

    func testTooltipAndAccessibilityRetainAllEvidenceWhenMenuCondenses() throws {
        let resetAt = now.addingTimeInterval(3 * 3_600 + 12 * 60)
        let snapshot = makeSnapshot(
            lanes: [
                makeLane(
                    id: AntigravityQuotaLaneID.geminiFiveHour.rawValue,
                    scope: .gemini,
                    cadence: .fiveHour,
                    remaining: 0.25,
                    resetAt: resetAt
                ),
                makeLane(
                    id: AntigravityQuotaLaneID.thirdPartyWeekly.rawValue,
                    scope: .thirdPartyModels,
                    cadence: .weekly,
                    remaining: 0.1,
                    resetAt: resetAt
                ),
            ],
            identity: ProviderAccountIdentity(
                stableAccountID: "subject-1",
                email: "nathan@example.com"
            ),
            transport: .googleOAuth,
            fetchedAt: now.addingTimeInterval(-125)
        )

        let presentation = AntigravityQuotaPresentationMapper.map(
            snapshot: snapshot,
            settings: .default,
            now: now,
            timeZone: utc
        )

        XCTAssertEqual(
            presentation.identityRail.visibleSegments,
            ["nathan@…", "Google 계정", "2분 전 갱신"]
        )
        XCTAssertFalse(
            presentation.identityRail.accessibilityValue.contains(
                "example.com"
            )
        )
        XCTAssertEqual(presentation.menuBar.condensedText, "90%")
        XCTAssertTrue(presentation.menuBar.tooltip.contains("계정: nathan@…"))
        XCTAssertTrue(presentation.menuBar.tooltip.contains("조회: Google 계정"))
        XCTAssertTrue(presentation.menuBar.tooltip.contains("Gemini"))
        XCTAssertTrue(presentation.menuBar.tooltip.contains("Claude · GPT"))
        XCTAssertTrue(presentation.menuBar.tooltip.contains("5시간: 75% 사용"))
        XCTAssertTrue(presentation.menuBar.tooltip.contains("주간: 90% 사용"))
        XCTAssertTrue(presentation.menuBar.tooltip.contains("3시간 12분 후"))
        XCTAssertTrue(
            presentation.menuBar.accessibilityValue.contains(
                "조회 경로 Google 계정"
            )
        )
    }

    func testFreshnessNeverClaimsSecondLevelPrecision() {
        let presentation = map(
            [
                makeLane(
                    id: AntigravityQuotaLaneID.geminiFiveHour.rawValue,
                    scope: .gemini,
                    cadence: .fiveHour,
                    remaining: 0.5
                ),
            ],
            fetchedAt: now.addingTimeInterval(-59)
        )

        XCTAssertEqual(
            presentation.identityRail.freshnessLabel,
            "방금 갱신"
        )
        XCTAssertFalse(
            presentation.identityRail.freshnessLabel.contains("초")
        )
    }

    private func map(
        _ lanes: [AntigravityQuotaLane],
        settings: AntigravityDisplaySettings = .default,
        fetchedAt: Date? = nil
    ) -> AntigravityQuotaPresentation {
        AntigravityQuotaPresentationMapper.map(
            snapshot: makeSnapshot(
                lanes: lanes,
                identity: ProviderAccountIdentity(
                    stableAccountID: "subject-1",
                    email: "user@example.com"
                ),
                fetchedAt: fetchedAt ?? now
            ),
            settings: settings,
            now: now,
            timeZone: utc
        )
    }

    func testCLIReportWithoutIdentityNamesTheCLILoginInsteadOfAnUnknownAccount() {
        let lane = makeLane(
            id: AntigravityQuotaLaneID.geminiWeekly.rawValue, scope: .gemini, cadence: .weekly, remaining: 0.5)
        let report = makeSnapshot(lanes: [lane], transport: .cliUsageReport, fetchedAt: now)
        let appWithoutIdentity = makeSnapshot(lanes: [lane], transport: .localAppRPC, fetchedAt: now)

        let reportRail = AntigravityQuotaPresentationMapper.map(
            snapshot: report, settings: .default, now: now, timeZone: utc
        ).identityRail
        let appRail = AntigravityQuotaPresentationMapper.map(
            snapshot: appWithoutIdentity, settings: .default, now: now, timeZone: utc
        ).identityRail

        XCTAssertEqual(reportRail.accountLabel, "AGY CLI 로그인 계정")
        XCTAssertEqual(reportRail.sourceLabel, "AGY CLI")
        XCTAssertTrue(reportRail.tooltip.contains("조회 계정: AGY CLI 로그인 계정"))
        XCTAssertEqual(appRail.accountLabel, "계정 미확인")
    }

    private func makeSnapshot(
        lanes: [AntigravityQuotaLane],
        identity: ProviderAccountIdentity? = nil,
        transport: AntigravityQuotaProvenance.Transport = .localAppRPC,
        fetchedAt: Date,
        decodeIssues: [AntigravityQuotaDecodeIssue] = []
    ) -> AntigravityQuotaSnapshot {
        AntigravityQuotaSnapshot(
            identity: identity,
            plan: "test",
            lanes: lanes,
            decodeIssues: decodeIssues,
            provenance: AntigravityQuotaProvenance(
                transport: transport,
                endpointOwner: .external,
                accountIdentity: identity,
                capability: .groupedQuotaSummary,
                processIdentity: nil
            ),
            fetchedAt: fetchedAt
        )
    }

    private func makeLane(
        id: String,
        scope: AntigravityQuotaScope,
        cadence: AntigravityQuotaCadence,
        remaining: Double?,
        resetAt: Date? = nil,
        availability: AntigravityQuotaAvailability = .available
    ) -> AntigravityQuotaLane {
        AntigravityQuotaLane(
            id: AntigravityQuotaLaneID(rawValue: id),
            upstreamGroupID: "group-\(id)",
            upstreamBucketID: "bucket-\(id)",
            scope: scope,
            cadence: cadence,
            remainingFraction: remaining,
            resetAt: resetAt,
            resetDescription: nil,
            availability: availability
        )
    }
}

extension AntigravityQuotaPresentationMapperTests {

    func testMissingExplicitMenuBarLaneRemainsVisibleAsUnavailable() {
        let missing = AntigravityQuotaLaneID(rawValue: "flash.weekly")
        let pro = makeLane(
            id: "pro.weekly", scope: .unknown(id: "pro", label: "Gemini Pro"), cadence: .weekly, remaining: 0.2)
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.percentageLaneIDs = [missing]
        settings.menuBar.resetLaneIDs = []
        let presentation = AntigravityQuotaPresentationMapper.map(
            snapshot: makeSnapshot(lanes: [pro], fetchedAt: now), settings: settings, now: now)
        XCTAssertTrue(presentation.menuBar.regularText?.contains("데이터 없음") == true)
        XCTAssertTrue(presentation.menuBar.accessibilityValue.contains("데이터 없음"))
    }

    func testMenuBarAccessibilityIncludesDisplayedModelSeparateFromGauge() {
        let flash = makeLane(
            id: "flash.weekly", scope: .unknown(id: "flash", label: "Gemini Flash"), cadence: .weekly, remaining: 0.7)
        let pro = makeLane(
            id: "pro.weekly", scope: .unknown(id: "pro", label: "Gemini Pro"), cadence: .weekly, remaining: 0.2)
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.laneSelection = .fixed(flash.id)
        settings.menuBar.percentageLaneIDs = [pro.id]
        settings.menuBar.resetLaneIDs = []
        let presentation = AntigravityQuotaPresentationMapper.map(
            snapshot: makeSnapshot(lanes: [flash, pro], fetchedAt: now), settings: settings, now: now)
        XCTAssertEqual(presentation.menuBar.selectedLaneID, flash.id)
        XCTAssertTrue(presentation.menuBar.regularText?.contains("Gemini Pro") == true)
        XCTAssertTrue(presentation.menuBar.accessibilityValue.contains("Gemini Pro"))
    }

    func testExplicitMenuBarNumbersAndResetAreIndependentOfGaugeAndPopoverHiding() throws {
        let flash = makeLane(
            id: "flash.weekly", scope: .unknown(id: "flash", label: "Gemini Flash"), cadence: .weekly, remaining: 0.7)
        let pro = makeLane(
            id: "pro.weekly", scope: .unknown(id: "pro", label: "Gemini Pro"), cadence: .weekly, remaining: 0.2,
            resetAt: now.addingTimeInterval(3600))
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.laneSelection = .fixed(flash.id)
        settings.menuBar.percentageLaneIDs = [flash.id]
        settings.menuBar.resetLaneIDs = [pro.id]
        settings.standard.hiddenLaneIDs = [pro.id]
        let presentation = AntigravityQuotaPresentationMapper.map(
            snapshot: makeSnapshot(lanes: [flash, pro], fetchedAt: now), settings: settings, now: now, timeZone: utc)
        XCTAssertEqual(presentation.menuBar.selectedLaneID, flash.id)
        XCTAssertTrue(presentation.menuBar.regularText?.contains("Gemini Flash") == true)
        XCTAssertTrue(presentation.menuBar.regularText?.contains("Gemini Pro") == true)
        XCTAssertFalse(presentation.menuBar.regularText?.contains("80%") == true)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AntigravityDisplaySettings.self, from: data), settings)
    }
}
