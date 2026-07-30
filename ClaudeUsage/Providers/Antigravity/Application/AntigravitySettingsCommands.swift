import Foundation

nonisolated struct AntigravityAccountCommandCoordinator:
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

    func selectAccount(
        _ accountID: AntigravityAccountID?
    ) async throws -> AntigravityRuntimeSnapshot {
        try await runtime.selectAccount(accountID)
    }

    func connectAccount(
        credentials: AntigravityOAuthCredentials,
        label: String?
    ) async throws -> AntigravityRuntimeSnapshot {
        try await runtime.connectAccount(
            credentials: credentials,
            label: label
        )
    }

    func deleteAccount(
        _ accountID: AntigravityAccountID
    ) async throws -> AntigravityRuntimeSnapshot {
        try await runtime.deleteAccount(accountID)
    }

    func removeAllAccounts(
        interactively: Bool
    ) async -> AntigravityRuntimeSnapshot {
        await runtime.removeAllAccounts(
            interactively: interactively
        )
    }
}

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
