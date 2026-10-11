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
            XCTAssertFalse(summary.message?.contains("Google 계정을 다시 연결") ?? false)
            XCTAssertFalse(summary.message?.contains("재시동") ?? false, "No failure may require restarting ClaudeUsage")
        }
    }

    func testOldAGYNamesTheRequiredRelease() {
        let summary = AntigravityPopoverPresentationAdapter.failureSummary(
            .runtimeUnavailable(.unsupportedVersion))

        XCTAssertTrue(summary.message?.contains(AntigravityCLIVersion.minimumUsageReport.description) == true)
        XCTAssertEqual(summary.action, .openSettings)
    }

    func testFailedUsageReportPointsToTheCLILogin() {
        let failure = AntigravityFailure.cliReportFailed
        let summary = AntigravityPopoverPresentationAdapter.failureSummary(failure)
        let notice = AntigravitySettingsNoticePresenter.refreshOutcomeNotice(.failed(failure))

        XCTAssertEqual(notice?.title, summary.title)
        XCTAssertEqual(notice?.message, summary.message)
        XCTAssertEqual(failure.diagnosticCode, "cliReport.reportFailed")
        XCTAssertTrue(summary.message?.contains("AGY CLI") == true)
        XCTAssertTrue(summary.message?.contains("로그인") == true)
        XCTAssertEqual(summary.action, .retry)
    }

    func testSettingsNoticeShowsTheRefreshOutcomeWithoutAccountState() {
        let failed = AntigravitySettingsNoticePresenter.notice(
            for: snapshot(readiness: .ready, presentation: .failed(.cliReportFailed)))
        let summary = AntigravityPopoverPresentationAdapter.failureSummary(.cliReportFailed)
        XCTAssertEqual(failed?.title, summary.title)
        XCTAssertEqual(failed?.action, .dismiss)

        let ready = AntigravitySettingsNoticePresenter.notice(
            for: snapshot(readiness: .ready, presentation: .ready(Self.report)))
        XCTAssertNil(ready)
    }

    func testBlockedSettingsNoticeOffersReloadWithoutMentioningAccounts() {
        for blocker in [AntigravityRuntimeBlocker.settingsMigration, .typedSettings] {
            let notice = AntigravitySettingsNoticePresenter.notice(
                for: snapshot(readiness: .blocked(blocker), presentation: .failed(.invalidRefreshContext)))
            XCTAssertEqual(notice?.title, "Antigravity를 준비하지 못했습니다")
            XCTAssertEqual(notice?.action, .retryLoad)
            XCTAssertFalse(notice?.message.contains("계정") ?? true)
        }
    }

    private func snapshot(
        readiness: AntigravityRuntimeReadiness,
        presentation: AntigravityPresentationState
    ) -> AntigravityRuntimeSnapshot {
        AntigravityRuntimeSnapshot(
            readiness: readiness,
            settings: AntigravitySettingsSnapshot(connection: .default, display: .default),
            presentationState: presentation,
            quotaPresentation: .unavailable(presentation),
            managedRuntimeAvailability: .unavailable(reason: .executableNotFound),
            lastAttemptAt: nil,
            lastSuccessfulAt: nil)
    }

    private static let report = AntigravityQuotaSnapshot(
        identity: nil, plan: nil, lanes: [], decodeIssues: [],
        provenance: AntigravityQuotaProvenance(transport: .cliUsageReport, accountIdentity: nil),
        fetchedAt: Date(timeIntervalSince1970: 1_900_000_000))
}
