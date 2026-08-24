import Foundation

nonisolated enum AntigravityRefreshAccountTarget:
    Sendable,
    Equatable
{
    case selectedOAuth(AntigravityAccountID)
    case ambientLocal
}

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
/// source selection, managed-session policy, and single-flight identity cannot
/// observe settings from different revisions. Account target remains an
/// explicit boundary: `.ambientLocal` never means "whichever OAuth account
/// happens to be active" and `.selectedOAuth` never authorizes a local identity
/// guess.
nonisolated struct AntigravityRefreshRequest:
    Sendable,
    Equatable
{
    let trigger: AntigravityRefreshTrigger
    let accountTarget: AntigravityRefreshAccountTarget
    let repositoryRevision: UInt64
    let connection: AntigravityConnectionSettings
    let managedLaunch: AntigravityManagedLaunchState

    init(
        trigger: AntigravityRefreshTrigger,
        accountTarget: AntigravityRefreshAccountTarget,
        repositoryRevision: UInt64,
        connection: AntigravityConnectionSettings,
        managedLaunch: AntigravityManagedLaunchState
    ) {
        precondition(
            connection.isCurrentAndValid,
            "Refresh requires validated connection settings"
        )
        self.trigger = trigger
        self.accountTarget = accountTarget
        self.repositoryRevision = repositoryRevision
        self.connection = connection
        self.managedLaunch = managedLaunch
    }
}

/// Whether this refresh may start an app-owned AGY process, carried as one
/// state so the illegal "enabled but recovery-blocked" combination is not
/// representable and every consumer can name the disable cause.
nonisolated enum AntigravityManagedLaunchState:
    Sendable,
    Equatable
{
    case enabled
    case disabled
    /// Disabled because startup recovery could not reconcile a persisted
    /// managed-process record. An ambient refresh that finds no local
    /// session names this cause instead of asking the user to log in.
    case recoveryBlocked

    var allowsLaunch: Bool {
        self == .enabled
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
    case borrowedCLI
    case managedCLI
    case googleOAuth
}

nonisolated enum AntigravitySetupReason:
    Sendable,
    Equatable
{
    case noSelectedOAuthAccount
    case noAmbientLocalSession
    /// No local session is reachable and the app's own managed launch is
    /// disabled because startup recovery could not reconcile a persisted
    /// managed-process record. Logging in does not resolve this state.
    case managedRecoveryBlocked
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
    case interactionRequired(AntigravityUsageSourceID)
    case deadlineExceeded(AntigravityUsageSourceID)
    case schemaChanged(AntigravityUsageSourceID)
    case transportUnavailable(AntigravityUsageSourceID)
    case sourceContractViolation(AntigravityUsageSourceID)
    case numericQuotaUnavailable
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
