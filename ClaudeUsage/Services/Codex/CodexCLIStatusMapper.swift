import Foundation

/// CLI `/status` 텍스트 스냅샷을 우리 앱의 `CodexUsageResponse` 모델로 변환.
///
/// 한계: CLI 텍스트에는 `limit_window_seconds` 같은 메타데이터가 없고, `resets HH:MM`
/// 형식의 짧은 문자열만 있다. 가능한 만큼 채우고 비어있는 필드는 nil 로 둔다.
enum CodexCLIStatusMapper {
    /// `5h limit ... resets 13:14` / `Weekly limit ... resets at 13:14 on 17 May` 같은 reset 표현을
    /// Unix timestamp 로 변환. 변환 실패 시 nil.
    static func parseResetUnixTimestamp(_ raw: String?, now: Date = .init()) -> Double? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.defaultDate = now

        // "HH:mm on D MMM" / "HH:mm on MMM d"
        if let match = text.firstMatch(of: /^([0-9]{1,2}:[0-9]{2}) on ([0-9]{1,2} [A-Za-z]{3})$/) {
            formatter.dateFormat = "d MMM HH:mm"
            if let date = formatter.date(from: "\(match.output.2) \(match.output.1)") {
                return self.bumpedTimestamp(date, now: now, calendar: calendar)
            }
        }
        if let match = text.firstMatch(of: /^([0-9]{1,2}:[0-9]{2}) on ([A-Za-z]{3} [0-9]{1,2})$/) {
            formatter.dateFormat = "MMM d HH:mm"
            if let date = formatter.date(from: "\(match.output.2) \(match.output.1)") {
                return self.bumpedTimestamp(date, now: now, calendar: calendar)
            }
        }

        // "HH:mm" 만 있는 경우 → 오늘 같은 시각, 이미 지났으면 내일.
        for format in ["HH:mm", "H:mm"] {
            formatter.dateFormat = format
            if let time = formatter.date(from: text) {
                let components = calendar.dateComponents([.hour, .minute], from: time)
                guard let anchored = calendar.date(
                    bySettingHour: components.hour ?? 0,
                    minute: components.minute ?? 0,
                    second: 0,
                    of: now)
                else {
                    return nil
                }
                if anchored >= now { return anchored.timeIntervalSince1970 }
                return calendar.date(byAdding: .day, value: 1, to: anchored)?.timeIntervalSince1970
            }
        }

        return nil
    }

    private static func bumpedTimestamp(_ date: Date, now: Date, calendar: Calendar) -> Double? {
        if date >= now { return date.timeIntervalSince1970 }
        return calendar.date(byAdding: .year, value: 1, to: date)?.timeIntervalSince1970
    }

    /// CLI 텍스트 스냅샷 → `CodexUsageResponse` 매핑.
    /// usedPercent = 100 - percentLeft. CLI 응답에 left 만 있으니 변환.
    static func mapToUsageResponse(
        _ snapshot: CodexCLIStatusSnapshot,
        now: Date = .init()
    ) -> CodexUsageResponse {
        let primary: CodexUsageWindow? = snapshot.fiveHourPercentLeft.map { left in
            CodexUsageWindow(
                usedPercent: Double(max(0, min(100, 100 - left))),
                resetAt: parseResetUnixTimestamp(snapshot.fiveHourResetDescription, now: now),
                limitWindowSeconds: 5 * 3600
            )
        }
        let secondary: CodexUsageWindow? = snapshot.weeklyPercentLeft.map { left in
            CodexUsageWindow(
                usedPercent: Double(max(0, min(100, 100 - left))),
                resetAt: parseResetUnixTimestamp(snapshot.weeklyResetDescription, now: now),
                limitWindowSeconds: 7 * 24 * 3600
            )
        }

        // credits → 직접 매핑하기엔 우리 모델의 hasCredits/unlimited/balance 와 맞지 않음.
        // CLI 의 credits 가 표시되면 balance 로 채우고, hasCredits=true 로.
        let credits: CodexCredits? = snapshot.credits.map { balance in
            CodexCredits(hasCredits: balance > 0, unlimited: false, balance: balance)
        }

        return CodexUsageResponse(
            planType: nil,
            rateLimit: (primary != nil || secondary != nil)
                ? CodexRateLimit(primaryWindow: primary, secondaryWindow: secondary)
                : nil,
            credits: credits
        )
    }
}
