import Foundation
import os

/// Only fixed codes and route names cross the production logging boundary.
/// Account identifiers, URLs, server descriptions and credentials are never fields.
nonisolated struct OperationalDiagnostic: Equatable, Sendable {
    let code: String
    let source: String
    let isFailure: Bool

    private init(code: String, source: String, isFailure: Bool = false) {
        self.code = code
        self.source = source
        self.isFailure = isFailure
    }

    static func antigravity(_ state: AntigravityPresentationState) -> Self? {
        switch state {
        case .ready(let snapshot):
            return Self(code: "agy.quotaReady", source: snapshot.provenance.transport.rawValue)
        case .partial(let snapshot, _):
            return Self(code: "agy.quotaPartial", source: snapshot.provenance.transport.rawValue)
        case .limited(let evidence):
            return Self(code: "agy.quotaLimited", source: evidence.provenance.transport.rawValue)
        case .identityOnly(let evidence):
            return Self(code: "agy.identityOnly", source: evidence.provenance.transport.rawValue)
        case .accountMismatch:
            return Self(code: "agy.accountMismatch", source: "coordinator", isFailure: true)
        case .stale(_, let failure), .failed(let failure):
            if failure == .cancelled || failure == .appShuttingDown { return nil }
            return Self(
                code: "agy." + failure.diagnosticCode,
                source: source(for: failure), isFailure: true)
        case .setupRequired(let reason):
            let code: String
            switch reason {
            case .noSelectedOAuthAccount: code = "agy.noSelectedAccount"
            case .noAmbientLocalSession: code = "agy.noLocalSession"
            case .usageTargetSelection, .ambiguousLocalSessions: code = "agy.usageTargetSelectionRequired"
            case .managedRecoveryBlocked: code = "agy.recoveryBlocked"
            }
            return Self(code: code, source: "coordinator", isFailure: true)
        case .disabled, .refreshing:
            return nil
        }
    }

    private static func source(for failure: AntigravityFailure) -> String {
        switch failure {
        case .sourceUnavailable(let source), .authenticationRequired(let source),
            .localAuthentication(let source, _), .interactionRequired(let source),
            .deadlineExceeded(let source), .schemaChanged(let source),
            .transportUnavailable(let source), .sourceContractViolation(let source):
            return source.rawValue
        case .runtimeUnavailable:
            return AntigravityUsageSourceID.managedCLI.rawValue
        default:
            return "coordinator"
        }
    }

    enum UpdateOutcome: String, Sendable {
        case available, upToDate, cancelled, feedUnavailable, validationFailed
        case downloadFailed, installationFailed, configurationInvalid, connectionFailed, failed
    }

    static func update(_ outcome: UpdateOutcome) -> Self {
        Self(
            code: "update." + outcome.rawValue, source: "sparkle",
            isFailure: ![.available, .upToDate, .cancelled].contains(outcome))
    }
}

nonisolated enum OperationalLog {
    private static let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.seongmin.ClaudeUsage",
        category: "operational"
    )

    static func record(_ diagnostic: OperationalDiagnostic?, elapsed: Duration?) {
        guard let diagnostic else { return }
        let code = diagnostic.code
        let source = diagnostic.source
        // A missing cycle start is explicit; it is not reported as a zero-duration request.
        let milliseconds =
            elapsed.map {
                Double($0.components.seconds) * 1_000 + Double($0.components.attoseconds) / 1e15
            } ?? -1
        if diagnostic.isFailure {
            logger.error(
                "event=\(code, privacy: .public) source=\(source, privacy: .public) duration_ms=\(milliseconds)")
        } else {
            logger.info(
                "event=\(code, privacy: .public) source=\(source, privacy: .public) duration_ms=\(milliseconds)")
        }
    }
}
