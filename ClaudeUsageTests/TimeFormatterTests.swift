import XCTest
@testable import ClaudeUsage

final class TimeFormatterTests: XCTestCase {
    func testResetTimePreservesNonHourlyMinute() throws {
        let resetAt = "2026-04-25T10:17:30Z"
        let resetDate = try XCTUnwrap(TimeFormatter.parseISO8601(resetAt))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"

        XCTAssertEqual(
            TimeFormatter.formatResetTime(from: resetAt, style: .h24, includeDateIfNotToday: false),
            formatter.string(from: resetDate)
        )
    }

    func testRelativeClockUsesRefreshEstimateCopy() {
        let resetAt = isoString(from: Date().addingTimeInterval(95 * 60))

        let text = TimeFormatter.formatRelativeTimeWithClock(from: resetAt, style: .h24)

        XCTAssertTrue(text.hasPrefix("갱신 예상: "))
        XCTAssertTrue(text.contains("1시간 35분 후") || text.contains("1시간 34분 후"))
        XCTAssertTrue(text.contains(" · "))
        XCTAssertFalse(text.contains("("))
        XCTAssertFalse(text.contains("리셋"))
    }

    func testUsageDetailOmitsRedundantLabelAndNestedParentheses() {
        let resetAt = isoString(
            from: Date().addingTimeInterval(
                4 * 24 * 3600 + 8 * 3600
            )
        )

        let text =
            TimeFormatter
                .formatRelativeTimeWithClockWeekly(
                    from: resetAt,
                    style: .h24,
                    label: nil
                )

        XCTAssertFalse(text.hasPrefix("갱신 예상"))
        XCTAssertTrue(text.contains("4일"))
        XCTAssertTrue(text.contains(" · "))
        XCTAssertTrue(text.contains("월"))
        XCTAssertFalse(text.contains("("))
        XCTAssertFalse(text.contains(")"))
    }

    func testDateBasedUsageDetailMatchesProviderFormattingRules() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetAt =
            now.addingTimeInterval(
                4 * 24 * 3600 + 8 * 3600
            )

        let text = TimeFormatter.formatUsageResetDetail(
            resetAt: resetAt,
            isWeekly: true,
            now: now,
            locale: Locale(identifier: "ko_KR"),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            label: nil
        )

        XCTAssertTrue(text.hasPrefix("4일 8시간 후 · "))
        XCTAssertTrue(text.contains("월"))
        XCTAssertFalse(text.contains("("))
        XCTAssertFalse(text.contains(")"))
    }

    func testPastResetAtShowsSoonRefreshCopy() {
        let resetAt = isoString(from: Date().addingTimeInterval(-60))

        XCTAssertEqual(
            TimeFormatter.formatRelativeTimeWithClock(from: resetAt, style: .h24),
            "갱신 예상: 곧 갱신"
        )
    }

    func testCompactResetRulesAreSharedAcrossProvidersAndKeepWeeklyTextShort() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weekly = isoString(from: now.addingTimeInterval(3 * 86400 + 2 * 3600))
        let hourly = isoString(from: now.addingTimeInterval(3 * 3600 + 12 * 60))
        let zone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(
            TimeFormatter.formatCompactUsageReset(
                from: weekly, isWeekly: true, style: .remaining, now: now, timeZone: zone), "3d 2h")
        XCTAssertEqual(
            TimeFormatter.formatCompactUsageReset(
                from: hourly, isWeekly: false, style: .remaining, now: now, timeZone: zone), "3h 12m")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = zone
        formatter.dateFormat = "M/d E"
        for style in [TimeFormatStyle.h12, .h24] {
            XCTAssertEqual(
                TimeFormatter.formatCompactUsageReset(
                    from: weekly, isWeekly: true, style: style, now: now, timeZone: zone),
                formatter.string(from: now.addingTimeInterval(3 * 86400 + 2 * 3600)))
        }
        XCTAssertNil(
            TimeFormatter.formatCompactUsageReset(from: "invalid", isWeekly: true, style: .remaining, now: now))
        XCTAssertEqual(
            TimeFormatter.formatCompactUsageReset(
                from: isoString(from: now.addingTimeInterval(-1)), isWeekly: true, style: .remaining, now: now),
            "0h 00m")
    }

    private func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
