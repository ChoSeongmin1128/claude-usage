import Foundation

nonisolated enum AntigravityRuntimeBlocker:
    String,
    Sendable,
    Equatable
{
    case settingsMigration
    case canonicalAccountState
    case typedSettings
    case managedRuntimeRecovery
}

nonisolated enum AntigravityRuntimeReadiness:
    Sendable,
    Equatable
{
    case idle
    case bootstrapping
    case ready
    case blocked(AntigravityRuntimeBlocker)
    case shuttingDown
}

nonisolated enum AntigravityManagedRuntimeAvailability:
    Sendable,
    Equatable
{
    nonisolated enum UnavailableReason:
        Sendable,
        Equatable
    {
        case executableNotFound
        case signatureRejected
    }

    case unavailable(reason: UnavailableReason)
    case available(displayPath: String)
    case recoveryBlocked(displayPath: String?)

    var launchState: AntigravityManagedLaunchState {
        switch self {
        case .available:
            .enabled
        case .unavailable:
            .disabled
        case .recoveryBlocked:
            .recoveryBlocked
        }
    }

    var allowsManagedLaunch: Bool {
        guard case .available = self else {
            return false
        }
        return true
    }
}

nonisolated struct AntigravityRuntimeAccountSummary:
    Identifiable,
    Sendable,
    Equatable
{
    let id: AntigravityAccountID
    let label: String
    let identity: ProviderAccountIdentity
    let isActive: Bool
}

/// Secret-free, atomic product projection for every Antigravity surface.
///
/// The old `AntigravityUsageResponse` cannot represent dynamic quota lanes or
/// the account/source boundary. Popover, compact view, menu bar, settings and
/// notifications therefore consume this side lane together instead of
/// independently adapting the old primary/secondary model.
nonisolated struct AntigravityRuntimeSnapshot:
    Sendable,
    Equatable
{
    let readiness: AntigravityRuntimeReadiness
    let migrationStatus: AntigravityMigrationStatus?
    let repositoryRevision: UInt64?
    let accounts: [AntigravityRuntimeAccountSummary]
    let activeAccountID: AntigravityAccountID?
    let settings: AntigravitySettingsSnapshot?
    let presentationState: AntigravityPresentationState
    let quotaPresentation:
        AntigravityQuotaPresentationMappingResult
    let managedRuntimeAvailability:
        AntigravityManagedRuntimeAvailability
    let lastAttemptAt: Date?
    let lastSuccessfulAt: Date?

    static let idle = AntigravityRuntimeSnapshot(
        readiness: .idle,
        migrationStatus: nil,
        repositoryRevision: nil,
        accounts: [],
        activeAccountID: nil,
        settings: nil,
        presentationState: .disabled,
        quotaPresentation: .unavailable(.disabled),
        managedRuntimeAvailability: .unavailable(
            reason: .executableNotFound
        ),
        lastAttemptAt: nil,
        lastSuccessfulAt: nil
    )

    var isLoading: Bool {
        if readiness == .bootstrapping {
            return true
        }
        guard case .refreshing = presentationState else {
            return false
        }
        return true
    }

    var hasQuotaContent: Bool {
        guard case .content = quotaPresentation else {
            return false
        }
        return true
    }

    var activeAccount: AntigravityRuntimeAccountSummary? {
        guard let activeAccountID else { return nil }
        return accounts.first { $0.id == activeAccountID }
    }
}
