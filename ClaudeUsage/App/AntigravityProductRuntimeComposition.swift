import Foundation

/// One production graph shared by AppDelegate, settings and every
/// Antigravity presentation surface.
///
/// Constructing a second refresh coordinator would create a second generation
/// authority, so the factory exposes the already assembled instances instead
/// of individual convenience constructors.
nonisolated struct AntigravityProductRuntimeComposition:
    Sendable
{
    let settingsStore: AntigravitySettingsStore
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
        let runtimeEnvironment = AntigravityRuntimeEnvironment.production(
            homeDirectoryURL: homeDirectoryURL, stateDirectory: stateDirectory
        )
        let settingsStore =
            AntigravitySettingsStore()
        let refreshCoordinator =
            AntigravityRefreshCoordinator(
                sources: [],
                runtimeEnvironment: runtimeEnvironment
            )
        let runtimeController =
            AntigravityRuntimeController(
                settingsStore: settingsStore,
                refreshCoordinator:
                    refreshCoordinator,
                runtimeLifecycle:
                    runtimeEnvironment,
                settingsBootstrap:
                    settingsBootstrap,
                agyExecutableStatus: .notFound,
                runtimeEnvironment: runtimeEnvironment,
                legacyAccountCleanup: {
                    _ =
                        AntigravityLegacyAccountCleanup
                        .production(homeDirectoryURL: homeDirectoryURL)
                        .run()
                }
            )

        return AntigravityProductRuntimeComposition(
            settingsStore: settingsStore,
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
