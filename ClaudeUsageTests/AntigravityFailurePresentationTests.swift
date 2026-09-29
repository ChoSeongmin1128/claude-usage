import XCTest
@testable import ClaudeUsage

final class AntigravityFailurePresentationTests: XCTestCase {
    func testRuntimeFailuresRemainActionableAcrossSettingsAndPopover() {
        for reason in [AntigravityRuntimeFailure.executableMissing, .executableChanged,
            .verificationRejected, .unsupportedVersion, .reportDisabled,
        ] {
            let failure = AntigravityFailure.runtimeUnavailable(reason)
            let summary = AntigravityPopoverPresentationAdapter.failureSummary(failure)
            let notice = AntigravitySettingsNoticePresenter.refreshOutcomeNotice(.failed(failure))
            XCTAssertEqual(notice?.title, summary.title)
            XCTAssertEqual(notice?.message, summary.message)
            XCTAssertEqual(failure.diagnosticCode, "cliReport." + reason.rawValue)
            XCTAssertFalse(summary.message.contains("Google 계정을 다시 연결"))
            XCTAssertFalse(summary.message.contains("재시동"), "No failure may require restarting ClaudeUsage")
        }
    }

    func testOldAGYNamesTheRequiredRelease() {
        let summary = AntigravityPopoverPresentationAdapter.failureSummary(
            .runtimeUnavailable(.unsupportedVersion))

        XCTAssertTrue(summary.message.contains(AntigravityCLIVersion.minimumUsageReport.description))
        XCTAssertEqual(summary.action, .openSettings)
    }

    func testFailedUsageReportPointsToTheCLILogin() {
        let failure = AntigravityFailure.cliReportFailed
        let summary = AntigravityPopoverPresentationAdapter.failureSummary(failure)
        let notice = AntigravitySettingsNoticePresenter.refreshOutcomeNotice(.failed(failure))

        XCTAssertEqual(notice?.title, summary.title)
        XCTAssertEqual(notice?.message, summary.message)
        XCTAssertEqual(failure.diagnosticCode, "cliReport.reportFailed")
        XCTAssertTrue(summary.message.contains("AGY CLI"))
        XCTAssertTrue(summary.message.contains("로그인"))
        XCTAssertEqual(summary.action, .retry)
    }

    func testCSRFProblemsHaveConsistentSafeDiagnosticsAndGuidance() {
        for problem in [AntigravityCSRFProblem.required, .rejected, .unavailable] {
            let failure = AntigravityFailure.localAuthentication(.localApp, problem)
            let summary = AntigravityPopoverPresentationAdapter.failureSummary(failure)
            let notice = AntigravitySettingsNoticePresenter.refreshOutcomeNotice(.failed(failure))
            XCTAssertEqual(notice?.title, summary.title)
            XCTAssertEqual(notice?.message, summary.message)
            XCTAssertEqual(failure.diagnosticCode, "localApp.csrf." + problem.rawValue)
            XCTAssertFalse(summary.message.contains("Google"))
            XCTAssertFalse(summary.message.contains("CSRF"))
            XCTAssertFalse(summary.message.isEmpty)
        }
    }

    func testLoginGuidanceUsesTheFailingSource() {
        let local = AntigravityPopoverPresentationAdapter.failureSummary(.authenticationRequired(.localApp))
        let oauth = AntigravityPopoverPresentationAdapter.failureSummary(.authenticationRequired(.googleOAuth))
        XCTAssertTrue(local.message.contains("Antigravity 앱"))
        XCTAssertTrue(oauth.message.contains("조회 대상"))
        XCTAssertFalse(oauth.message.contains("Google 계정을 다시 연결"))
        XCTAssertNotEqual(local.title, oauth.title)
    }
}
