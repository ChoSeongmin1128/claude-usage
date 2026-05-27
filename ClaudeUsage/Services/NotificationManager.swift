//
//  NotificationManager.swift
//  ClaudeUsage
//
//  Phase 4: macOS 알림 관리 (5시간/주간 세션 별도 추적)
//

import Foundation

enum SessionType: String {
    case fiveHour
    case weekly
    case codexPrimary
    case codexSecondary
    case antigravityPrimary
    case antigravitySecondary
    case antigravityTertiary

    var displayName: String {
        switch self {
        case .fiveHour, .codexPrimary:
            return "현재 세션"
        case .weekly:
            return "주간"
        case .codexSecondary:
            return "주간 세션"
        case .antigravityPrimary:
            return "Gemini Pro lane"
        case .antigravitySecondary:
            return "Gemini Flash lane"
        case .antigravityTertiary:
            return "Claude lane"
        }
    }

    var providerName: String {
        switch self {
        case .fiveHour, .weekly:
            return "Claude"
        case .codexPrimary, .codexSecondary:
            return "Codex"
        case .antigravityPrimary, .antigravitySecondary, .antigravityTertiary:
            return "Antigravity"
        }
    }
}

final class NotificationManager {
    static let shared = NotificationManager()

    private enum ThresholdPresentationMode {
        case used
        case remaining
    }

    private var trackers: [SessionType: SessionTracker] = [
        .fiveHour: SessionTracker(),
        .weekly: SessionTracker(),
        .codexPrimary: SessionTracker(),
        .codexSecondary: SessionTracker(),
        .antigravityPrimary: SessionTracker(),
        .antigravitySecondary: SessionTracker(),
        .antigravityTertiary: SessionTracker(),
    ]

    private let deliverer: NotificationDelivering

    init(deliverer: NotificationDelivering = UserNotificationDeliverer()) {
        self.deliverer = deliverer
    }

    // MARK: - Permission

    func requestPermission() {
        deliverer.requestPermission()
    }

    // MARK: - Threshold Check

    func checkThreshold(
        session: SessionType,
        percentage: Double,
        resetAt: String?,
        claudePolicy: ClaudeNotificationPolicy? = nil
    ) {
        let settings = AppSettings.shared

        guard settings.notificationsEnabled else { return }

        // 해당 세션 알림이 꺼져 있으면 무시
        switch session {
        case .fiveHour:
            guard settings.claudeAlertEnabled, settings.alertFiveHourEnabled else { return }
        case .weekly:
            guard settings.claudeAlertEnabled, settings.alertWeeklyEnabled else { return }
        case .codexPrimary, .codexSecondary:
            guard settings.codexAlertEnabled else { return }
        case .antigravityPrimary, .antigravitySecondary, .antigravityTertiary:
            guard settings.isProviderAlertEnabled(.antigravity) else { return }
        }

        guard let tracker = trackers[session] else { return }
        let thresholds: [Int] = {
            switch session {
            case .codexPrimary, .codexSecondary:
                return settings.enabledCodexAlertThresholds
            case .fiveHour, .weekly, .antigravityPrimary, .antigravitySecondary, .antigravityTertiary:
                return settings.enabledAlertThresholds
            }
        }()
        let normalizedClaudePolicy = claudePolicy?.isFreshEnoughForNotifications == true ? claudePolicy : nil
        let serviceName = session.providerName
        let thresholdMode: ThresholdPresentationMode = settings.alertRemainingMode ? .remaining : .used
        let effectiveThresholds = thresholds.filter {
            !shouldSuppressThreshold(
                $0,
                session: session,
                claudePolicy: normalizedClaudePolicy
            )
        }
        let decision = UsageWindowAlertPolicy.evaluate(
            previousPercentage: tracker.lastPercentage,
            currentPercentage: percentage,
            resetAt: resetAt,
            thresholds: effectiveThresholds,
            alertedThresholds: tracker.alertedThresholds,
            isFirstCheck: tracker.isFirstCheck
        )

        if tracker.isFirstCheck {
            Logger.info("\(session.displayName) 첫 실행 기록: \(Int(percentage))%")
        } else if resetAt != tracker.lastResetAt {
            Logger.debug(
                "\(session.displayName) 갱신 예상 시각 변경: \(tracker.lastResetAt ?? "nil") -> \(resetAt ?? "nil")"
            )
        }

        tracker.isFirstCheck = false
        tracker.lastPercentage = percentage
        tracker.lastResetAt = resetAt
        tracker.alertedThresholds = decision.alertedThresholds

        if let threshold = decision.thresholdToAlert {
            let title = thresholdAlertTitle(
                serviceName: serviceName,
                threshold: threshold,
                presentationMode: thresholdMode)
            let guidanceSuffix = (session == .fiveHour || session == .weekly)
                ? normalizedClaudePolicy?.guidanceSuffix(
                    threshold: threshold,
                    alertRemainingMode: settings.alertRemainingMode)
                : nil
            let body = thresholdAlertBody(
                session: session,
                threshold: threshold,
                presentationMode: thresholdMode,
                guidanceSuffix: guidanceSuffix)
            sendNotification(title: title, body: body)
        }
    }

    // MARK: - Private

    private final class SessionTracker {
        var alertedThresholds: Set<Int> = []
        var lastPercentage: Double?
        var lastResetAt: String?
        var isFirstCheck = true
    }

    private func shouldSuppressThreshold(
        _ threshold: Int,
        session: SessionType,
        claudePolicy: ClaudeNotificationPolicy?
    ) -> Bool {
        guard session == .fiveHour || session == .weekly else { return false }
        guard let claudePolicy else { return false }
        return claudePolicy.shouldSuppressLowUrgencyThresholds && threshold < 90
    }

    private func thresholdAlertTitle(
        serviceName: String,
        threshold: Int,
        presentationMode: ThresholdPresentationMode
    ) -> String {
        switch presentationMode {
        case .used:
            return threshold >= 95 ? "\(serviceName) 사용량 경고"
                : threshold >= 90 ? "\(serviceName) 사용량 주의"
                : "\(serviceName) 사용량 안내"
        case .remaining:
            let remaining = displayThresholdValue(threshold, mode: presentationMode)
            return remaining <= 5 ? "\(serviceName) 잔여 한도 경고"
                : remaining <= 10 ? "\(serviceName) 잔여 한도 주의"
                : "\(serviceName) 잔여 한도 안내"
        }
    }

    private func thresholdAlertBody(
        session: SessionType,
        threshold: Int,
        presentationMode: ThresholdPresentationMode,
        guidanceSuffix: String?
    ) -> String {
        let displayThreshold = displayThresholdValue(threshold, mode: presentationMode)
        let baseMessage: String
        switch presentationMode {
        case .used:
            baseMessage = "\(session.displayName)의 \(displayThreshold)%를 사용했습니다"
        case .remaining:
            baseMessage = "\(session.displayName)의 \(displayThreshold)%가 남았습니다"
        }

        guard let guidanceSuffix else { return baseMessage }
        return "\(baseMessage). \(guidanceSuffix)"
    }

    private func displayThresholdValue(
        _ threshold: Int,
        mode: ThresholdPresentationMode
    ) -> Int {
        switch mode {
        case .used:
            return threshold
        case .remaining:
            return max(1, min(100 - threshold, 99))
        }
    }

    // MARK: - Send Notification

    private func sendNotification(title: String, body: String) {
        deliverer.deliver(title: title, body: body)
    }

}
