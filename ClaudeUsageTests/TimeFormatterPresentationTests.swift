import AppKit
import SwiftUI
import XCTest
@testable import ClaudeUsage

@MainActor
final class ShortRemainingTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testShortFormatDropsMinutesOnlyAfterTwentyFourHours() {
        let cases: [(TimeInterval, String, String)] = [
            (0, "0:00", "0:00"),
            (-1, "0:00", "0:00"),
            (59, "0:00", "0:00"),
            (14 * 3600 + 22 * 60 + 59, "14:22", "14:22"),
            (23 * 3600 + 59 * 60 + 59, "23:59", "23:59"),
            (24 * 3600, "1d:00", "1일:00"),
            (24 * 3600 + 59 * 60 + 59, "1d:00", "1일:00"),
            (3 * 86400 + 14 * 3600 + 22 * 60, "3d:14", "3일:14"),
        ]
        for (interval, english, korean) in cases {
            for weekly in [false, true] {
                XCTAssertEqual(short(interval, language: .english, weekly: weekly), english)
                XCTAssertEqual(short(interval, language: .korean, weekly: weekly), korean)
            }
        }
    }

    func testTotalHoursAndDurationKeepTheirExistingRules() {
        let date = now.addingTimeInterval(3 * 86400 + 14 * 3600 + 22 * 60)
        for language in TimeUnitLanguage.allCases {
            XCTAssertEqual(
                TimeFormatter.formatRemaining(
                    until: date, now: now, style: .remainingTotalClock, isWeekly: true, unitLanguage: language),
                "86:22")
            XCTAssertEqual(
                TimeFormatter.formatRemaining(
                    until: now.addingTimeInterval(59 * 60 + 30), now: now,
                    style: .remainingTotalClock, isWeekly: false, unitLanguage: language),
                "1:00")
        }
        XCTAssertEqual(
            TimeFormatter.formatRemaining(until: date, now: now, style: .remaining, isWeekly: true), "3d 14h")
        XCTAssertEqual(
            TimeFormatter.formatRemaining(
                until: date, now: now, style: .remaining, isWeekly: true, unitLanguage: .korean), "3일 14시간")
        XCTAssertEqual(
            TimeFormatter.formatRemaining(
                until: now.addingTimeInterval(14 * 3600 + 22 * 60), now: now,
                style: .remaining, isWeekly: false, unitLanguage: .korean), "14시간 22분")
    }

    func testCountdownUnitsDoNotFollowLocaleOrChangeAbsoluteClocks() {
        let date = now.addingTimeInterval(3 * 86400 + 14 * 3600 + 22 * 60)
        for locale in [Locale(identifier: "ko_KR"), Locale(identifier: "en_US"), Locale(identifier: "fr_FR")] {
            XCTAssertEqual(
                TimeFormatter.formatUsageResetDetail(
                    resetAt: date, isWeekly: true, style: .remainingClock, now: now,
                    locale: locale, timeZone: TimeZone(secondsFromGMT: 0)!, label: nil, unitLanguage: .english),
                "3d:14")
            XCTAssertEqual(
                TimeFormatter.formatUsageResetDetail(
                    resetAt: date, isWeekly: true, style: .remainingClock, now: now,
                    locale: locale, timeZone: TimeZone(secondsFromGMT: 0)!, label: nil, unitLanguage: .korean),
                "3일:14")
            for style in [TimeFormatStyle.h12, .h24] {
                let english = TimeFormatter.formatUsageResetDetail(
                    resetAt: date, isWeekly: true, style: style, now: now,
                    locale: locale, timeZone: TimeZone(secondsFromGMT: 0)!, label: nil, unitLanguage: .english)
                let korean = TimeFormatter.formatUsageResetDetail(
                    resetAt: date, isWeekly: true, style: style, now: now,
                    locale: locale, timeZone: TimeZone(secondsFromGMT: 0)!, label: nil, unitLanguage: .korean)
                XCTAssertEqual(english, korean)
            }
        }
    }

    func testLegacyRawFormatStillDecodesAmongFiveChoices() throws {
        XCTAssertEqual(TimeFormatStyle.allCases.count, 5)
        let style = try JSONDecoder().decode(TimeFormatStyle.self, from: Data("\"remaining_clock\"".utf8))
        XCTAssertEqual(style, .remainingClock)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(style), as: UTF8.self), "\"remaining_clock\"")
        XCTAssertEqual(style.displayName, "남은 시간, 짧게")
    }

    private func short(_ interval: TimeInterval, language: TimeUnitLanguage, weekly: Bool) -> String {
        TimeFormatter.formatRemaining(
            until: now.addingTimeInterval(interval), now: now, style: .remainingClock,
            isWeekly: weekly, unitLanguage: language)
    }
}

@MainActor
final class TimeUnitLanguagePropagationTests: XCTestCase {
    func testCatalogPassesTheCommonLanguageToClaudeAndCodexRows() throws {
        let suite = "TimeUnitLanguagePropagation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.timeFormat = .remainingClock
        settings.timeUnitLanguage = .korean
        let claude = try JSONDecoder().decode(
            ClaudeUsageResponse.self,
            from: Data(#"{"five_hour":{"utilization":25,"resets_at":"2030-01-01T00:00:00Z"}}"#.utf8))
        let codex = try JSONDecoder().decode(
            CodexUsageResponse.self,
            from: Data(
                #"{"rate_limit":{"primary_window":{"used_percent":25,"reset_at":1893456000,"limit_window_seconds":18000}}}"#
                    .utf8))
        let context = UsageItemContext(
            density: .compact, settings: settings, claudeUsage: claude, claudeOverage: nil,
            claudeAccounts: [], activeClaudeAccountID: nil, codexUsage: codex, codexError: nil)
        for (service, item) in [(PopoverService.claude, "currentSession"), (.codex, "codexPrimary")] {
            let catalog = try XCTUnwrap(UsageItemCatalogRegistry.catalog(for: service))
            let section = try XCTUnwrap(catalog.section(for: item, context: context))
            guard case .usage(let usage) = section.payload else { return XCTFail("Expected numeric usage row") }
            XCTAssertEqual(usage.timeFormatStyle, .remainingClock)
            XCTAssertEqual(usage.timeUnitLanguage, .korean)
        }
    }

    func testLanguageChangeInvalidatesTheActualMenuBarRenderKey() throws {
        let suite = "MenuBarTimeUnitLanguage.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.timeFormat = .remainingClock
        let english = try XCTUnwrap(settings.menuBarDisplayConfig(for: .claude))
        settings.timeUnitLanguage = .korean
        let korean = try XCTUnwrap(settings.menuBarDisplayConfig(for: .claude))
        func key(_ config: ProviderMenuBarDisplayConfig) -> MenuBarRenderKey {
            let snapshot = MenuBarStatusComposer.claudeSnapshot(
                config: config, usage: nil, error: nil, hasAuthError: false, hasCredential: false,
                secondaryColor: .secondaryLabelColor, icon: nil, renderImages: false)
            return MenuBarRenderKey(
                appearance: .light, usesHighContrastText: false, layout: .single(snapshot.renderKey))
        }
        var state = MenuBarContentApplicationState()
        XCTAssertTrue(state.shouldApply(key(english), force: false))
        XCTAssertTrue(state.shouldApply(key(korean), force: false))
        XCTAssertFalse(state.shouldApply(key(korean), force: false))
    }

    func testUnitLanguageObservationReprojectsWithoutRequestingQuota() async throws {
        let suite = "ObservedTimeUnitLanguage.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let coordinator = AppRuntimeObservationCoordinator()
        defer { coordinator.cancelAll() }
        var formatChanges = 0
        var refreshChanges = 0
        let changed = expectation(description: "one common formatting change")
        coordinator.bind(
            settings: settings, onRefreshConfigurationChanged: { _ in refreshChanges += 1 },
            onUpdateConfigurationChanged: {}, onMenuBarDisplayChanged: {}, onProviderSelectionChanged: { _ in },
            onClaudeCredentialContextChanged: {},
            onTimeFormatChanged: {
                formatChanges += 1
                changed.fulfill()
            })
        XCTAssertEqual(formatChanges, 0)
        settings.timeUnitLanguage = .korean
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(formatChanges, 1)
        XCTAssertEqual(refreshChanges, 0)
    }

    func testAntigravityProjectsLanguageAcrossAllSurfaces() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3 * 86400 + 14 * 3600 + 22 * 60)
        let snapshot = AntigravityQuotaSnapshot(
            identity: nil, plan: nil,
            lanes: [
                .init(
                    id: .geminiWeekly, upstreamGroupID: "gemini", upstreamBucketID: "weekly", scope: .gemini,
                    cadence: .weekly, remainingFraction: 0.5, resetAt: reset, resetDescription: nil,
                    availability: .available)
            ],
            decodeIssues: [],
            provenance: .init(
                transport: .cliUsageReport, endpointOwner: .managed, accountIdentity: nil,
                capability: .groupedQuotaSummary, processIdentity: nil), fetchedAt: now)
        var settings = AntigravityDisplaySettings.default
        settings.menuBar.timeFormat = .remainingClock
        settings.menuBar.showsSelectedLanePercentage = false
        settings.menuBar.showsSelectedLaneResetTime = true
        for (language, expected) in [(TimeUnitLanguage.english, "3d:14"), (.korean, "3일:14")] {
            let presentation = AntigravityQuotaPresentationMapper.map(
                snapshot: snapshot, settings: settings, unitLanguage: language, now: now)
            XCTAssertEqual(presentation.groups[0].lanes[0].resetText, expected)
            XCTAssertEqual(presentation.compact.metrics[0].timeUnitLanguage, language)
            XCTAssertTrue(presentation.menuBar.regularText?.contains(expected) == true)
        }
    }
}

@MainActor
final class TimeFormatterPresentationTests: XCTestCase {
    func testShortTimeExamplesRenderInBothLanguages() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let intervals: [TimeInterval] = [14 * 3600 + 22 * 60, 24 * 3600, 3 * 86400 + 14 * 3600 + 22 * 60]
        for language in TimeUnitLanguage.allCases {
            let content = VStack(alignment: .leading, spacing: 12) {
                Text("남은 시간, 짧게").font(AppDesign.Typography.headline)
                Text(language.displayName).font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                ForEach(intervals.indices, id: \.self) { index in
                    Text(
                        TimeFormatter.formatRemaining(
                            until: now.addingTimeInterval(intervals[index]), now: now, style: .remainingClock,
                            isWeekly: true, unitLanguage: language)
                    )
                    .font(.system(.body, design: .monospaced))
                }
                Divider()
                Text("전체 시간 86:22").font(AppDesign.Typography.caption)
            }
            .padding(20).frame(width: 320, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let attachment = XCTAttachment(image: image)
            let name = "Remaining-time-\(language.rawValue)"
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            if let directory = ProcessInfo.processInfo.environment["CLAUDEUSAGE_UI_RENDER_DIRECTORY"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent(name + ".png"), options: .atomic)
            }
        }
    }
}
