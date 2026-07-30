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
    let managedRuntime:
        AntigravityManagedRuntimeComposition
    let refreshCoordinator:
        AntigravityRefreshCoordinator
    let runtimeController:
        AntigravityRuntimeController
    let executableResolution:
        AntigravityProductionExecutableResolution
}

@MainActor
enum
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
        let executableResolution =
            AntigravityProductionExecutableCatalogResolver(
                homeDirectoryURL:
                    homeDirectoryURL
            ).resolve()
        let managedRuntime =
            AntigravityManagedRuntimeCompositionFactory
                .makeProduction(
                    catalog:
                        executableResolution.catalog,
                    managedStateDirectoryURL:
                        stateDirectory,
                    managedLaunchCoordinationDirectoryURL:
                        managedLaunchCoordinationDirectory,
                    currentDirectoryURL:
                        homeDirectoryURL
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

        var sources: [any AntigravityUsageSource] = [
            AntigravityDiscoveredLocalUsageSource(
                id: .localApp,
                discovery:
                    managedRuntime.discovery,
                client:
                    managedRuntime.localRPCClient
            ),
            AntigravityDiscoveredLocalUsageSource(
                id: .borrowedCLI,
                discovery:
                    managedRuntime.discovery,
                client:
                    managedRuntime.localRPCClient
            ),
            AntigravityGoogleOAuthUsageSource(
                client:
                    AntigravityGoogleOAuthQuotaClient()
            ),
        ]
        if let executable =
                executableResolution
                    .managedLaunchExecutable
        {
            sources.append(
                AntigravityManagedCLIUsageSource(
                    session:
                        managedRuntime.managedSession,
                    executable: executable,
                    client:
                        managedRuntime.localRPCClient
                )
            )
        }

        let refreshCoordinator =
            AntigravityRefreshCoordinator(
                repository: repository,
                sources: sources
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
                    managedRuntime.managedSession,
                settingsBootstrap:
                    settingsBootstrap,
                agyExecutableStatus:
                    executableResolution
                        .agyExecutableStatus
            )

        return AntigravityProductRuntimeComposition(
            repository: repository,
            settingsStore: settingsStore,
            migrationCoordinator:
                migrationCoordinator,
            managedRuntime: managedRuntime,
            refreshCoordinator:
                refreshCoordinator,
            runtimeController:
                runtimeController,
            executableResolution:
                executableResolution
        )
    }
}
