import Foundation

enum ProviderRuntimeAction {
    case refresh(service: PopoverService, force: Bool, markSetupComplete: Bool)
    case clearState(PopoverService)
    case clearAndPromptAuth(PopoverService)
}

enum RefreshOrchestration {
    static func actionForTabSwitch(
        service: PopoverService,
        refreshInterval: TimeInterval,
        claudeLastUpdated: Date?,
        codexLastUpdated: Date?,
        hasClaudeUsage: Bool,
        hasCodexUsage: Bool,
        claudeError: APIError?,
        codexError: APIError?
    ) -> ProviderRuntimeAction? {
        guard ProviderTransitionPolicy.shouldRefreshOnTabSwitch(
            service: service,
            refreshInterval: refreshInterval,
            claudeLastUpdated: claudeLastUpdated,
            codexLastUpdated: codexLastUpdated,
            hasClaudeUsage: hasClaudeUsage,
            hasCodexUsage: hasCodexUsage,
            claudeError: claudeError,
            codexError: codexError
        ) else {
            return nil
        }

        return .refresh(service: service, force: false, markSetupComplete: false)
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
        service: PopoverService,
        enabled: Bool,
        hasClaudeSessionKey: Bool,
        isCodexAuthenticated: Bool
    ) -> ProviderRuntimeAction {
        switch ProviderTransitionPolicy.enabledChangeDecision(
            service: service,
            enabled: enabled,
            hasClaudeSessionKey: hasClaudeSessionKey,
            isCodexAuthenticated: isCodexAuthenticated
        ) {
        case .refreshNow:
            return .refresh(
                service: service,
                force: true,
                markSetupComplete: service == .claude
            )
        case .clearAndPromptAuth:
            return .clearAndPromptAuth(service)
        case .clearStateOnly:
            return .clearState(service)
        }
    }
}
