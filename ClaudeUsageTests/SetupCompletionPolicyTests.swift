import XCTest
@testable import ClaudeUsage

@MainActor
final class SetupCompletionPolicyTests: XCTestCase {
    func testResolvePresentationRecommendsBrowserImportFirst() {
        let presentation = SetupCompletionPolicy.resolvePresentation(
            hasReadyCredential: false,
            hasSuccessfulFetch: false,
            preferredOrganizationID: "",
            cachedMetadata: nil
        )

        XCTAssertEqual(presentation.progress.stage, .credential)
        XCTAssertEqual(presentation.credentialStep, .browserImport)
        XCTAssertEqual(presentation.primaryActionKind, .importFromBrowser)
        XCTAssertTrue(presentation.shouldShowWizard)
    }

    func testResolvePresentationHonorsManualOverride() {
        let presentation = SetupCompletionPolicy.resolvePresentation(
            hasReadyCredential: false,
            hasSuccessfulFetch: false,
            preferredOrganizationID: "",
            cachedMetadata: nil,
            credentialStepOverride: .manualSessionKey
        )

        XCTAssertEqual(presentation.credentialStep, .manualSessionKey)
        XCTAssertEqual(presentation.primaryActionKind, .openAdvancedSettings)
    }

    func testResolvePresentationMovesToOrganizationWhenPreferredOrganizationDoesNotMatch() {
        let metadata = ClaudeProfileMetadata(organizationUUID: "org-live")

        let presentation = SetupCompletionPolicy.resolvePresentation(
            hasReadyCredential: true,
            hasSuccessfulFetch: true,
            preferredOrganizationID: "org-selected",
            cachedMetadata: metadata
        )

        XCTAssertEqual(presentation.progress.stage, .organization)
        XCTAssertEqual(presentation.primaryActionKind, .openOrganizations)
        XCTAssertFalse(presentation.progress.isOrganizationReady)
    }

    func testResolvePresentationCompletesForAutomaticOrganizationModeAfterSuccessfulFetch() {
        let presentation = SetupCompletionPolicy.resolvePresentation(
            hasReadyCredential: true,
            hasSuccessfulFetch: true,
            preferredOrganizationID: "",
            cachedMetadata: ClaudeProfileMetadata(organizationUUID: "org-auto")
        )

        XCTAssertEqual(presentation.progress.stage, .complete)
        XCTAssertEqual(presentation.primaryActionKind, .complete)
        XCTAssertNil(presentation.organizationSummary)
        XCTAssertFalse(presentation.shouldShowWizard)
    }
}
