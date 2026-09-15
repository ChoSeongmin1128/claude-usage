import Foundation
import Sparkle
import XCTest
@testable import ClaudeUsage

@MainActor
final class OperationalLogTests: XCTestCase {
    func testSparkleCycleStartUsesTheActualDelegateSelector() {
        let engine = SparkleUpdateEngine(feedURL: nil)
        XCTAssertTrue(engine.responds(to: NSSelectorFromString("updater:mayPerformUpdateCheck:error:")))
    }

    func testAccountMaterialNeverEntersFailureDiagnostics() {
        let secret = "private@example.test bearer-secret csrf-secret"
        let diagnostic = OperationalDiagnostic.antigravity(
            .failed(.selectedAccountUnavailable(.init(rawValue: secret)))
        )
        XCTAssertEqual(diagnostic?.code, "agy.selectedAccountUnavailable")
        XCTAssertEqual(diagnostic?.source, "coordinator")
        XCTAssertFalse(String(describing: diagnostic).contains(secret))
    }

    func testCSRFAndTransportFailuresRemainDistinct() {
        let csrf = OperationalDiagnostic.antigravity(.failed(.localAuthentication(.managedCLI, .rejected)))
        let transport = OperationalDiagnostic.antigravity(.failed(.transportUnavailable(.managedCLI)))
        XCTAssertEqual(csrf?.code, "agy.managedCLI.csrf.rejected")
        XCTAssertEqual(csrf?.source, "managedCLI")
        XCTAssertEqual(transport?.code, "agy.managedCLI.transportUnavailable")
        XCTAssertEqual(csrf?.isFailure, true)
    }

    func testCancellationAndIntermediateStatesDoNotProduceOperationalNoise() {
        for state: AntigravityPresentationState in [
            .disabled, .refreshing(previous: nil),
            .failed(.cancelled), .failed(.appShuttingDown),
        ] {
            XCTAssertNil(OperationalDiagnostic.antigravity(state))
        }
    }

    func testNestedSparkleValidationFailureDoesNotBecomeGenericFeedFailure() {
        let inner = NSError(
            domain: SUSparkleErrorDomain, code: 3002,
            userInfo: [NSLocalizedDescriptionKey: "csrf-secret private@example.test"])
        let outer = NSError(
            domain: SUSparkleErrorDomain, code: 1000,
            userInfo: [NSUnderlyingErrorKey: inner])
        let outcome = SparkleUpdateResultInterpreter.diagnosticOutcome(error: outer, foundUpdate: false)
        let diagnostic = OperationalDiagnostic.update(outcome)
        XCTAssertEqual(diagnostic.code, "update.validationFailed")
        XCTAssertEqual(diagnostic.source, "sparkle")
        XCTAssertFalse(String(describing: diagnostic).contains("csrf-secret"))
    }

    func testOrdinaryUpdateResultsDoNotBecomeErrors() {
        XCTAssertEqual(SparkleUpdateResultInterpreter.diagnosticOutcome(error: nil, foundUpdate: true), .available)
        XCTAssertEqual(
            SparkleUpdateResultInterpreter.diagnosticOutcome(
                error: NSError(domain: SUSparkleErrorDomain, code: 1001), foundUpdate: false), .upToDate)
        XCTAssertEqual(
            SparkleUpdateResultInterpreter.diagnosticOutcome(
                error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled), foundUpdate: false), .cancelled)
        XCTAssertFalse(OperationalDiagnostic.update(.upToDate).isFailure)
    }
}
