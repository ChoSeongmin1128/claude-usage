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

    func testAccountMaterialNeverEntersDiagnostics() {
        let secret = "private@example.test bearer-secret"
        let identity = ProviderAccountIdentity(stableAccountID: secret, email: secret)
        let snapshot = AntigravityQuotaSnapshot(
            identity: identity, plan: nil, lanes: [], decodeIssues: [],
            provenance: AntigravityQuotaProvenance(transport: .cliUsageReport, accountIdentity: identity),
            fetchedAt: Date(timeIntervalSince1970: 1_900_000_000))
        let diagnostic = OperationalDiagnostic.antigravity(.ready(snapshot))
        XCTAssertEqual(diagnostic?.code, "agy.quotaReady")
        XCTAssertEqual(diagnostic?.source, "cliUsageReport")
        XCTAssertFalse(String(describing: diagnostic).contains(secret))
    }

    func testTransportFailuresAreAttributedToTheReportSource() {
        let transport = OperationalDiagnostic.antigravity(.failed(.transportUnavailable(.cliReport)))
        XCTAssertEqual(transport?.code, "agy.cliReport.transportUnavailable")
        XCTAssertEqual(transport?.source, "cliReport")
        XCTAssertEqual(transport?.isFailure, true)
    }

    func testCLIReportFailuresAreAttributedToTheReportSource() {
        let failed = OperationalDiagnostic.antigravity(.failed(.cliReportFailed))
        let runtime = OperationalDiagnostic.antigravity(.failed(.runtimeUnavailable(.unsupportedVersion)))
        XCTAssertEqual(failed?.code, "agy.cliReport.reportFailed")
        XCTAssertEqual(failed?.source, "cliReport")
        XCTAssertEqual(runtime?.code, "agy.cliReport.unsupportedVersion")
        XCTAssertEqual(runtime?.source, "cliReport")
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
