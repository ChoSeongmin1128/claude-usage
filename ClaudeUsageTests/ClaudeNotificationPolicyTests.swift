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
        XCTAssertNil(policy.guidanceSuffix(threshold: 90, alertRemainingMode: false))
    }

    func testOrganizationPlanWithoutExtraUsageKeepsAdminGuidance() {
        let metadata = ClaudeProfileMetadata(
            subscriptionType: "team",
            hasExtraUsageEnabled: false,
            billingType: "organization"
        )

        let policy = ClaudeNotificationPolicy(metadata: metadata)

        XCTAssertEqual(
            policy.summaryLine,
            "조직 플랜이지만 추가 사용량이 꺼져 있어 Claude 알림에 관리자 확인 안내를 함께 표시합니다"
        )
        XCTAssertEqual(policy.guidanceSuffix, "관리자에게 추가 사용량 설정을 확인해 주세요")
    }
}
