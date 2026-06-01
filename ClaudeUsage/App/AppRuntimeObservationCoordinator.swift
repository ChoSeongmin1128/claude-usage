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
        onClaudeSessionKeyChanged: @escaping () -> Void
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

        NotificationCenter.default.publisher(for: .claudeSessionKeyDidChange)
            .receive(on: RunLoop.main)
            .sink { _ in onClaudeSessionKeyChanged() }
            .store(in: &cancellables)
    }

    func cancelAll() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }
}
