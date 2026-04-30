import XCTest
@testable import ClaudeUsage

@MainActor
final class ServiceSelectionHelperTests: XCTestCase {
    func testPreferredPopoverServiceNormalizesWhitespaceAndCase() {
        XCTAssertEqual(ServiceSelectionHelper.preferredPopoverService(from: "  CoDeX \n"), .codex)
        XCTAssertEqual(ServiceSelectionHelper.preferredPopoverService(from: "unknown"), .claude)
    }

    func testResolvedPopoverServiceReturnsSingleEnabledRuntimeService() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        settings.setProviderEnabled(false, for: .claude)
        settings.setProviderEnabled(true, for: .codex)
        settings.setProviderEnabled(false, for: .gemini)
        settings.setProviderEnabled(false, for: .antigravity)
        settings.setActiveMenuBarService(.claude)

        XCTAssertEqual(ServiceSelectionHelper.resolvedPopoverService(settings: settings), .codex)
    }

    func testResolvedPopoverServicePrefersActiveRuntimeOverMenuBarPreference() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        settings.setProviderEnabled(true, for: .claude)
        settings.setProviderEnabled(true, for: .gemini)
        settings.setActiveMenuBarService(.claude)

        ServiceSelectionHelper.setActivePopoverService(.gemini, settings: settings)

        XCTAssertEqual(ServiceSelectionHelper.resolvedPopoverService(settings: settings), .gemini)
    }

    func testResolvedMenuBarServiceFallsBackToVisibleRuntimeWhenPreferredIsHidden() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        settings.setProviderEnabled(true, for: .claude)
        settings.setProviderEnabled(true, for: .codex)
        settings.setProviderMenuBarVisible(true, for: .claude)
        settings.setProviderMenuBarVisible(false, for: .codex)
        settings.setActiveMenuBarService(.codex)
        ServiceSelectionHelper.setActivePopoverService(.codex, settings: settings)

        XCTAssertEqual(ServiceSelectionHelper.resolvedMenuBarService(settings: settings), .claude)
    }

    func testResolvedMenuBarServiceReturnsNilWhenNoVisibleRuntimeServicesRemain() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        AppProviderKind.runtimeKinds.forEach {
            settings.setProviderEnabled(true, for: $0)
            settings.setProviderMenuBarVisible(false, for: $0)
        }

        XCTAssertNil(ServiceSelectionHelper.resolvedMenuBarService(settings: settings))
    }

    func testRefreshableServicesRespectCredentialsAndRuntimeReachability() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        AppProviderKind.runtimeKinds.forEach { settings.setProviderEnabled(true, for: $0) }

        let services = ServiceSelectionHelper.refreshableServices(
            settings: settings,
            hasClaudeSessionKey: false,
            hasClaudeOAuthCredential: true,
            isCodexAuthenticated: false,
            geminiRuntimeReachability: true,
            antigravityRuntimeReachability: false
        )

        XCTAssertEqual(services, [.claude, .gemini])
    }
}
