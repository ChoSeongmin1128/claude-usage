import Foundation

/// A synchronous, process-local once gate.
///
/// `AppSettings` reads and normalizes persisted popover configuration during
/// initialization. Antigravity's settings migration must therefore finish
/// before the first `AppSettings.shared` access, not later from
/// `applicationDidFinishLaunching`.
nonisolated final class AntigravitySettingsBootstrapGate<Result>:
    @unchecked Sendable
{
    private enum State {
        case pending
        case running
        case completed(Result)
    }

    private let condition = NSCondition()
    private var state: State = .pending

    func run(_ operation: () -> Result) -> Result {
        condition.lock()
        while true {
            switch state {
            case .pending:
                state = .running
                condition.unlock()

                let result = operation()

                condition.lock()
                state = .completed(result)
                condition.broadcast()
                condition.unlock()
                return result

            case .running:
                condition.wait()

            case .completed(let result):
                condition.unlock()
                return result
            }
        }
    }
}

nonisolated enum AntigravitySettingsBootstrapResult:
    Equatable,
    Sendable
{
    case ready(
        AntigravitySettingsMigrationCoordinator.Outcome
    )
    case blocked(
        AntigravitySettingsMigrationCoordinator.Failure
    )

    var isReady: Bool {
        guard case .ready = self else { return false }
        return true
    }
}

@MainActor
enum AntigravityApplicationBootstrap {
    private static let settingsGate =
        AntigravitySettingsBootstrapGate<
            AntigravitySettingsBootstrapResult
        >()

    static let settingsMigrationResult =
        settingsGate.run {
            let outcome =
                AntigravitySettingsMigrationCoordinator()
                    .migrate()
            switch outcome {
            case .alreadyCurrent, .migrated:
                return .ready(outcome)
            case .failed(let failure):
                return .blocked(failure)
            }
        }

    @discardableResult
    static func prepareSettings()
        -> AntigravitySettingsBootstrapResult
    {
        settingsMigrationResult
    }
}
