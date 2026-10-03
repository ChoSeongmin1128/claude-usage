import Foundation

nonisolated enum AntigravityRefreshTrigger:
    String,
    Sendable,
    Equatable
{
    case scheduled
    case manual
    case retry
    case accountBoundaryChanged
    case migrationCompleted

    var clearsPreviousSnapshot: Bool {
        switch self {
        case .accountBoundaryChanged,
             .migrationCompleted:
            true
        case .scheduled, .manual, .retry:
            false
        }
    }
}

/// Immutable input captured at the beginning of one refresh transaction.
///
/// The complete validated connection snapshot travels with the request so
/// source selection and single-flight identity cannot observe settings from
/// different revisions. Account target remains an
/// explicit product boundary. The authenticated identity is observed on each
/// refresh instead of being persisted as a user-selectable login.
nonisolated struct AntigravityRefreshRequest:
    Sendable,
    Equatable
{
    let trigger: AntigravityRefreshTrigger
    /// 2.10.0부터 AGY CLI만 조회한다. 저장된 값(이전 버전의 독립 앱, 미선택)은 되돌릴 때를 위해 그대로 두고 여기서만 CLI로 본다.
    var target: AntigravityUsageTarget { .cli }
    let repositoryRevision: UInt64
    let connection: AntigravityConnectionSettings
    var forcesDiscovery: Bool { trigger != .scheduled }
    init(
        trigger: AntigravityRefreshTrigger,
        repositoryRevision: UInt64,
        connection: AntigravityConnectionSettings
    ) {
        precondition(
            connection.isCurrentAndValid,
            "Refresh requires validated connection settings"
        )
        self.trigger = trigger
        self.repositoryRevision = repositoryRevision
        self.connection = connection
    }
}

nonisolated enum AntigravityUsageSourceID:
    String,
    CaseIterable,
    Sendable,
    Equatable,
    Hashable
{
    case localApp
    case cliReport
    case googleOAuth

    // A CLI usage report is one atomic answer from the signed-in CLI and
    // names no account, so there is no cross-request boundary to verify.
    var reportsAccountIdentity: Bool {
        switch self {
        case .localApp, .googleOAuth: true
        case .cliReport: false
        }
    }
}

nonisolated enum AntigravitySetupReason:
    Sendable,
    Equatable
{
    case noSelectedOAuthAccount
    case noAmbientLocalSession
    case usageTargetSelection
    case ambiguousLocalSessions
}

nonisolated struct AntigravityIdentityOnlyUsage:
    Sendable,
    Equatable
{
    let identity: ProviderAccountIdentity
    let plan: String?
    let provenance: AntigravityQuotaProvenance
    let fetchedAt: Date
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
    case repositoryUnavailable
    case repositoryRevisionChanged
    case credentialCommitFailed
    case credentialCommitAmbiguous
    case selectedAccountUnavailable(AntigravityAccountID)
    case selectedAccountIdentityUnavailable(AntigravityAccountID)
    case noEligibleSource
    case sourceUnavailable(AntigravityUsageSourceID)
    case authenticationRequired(AntigravityUsageSourceID)
    case localAuthentication(AntigravityUsageSourceID, AntigravityCSRFProblem)
    case interactionRequired(AntigravityUsageSourceID)
    case deadlineExceeded(AntigravityUsageSourceID)
    case schemaChanged(AntigravityUsageSourceID)
    case transportUnavailable(AntigravityUsageSourceID)
    case sourceContractViolation(AntigravityUsageSourceID)
    case numericQuotaUnavailable
    case accountChanged
    case runtimeUnavailable(AntigravityRuntimeFailure)
    case cliReportFailed
}

extension AntigravityFailure {
    /// No account IDs, token material or raw server errors may enter diagnostics.
    var diagnosticCode: String {
        switch self {
        case .localAuthentication(let source, let problem): "\(source.rawValue).csrf.\(problem.rawValue)"
        case .runtimeUnavailable(let reason): "cliReport.\(reason.rawValue)"
        case .cliReportFailed: "cliReport.reportFailed"
        case .authenticationRequired(let source): "\(source.rawValue).authenticationRequired"
        case .interactionRequired(let source): "\(source.rawValue).interactionRequired"
        case .deadlineExceeded(let source): "\(source.rawValue).deadlineExceeded"
        case .schemaChanged(let source): "\(source.rawValue).schemaChanged"
        case .transportUnavailable(let source): "\(source.rawValue).transportUnavailable"
        case .sourceUnavailable(let source): "\(source.rawValue).sourceUnavailable"
        case .sourceContractViolation(let source): "\(source.rawValue).sourceContractViolation"
        case .selectedAccountUnavailable: "selectedAccountUnavailable"
        case .selectedAccountIdentityUnavailable: "selectedAccountIdentityUnavailable"
        case .cancelled: "cancelled"
        case .appShuttingDown: "appShuttingDown"
        case .invalidRefreshContext: "invalidRefreshContext"
        case .generationExhausted: "generationExhausted"
        case .repositoryUnavailable: "repositoryUnavailable"
        case .repositoryRevisionChanged: "repositoryRevisionChanged"
        case .credentialCommitFailed: "credentialCommitFailed"
        case .credentialCommitAmbiguous: "credentialCommitAmbiguous"
        case .noEligibleSource: "noEligibleSource"
        case .numericQuotaUnavailable: "numericQuotaUnavailable"
        case .accountChanged: "accountChanged"
        }
    }
}

nonisolated enum AntigravityPresentationState:
    Sendable,
    Equatable
{
    case disabled
    case setupRequired(AntigravitySetupReason)
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
    case accountMismatch(
        expected: ProviderAccountIdentity,
        received: ProviderAccountIdentity?
    )
    case limited(AntigravityLimitedQuotaCapability)
    case identityOnly(AntigravityIdentityOnlyUsage)
    case failed(AntigravityFailure)
}

/// Settings and account mutations invalidate the old boundary before changing
/// persistence, then issue exactly one refresh with the newly captured request.
/// The protocol keeps those callers independent of the concrete actor.
nonisolated protocol AntigravityRefreshCoordinating: Sendable {
    func quiesceForShutdown() async

    func invalidateBoundary() async

    func refresh(
        _ request: AntigravityRefreshRequest
    ) async -> AntigravityPresentationState

    func presentationState() async -> AntigravityPresentationState

}
