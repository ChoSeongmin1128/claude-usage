import Foundation

/// 자동 조회 주기. 사용자가 보고 있거나 쓰고 있거나 한도가 임박하면 2분, 오래 안 보면 30분까지 늘린다.
nonisolated enum AdaptiveRefreshPolicy {
    static let minimumInterval: TimeInterval = 120
    static let maximumInterval: TimeInterval = 1_800
    /// 팝오버를 열거나 서비스를 바꿀 때 이보다 오래된 값만 다시 조회한다
    static let staleAfter: TimeInterval = 120
    /// 수동 새로고침이 끝난 뒤 이 시간 안에는 요청하지 않는다
    static let manualRefreshQuietPeriod: TimeInterval = 10
    /// 남은 양이 이 이하인 한도가 있으면 최소 주기로 본다
    static let lowRemainingPercent: Double = 10
    /// 세션 파일이 이 시간 안에 바뀌었으면 사용 중으로 본다
    static let activityWindow: TimeInterval = 300
    /// 초기화 시각 직후 한 번 조회할 때 서버 반영을 기다리는 여유
    static let resetFollowUpDelay: TimeInterval = 5

    struct Inputs: Equatable, Sendable {
        var now: Date
        var isPopoverOpen: Bool
        var lastPopoverOpenedAt: Date?
        var lastActivityAt: Date?
        var hasLowRemainingLimit: Bool
    }

    static func interval(_ inputs: Inputs) -> TimeInterval {
        if inputs.isPopoverOpen || inputs.hasLowRemainingLimit { return minimumInterval }
        if let activity = inputs.lastActivityAt, inputs.now.timeIntervalSince(activity) <= activityWindow {
            return minimumInterval
        }
        guard let opened = inputs.lastPopoverOpenedAt else { return maximumInterval }
        let elapsed = inputs.now.timeIntervalSince(opened)
        if elapsed <= 300 { return minimumInterval }
        if elapsed <= 3_600 { return 300 }
        if elapsed <= 14_400 { return 900 }
        return maximumInterval
    }

    static func isStale(lastUpdatedAt: Date?, now: Date) -> Bool {
        guard let lastUpdatedAt else { return true }
        return now.timeIntervalSince(lastUpdatedAt) > staleAfter
    }

    /// 수동 새로고침을 다시 받을 수 있는 시각. 없으면 지금 받을 수 있다.
    static func manualRefreshBlockedUntil(lastCompletedAt: Date?, retryAllowedAt: Date?, now: Date) -> Date? {
        let quiet = lastCompletedAt.map { $0.addingTimeInterval(manualRefreshQuietPeriod) }
        return [quiet, retryAllowedAt].compactMap { $0 }.filter { $0 > now }.max()
    }

    static func nextResetFollowUp(resetDates: [Date], now: Date) -> Date? {
        resetDates.filter { $0 > now }.min().map { $0.addingTimeInterval(resetFollowUpDelay) }
    }
}
