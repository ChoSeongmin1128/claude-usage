//
//  TimeFormatter.swift
//  ClaudeUsage
//
//  Phase 2: 상대 시간 포맷터
//

import Foundation

enum TimeFormatter {
    /// ISO 8601 날짜 문자열 파싱 (마이크로초 포함)
    /// 예: "2026-02-11T09:59:59.892268+00:00"
    nonisolated private static func parseISO8601(_ string: String) -> Date? {
        // 1차: fractionalSeconds 포함 시도
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) {
            return date
        }

        // 2차: fractionalSeconds 없이 시도
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) {
            return date
        }

        // 3차: 마이크로초(6자리)를 밀리초(3자리)로 잘라서 시도
        // "2026-02-11T09:59:59.892268+00:00" → "2026-02-11T09:59:59.892+00:00"
        let trimmed = trimFractionalSeconds(string)
        if trimmed != string {
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: trimmed) {
                return date
            }
        }

        // 4차: DateFormatter 폴백
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ"
        if let date = df.date(from: string) {
            return date
        }

        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return df.date(from: string)
    }

    /// 소수점 이하 6자리를 3자리로 축소
    nonisolated private static func trimFractionalSeconds(_ string: String) -> String {
        // ".892268+00:00" → ".892+00:00"
        guard let dotIndex = string.firstIndex(of: ".") else { return string }

        let afterDot = string[string.index(after: dotIndex)...]
        // 소수점 뒤에서 숫자가 아닌 첫 문자 찾기
        guard let nonDigitIndex = afterDot.firstIndex(where: { !$0.isNumber }) else { return string }

        let fractional = String(afterDot[afterDot.startIndex..<nonDigitIndex])
        if fractional.count > 3 {
            let trimmed = String(fractional.prefix(3))
            return String(string[string.startIndex...dotIndex]) + trimmed + String(afterDot[nonDigitIndex...])
        }

        return string
    }

    /// 리셋 시간까지 남은 시간을 한국어로 포맷
    nonisolated static func formatRelativeTime(from resetAt: String) -> String {
        guard let resetDate = parseISO8601(resetAt) else {
            Logger.warning("날짜 파싱 실패: \(resetAt)")
            return "시간 정보 없음"
        }

        return formatRelativeTime(until: resetDate)
    }

    /// 리셋 시각을 "HH:mm" 형태로 포맷
    nonisolated static func formatResetTime(from resetAt: String) -> String? {
        guard let resetDate = parseISO8601(resetAt) else { return nil }

        let df = DateFormatter()
        df.locale = Locale(identifier: "ko_KR")
        df.timeZone = .current
        df.dateFormat = "HH:mm"
        return df.string(from: resetDate)
    }

    /// 남은 시간 + 리셋 시각을 결합한 포맷
    /// 예: "2시간 34분 후 리셋 (12:34)"
    nonisolated static func formatRelativeTimeWithClock(from resetAt: String) -> String {
        let relative = formatRelativeTime(from: resetAt)
        if let clock = formatResetTime(from: resetAt) {
            return "\(relative) (\(clock))"
        }
        return relative
    }

    /// Date 기반 상대 시간 포맷
    nonisolated static func formatRelativeTime(until date: Date) -> String {
        let now = Date()
        let interval = date.timeIntervalSince(now)

        if interval <= 0 {
            return "곧 리셋"
        }

        let totalMinutes = Int(interval / 60)
        let totalHours = totalMinutes / 60
        let days = totalHours / 24

        let hours = totalHours % 24
        let minutes = totalMinutes % 60

        if days > 0 {
            if hours > 0 {
                return "\(days)일 \(hours)시간 후 리셋"
            }
            return "\(days)일 후 리셋"
        }

        if hours > 0 {
            if minutes > 0 {
                return "\(hours)시간 \(minutes)분 후 리셋"
            }
            return "\(hours)시간 후 리셋"
        }

        if minutes > 0 {
            return "\(minutes)분 후 리셋"
        }

        return "곧 리셋"
    }
}
