import Foundation

nonisolated enum AntigravityRuntimeBlocker:
    String,
    Sendable,
    Equatable
{
    case settingsMigration
    case typedSettings
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
}

/// Secret-free, atomic product projection for every Antigravity surface.
///
/// The old `AntigravityUsageResponse` cannot represent dynamic quota lanes.
/// Popover, compact view, menu bar, settings and notifications therefore
/// consume this side lane together instead of independently adapting the old
/// primary/secondary model.
nonisolated struct AntigravityRuntimeSnapshot:
    Sendable,
    Equatable
{
    let readiness: AntigravityRuntimeReadiness
    let settings: AntigravitySettingsSnapshot?
    let presentationState: AntigravityPresentationState
    let quotaPresentation:
        AntigravityQuotaPresentationMappingResult
    let managedRuntimeAvailability:
        AntigravityManagedRuntimeAvailability
    let lastAttemptAt: Date?
    let lastSuccessfulAt: Date?
    var publicationRevision: UInt64 = 0

    static let idle = AntigravityRuntimeSnapshot(
        readiness: .idle,
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
}
