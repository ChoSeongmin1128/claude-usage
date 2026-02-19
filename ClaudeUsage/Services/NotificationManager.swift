//
//  NotificationManager.swift
//  ClaudeUsage
//
//  Phase 4: macOS 알림 관리 (5시간/주간 세션 별도 추적)
//

import Foundation
import UserNotifications

enum SessionType: String {
    case fiveHour = "현재 세션"
    case weekly = "주간"
    case codexPrimary = "Codex 현재"
    case codexSecondary = "Codex 주간"
}

class NotificationManager {
    static let shared = NotificationManager()

    private var trackers: [SessionType: SessionTracker] = [
        .fiveHour: SessionTracker(),
        .weekly: SessionTracker(),
        .codexPrimary: SessionTracker(),
        .codexSecondary: SessionTracker(),
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

    func checkThreshold(session: SessionType, percentage: Double, resetAt: String?) {
        let settings = AppSettings.shared

        // 해당 세션 알림이 꺼져 있으면 무시
        switch session {
        case .fiveHour:
            guard settings.alertFiveHourEnabled else { return }
        case .weekly:
            guard settings.alertWeeklyEnabled else { return }
        case .codexPrimary, .codexSecondary:
            guard settings.codexAlertEnabled else { return }
        }

        guard let tracker = trackers[session] else { return }
        let thresholds = settings.enabledAlertThresholds

        // 첫 번째 호출: 현재 상태만 기록, 알림 보내지 않음
        if tracker.isFirstCheck {
            tracker.isFirstCheck = false
            tracker.lastResetAt = resetAt

            for threshold in thresholds where percentage >= Double(threshold) {
                tracker.alertedThresholds.insert(threshold)
            }

            Logger.info("\(session.rawValue) 첫 실행 기록: \(Int(percentage))%")
            return
        }

        let isCodex = session == .codexPrimary || session == .codexSecondary
        let serviceName = isCodex ? "Codex" : "Claude"

        // 리셋 감지: 5분 이상 차이나야 실제 리셋으로 판단
        if let resetAt = resetAt, let lastReset = tracker.lastResetAt, isActualReset(from: lastReset, to: resetAt) {
            Logger.info("\(session.rawValue) 세션 리셋 감지")
            tracker.alertedThresholds.removeAll()
            tracker.lastResetAt = resetAt

            sendNotification(
                title: "\(serviceName) 세션 리셋",
                body: "\(session.rawValue) 세션이 리셋되었습니다"
            )
            return
        }

        tracker.lastResetAt = resetAt

        // 임계값 알림 (높은 순서대로, 한 번에 하나만)
        for threshold in thresholds.reversed() {
            if percentage >= Double(threshold) && !tracker.alertedThresholds.contains(threshold) {
                let title = threshold >= 95 ? "\(serviceName) 사용량 경고"
                    : threshold >= 90 ? "\(serviceName) 사용량 주의"
                    : "\(serviceName) 사용량 안내"
                sendNotification(
                    title: title,
                    body: "\(session.rawValue) 세션의 \(threshold)%를 사용했습니다"
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
