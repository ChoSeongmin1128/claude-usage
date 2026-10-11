import Foundation

/// 서버 응답의 공통 해석. 같은 403, 429가 조회 경로마다 다른 오류가 되지 않게 한 곳에 둔다.
nonisolated enum HTTPResponseClassification {
    /// Retry-After의 초 또는 HTTP 날짜를 남은 초로 바꾼다. 지난 시각이나 읽을 수 없는 값은 nil이다.
    static func retryAfterSeconds(_ response: HTTPURLResponse?, now: Date = Date()) -> Int? {
        guard
            let header = response?.value(forHTTPHeaderField: "Retry-After")?
                .trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty
        else { return nil }
        if let seconds = Int(header) { return seconds > 0 ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let retryAt = formatter.date(from: header) else { return nil }
        let remaining = Int(ceil(retryAt.timeIntervalSince(now)))
        return remaining > 0 ? remaining : nil
    }

    /// Cloudflare 확인 페이지는 로그인 만료가 아니라 잠시 막힌 상태다.
    static func isCloudflareChallenge(_ data: Data?) -> Bool {
        guard let data, let body = String(data: data, encoding: .utf8)?.lowercased() else { return false }
        return body.contains("just a moment") || body.contains("cloudflare") || body.contains("cf-ray")
            || body.contains("attention required")
    }
}
