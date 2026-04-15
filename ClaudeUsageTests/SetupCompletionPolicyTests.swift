import XCTest
@testable import ClaudeUsage

@MainActor
final class SetupCompletionPolicyTests: XCTestCase {
    func testResolvePresentationUsesChromeImportByDefaultWhenChromeExists() {
        let presentation = SetupCompletionPolicy.resolvePresentation(
            hasReadyCredential: false,
            hasSuccessfulFetch: false,
            preferredOrganizationID: "",
            cachedMetadata: nil,
            hasChromeApp: true
        )

        XCTAssertEqual(presentation.progress.stage, .credential)
        XCTAssertEqual(presentation.credentialStep, .chromeImport)
        XCTAssertEqual(presentation.landingSettingsTab, .overview)
        XCTAssertEqual(presentation.primaryActionKind, .openChrome)
        XCTAssertTrue(presentation.shouldShowWizard)
    }

    func testResolvePresentationHonorsManualOverride() {
        let presentation = SetupCompletionPolicy.resolvePresentation(
            hasReadyCredential: false,
            hasSuccessfulFetch: false,
            preferredOrganizationID: "",
            cachedMetadata: nil,
            hasChromeApp: true,
            credentialStepOverride: .manualSessionKey
        )

        XCTAssertEqual(presentation.credentialStep, .manualSessionKey)
        XCTAssertEqual(presentation.landingSettingsTab, .overview)
        XCTAssertEqual(presentation.primaryActionKind, .openAdvancedSettings)
    }

    func testResolvePresentationMovesToOrganizationWhenPreferredOrganizationDoesNotMatch() {
        let metadata = ClaudeProfileMetadata(organizationUUID: "org-live")

        let presentation = SetupCompletionPolicy.resolvePresentation(
            hasReadyCredential: true,
            hasSuccessfulFetch: true,
            preferredOrganizationID: "org-selected",
            cachedMetadata: metadata,
            hasChromeApp: true
        )

        XCTAssertEqual(presentation.progress.stage, .organization)
        XCTAssertEqual(presentation.landingSettingsTab, .overview)
        XCTAssertEqual(presentation.primaryActionKind, .openOrganizations)
        XCTAssertFalse(presentation.progress.isOrganizationReady)
    }

    func testResolvePresentationCompletesForAutomaticOrganizationModeAfterSuccessfulFetch() {
        let presentation = SetupCompletionPolicy.resolvePresentation(
            hasReadyCredential: true,
            hasSuccessfulFetch: true,
            preferredOrganizationID: "",
            cachedMetadata: ClaudeProfileMetadata(organizationUUID: "org-auto"),
            hasChromeApp: false
        )

        XCTAssertEqual(presentation.progress.stage, .complete)
        XCTAssertEqual(presentation.landingSettingsTab, .overview)
        XCTAssertEqual(presentation.primaryActionKind, .complete)
        XCTAssertEqual(presentation.organizationSummary, "자동 선택 모드로 바로 사용할 수 있습니다")
        XCTAssertFalse(presentation.shouldShowWizard)
    }
}
