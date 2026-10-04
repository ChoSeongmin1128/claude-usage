import Foundation

nonisolated struct AntigravityDisplaySettingsCommandAdapter:
    Sendable
{
    private let runtime:
        any AntigravitySettingsRuntimeControlling

    init(
        runtime:
            any AntigravitySettingsRuntimeControlling
    ) {
        self.runtime = runtime
    }

    func update(
        _ display: AntigravityDisplaySettings,
        replacing expected:
            AntigravityDisplaySettings
    ) async throws -> AntigravityRuntimeSnapshot {
        try await runtime.updateDisplay(
            display,
            replacing: expected
        )
    }

    func acknowledgeMigrationNotice() async
        -> AntigravityRuntimeSnapshot
    {
        await runtime.consumePendingSettingsNotice()
    }
}
