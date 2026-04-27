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
        XCTAssertFalse(text.contains("리셋"))
    }

    func testPastResetAtShowsSoonRefreshCopy() {
        let resetAt = isoString(from: Date().addingTimeInterval(-60))

        XCTAssertEqual(
            TimeFormatter.formatRelativeTimeWithClock(from: resetAt, style: .h24),
            "갱신 예상: 곧 갱신"
        )
    }

    private func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
