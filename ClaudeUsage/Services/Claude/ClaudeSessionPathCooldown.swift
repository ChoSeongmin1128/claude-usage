import Foundation

/// 세션 키 경로가 429나 Cloudflare 확인 페이지를 받으면 점점 길게 쉬게 한다. 성공하면 처음으로 돌아간다.
nonisolated struct ClaudeSessionPathCooldown {
    private var until: Date?
    private var reason: APIError?
    private var strike = 0

    mutating func apply(after error: APIError, now: Date = Date()) {
        let baseSeconds: Double
        let retryAfter: Int?
        switch error {
        case .rateLimited(let value): (baseSeconds, retryAfter) = (30, value)
        case .cloudflareBlocked(let value): (baseSeconds, retryAfter) = (45, value)
        default: return
        }
        strike += 1
        let calculated = min(300, baseSeconds * pow(1.7, Double(max(0, strike - 1))))
        let seconds = Int(max(Double(retryAfter ?? 0), calculated))
        until = now.addingTimeInterval(Double(seconds))
        if case .cloudflareBlocked = error {
            reason = .cloudflareBlocked(retryAfter: seconds)
        } else {
            reason = .rateLimited(retryAfter: seconds)
        }
        Logger.warning("세션키 경로 백오프 적용: \(seconds)초 (연속 제한 \(strike)회)")
    }

    /// 쉬는 중이면 남은 시간을 담은 오류를 돌려준다. 기한이 지났으면 지운다.
    mutating func currentError(now: Date = Date()) -> APIError? {
        guard let remaining = remainingSeconds(now: now) else {
            until = nil
            reason = nil
            return nil
        }
        if case .cloudflareBlocked = reason { return .cloudflareBlocked(retryAfter: remaining) }
        return .rateLimited(retryAfter: remaining)
    }

    func remainingSeconds(now: Date = Date()) -> Int? {
        guard let until else { return nil }
        let remaining = Int(ceil(until.timeIntervalSince(now)))
        return remaining > 0 ? remaining : nil
    }

    mutating func reset() {
        until = nil
        reason = nil
        strike = 0
    }
}
