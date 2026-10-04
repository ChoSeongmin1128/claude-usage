import XCTest
@testable import ClaudeUsage

final class ClaudeNotificationPolicyTests: XCTestCase {
    func testPersonalPlanDoesNotShowAdditionalPlanGuidance() {
        let metadata = ClaudeProfileMetadata(
            subscriptionType: "max",
            billingType: "individual"
        )

        let policy = ClaudeNotificationPolicy(metadata: metadata)

        XCTAssertNil(policy.summaryLine)
        XCTAssertNil(policy.guidanceSuffix)
    }

    func testOrganizationPlanWithoutExtraUsageKeepsAdminGuidance() {
        let metadata = ClaudeProfileMetadata(
            subscriptionType: "team",
            hasExtraUsageEnabled: false,
            billingType: "organization"
        )

        let policy = ClaudeNotificationPolicy(metadata: metadata)

        XCTAssertNil(policy.summaryLine, "알림 동작이 같으면 설정에 안내를 띄우지 않습니다")
        XCTAssertEqual(policy.guidanceSuffix, "추가 사용량이 꺼져 있습니다. 관리자에게 문의하세요.")
    }

    func testOrganizationPlanWithExtraUsageExplainsSuppressedLowAlerts() {
        let metadata = ClaudeProfileMetadata(
            subscriptionType: "team",
            hasExtraUsageEnabled: true,
            billingType: "organization"
        )

        let policy = ClaudeNotificationPolicy(metadata: metadata)

        XCTAssertTrue(policy.shouldSuppressLowUrgencyThresholds)
        XCTAssertEqual(policy.summaryLine, "추가 사용량이 켜진 조직 플랜이라 낮은 구간 알림은 보내지 않습니다")
        XCTAssertNil(policy.guidanceSuffix)
    }
}
