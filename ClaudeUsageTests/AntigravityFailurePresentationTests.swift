import XCTest
@testable import ClaudeUsage

final class AntigravityFailurePresentationTests: XCTestCase {
    func testRuntimeFailuresRemainActionableAcrossSettingsAndPopover() {
        for reason in [AntigravityRuntimeFailure.executableMissing, .executableChanged,
                       .verificationRejected, .recoveryBlocked] {
            let failure = AntigravityFailure.runtimeUnavailable(reason)
            let summary = AntigravityPopoverPresentationAdapter.failureSummary(failure)
            let notice = AntigravitySettingsNoticePresenter.refreshOutcomeNotice(.failed(failure))
            XCTAssertEqual(notice?.title, summary.title)
            XCTAssertEqual(notice?.message, summary.message)
            XCTAssertFalse(summary.message.contains("Google 계정을 다시 연결"))
        }
    }

    func testCSRFProblemsHaveConsistentSafeDiagnosticsAndGuidance() {
        for problem in [AntigravityCSRFProblem.required, .rejected, .unavailable] {
            let failure = AntigravityFailure.localAuthentication(.managedCLI, problem)
            let summary = AntigravityPopoverPresentationAdapter.failureSummary(failure)
            let notice = AntigravitySettingsNoticePresenter.refreshOutcomeNotice(.failed(failure))
            XCTAssertEqual(notice?.title, summary.title)
            XCTAssertEqual(notice?.message, summary.message)
            XCTAssertEqual(failure.diagnosticCode, "managedCLI.csrf." + problem.rawValue)
            XCTAssertFalse(summary.message.contains("Google"))
            XCTAssertFalse(summary.message.contains("CSRF"))
            XCTAssertFalse(summary.message.isEmpty)
        }
    }

    func testLoginGuidanceUsesTheFailingSource() {
        let local = AntigravityPopoverPresentationAdapter.failureSummary(.authenticationRequired(.managedCLI))
        let oauth = AntigravityPopoverPresentationAdapter.failureSummary(.authenticationRequired(.googleOAuth))
        XCTAssertTrue(local.message.contains("AGY CLI"))
        XCTAssertTrue(oauth.message.contains("Google 계정을 다시 연결"))
        XCTAssertNotEqual(local.title, oauth.title)
    }
}
