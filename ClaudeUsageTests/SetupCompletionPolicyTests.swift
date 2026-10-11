import XCTest
@testable import ClaudeUsage

@MainActor
final class SetupCompletionPolicyTests: XCTestCase {
    func testMissingCredentialStartsAtTheCredentialStage() {
        let progress = SetupCompletionPolicy.resolveProgress(
            hasReadyCredential: false, hasSuccessfulFetch: false, preferredOrganizationID: "", cachedMetadata: nil)

        XCTAssertEqual(progress.stage, .credential)
    }

    func testCredentialWithoutFetchWaitsForVerification() {
        let progress = SetupCompletionPolicy.resolveProgress(
            hasReadyCredential: true, hasSuccessfulFetch: false, preferredOrganizationID: "", cachedMetadata: nil)

        XCTAssertEqual(progress.stage, .verification)
    }

    func testMismatchedPreferredOrganizationStaysAtTheOrganizationStage() {
        let progress = SetupCompletionPolicy.resolveProgress(
            hasReadyCredential: true, hasSuccessfulFetch: true, preferredOrganizationID: "org-selected",
            cachedMetadata: ClaudeProfileMetadata(organizationUUID: "org-live"))

        XCTAssertEqual(progress.stage, .organization)
        XCTAssertFalse(progress.isOrganizationReady)
    }

    func testAutomaticOrganizationCompletesAfterSuccessfulFetch() {
        let progress = SetupCompletionPolicy.resolveProgress(
            hasReadyCredential: true, hasSuccessfulFetch: true, preferredOrganizationID: "",
            cachedMetadata: ClaudeProfileMetadata(organizationUUID: "org-auto"))

        XCTAssertEqual(progress.stage, .complete)
    }
}
