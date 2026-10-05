import XCTest
@testable import ClaudeUsage

final class TimeFormatUnificationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "TimeFormatUnificationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDifferentProviderFormatsQueueOneUpdateNote() {
        defaults.set("24h", forKey: "timeFormat")
        defaults.set("12h", forKey: "codexTimeFormat")

        TimeFormatUnification.migrate(defaults: defaults)
        TimeFormatUnification.migrate(defaults: defaults)

        XCTAssertEqual(UpdateNotesQueue.pending(defaults: defaults), [.timeFormatUnified])
    }

    func testMigrationDecidesOnlyOnce() {
        defaults.set("12h", forKey: "timeFormat")
        TimeFormatUnification.migrate(defaults: defaults)
        defaults.set("24h", forKey: "codexTimeFormat")

        TimeFormatUnification.migrate(defaults: defaults)

        XCTAssertTrue(UpdateNotesQueue.pending(defaults: defaults).isEmpty)
    }

    func testDefaultAntigravityFormatIsNotTreatedAsAChoice() throws {
        defaults.set("12h", forKey: "timeFormat")
        defaults.set(
            try JSONEncoder().encode(AntigravityDisplaySettings.default),
            forKey: AntigravitySettingsMigrationKeys.displaySettings)

        TimeFormatUnification.migrate(defaults: defaults)

        XCTAssertTrue(UpdateNotesQueue.pending(defaults: defaults).isEmpty)
    }

    func testMatchingFormatsKeepSilent() {
        defaults.set("remaining", forKey: "timeFormat")
        defaults.set("remaining", forKey: "codexTimeFormat")

        TimeFormatUnification.migrate(defaults: defaults)

        XCTAssertTrue(UpdateNotesQueue.pending(defaults: defaults).isEmpty)
    }

    func testLegacyCountdownChoicesDoNotQueueAFalseProviderMismatch() {
        defaults.set("remaining_clock", forKey: "timeFormat")
        defaults.set("remaining_total_clock", forKey: "codexTimeFormat")

        TimeFormatUnification.migrate(defaults: defaults)

        XCTAssertTrue(UpdateNotesQueue.pending(defaults: defaults).isEmpty)
    }

    func testRetiredCodexKeyIsRemovedAfterMigration() {
        defaults.set("12h", forKey: "codexTimeFormat")
        TimeFormatUnification.migrate(defaults: defaults)
        RetiredAppDefaults.remove(from: defaults)
        XCTAssertNil(defaults.object(forKey: "codexTimeFormat"))
    }

    func testAntigravityUsesTheCommonFormat() {
        let display = AntigravityRuntimeController.applyingCommonTimeFormat(.remaining, to: .default)
        XCTAssertEqual(display.menuBar.timeFormat.rawValue, TimeFormatStyle.remaining.rawValue)
        XCTAssertEqual(AntigravityRuntimeController.applyingCommonTimeFormat(nil, to: .default), .default)
    }
}

final class RemainingTimeFormatTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testDurationKeepsItsRoundingAndWeeklyRules() {
        XCTAssertEqual(TimeFormatter.formatRemaining(until: now, now: now, isWeekly: false), "0h 00m")
        XCTAssertEqual(
            TimeFormatter.formatRemaining(until: now.addingTimeInterval(-1), now: now, isWeekly: false), "0h 00m")
        XCTAssertEqual(
            TimeFormatter.formatRemaining(until: now.addingTimeInterval(59 * 60 + 29), now: now, isWeekly: false),
            "0h 59m")
        XCTAssertEqual(
            TimeFormatter.formatRemaining(until: now.addingTimeInterval(59 * 60 + 30), now: now, isWeekly: false),
            "1h 00m")
        XCTAssertEqual(
            TimeFormatter.formatRemaining(
                until: now.addingTimeInterval(3 * 86400 + 2 * 3600 + 12 * 60),
                now: now, isWeekly: true), "3d 2h")
    }

    func testLegacyCountdownValuesDecodeAndEncodeAsTheSharedDuration() throws {
        XCTAssertEqual(TimeFormatStyle.allCases, [.h24, .h12, .remaining])
        for rawValue in ["remaining_clock", "remaining_total_clock"] {
            XCTAssertEqual(TimeFormatStyle(rawValue: rawValue), .remaining)
            let style = try JSONDecoder().decode(TimeFormatStyle.self, from: Data("\"\(rawValue)\"".utf8))
            XCTAssertEqual(style, .remaining)
            XCTAssertEqual(String(decoding: try JSONEncoder().encode(style), as: UTF8.self), "\"remaining\"")
            let agyStyle = try JSONDecoder().decode(
                AntigravityDisplaySettings.MenuBarPresentationIntent.TimeFormat.self,
                from: Data("\"\(rawValue)\"".utf8))
            XCTAssertEqual(agyStyle, .remaining)
        }
        XCTAssertNil(TimeFormatStyle(rawValue: "unknown-format"))
        XCTAssertThrowsError(try JSONDecoder().decode(TimeFormatStyle.self, from: Data("\"unknown-format\"".utf8)))
    }
}
