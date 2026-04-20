import Foundation

enum ProviderRuntimeAction {
    case refresh(service: PopoverService, force: Bool)
    case clearState(PopoverService)
    case clearAndPromptAuth(PopoverService)
}

enum RefreshOrchestration {
    static func actionForTabSwitch(
        state: RuntimeProviderPresentationState,
        refreshInterval: TimeInterval
    ) -> ProviderRuntimeAction? {
        guard ProviderTransitionPolicy.shouldRefreshOnTabSwitch(
            state: state,
            refreshInterval: refreshInterval
        ) else {
            return nil
        }

        return .refresh(service: state.service, force: false)
    }

    static func actionsForRefreshAll(
        supportedServices: [PopoverService],
        refreshableServices: [PopoverService],
        settings: AppSettings,
        force: Bool,
        lastRefreshedAt: [PopoverService: Date] = [:]
    ) -> [ProviderRuntimeAction] {
        let now = Date()
        return supportedServices.compactMap { service in
            if force,
               service.providerKind.isRuntimeProvider,
               ServiceSelectionHelper.isEnabled(service, settings: settings)
            {
                return .refresh(service: service, force: true)
            }

            guard refreshableServices.contains(service) else {
                return nil
            }

            if settings.usePerProviderRefreshIntervals,
               let lastRefresh = lastRefreshedAt[service] {
                let interval = settings.effectiveRefreshInterval(for: service)
                guard now.timeIntervalSince(lastRefresh) >= interval else {
                    return nil
                }
            }

            return .refresh(service: service, force: force)
        }
    }

    static func actionForEnabledChange(
        state: RuntimeProviderActivationState
    ) -> ProviderRuntimeAction {
        switch ProviderTransitionPolicy.enabledChangeDecision(
            state: state
        ) {
        case .refreshNow:
            return .refresh(service: state.service, force: true)
        case .clearAndPromptAuth:
            return .clearAndPromptAuth(state.service)
        case .clearStateOnly:
            return .clearState(state.service)
        }
    }
}
