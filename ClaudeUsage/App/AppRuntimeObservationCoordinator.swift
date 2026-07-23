import Combine
import Foundation

@MainActor
final class AppRuntimeObservationCoordinator {
    private var cancellables = Set<AnyCancellable>()

    func bind(
        onRefreshConfigurationChanged: @escaping () -> Void,
        onUpdateConfigurationChanged: @escaping () -> Void,
        onMenuBarDisplayChanged: @escaping () -> Void,
        onProviderSelectionChanged: @escaping (ProviderSelectionState) -> Void,
        onPowerStateChanged: @escaping () -> Void,
        onClaudeCredentialContextChanged: @escaping () -> Void
    ) {
        cancelAll()

        AppSettings.shared.$refreshInterval
            .dropFirst()
            .sink { _ in onRefreshConfigurationChanged() }
            .store(in: &cancellables)

        AppSettings.shared.$autoRefresh
            .dropFirst()
            .sink { _ in onRefreshConfigurationChanged() }
            .store(in: &cancellables)

        AppSettings.shared.$updateCheckInterval
            .dropFirst()
            .sink { _ in onUpdateConfigurationChanged() }
            .store(in: &cancellables)

        AppSettings.shared.menuBarDisplayChangePublisher
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { onMenuBarDisplayChanged() }
            .store(in: &cancellables)

        AppSettings.shared.$providerStates
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { _ in onProviderSelectionChanged(AppSettings.shared.providerSelectionState) }
            .store(in: &cancellables)

        AppSettings.shared.$additionalRuntimeProvidersEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { _ in onProviderSelectionChanged(AppSettings.shared.providerSelectionState) }
            .store(in: &cancellables)

        PowerMonitor.shared.$isOnBattery
            .dropFirst()
            .sink { _ in onPowerStateChanged() }
            .store(in: &cancellables)

        Publishers.Merge3(
            NotificationCenter.default.publisher(for: .claudeAccountDidChange),
            NotificationCenter.default.publisher(for: .claudeSessionKeyDidChange),
            NotificationCenter.default.publisher(for: .claudeCredentialRefreshRequested)
        )
            .filter { notification in
                guard notification.name == .claudeSessionKeyDidChange,
                      let changedAccountID = notification.object as? String else {
                    return true
                }
                return ClaudeAccountStore.shared.state().activeAccountID == changedAccountID
            }
            .debounce(for: .milliseconds(40), scheduler: RunLoop.main)
            .receive(on: RunLoop.main)
            .sink { _ in onClaudeCredentialContextChanged() }
            .store(in: &cancellables)
    }

    func cancelAll() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }
}
