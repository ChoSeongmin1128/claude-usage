import Foundation

enum ProviderRuntimeAction {
    case refresh(service: PopoverService, force: Bool, markSetupComplete: Bool)
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

        return .refresh(service: state.service, force: false, markSetupComplete: false)
    }

    static func actionsForRefreshAll(
        supportedServices: [PopoverService],
        refreshableServices: [PopoverService],
        settings: AppSettings,
        force: Bool
    ) -> [ProviderRuntimeAction] {
        supportedServices.compactMap { service in
            if refreshableServices.contains(service) {
                return .refresh(service: service, force: force, markSetupComplete: false)
            }

            if ServiceSelectionHelper.isEnabled(service, settings: settings) {
                return .clearState(service)
            }

            return nil
        }
    }

    static func actionForEnabledChange(
        state: RuntimeProviderActivationState
    ) -> ProviderRuntimeAction {
        switch ProviderTransitionPolicy.enabledChangeDecision(
            state: state
        ) {
        case .refreshNow:
            return .refresh(
                service: state.service,
                force: true,
                markSetupComplete: state.shouldMarkSetupCompleteOnRefresh
            )
        case .clearAndPromptAuth:
            return .clearAndPromptAuth(state.service)
        case .clearStateOnly:
            return .clearState(state.service)
        }
    }
}
