import AppKit
import Foundation
import XCTest
@testable import ClaudeUsage

@MainActor
final class QuotaAvailabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_150_000)

    func testHiddenClaudeWeeklyBlocksSessionAndFableWithoutChangingMeasurements() throws {
        let usage = try decode(
            ClaudeUsageResponse.self,
            """
            {"five_hour":{"utilization":0},"seven_day":{"utilization":100},
             "limits":[{"group":"weekly","kind":"weekly_scoped","percent":11,
                        "scope":{"model":{"display_name":"Fable"}}}]}
            """)
        let limits = UsageLimitCatalog.claude(usage)
        let session = try XCTUnwrap(limits.first { $0.periodSeconds == 18_000 })
        let weekly = try XCTUnwrap(limits.first { $0.scope == "seven_day" })
        let fable = try XCTUnwrap(limits.first(where: \.isModelScoped))
        let availability = QuotaAvailability(limits: limits, now: now)
        let projection = MenuBarQuotaProjection(
            selection: .init(percentageIDs: [session.id], gaugeIDs: [session.id]),
            limits: limits, basis: .remaining, timeFormat: .remaining, availability: availability)
        XCTAssertEqual(projection.gauges.first?.percentage, 100)
        XCTAssertEqual(projection.gauges.first?.indicator, .exhausted)
        XCTAssertEqual(projection.percentageText, "", "The same warning must not be duplicated alongside the battery")
        XCTAssertEqual(availability[session.id]?.blockers.map(\.limitID), [weekly.id])
        XCTAssertEqual(availability[fable.id]?.indicator, .exhausted)
        XCTAssertEqual(availability.row(for: weekly.id)?.isExhausted, true)
        XCTAssertEqual(availability.row(for: session.id)?.isExhausted, false)
    }

    func testModelOnlyExhaustionDoesNotBlockClaudeSession() throws {
        let usage = try decode(
            ClaudeUsageResponse.self,
            """
            {"five_hour":{"utilization":0},"seven_day":{"utilization":10},
             "limits":[{"group":"weekly","kind":"weekly_scoped","percent":100,
                        "scope":{"model":{"display_name":"Fable"}}}]}
            """)
        let limits = UsageLimitCatalog.claude(usage)
        let availability = QuotaAvailability(limits: limits, now: now)
        XCTAssertNil(availability.row(legacyKey: "fiveHour"))
        XCTAssertEqual(limits.first(where: \.isModelScoped).flatMap { availability[$0.id]?.indicator }, .exhausted)
    }

    func testCodexWeeklyOnlyAndNamedBucketRemainIndependent() throws {
        let usage = try decode(
            CodexUsageResponse.self,
            """
            {"rate_limit":{"primary_window":{"used_percent":100,"limit_window_seconds":604800}},
             "additional_rate_limits":[{"metered_feature":"spark","limit_name":"Spark",
                 "rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":604800}}}]}
            """)
        let limits = UsageLimitCatalog.codex(usage)
        let availability = QuotaAvailability(limits: limits, now: now)
        XCTAssertFalse(usage.hasSessionWindow)
        XCTAssertEqual(availability.row(legacyKey: "base", slot: "primary")?.isExhausted, true)
        let spark = try XCTUnwrap(limits.first(where: \.isModelScoped))
        XCTAssertNil(availability[spark.id])
        let workspace = QuotaAvailability(limits: limits, accountRestriction: "워크스페이스 크레딧 소진", now: now)
        XCTAssertEqual(workspace[spark.id]?.blockers.first?.title, "워크스페이스 크레딧 소진")
        XCTAssertEqual(workspace[spark.id]?.canUsePaidCredits, false)
    }

    func testAntigravityMapperWarnsOnlyWithinAffectedModelFamily() throws {
        let snapshot = AntigravityQuotaSnapshot(
            identity: nil, plan: nil,
            lanes: [
                agyLane(.geminiFiveHour, scope: .gemini, cadence: .fiveHour, remaining: 1),
                agyLane(.geminiWeekly, scope: .gemini, cadence: .weekly, remaining: 0),
                agyLane(.thirdPartyFiveHour, scope: .thirdPartyModels, cadence: .fiveHour, remaining: 0.6),
            ], decodeIssues: [], provenance: .init(transport: .cliUsageReport, accountIdentity: nil), fetchedAt: now)
        let mapped = AntigravityQuotaPresentationMapper.map(snapshot: snapshot, settings: .default, now: now)
        let lanes = mapped.allGroups.flatMap(\.lanes)
        XCTAssertEqual(lanes.first { $0.id == .geminiFiveHour }?.quota?.status.indicator, .exhausted)
        XCTAssertEqual(lanes.first { $0.id == .geminiWeekly }?.quota?.isExhausted, true)
        XCTAssertNil(lanes.first { $0.id == .thirdPartyFiveHour }?.quota)
    }

    func testRefreshingPreviouslyStaleReadingsDoesNotReviveOldWarnings() throws {
        let usage = ClaudeUsageResponse(
            fiveHour: .init(utilization: 0, resetsAt: nil),
            sevenDay: .init(utilization: 100, resetsAt: nil))
        let snapshot = RuntimeProviderSnapshot(
            service: .claude, payload: .claude(usage), isLoading: true, lastUpdated: now,
            credentialState: .usable, isDetected: true, canAttemptRefresh: true, hasAuthError: false,
            consecutiveFailures: 2)
        XCTAssertNil(snapshot.quotaAvailability(now: now).row(legacyKey: "fiveHour"))

        let agy = AntigravityQuotaSnapshot(
            identity: nil, plan: nil,
            lanes: [agyLane(.geminiWeekly, scope: .gemini, cadence: .weekly, remaining: 0)],
            decodeIssues: [], provenance: .init(transport: .cliUsageReport, accountIdentity: nil), fetchedAt: now)
        let state = AntigravityPresentationState.refreshing(previous: agy)
        guard
            case .content(let stale) = AntigravityQuotaPresentationMapper.map(
                state: state, settings: .default, marksStale: true, now: now
            ),
            case .content(let current) = AntigravityQuotaPresentationMapper.map(
                state: state, settings: .default, marksStale: false, now: now
            )
        else { return XCTFail("Expected retained AGY readings") }
        XCTAssertNil(stale.allGroups.first?.lanes.first?.quota)
        XCTAssertEqual(current.allGroups.first?.lanes.first?.quota?.status.indicator, .exhausted)
    }

    func testResetBoundaryStaleValueAndRoundingDoNotDeclareExhaustion() throws {
        let reset = ISO8601DateFormatter().string(from: now)
        let usage = try decode(
            ClaudeUsageResponse.self,
            """
            {"five_hour":{"utilization":99.8},"seven_day":{"utilization":100,"resets_at":"\(reset)"}}
            """)
        let limits = UsageLimitCatalog.claude(usage)
        let session = try XCTUnwrap(limits.first)
        XCTAssertEqual(QuotaAvailability(limits: limits, now: now)[session.id]?.indicator, .checking)
        XCTAssertNil(QuotaAvailability(limits: limits, isCurrent: false, now: now)[session.id])
        XCTAssertNil(QuotaAvailability(limits: [session], now: now)[session.id])
        let stillExhausted = QuotaAvailability(limits: limits, paidCoverage: .shared, now: now.addingTimeInterval(-1))
        XCTAssertEqual(stillExhausted[session.id]?.indicator, .exhausted)
        XCTAssertEqual(stillExhausted[session.id]?.canUsePaidCredits, true)
    }

    func testAutomaticRecoveryUsesTheLastRequiredResetAndRejectsUnknownDates() throws {
        let date = ISO8601DateFormatter()
        let short = date.string(from: now.addingTimeInterval(3600))
        let long = date.string(from: now.addingTimeInterval(86_400 * 3))
        let usage = try decode(
            ClaudeUsageResponse.self,
            """
            {"five_hour":{"utilization":100,"resets_at":"\(short)"},
             "seven_day":{"utilization":100,"resets_at":"\(long)"}}
            """)
        let limits = UsageLimitCatalog.claude(usage)
        let session = try XCTUnwrap(limits.first { $0.legacyKey == "fiveHour" })
        let weekly = try XCTUnwrap(limits.first { $0.legacyKey == "weekly" })
        let assessment = QuotaAvailability(limits: limits, now: now)
        XCTAssertEqual(assessment[session.id]?.automaticRecovery?.limitID, weekly.id)
        let retrying = QuotaAvailability(limits: limits, now: now.addingTimeInterval(3600))
        XCTAssertEqual(retrying[session.id]?.indicator, .exhausted)
        XCTAssertNil(retrying[session.id]?.automaticRecovery)
        let unknown = QuotaAvailability(limits: limits, accountRestriction: "지출 제한", now: now)
        XCTAssertNil(unknown[session.id]?.automaticRecovery)
    }

    func testTextOnlySelectionStillWarnsWithAnOldGaugeSelection() throws {
        let usage = ClaudeUsageResponse(
            fiveHour: .init(utilization: 0, resetsAt: nil), sevenDay: .init(utilization: 100, resetsAt: nil))
        let limits = UsageLimitCatalog.claude(usage)
        let session = try XCTUnwrap(limits.first)
        let assessment = QuotaAvailability(limits: limits, now: now)
        let numbers = MenuBarQuotaProjection(
            selection: .init(percentageIDs: [session.id], gaugeIDs: [session.id]),
            limits: limits, basis: .remaining, timeFormat: .remaining, availability: assessment, showsGauges: false)
        let time = MenuBarQuotaProjection(
            selection: .init(resetIDs: [session.id], gaugeIDs: [session.id]),
            limits: limits, basis: .remaining, timeFormat: .remaining, availability: assessment, showsGauges: false)
        XCTAssertEqual(numbers.percentageText, "!")
        XCTAssertEqual(time.resetText, "!")
    }

    func testMenuBarPopoverAndHoverUseTheSameClaudeSnapshot() throws {
        let defaultsName = "QuotaAvailabilityTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settings = AppSettings(defaults: defaults)
        settings.popoverCompact = true
        let usage = try decode(
            ClaudeUsageResponse.self,
            """
            {"five_hour":{"utilization":0},"seven_day":{"utilization":100},
             "cedar_ember":{"eligible":true,"grants":[
                 {"id":"a","clears":["five_hour"],"resets_left":1},
                 {"id":"b","clears":["seven_day"],"resets_left":1}]}}
            """)
        let snapshot = RuntimeProviderSnapshot(
            service: .claude, payload: .claude(usage), lastUpdated: now, credentialState: .usable,
            isDetected: true, canAttemptRefresh: true, hasAuthError: false)
        let model = PopoverViewModel(updateRuntimeState: UpdateRuntimeState(settings: settings))
        model.update(snapshots: [snapshot])
        let layout = model.layoutWithSections(for: .claude, settings: settings)
        let weekly = try XCTUnwrap(layout.sections.first { $0.id == "weeklyLimit" })
        guard case .usage(let measurement) = weekly.payload else { return XCTFail("Expected a usage row") }
        XCTAssertEqual(measurement.percentage, 100)
        XCTAssertEqual(measurement.quota?.isExhausted, true)
        let resetSection = try XCTUnwrap(layout.sections.first { $0.kind == .resetCredits })
        XCTAssertEqual(resetSection.displayRowCount, 2)
        if case .resetCredits(let reset) = resetSection.payload {
            XCTAssertEqual(reset.rows.map(\.title), ["주간 초기화권", "5시간 초기화권"])
        }
        XCTAssertTrue(
            MenuBarHoverUsageContent.catalogProvider(snapshot: snapshot, settings: settings)?
                .quotaNotice?.contains("주간 소진") == true)
        let config = ProviderMenuBarDisplayConfig(
            kind: .claude, showIcon: false, style: .batteryBar, percentageDisplay: .none,
            showBatteryPercent: true, resetTimeDisplay: .none, timeFormat: .remaining,
            circularDisplayMode: .usage, iconMetric: .fiveHour, basisOverride: .remaining)
        let menu = MenuBarStatusComposer.claudeSnapshot(
            config: config, usage: usage, error: nil, hasAuthError: false, hasCredential: true,
            secondaryColor: .secondaryLabelColor, icon: nil, availability: snapshot.quotaAvailability(now: now))
        XCTAssertNotNil(menu.styleIcon)
        XCTAssertTrue(menu.accessibilityValue?.contains("주간 소진") == true)
    }

    func testWarningRendersWithinOriginalGaugeBoundsInBothLayouts() throws {
        for design in [MenuBarDesign.modern, .classic] {
            for (style, layout) in [
                (MenuBarStyle.batteryBar, MenuBarGaugeLayout.stacked), (.batteryBar, .horizontal),
                (.circular, .concentric),
            ] {
                let healthy = MenuBarGaugeValue(id: "a", title: "5시간", usedPercentage: 0, basis: .remaining)
                var blocked = healthy
                blocked.indicator = .exhausted
                func render(_ first: MenuBarGaugeValue) throws -> NSImage {
                    try XCTUnwrap(
                        MenuBarIconRenderer.gaugeListIcon(
                            [.init(value: first, color: .systemGreen), .init(value: healthy, color: .systemGreen)],
                            shape: style, layout: layout, showPercent: true, design: design))
                }
                let original = try render(healthy)
                let warning = try render(blocked)
                XCTAssertEqual(original.size, warning.size)
                XCTAssertNotEqual(original.tiffRepresentation, warning.tiffRepresentation)
            }
        }
    }

    private func agyLane(
        _ id: AntigravityQuotaLaneID, scope: AntigravityQuotaScope, cadence: AntigravityQuotaCadence,
        remaining: Double
    ) -> AntigravityQuotaLane {
        .init(
            id: id, upstreamGroupID: nil, upstreamBucketID: id.rawValue, scope: scope, cadence: cadence,
            remainingFraction: remaining, resetAt: now.addingTimeInterval(3_600),
            resetDescription: nil, availability: .available)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
