import Foundation
import UserNotifications

protocol NotificationDelivering {
    func requestPermission()
    func deliver(title: String, body: String)
}

final class UserNotificationDeliverer: NotificationDelivering {
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                Logger.info("알림 권한 허용됨")
            } else {
                Logger.warning("알림 권한 거부됨: \(error?.localizedDescription ?? "")")
            }
        }
    }

    func deliver(title: String, body: String) {
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
