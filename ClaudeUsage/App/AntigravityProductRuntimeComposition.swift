import Foundation

/// One production graph shared by AppDelegate, settings and every
/// Antigravity presentation surface.
///
/// Constructing a second repository or refresh coordinator would create a
/// second revision/generation authority, so the factory exposes the already
/// assembled instances instead of individual convenience constructors.
nonisolated struct AntigravityProductRuntimeComposition:
    Sendable
{
    let repository: AntigravityAccountRepository
    let settingsStore: AntigravitySettingsStore
    let migrationCoordinator:
        AntigravityMigrationCoordinator
    let runtimeEnvironment: AntigravityRuntimeEnvironment
    let refreshCoordinator:
        AntigravityRefreshCoordinator
    let runtimeController:
        AntigravityRuntimeController
}

nonisolated enum
    AntigravityProductRuntimeCompositionFactory
{
    static func makeProduction(
        settingsBootstrap:
            AntigravitySettingsBootstrapResult,
        homeDirectoryURL: URL =
            FileManager.default.realHomeDirectory
    ) -> AntigravityProductRuntimeComposition {
        let stateDirectory =
            AntigravityStoragePaths
                .canonicalStateDirectoryURL(
                    homeDirectoryURL:
                        homeDirectoryURL
                )
        let applicationSupportDirectory =
            AntigravityStoragePaths
                .applicationSupportDirectoryURL(
                    homeDirectoryURL:
                        homeDirectoryURL
                )
        let managedLaunchCoordinationDirectory =
            AntigravityStoragePaths
                .managedLaunchCoordinationDirectoryURL(
                    homeDirectoryURL:
                        homeDirectoryURL
                )
        let runtimeEnvironment = AntigravityRuntimeEnvironment.production(
            homeDirectoryURL: homeDirectoryURL, stateDirectory: stateDirectory,
            managedLaunchCoordinationDirectory: managedLaunchCoordinationDirectory
        )

        let repository =
            AntigravityAccountRepository(
                metadataStore:
                    AntigravityAccountMetadataFileStore(
                        fileURL:
                            stateDirectory
                                .appendingPathComponent(
                                    "accounts.json"
                                )
                    ),
                journalStore:
                    AntigravityAccountOperationJournalFileStore(
                        fileURL:
                            stateDirectory
                                .appendingPathComponent(
                                    "account-operation.json"
                                )
                    ),
                vault:
                    SecurityFrameworkOAuthCredentialVault
                        .shared
            )
        let settingsStore =
            AntigravitySettingsStore()
        let migrationCoordinator =
            AntigravityMigrationCoordinator(
                repository: repository,
                journalStore:
                    AntigravityMigrationJournalFileStore(
                        fileURL:
                            stateDirectory
                                .appendingPathComponent(
                                    "credential-migration-v2.json"
                                )
                    ),
                completionMarkerStore:
                    AntigravityMigrationCompletionMarkerFileStore(
                        fileURL:
                            applicationSupportDirectory
                                .appendingPathComponent(
                                    "Migrations",
                                    isDirectory: true
                                )
                                .appendingPathComponent(
                                    "antigravity-credentials-v2.json"
                                )
                    )
            )

        let sources: [any AntigravityUsageSource] = [
            AntigravityGoogleOAuthUsageSource(client: AntigravityGoogleOAuthQuotaClient()),
        ]

        let refreshCoordinator =
            AntigravityRefreshCoordinator(
                repository: repository,
                sources: sources,
                runtimeEnvironment: runtimeEnvironment
            )
        let runtimeController =
            AntigravityRuntimeController(
                repository: repository,
                settingsStore: settingsStore,
                migrationCoordinator:
                    migrationCoordinator,
                refreshCoordinator:
                    refreshCoordinator,
                managedSession:
                    runtimeEnvironment,
                settingsBootstrap:
                    settingsBootstrap,
                agyExecutableStatus: .notFound,
                runtimeEnvironment: runtimeEnvironment
            )

        return AntigravityProductRuntimeComposition(
            repository: repository,
            settingsStore: settingsStore,
            migrationCoordinator:
                migrationCoordinator,
            runtimeEnvironment: runtimeEnvironment,
            refreshCoordinator:
                refreshCoordinator,
            runtimeController:
                runtimeController
        )
    }
}

nonisolated enum AntigravityProductRuntimeLoader {
    static func makeProduction(
        settingsBootstrap:
            AntigravitySettingsBootstrapResult,
        homeDirectoryURL: URL =
            FileManager.default.realHomeDirectory
    ) async -> AntigravityProductRuntimeComposition {
        await performDetached {
            AntigravityProductRuntimeCompositionFactory
                .makeProduction(
                    settingsBootstrap:
                        settingsBootstrap,
                    homeDirectoryURL:
                        homeDirectoryURL
                )
        }
    }

    static func performDetached<Result: Sendable>(
        _ operation:
            @escaping @Sendable () -> Result
    ) async -> Result {
        await Task.detached(
            priority: .userInitiated,
            operation: operation
        )
        .value
    }
}
