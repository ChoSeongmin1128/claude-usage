import XCTest
@testable import ClaudeUsage

@MainActor
final class ProviderSettingsTabTests: XCTestCase {
    func testClaudeLegacyTabsNormalizeToOverview() {
        XCTAssertEqual(ProviderSettingsTab.normalized(rawValue: "auth", for: .claude), .overview)
        XCTAssertEqual(ProviderSettingsTab.normalized(rawValue: "status", for: .claude), .overview)
        XCTAssertEqual(ProviderSettingsTab.normalized(rawValue: "organizations", for: .claude), .overview)
        XCTAssertEqual(ProviderSettingsTab.normalized(rawValue: "display", for: .claude), .overview)
        XCTAssertEqual(ProviderSettingsTab.normalized(rawValue: "popover", for: .claude), .overview)
        XCTAssertEqual(ProviderSettingsTab.normalized(rawValue: "advanced", for: .claude), .overview)
        XCTAssertEqual(ProviderSettingsTab.normalized(rawValue: "alerts", for: .claude), .overview)
    }

    func testCodexLegacyTabsNormalizeToExpectedTabs() {
        XCTAssertEqual(ProviderSettingsTab.normalized(rawValue: "auth", for: .codex), .overview)
        XCTAssertEqual(ProviderSettingsTab.normalized(rawValue: "display", for: .codex), .overview)
        XCTAssertEqual(ProviderSettingsTab.normalized(rawValue: "popover", for: .codex), .overview)
        XCTAssertEqual(ProviderSettingsTab.normalized(rawValue: "advanced", for: .codex), .overview)
        XCTAssertEqual(ProviderSettingsTab.normalized(rawValue: "alerts", for: .codex), .overview)
    }

    func testRuntimeProviderLegacyTabsNormalizeToExpectedTabs() {
        XCTAssertEqual(ProviderSettingsTab.normalized(rawValue: "auth", for: .gemini), .overview)
        XCTAssertEqual(ProviderSettingsTab.normalized(rawValue: "display", for: .gemini), .overview)
        XCTAssertEqual(ProviderSettingsTab.normalized(rawValue: "popover", for: .gemini), .overview)
        XCTAssertEqual(ProviderSettingsTab.normalized(rawValue: "advanced", for: .gemini), .overview)
        XCTAssertEqual(ProviderSettingsTab.normalized(rawValue: "alerts", for: .gemini), .overview)
        XCTAssertEqual(ProviderSettingsTab.normalized(rawValue: "auth", for: .antigravity), .overview)
    }

    func testProviderTabsCollapseToOverviewOnly() {
        XCTAssertEqual(ProviderSettingsTab.tabs(for: .claude), [.overview])
        XCTAssertEqual(ProviderSettingsTab.tabs(for: .codex), [.overview])
        XCTAssertEqual(ProviderSettingsTab.tabs(for: .gemini), [.overview])
        XCTAssertEqual(ProviderSettingsTab.tabs(for: .antigravity), [.overview])
    }

    func testOverviewIsDefaultForUnknownOrMissingValues() {
        XCTAssertEqual(ProviderSettingsTab.normalized(rawValue: nil, for: .claude), .overview)
        XCTAssertEqual(ProviderSettingsTab.normalized(rawValue: "unknown", for: .codex), .overview)
    }
}
