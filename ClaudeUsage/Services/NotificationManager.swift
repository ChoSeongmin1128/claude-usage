//
//  NotificationManager.swift
//  ClaudeUsage
//
//  Phase 4: macOS 알림 관리 (5시간/주간 세션 별도 추적)
//

import Foundation
import UserNotifications

enum SessionType: String {
    case fiveHour
    case weekly
    case codexPrimary
    case codexSecondary
    case geminiPrimary
    case geminiSecondary
    case geminiTertiary
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
        case .geminiPrimary:
            return "Gemini Pro"
        case .geminiSecondary:
            return "Gemini Flash"
        case .geminiTertiary:
            return "Gemini Lite"
        case .antigravityPrimary:
            return "Claude lane"
        case .antigravitySecondary:
            return "Gemini Pro lane"
        case .antigravityTertiary:
            return "Gemini Flash lane"
        }
    }

    var providerName: String {
        switch self {
        case .fiveHour, .weekly:
            return "Claude"
        case .codexPrimary, .codexSecondary:
            return "Codex"
        case .geminiPrimary, .geminiSecondary, .geminiTertiary:
            return "Gemini"
        case .antigravityPrimary, .antigravitySecondary, .antigravityTertiary:
            return "Antigravity"
        }
    }
}

class NotificationManager {
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
        .geminiPrimary: SessionTracker(),
        .geminiSecondary: SessionTracker(),
        .geminiTertiary: SessionTracker(),
        .antigravityPrimary: SessionTracker(),
        .antigravitySecondary: SessionTracker(),
        .antigravityTertiary: SessionTracker(),
    ]

    private init() {}

    // MARK: - Permission

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                Logger.info("알림 권한 허용됨")
            } else {
                Logger.warning("알림 권한 거부됨: \(error?.localizedDescription ?? "")")
            }
        }
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
        case .geminiPrimary, .geminiSecondary, .geminiTertiary:
            guard settings.isProviderAlertEnabled(.gemini) else { return }
        case .antigravityPrimary, .antigravitySecondary, .antigravityTertiary:
            guard settings.isProviderAlertEnabled(.antigravity) else { return }
        }

        guard let tracker = trackers[session] else { return }
        let thresholds: [Int] = {
            switch session {
            case .codexPrimary, .codexSecondary:
                return settings.enabledCodexAlertThresholds
            case .fiveHour, .weekly, .geminiPrimary, .geminiSecondary, .geminiTertiary, .antigravityPrimary, .antigravitySecondary, .antigravityTertiary:
                return settings.enabledAlertThresholds
            }
        }()
        let normalizedClaudePolicy = claudePolicy?.isFreshEnoughForNotifications == true ? claudePolicy : nil
        let thresholdMode: ThresholdPresentationMode = settings.alertRemainingMode ? .remaining : .used

        // 첫 번째 호출: 현재 상태만 기록, 알림 보내지 않음
        if tracker.isFirstCheck {
            tracker.isFirstCheck = false
            tracker.lastResetAt = resetAt

            for threshold in thresholds where percentage >= Double(threshold) {
                if shouldSuppressThreshold(
                    threshold,
                    session: session,
                    claudePolicy: normalizedClaudePolicy
                ) {
                    continue
                }
                tracker.alertedThresholds.insert(threshold)
            }

            Logger.info("\(session.displayName) 첫 실행 기록: \(Int(percentage))%")
            return
        }

        let serviceName = session.providerName

        // 리셋 감지: 5분 이상 차이나야 실제 리셋으로 판단
        if let resetAt = resetAt, let lastReset = tracker.lastResetAt, isActualReset(from: lastReset, to: resetAt) {
            Logger.info("\(session.displayName) 세션 리셋 감지")
            tracker.alertedThresholds.removeAll()
            tracker.lastResetAt = resetAt

            sendNotification(
                title: "\(serviceName) 세션 리셋",
                body: "\(session.displayName) 세션이 리셋되었습니다"
            )
            return
        }

        tracker.lastResetAt = resetAt

        // 임계값 알림 (높은 순서대로, 한 번에 하나만)
        for threshold in thresholds.reversed() {
            if shouldSuppressThreshold(
                threshold,
                session: session,
                claudePolicy: normalizedClaudePolicy
            ) {
                continue
            }
            if percentage >= Double(threshold) && !tracker.alertedThresholds.contains(threshold) {
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
                sendNotification(
                    title: title,
                    body: body
                )
                tracker.alertedThresholds.insert(threshold)
                break
            }
        }
    }

    // MARK: - Private

    private class SessionTracker {
        var alertedThresholds: Set<Int> = []
        var lastResetAt: String?
        var isFirstCheck = true
    }

    private func isActualReset(from oldResetAt: String, to newResetAt: String) -> Bool {
        let parse: (String) -> Date? = { str in
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fmt.date(from: str) { return d }
            fmt.formatOptions = [.withInternetDateTime]
            return fmt.date(from: str)
        }

        guard let oldDate = parse(oldResetAt), let newDate = parse(newResetAt) else {
            return oldResetAt != newResetAt
        }

        return abs(newDate.timeIntervalSince(oldDate)) > 300
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
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Logger.error("알림 발송 실패: \(error)")
            } else {
                Logger.info("알림 발송: \(title) - \(body)")
            }
        }
    }
}
