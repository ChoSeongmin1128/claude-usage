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

    /// resets_at 문자열을 시간 단위까지만 잘라서 비교용 키 생성
    /// "2026-02-11T09:59:59.818398+00:00" → "2026-02-11T09"
    /// 정각 기준 ±1분 차이(10:00 vs 09:59)를 무시하기 위해 시간 단위 비교
    private func normalizeResetTime(_ resetAt: String) -> String {
        guard let tIndex = resetAt.firstIndex(of: "T") else { return resetAt }
        let timeStart = resetAt.index(after: tIndex)
        let afterT = resetAt[timeStart...]
        // "HH" = 2글자
        if afterT.count >= 2 {
            let hourEnd = resetAt.index(timeStart, offsetBy: 2)
            return String(resetAt[resetAt.startIndex..<hourEnd])
        }
        return resetAt
    }

    func checkThreshold(percentage: Double, resetAt: String) {
        let settings = AppSettings.shared
        let normalizedReset = normalizeResetTime(resetAt)

        // 첫 번째 호출: 현재 상태만 기록, 알림 보내지 않음
        if isFirstCheck {
            isFirstCheck = false
            lastResetAt = normalizedReset

            // 이미 넘은 임계값은 alerted 처리 (앱 시작 시 알림 방지)
            if percentage >= 75 { alerted75 = true }
            if percentage >= 90 { alerted90 = true }
            if percentage >= 95 { alerted95 = true }

            Logger.info("첫 실행 기록: \(Int(percentage))%, 리셋: \(normalizedReset)")
            return
        }

        // 리셋 감지: 분 단위까지 비교하여 실제 리셋만 감지
        if let lastReset = lastResetAt, lastReset != normalizedReset {
            Logger.info("세션 리셋 감지: \(lastReset) → \(normalizedReset)")
            resetFlags()
            lastResetAt = normalizedReset

            sendNotification(
                title: "Claude 세션 리셋",
                body: "5시간 세션이 리셋되었습니다"
            )
            return  // 리셋 직후에는 임계값 알림 생략
        }

        lastResetAt = normalizedReset

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
