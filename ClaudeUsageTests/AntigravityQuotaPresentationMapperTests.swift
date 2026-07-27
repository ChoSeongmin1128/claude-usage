import XCTest
@testable import ClaudeUsage

final class AntigravityQuotaPresentationMapperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let utc = TimeZone(secondsFromGMT: 0)!

    func testStandardGroupsKnownScopesAndCadencesBeforePreservedUnknowns() {
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

        let presentation = map(lanes)

        XCTAssertEqual(
            presentation.groups.map(\.title),
            ["Gemini", "Claude · GPT", "Agent Mode"]
        )
        XCTAssertEqual(
            presentation.groups[0].lanes.map(\.cadenceTitle),
            ["5시간", "주간", "burst"]
        )
        XCTAssertEqual(
            presentation.groups[1].lanes.map(\.cadenceTitle),
            ["5시간", "주간"]
        )
        XCTAssertEqual(
            presentation.groups[2].lanes.map(\.cadenceTitle),
            ["daily"]
        )
        XCTAssertFalse(presentation.groups[0].isUnknownScope)
        XCTAssertTrue(presentation.groups[2].isUnknownScope)
        XCTAssertEqual(presentation.observedLaneCount, lanes.count)
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
            ["이전 데이터"]
        )
        XCTAssertEqual(
            stalePresentation.identityRail.tone,
            .attention
        )
        XCTAssertTrue(
            stalePresentation.identityRail.tooltip.contains(
                "최근 갱신에 실패해"
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

    func testCompactAndMenuSelectExactlyOneMostConstrainedLane() throws {
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

        let compactMetric = try XCTUnwrap(presentation.compact.metric)
        XCTAssertEqual(compactMetric.laneID, .thirdPartyWeekly)
        XCTAssertEqual(compactMetric.label, "Claude·GPT · 주간")
        XCTAssertEqual(compactMetric.usedPercentage, 68, accuracy: 0.0001)
        XCTAssertEqual(compactMetric.percentageText, "68%")
        XCTAssertEqual(presentation.menuBar.selectedLaneID, .thirdPartyWeekly)
        XCTAssertEqual(presentation.menuBar.regularText, "C/G·주 68%")
        XCTAssertEqual(presentation.menuBar.condensedText, "68%")
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
            try XCTUnwrap(presentation.compact.metric).laneID,
            .geminiFiveHour
        )
    }

    func testFixedLaneLossFallsBackWithoutMutatingSettings() throws {
        var settings = AntigravityDisplaySettings.default
        let missingCompactID = AntigravityQuotaLaneID(
            rawValue: "removed.compact"
        )
        let missingMenuID = AntigravityQuotaLaneID(
            rawValue: "removed.menu"
        )
        settings.compact.laneSelection = .fixed(missingCompactID)
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
        XCTAssertEqual(
            try XCTUnwrap(presentation.compact.metric).laneID,
            .thirdPartyWeekly
        )
        XCTAssertEqual(presentation.menuBar.selectedLaneID, .thirdPartyWeekly)
        XCTAssertEqual(
            presentation.notices.map(\.surface),
            [.compact, .menuBar]
        )
        XCTAssertEqual(
            presentation.notices.map(\.kind),
            [
                .fixedLaneUnavailable(
                    requestedLaneID: missingCompactID,
                    fallbackLaneID: .thirdPartyWeekly
                ),
                .fixedLaneUnavailable(
                    requestedLaneID: missingMenuID,
                    fallbackLaneID: .thirdPartyWeekly
                ),
            ]
        )
    }

    func testFixedAvailableLaneWinsEvenWhenAnotherLaneIsMoreConstrained() throws {
        var settings = AntigravityDisplaySettings.default
        settings.compact.laneSelection = .fixed(.geminiFiveHour)

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
            try XCTUnwrap(presentation.compact.metric).laneID,
            .geminiFiveHour
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
            "C/G·주 1일 2시간 후"
        )
        XCTAssertEqual(
            presentation.menuBar.condensedText,
            "1일 2시간 후"
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
