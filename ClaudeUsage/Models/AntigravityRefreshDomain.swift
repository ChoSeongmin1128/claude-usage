import Foundation

nonisolated enum AntigravityRefreshTrigger:
    String,
    Sendable,
    Equatable
{
    case scheduled
    case manual
    case retry
}

/// Immutable input captured at the beginning of one refresh transaction.
///
/// The complete validated connection snapshot travels with the request so
/// single-flight identity cannot observe settings from different revisions.
/// 2.8.0부터 AGY CLI만 조회한다. 저장된 조회 대상(이전 버전의 독립 앱, 미선택)은 되돌릴 때를 위해 그대로 둔다.
nonisolated struct AntigravityRefreshRequest:
    Sendable,
    Equatable
{
    let trigger: AntigravityRefreshTrigger
    let connection: AntigravityConnectionSettings
    init(
        trigger: AntigravityRefreshTrigger,
        connection: AntigravityConnectionSettings
    ) {
        precondition(
            connection.isCurrentAndValid,
            "Refresh requires validated connection settings"
        )
        self.trigger = trigger
        self.connection = connection
    }
}

/// 진단 코드의 접두어로 남긴다. 조회 경로는 AGY CLI 사용량 보고 하나다.
nonisolated enum AntigravityUsageSourceID:
    String,
    CaseIterable,
    Sendable,
    Equatable,
    Hashable
{
    case cliReport
}

nonisolated enum AntigravityRuntimeFailure: String, Error, Sendable, Equatable {
    case executableMissing
    case executableChanged
    case verificationRejected
    case unsupportedVersion
    case reportDisabled
}

/// Stable, secret-free failures suitable for UI state and diagnostics.
nonisolated enum AntigravityFailure:
    Error,
    Sendable,
    Equatable
{
    case cancelled
    case appShuttingDown
    case invalidRefreshContext
    case generationExhausted
    case sourceUnavailable(AntigravityUsageSourceID)
    case deadlineExceeded(AntigravityUsageSourceID)
    case schemaChanged(AntigravityUsageSourceID)
    case transportUnavailable(AntigravityUsageSourceID)
    case sourceContractViolation(AntigravityUsageSourceID)
    case runtimeUnavailable(AntigravityRuntimeFailure)
    case cliReportFailed
}

extension AntigravityFailure {
    /// No account IDs, token material or raw server errors may enter diagnostics.
    var diagnosticCode: String {
        switch self {
        case .runtimeUnavailable(let reason): "cliReport.\(reason.rawValue)"
        case .cliReportFailed: "cliReport.reportFailed"
        case .deadlineExceeded(let source): "\(source.rawValue).deadlineExceeded"
        case .schemaChanged(let source): "\(source.rawValue).schemaChanged"
        case .transportUnavailable(let source): "\(source.rawValue).transportUnavailable"
        case .sourceUnavailable(let source): "\(source.rawValue).sourceUnavailable"
        case .sourceContractViolation(let source): "\(source.rawValue).sourceContractViolation"
        case .cancelled: "cancelled"
        case .appShuttingDown: "appShuttingDown"
        case .invalidRefreshContext: "invalidRefreshContext"
        case .generationExhausted: "generationExhausted"
        }
    }
}

nonisolated enum AntigravityPresentationState:
    Sendable,
    Equatable
{
    case disabled
    case refreshing(previous: AntigravityQuotaSnapshot?)
    case ready(AntigravityQuotaSnapshot)
    case partial(
        AntigravityQuotaSnapshot,
        issues: [AntigravityQuotaDecodeIssue]
    )
    case stale(
        AntigravityQuotaSnapshot,
        failure: AntigravityFailure
    )
    case failed(AntigravityFailure)
}

/// The protocol keeps the runtime controller independent of the concrete actor.
nonisolated protocol AntigravityRefreshCoordinating: Sendable {
    func quiesceForShutdown() async

    func refresh(
        _ request: AntigravityRefreshRequest
    ) async -> AntigravityPresentationState

    func presentationState() async -> AntigravityPresentationState

}
