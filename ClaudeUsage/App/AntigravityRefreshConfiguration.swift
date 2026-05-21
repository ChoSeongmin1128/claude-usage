import Foundation

struct AntigravityRefreshConfiguration: Sendable, Equatable {
    let dataSource: AntigravityUsageDataSource
    let activeOAuthAccountID: String?
    let activeOAuthAccountUpdatedAtMilliseconds: Double?

    static func current(
        dataSource: AntigravityUsageDataSource = AppSettings.shared.antigravityUsageDataSource,
        accountStore: AntigravityOAuthAccountStore = AntigravityOAuthAccountStore()
    ) -> AntigravityRefreshConfiguration {
        switch dataSource {
        case .localIDE:
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
