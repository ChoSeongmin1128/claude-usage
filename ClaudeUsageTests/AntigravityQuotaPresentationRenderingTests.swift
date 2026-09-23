import AppKit
import SwiftUI
import XCTest
@testable import ClaudeUsage

@MainActor
final class AntigravityQuotaPresentationRenderingTests: XCTestCase {
    func testStandardQuotaRowsRenderAtPopoverWidthInLightAndDark() throws {
        let presentation = makePresentation()

        for scheme in [ColorScheme.light, .dark] {
            let view = VStack(alignment: .leading, spacing: 12) {
                ProviderIdentityRail(
                    projection: presentation.identityRail
                )
                ForEach(presentation.groups) { group in
                    AntigravityQuotaGroupView(group: group)
                }
            }
            .frame(width: 336)
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(scheme)

            let image = try render(view)

            XCTAssertEqual(image.size.width, 368, accuracy: 0.5)
            XCTAssertGreaterThan(image.size.height, 120)
            XCTAssertLessThan(image.size.height, 290)
            addAttachment(
                image,
                name: "Antigravity standard usage rows \(scheme)"
            )
        }
    }

    func testCompactVisibleMetricsRenderAtMinimumPopoverWidth() throws {
        let presentation = makePresentation()
        let view = VStack(alignment: .leading, spacing: 4) {
            ProviderIdentityRail(
                projection: presentation.identityRail,
                compact: true
            )
            AntigravityCompactQuotaView(
                presentation: presentation.compact
            )
        }
        .frame(width: 276)
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)

        let image = try render(view)

        XCTAssertEqual(image.size.width, 296, accuracy: 0.5)
        XCTAssertGreaterThan(image.size.height, 90)
        let rows = try render(AntigravityCompactQuotaView(presentation: presentation.compact).frame(width: 276))
        XCTAssertEqual(
            rows.size.height,
            PopoverLayoutMetrics.compactContentBodyHeight(rowCount: presentation.compact.metrics.count),
            accuracy: 0.5)
        XCTAssertLessThan(image.size.height, 140)
        XCTAssertEqual(
            presentation.compact.metrics.map(\.label),
            [
                "Claude·GPT 주간",
                "Gemini 주간",
                "Gemini 5시간",
                "Claude·GPT 5시간",
            ]
        )
        addAttachment(
            image,
            name: "Antigravity compact visible lanes"
        )
    }

    func testSingleWeeklyModelUsesTheSameOneLineRowAsClaude() throws {
        let now = Date()
        let reset = now.addingTimeInterval(3 * 86400 + 2 * 3600 + 5 * 60)
        let lane = makeLane(id: .geminiWeekly, scope: .gemini, cadence: .weekly, remaining: 0.75, resetAt: reset)
        let snapshot = AntigravityQuotaSnapshot(
            identity: nil, plan: nil, lanes: [lane], decodeIssues: [],
            provenance: .init(
                transport: .borrowedAGYRPC, endpointOwner: .borrowed, accountIdentity: nil,
                capability: .groupedQuotaSummary, processIdentity: nil), fetchedAt: now)
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.timeFormat = .remaining
        let presentation = AntigravityQuotaPresentationMapper.map(snapshot: snapshot, settings: settings, now: now)
        let metric = try XCTUnwrap(presentation.compact.metrics.first)
        XCTAssertEqual(metric.label, "Gemini")
        let agy = AntigravityCompactQuotaView(presentation: presentation.compact).frame(width: 276)
        let claude = CompactUsageRow(
            label: "Fable", percentage: 25, resetAt: metric.resetAt, isWeekly: true, timeFormatStyle: .remaining
        ).frame(width: 276)
        XCTAssertEqual(try render(agy).size.height, 18, accuracy: 0.5)
        XCTAssertEqual(try render(claude).size.height, try render(agy).size.height, accuracy: 0.5)
        let rows = VStack(spacing: PopoverLayoutMetrics.compactSectionSpacing) {
            claude; agy
        }
        .padding(10).frame(width: 296).background(Color(nsColor: .windowBackgroundColor))
        addAttachment(try render(rows), name: "Claude and AGY shared single-line weekly reset")
    }

    func testUnknownAndUnavailableLanesRenderWithoutSyntheticProgress() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = AntigravityQuotaSnapshot(
            identity: nil,
            plan: nil,
            lanes: [
                AntigravityQuotaLane(
                    id: AntigravityQuotaLaneID(
                        rawValue: "future.daily"
                    ),
                    upstreamGroupID: "future",
                    upstreamBucketID: "daily",
                    scope: .unknown(
                        id: "future",
                        label: "Future Tools"
                    ),
                    cadence: .unknown(rawValue: "daily"),
                    remainingFraction: nil,
                    resetAt: nil,
                    resetDescription: nil,
                    availability: .unknown
                ),
            ],
            decodeIssues: [],
            provenance: AntigravityQuotaProvenance(
                transport: .borrowedAGYRPC,
                endpointOwner: .borrowed,
                accountIdentity: nil,
                capability: .groupedQuotaSummary,
                processIdentity: nil
            ),
            fetchedAt: now
        )
        let presentation = AntigravityQuotaPresentationMapper.map(
            snapshot: snapshot,
            settings: .default,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let group = try XCTUnwrap(presentation.groups.first)
        let view = AntigravityQuotaGroupView(group: group)
            .frame(width: 336)
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))

        let image = try render(view)

        XCTAssertGreaterThan(image.size.height, 35)
        XCTAssertNil(group.lanes.first?.percentageText)
        XCTAssertEqual(
            group.lanes.first?.value,
            .unavailable(.notReported)
        )
        addAttachment(
            image,
            name: "Antigravity unknown unavailable lane"
        )
    }

    private func makePresentation() -> AntigravityQuotaPresentation {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetAt = now.addingTimeInterval(4 * 3_600)
        let lanes: [AntigravityQuotaLane] = [
            makeLane(
                id: .geminiFiveHour,
                scope: .gemini,
                cadence: .fiveHour,
                remaining: 0.82,
                resetAt: resetAt
            ),
            makeLane(
                id: .geminiWeekly,
                scope: .gemini,
                cadence: .weekly,
                remaining: 0.58,
                resetAt: resetAt
            ),
            makeLane(
                id: .thirdPartyFiveHour,
                scope: .thirdPartyModels,
                cadence: .fiveHour,
                remaining: 0.88,
                resetAt: resetAt
            ),
            makeLane(
                id: .thirdPartyWeekly,
                scope: .thirdPartyModels,
                cadence: .weekly,
                remaining: 0.32,
                resetAt: resetAt
            ),
        ]
        let identity = ProviderAccountIdentity(
            stableAccountID: "subject-1",
            email: "a-very-long-antigravity-account@example.com"
        )
        let snapshot = AntigravityQuotaSnapshot(
            identity: identity,
            plan: "pro",
            lanes: lanes,
            decodeIssues: [],
            provenance: AntigravityQuotaProvenance(
                transport: .borrowedAGYRPC,
                endpointOwner: .borrowed,
                accountIdentity: identity,
                capability: .groupedQuotaSummary,
                processIdentity: nil
            ),
            fetchedAt: now.addingTimeInterval(-90)
        )
        return AntigravityQuotaPresentationMapper.map(
            snapshot: snapshot,
            settings: .default,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
    }

    private func makeLane(
        id: AntigravityQuotaLaneID,
        scope: AntigravityQuotaScope,
        cadence: AntigravityQuotaCadence,
        remaining: Double,
        resetAt: Date
    ) -> AntigravityQuotaLane {
        AntigravityQuotaLane(
            id: id,
            upstreamGroupID: id.rawValue,
            upstreamBucketID: id.rawValue,
            scope: scope,
            cadence: cadence,
            remainingFraction: remaining,
            resetAt: resetAt,
            resetDescription: nil,
            availability: .available
        )
    }

    private func render<Content: View>(
        _ content: Content
    ) throws -> NSImage {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return try XCTUnwrap(renderer.nsImage)
    }

    private func addAttachment(
        _ image: NSImage,
        name: String
    ) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
