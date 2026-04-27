import XCTest
@testable import ClaudeUsage

@MainActor
final class NotificationManagerTests: XCTestCase {
    private var settingsSnapshot: AppSettings.Snapshot!
    private var deliverer: MockNotificationDeliverer!
    private var manager: NotificationManager!

    override func setUp() {
        super.setUp()
        settingsSnapshot = AppSettings.shared.createSnapshot()
        deliverer = MockNotificationDeliverer()
        manager = NotificationManager(deliverer: deliverer)
        configureNotifications()
    }

    override func tearDown() {
        AppSettings.shared.restore(from: settingsSnapshot)
        manager = nil
        deliverer = nil
        settingsSnapshot = nil
        super.tearDown()
    }

    func testResetAtChangeDoesNotSendLegacyResetNotification() {
        manager.checkThreshold(
            session: .fiveHour,
            percentage: 10,
            resetAt: "2026-04-25T10:00:00Z"
        )
        manager.checkThreshold(
            session: .fiveHour,
            percentage: 10,
            resetAt: "2026-04-25T15:30:00Z"
        )

        XCTAssertTrue(deliverer.delivered.isEmpty)
        XCTAssertFalse(deliverer.delivered.contains { $0.title.contains("세션 리셋") })
    }

    func testThresholdNotificationUsesUsageTransition() {
        manager.checkThreshold(session: .fiveHour, percentage: 84, resetAt: nil)
        manager.checkThreshold(session: .fiveHour, percentage: 90, resetAt: nil)

        XCTAssertEqual(deliverer.delivered.map(\.title), ["Claude 사용량 주의"])
        XCTAssertEqual(deliverer.delivered.map(\.body), ["현재 세션의 90%를 사용했습니다"])
    }

    func testFirstCheckDoesNotSendThresholdNotificationEvenWhenAlreadyHigh() {
        manager.checkThreshold(session: .fiveHour, percentage: 91, resetAt: nil)

        XCTAssertTrue(deliverer.delivered.isEmpty)
    }

    func testClaudeLowUrgencySuppressionStillApplies() {
        AppSettings.shared.notificationPresets = [
            NotificationPreset(id: "seventy-five", threshold: 75),
            NotificationPreset(id: "ninety", threshold: 90),
        ]
        let policy = ClaudeNotificationPolicy(
            metadata: ClaudeProfileMetadata(
                subscriptionType: "team",
                hasExtraUsageEnabled: true,
                billingType: "organization",
                lastUpdatedAt: Date()
            )
        )

        manager.checkThreshold(session: .fiveHour, percentage: 70, resetAt: nil, claudePolicy: policy)
        manager.checkThreshold(session: .fiveHour, percentage: 75, resetAt: nil, claudePolicy: policy)
        manager.checkThreshold(session: .fiveHour, percentage: 90, resetAt: nil, claudePolicy: policy)

        XCTAssertEqual(deliverer.delivered.map(\.title), ["Claude 사용량 주의"])
        XCTAssertEqual(deliverer.delivered.map(\.body), ["현재 세션의 90%를 사용했습니다"])
    }

    private func configureNotifications() {
        let settings = AppSettings.shared
        settings.notificationsEnabled = true
        settings.claudeAlertEnabled = true
        settings.alertFiveHourEnabled = true
        settings.alertWeeklyEnabled = true
        settings.codexAlertEnabled = true
        settings.alertRemainingMode = false
        settings.notificationPresets = [
            NotificationPreset(id: "ninety", threshold: 90),
            NotificationPreset(id: "ninety-five", threshold: 95),
        ]
    }
}

private final class MockNotificationDeliverer: NotificationDelivering {
    private(set) var delivered: [(title: String, body: String)] = []

    func requestPermission() {}

    func deliver(title: String, body: String) {
        delivered.append((title: title, body: body))
    }
}
