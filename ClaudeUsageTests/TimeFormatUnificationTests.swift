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

    func testRetiredCodexKeyIsRemovedAfterMigration() {
        defaults.set("12h", forKey: "codexTimeFormat")
        TimeFormatUnification.migrate(defaults: defaults)
        RetiredAppDefaults.remove(from: defaults)
        XCTAssertNil(defaults.object(forKey: "codexTimeFormat"))
    }

    func testAntigravityUsesTheCommonFormat() {
        let display = AntigravityRuntimeController.applyingCommonTimeFormat(.remainingClock, to: .default)
        XCTAssertEqual(display.menuBar.timeFormat.rawValue, TimeFormatStyle.remainingClock.rawValue)
        XCTAssertEqual(AntigravityRuntimeController.applyingCommonTimeFormat(nil, to: .default), .default)
    }
}

final class RemainingTimeFormatTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testClockStyles() {
        let session = now.addingTimeInterval(2 * 3600 + 34 * 60)
        let shortly = now.addingTimeInterval(23 * 60)
        let weekly = now.addingTimeInterval(3 * 86400 + 2 * 3600 + 12 * 60)

        XCTAssertEqual(
            TimeFormatter.formatRemaining(until: session, now: now, style: .remainingClock, isWeekly: false), "2:34")
        XCTAssertEqual(
            TimeFormatter.formatRemaining(until: shortly, now: now, style: .remainingClock, isWeekly: false), "0:23")
        XCTAssertEqual(
            TimeFormatter.formatRemaining(until: weekly, now: now, style: .remainingClock, isWeekly: true), "3d:02")
        XCTAssertEqual(
            TimeFormatter.formatRemaining(until: weekly, now: now, style: .remainingTotalClock, isWeekly: true), "74:12"
        )
        XCTAssertEqual(
            TimeFormatter.formatRemaining(until: weekly, now: now, style: .remaining, isWeekly: true), "3d 2h")
        XCTAssertEqual(
            TimeFormatter.formatRemaining(until: session, now: now, style: .remaining, isWeekly: false), "2h 34m")
    }
}
