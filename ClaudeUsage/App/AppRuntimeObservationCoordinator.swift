import Combine
import Foundation

@MainActor
final class AppRuntimeObservationCoordinator {
    private var cancellables = Set<AnyCancellable>()

    func bind(
        settings: AppSettings = .shared,
        onRefreshConfigurationChanged: @escaping (RuntimeRefreshConfiguration) -> Void,
        onUpdateConfigurationChanged: @escaping () -> Void,
        onMenuBarDisplayChanged: @escaping () -> Void,
        onProviderSelectionChanged: @escaping (ProviderSelectionState) -> Void,
        onClaudeCredentialContextChanged: @escaping () -> Void,
        onUsageDisplayModeChanged: @escaping () -> Void = {},
        onTimeFormatChanged: @escaping () -> Void = {}
    ) {
        cancelAll()

        settings.$autoRefresh
            .map(RuntimeRefreshConfiguration.init(autoRefresh:))
            .removeDuplicates()
            .dropFirst()
            .sink(receiveValue: onRefreshConfigurationChanged)
            .store(in: &cancellables)

        settings.$updateCheckInterval
            .map(\.normalizedForAutomaticChecks)
            .removeDuplicates()
            .dropFirst()
            .sink { _ in onUpdateConfigurationChanged() }
            .store(in: &cancellables)

        settings.menuBarDisplayChangePublisher
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { onMenuBarDisplayChanged() }
            .store(in: &cancellables)

        settings.$usageDisplayMode
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { _ in onUsageDisplayModeChanged() }
            .store(in: &cancellables)

        settings.$timeFormat
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { _ in onTimeFormatChanged() }
            .store(in: &cancellables)

        settings.$providerSelectionRevision
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { _ in onProviderSelectionChanged(settings.providerSelectionState) }
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
