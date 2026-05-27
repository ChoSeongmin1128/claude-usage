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

        XCTAssertEqual(snapshot.text, "!")
        XCTAssertTrue(snapshot.color.isEqual(NSColor.systemOrange))
        XCTAssertFalse(snapshot.tooltip.contains("Google OAuth"))
        XCTAssertFalse(snapshot.tooltip.contains("AGY CLI"))
        XCTAssertTrue(snapshot.tooltip.contains("계정 확인됨"))
        XCTAssertTrue(snapshot.tooltip.contains("quota 수치 미지원"))
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
        XCTAssertTrue(snapshot.tooltip.contains("Google 계정"))
        XCTAssertFalse(snapshot.tooltip.contains("세션 키"))
    }

    func testAntigravityMenuBarUsesSelectedModelIDs() {
        let usage = AntigravityUsageResponse(
            source: .agyCLI,
            accountEmail: nil,
            accountPlan: nil,
            modelWindows: [
                AntigravityUsageWindow(label: "Gemini 3.5 Flash (Medium)", modelID: "gemini-3.5-flash-medium", usedPercent: 20, resetAtISO: nil),
                AntigravityUsageWindow(label: "Gemini 3.1 Pro (Low)", modelID: "gemini-3.1-pro-low", usedPercent: 24, resetAtISO: nil),
                AntigravityUsageWindow(label: "Claude Sonnet 4.6 (Thinking)", modelID: "claude-sonnet-4.6-thinking", usedPercent: 0, resetAtISO: nil),
            ]
        )

        let snapshot = MenuBarStatusComposer.antigravitySnapshot(
            config: ProviderMenuBarDisplayConfig(
                kind: .antigravity,
                showIcon: false,
                style: .none,
                percentageDisplay: .dual,
                showBatteryPercent: true,
                resetTimeDisplay: .none,
                timeFormat: .remaining,
                circularDisplayMode: .usage,
                iconMetric: .fiveHour,
                primaryModelID: "gemini-3.5-flash-medium",
                secondaryModelID: "claude-sonnet-4.6-thinking"
            ),
            usage: usage,
            error: nil,
            hasAuthError: false,
            hasCredential: true,
            secondaryColor: .secondaryLabelColor,
            icon: nil
        )

        XCTAssertEqual(snapshot.text, "20%·0%")
        XCTAssertTrue(snapshot.tooltip.contains("Gemini 3.5 Flash (Medium) 20%"))
        XCTAssertTrue(snapshot.tooltip.contains("Claude Sonnet 4.6 (Thinking) 0%"))
        XCTAssertFalse(snapshot.tooltip.contains("Gemini 3.1 Pro"))
    }
}
