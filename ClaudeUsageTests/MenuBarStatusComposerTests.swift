import AppKit
import XCTest
@testable import ClaudeUsage

@MainActor
final class MenuBarStatusComposerTests: XCTestCase {
    func testAntigravityIdentityOnlyUsageDoesNotRenderFakeZeroQuota() {
        let usage = AntigravityUsageResponse(
            source: .googleOAuth,
            accountEmail: "nathan@example.com",
            accountPlan: "Paid",
            primaryWindow: nil,
            secondaryWindow: nil,
            tertiaryWindow: nil
        )

        let snapshot = MenuBarStatusComposer.antigravitySnapshot(
            config: ProviderMenuBarDisplayConfig(
                kind: .antigravity,
                showIcon: false,
                style: .batteryBar,
                percentageDisplay: .dual,
                showBatteryPercent: true,
                resetTimeDisplay: .dual,
                timeFormat: .remaining,
                circularDisplayMode: .usage,
                iconMetric: .fiveHour
            ),
            usage: usage,
            error: nil,
            hasAuthError: false,
            hasCredential: true,
            secondaryColor: .secondaryLabelColor,
            icon: nil
        )

        XCTAssertEqual(snapshot.text, "연결")
        XCTAssertTrue(snapshot.color.isEqual(NSColor.systemBlue))
        XCTAssertTrue(snapshot.tooltip.contains("Google OAuth"))
        XCTAssertTrue(snapshot.tooltip.contains("quota 정보 없음"))
        XCTAssertNil(snapshot.styleIcon)
        XCTAssertNil(snapshot.resetText)
    }

    func testAntigravityAuthErrorTooltipDoesNotExposeGenericSessionKeyCopy() {
        let snapshot = MenuBarStatusComposer.antigravitySnapshot(
            config: ProviderMenuBarDisplayConfig(
                kind: .antigravity,
                showIcon: false,
                style: .batteryBar,
                percentageDisplay: .dual,
                showBatteryPercent: true,
                resetTimeDisplay: .dual,
                timeFormat: .remaining,
                circularDisplayMode: .usage,
                iconMetric: .fiveHour
            ),
            usage: nil,
            error: .invalidSessionKey,
            hasAuthError: true,
            hasCredential: true,
            secondaryColor: .secondaryLabelColor,
            icon: nil
        )

        XCTAssertEqual(snapshot.text, "연결")
        XCTAssertTrue(snapshot.tooltip.contains("Antigravity"))
        XCTAssertTrue(snapshot.tooltip.contains("Google OAuth"))
        XCTAssertFalse(snapshot.tooltip.contains("세션 키"))
    }
}
