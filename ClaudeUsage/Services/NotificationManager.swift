//
//  NotificationManager.swift
//  ClaudeUsage
//
//  Phase 4: macOS 알림 관리
//

import Foundation
import UserNotifications

class NotificationManager {
    static let shared = NotificationManager()

    private var alerted75 = false
    private var alerted90 = false
    private var alerted95 = false
    private var lastResetAt: String?
    private var isFirstCheck = true

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

    /// 두 resets_at 문자열이 실제 리셋인지 판별 (30분 이상 차이나야 리셋)
    /// API가 정각 기준 ±1분 오차를 반환하므로 단순 문자열 비교 불가
    private func isActualReset(from oldResetAt: String, to newResetAt: String) -> Bool {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let parse: (String) -> Date? = { str in
            if let d = iso.date(from: str) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: str)
        }

        guard let oldDate = parse(oldResetAt), let newDate = parse(newResetAt) else {
            return oldResetAt != newResetAt
        }

        let diff = abs(newDate.timeIntervalSince(oldDate))
        return diff > 300  // 5분(300초) 이상 차이나면 실제 리셋
    }

    func checkThreshold(percentage: Double, resetAt: String) {
        let settings = AppSettings.shared

        // 첫 번째 호출: 현재 상태만 기록, 알림 보내지 않음
        if isFirstCheck {
            isFirstCheck = false
            lastResetAt = resetAt

            // 이미 넘은 임계값은 alerted 처리 (앱 시작 시 알림 방지)
            if percentage >= 75 { alerted75 = true }
            if percentage >= 90 { alerted90 = true }
            if percentage >= 95 { alerted95 = true }

            Logger.info("첫 실행 기록: \(Int(percentage))%, 리셋: \(resetAt)")
            return
        }

        // 리셋 감지: 30분 이상 차이나야 실제 리셋으로 판단
        if let lastReset = lastResetAt, isActualReset(from: lastReset, to: resetAt) {
            Logger.info("세션 리셋 감지: \(lastReset) → \(resetAt)")
            resetFlags()
            lastResetAt = resetAt

            sendNotification(
                title: "Claude 세션 리셋",
                body: "5시간 세션이 리셋되었습니다"
            )
            return  // 리셋 직후에는 임계값 알림 생략
        }

        lastResetAt = resetAt

        // 임계값 알림 (높은 순서대로)
        if percentage >= 95 && !alerted95 && settings.alertAt95 {
            sendNotification(
                title: "Claude 사용량 경고",
                body: "5시간 세션의 95%를 사용했습니다"
            )
            alerted95 = true
        } else if percentage >= 90 && !alerted90 && settings.alertAt90 {
            sendNotification(
                title: "Claude 사용량 주의",
                body: "5시간 세션의 90%를 사용했습니다"
            )
            alerted90 = true
        } else if percentage >= 75 && !alerted75 && settings.alertAt75 {
            sendNotification(
                title: "Claude 사용량 안내",
                body: "5시간 세션의 75%를 사용했습니다"
            )
            alerted75 = true
        }
    }

    /// 알림 플래그 초기화 (세션 리셋 시)
    private func resetFlags() {
        alerted75 = false
        alerted90 = false
        alerted95 = false
        Logger.info("알림 플래그 초기화")
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
