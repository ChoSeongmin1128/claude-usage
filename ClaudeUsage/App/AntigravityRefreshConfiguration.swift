import Foundation

struct AntigravityRefreshConfiguration: Sendable, Equatable {
    let dataSource: AntigravityUsageDataSource
    let activeOAuthAccountID: String?
    let activeOAuthAccountUpdatedAtMilliseconds: Double?

    static func current(
        dataSource: AntigravityUsageDataSource = .auto,
        accountStore: AntigravityOAuthAccountStore = AntigravityOAuthAccountStore()
    ) -> AntigravityRefreshConfiguration {
        switch dataSource {
        case .localIDE, .agyCLI:
            return AntigravityRefreshConfiguration(
                dataSource: dataSource,
                activeOAuthAccountID: nil,
                activeOAuthAccountUpdatedAtMilliseconds: nil
            )
        case .auto, .googleOAuth:
            return make(dataSource: dataSource, activeAccount: accountStore.state().activeAccount)
        }
    }

    static func make(
        dataSource: AntigravityUsageDataSource,
        activeAccount: AntigravityOAuthAccount?
    ) -> AntigravityRefreshConfiguration {
        AntigravityRefreshConfiguration(
            dataSource: dataSource,
            activeOAuthAccountID: activeAccount?.id,
            activeOAuthAccountUpdatedAtMilliseconds: activeAccount?.updatedAtMilliseconds
        )
    }
}

enum AntigravitySetupPolicy {
    static func requiresInteractiveSetup(
        dataSource: AntigravityUsageDataSource,
        signals: AntigravityEnvironmentSignals
    ) -> Bool {
        switch dataSource {
        case .googleOAuth:
            return !signals.hasOAuthCredential && !signals.hasRuntimeConnection
        case .agyCLI:
            return !signals.hasCLIBinary
        case .localIDE:
            return !signals.hasRuntimeConnection && !signals.hasCredentialRelevant(to: dataSource)
        case .auto:
            return !signals.hasRuntimeConnection && !signals.hasCredentialRelevant(to: dataSource)
        }
    }
}
