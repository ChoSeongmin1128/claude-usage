import XCTest
@testable import ClaudeUsage

final class AntigravityStatusProjectionTests: XCTestCase {
    private static let failures: [AntigravityFailure] =
        [
            .cancelled, .appShuttingDown, .invalidRefreshContext, .generationExhausted, .sourceUnavailable(.cliReport),
            .deadlineExceeded(.cliReport), .schemaChanged(.cliReport), .transportUnavailable(.cliReport),
            .sourceContractViolation(.cliReport), .cliReportFailed,
        ]
        + [.executableMissing, .executableChanged, .verificationRejected, .unsupportedVersion, .reportDisabled]
        .map(AntigravityFailure.runtimeUnavailable)

    func testEveryFailureUsesOneRemedyAcrossPopoverButtonSummaryAndAction() {
        for failure in Self.failures {
            let presentation = AntigravityFailurePresentation(failure)
            let summary = AntigravityPopoverPresentationAdapter.failureSummary(failure)
            let status = AntigravityStatusProjection(snapshot: snapshot(.failed(failure)))
            XCTAssertEqual(summary.title, presentation.title, "\(failure)")
            XCTAssertEqual(summary.message, presentation.message, "\(failure)")
            XCTAssertEqual(summary.action, presentation.remedy == .settings ? .openSettings : .retry, "\(failure)")
            XCTAssertEqual(status.summary, presentation.title, "\(failure)")
            XCTAssertEqual(status.requiresAction, presentation.remedy == .signIn, "\(failure)")
            XCTAssertEqual(status.phase, presentation.remedy == .signIn ? .authRequired : .temporaryError, "\(failure)")
            XCTAssertEqual(status.attemptState, .definitiveFailure)
            XCTAssertTrue(status.showsWarning)
        }
    }

    func testReadinessAndEnablementOverrideThePresentationState() {
        let failed = snapshot(.failed(.cliReportFailed), readiness: .bootstrapping)
        XCTAssertEqual(AntigravityStatusProjection(snapshot: failed).phase, .loading)
        XCTAssertEqual(AntigravityStatusProjection(snapshot: failed).attemptState, .loading)
        let blocked = AntigravityStatusProjection(snapshot: snapshot(.disabled, readiness: .blocked(.typedSettings)))
        XCTAssertEqual(blocked.summary, "설정 오류")
        XCTAssertTrue(blocked.showsWarning)
        let disabled = AntigravityStatusProjection(snapshot: snapshot(.failed(.cliReportFailed)), isEnabled: false)
        XCTAssertEqual(disabled.phase, .disabled)
        XCTAssertFalse(disabled.showsWarning)
    }

    private func snapshot(
        _ state: AntigravityPresentationState, readiness: AntigravityRuntimeReadiness = .ready
    ) -> AntigravityRuntimeSnapshot {
        AntigravityRuntimeSnapshot(
            readiness: readiness, settings: .init(connection: .default, display: .default), presentationState: state,
            quotaPresentation: .unavailable(state),
            managedRuntimeAvailability: .unavailable(reason: .executableNotFound),
            lastAttemptAt: nil, lastSuccessfulAt: nil)
    }
}
