import Foundation

struct ServiceSelectionHelper {
    static let supportedProviderKinds: [AppProviderKind] = AppProviderKind.runtimeKinds
    static let supportedPopoverServices: [PopoverService] = RuntimeProviderRegistry.supportedServices

    nonisolated static func providerKind(for service: PopoverService) -> AppProviderKind {
        AppProviderKind(rawValue: service.rawValue) ?? .claude
    }

    nonisolated static func service(for kind: AppProviderKind) -> PopoverService? {
        kind.runtimeService
    }

    nonisolated static func preferredPopoverService(from rawValue: String) -> PopoverService {
        PopoverService(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .claude
    }

    static func preferredPopoverService(settings: AppSettings) -> PopoverService {
        preferredPopoverService(from: settings.activeMenuBarServiceRawValue)
    }

    static func enabledServices(settings: AppSettings) -> [PopoverService] {
        settings.providerSelectionState.runtimeEnabledKinds.compactMap(service(for:))
    }

    static func enabledRuntimeProviderKinds(settings: AppSettings) -> [AppProviderKind] {
        settings.providerSelectionState.runtimeEnabledKinds
    }

    static func isEnabled(_ service: PopoverService, settings: AppSettings) -> Bool {
        settings.isProviderEnabled(providerKind(for: service))
    }

    static func hasAnyEnabledService(settings: AppSettings) -> Bool {
        settings.providerSelectionState.runtimeEnabledKinds.isEmpty == false
    }

    static func hasMultipleEnabledServices(settings: AppSettings) -> Bool {
        settings.providerSelectionState.runtimeEnabledKinds.count > 1
    }

    static func resolvedPopoverService(settings: AppSettings) -> PopoverService {
        let selectionState = settings.providerSelectionState
        let runtimeKinds = selectionState.runtimeEnabledKinds
        guard !runtimeKinds.isEmpty else {
            return preferredPopoverService(settings: settings)
        }

        if runtimeKinds.count == 1, let service = service(for: runtimeKinds[0]) {
            return service
        }

        if let activeRuntime = selectionState.activeRuntimeKind, runtimeKinds.contains(activeRuntime), let service = service(for: activeRuntime) {
            return service
        }

        let preferredRuntime = preferredPopoverService(settings: settings)
        let preferredKind = providerKind(for: preferredRuntime)
        if runtimeKinds.contains(preferredKind) {
            return preferredRuntime
        }
        if let firstRuntime = runtimeKinds.first, let service = service(for: firstRuntime) {
            return service
        }

        return preferredPopoverService(settings: settings)
    }

    static func resolvedMenuBarService(settings: AppSettings) -> PopoverService? {
        let selectionState = settings.providerSelectionState
        let runtimeKinds = selectionState.runtimeEnabledKinds.filter { settings.isProviderVisibleInMenuBar($0) }
        guard !runtimeKinds.isEmpty else { return nil }

        let preferred = preferredPopoverService(from: settings.activeMenuBarServiceRawValue)
        let preferredKind = providerKind(for: preferred)
        if runtimeKinds.contains(preferredKind) {
            return preferred
        }

        if let activeRuntime = selectionState.activeRuntimeKind,
           runtimeKinds.contains(activeRuntime),
           let service = service(for: activeRuntime) {
            return service
        }

        return runtimeKinds.first.flatMap(service(for:))
    }

    static func setActivePopoverService(_ service: PopoverService, settings: AppSettings) {
        settings.setActiveProvider(providerKind(for: service))
    }

    static func isPinned(_ service: PopoverService, settings: AppSettings) -> Bool {
        settings.popoverPinned
    }

    static func canRefresh(
        _ service: PopoverService,
        selectionState: ProviderSelectionState,
        hasClaudeSessionKey: Bool,
        hasClaudeOAuthCredential: Bool,
        isCodexAuthenticated: Bool,
        geminiRuntimeReachability: Bool,
        antigravityRuntimeReachability: Bool,
        antigravityRefreshReachability: Bool? = nil
    ) -> Bool {
        guard selectionState.runtimeEnabledKinds.contains(providerKind(for: service)) else { return false }
        let context = RuntimeProviderRefreshContext(
            hasClaudeSessionKey: hasClaudeSessionKey,
            hasClaudeOAuthCredential: hasClaudeOAuthCredential,
            isCodexAuthenticated: isCodexAuthenticated,
            geminiRuntimeReachability: geminiRuntimeReachability,
            antigravityRuntimeReachability: antigravityRuntimeReachability,
            antigravityRefreshReachability: antigravityRefreshReachability ?? antigravityRuntimeReachability
        )
        guard let descriptor = RuntimeProviderRegistry.descriptor(for: service) else { return false }
        return descriptor.isRefreshable(using: context)
    }

    static func refreshableServices(
        selectionState: ProviderSelectionState,
        hasClaudeSessionKey: Bool,
        hasClaudeOAuthCredential: Bool,
        isCodexAuthenticated: Bool,
        geminiRuntimeReachability: Bool,
        antigravityRuntimeReachability: Bool,
        antigravityRefreshReachability: Bool? = nil
    ) -> [PopoverService] {
        selectionState.runtimeEnabledKinds.compactMap(service(for:)).filter {
            canRefresh(
                $0,
                selectionState: selectionState,
                hasClaudeSessionKey: hasClaudeSessionKey,
                hasClaudeOAuthCredential: hasClaudeOAuthCredential,
                isCodexAuthenticated: isCodexAuthenticated,
                geminiRuntimeReachability: geminiRuntimeReachability,
                antigravityRuntimeReachability: antigravityRuntimeReachability,
                antigravityRefreshReachability: antigravityRefreshReachability
            )
        }
    }

    static func refreshableServices(
        settings: AppSettings,
        hasClaudeSessionKey: Bool,
        hasClaudeOAuthCredential: Bool,
        isCodexAuthenticated: Bool,
        geminiRuntimeReachability: Bool,
        antigravityRuntimeReachability: Bool,
        antigravityRefreshReachability: Bool? = nil
    ) -> [PopoverService] {
        refreshableServices(
            selectionState: settings.providerSelectionState,
            hasClaudeSessionKey: hasClaudeSessionKey,
            hasClaudeOAuthCredential: hasClaudeOAuthCredential,
            isCodexAuthenticated: isCodexAuthenticated,
            geminiRuntimeReachability: geminiRuntimeReachability,
            antigravityRuntimeReachability: antigravityRuntimeReachability,
            antigravityRefreshReachability: antigravityRefreshReachability
        )
    }

    static func hasRefreshableService(
        selectionState: ProviderSelectionState,
        hasClaudeSessionKey: Bool,
        hasClaudeOAuthCredential: Bool,
        isCodexAuthenticated: Bool,
        geminiRuntimeReachability: Bool,
        antigravityRuntimeReachability: Bool,
        antigravityRefreshReachability: Bool? = nil
    ) -> Bool {
        !refreshableServices(
            selectionState: selectionState,
            hasClaudeSessionKey: hasClaudeSessionKey,
            hasClaudeOAuthCredential: hasClaudeOAuthCredential,
            isCodexAuthenticated: isCodexAuthenticated,
            geminiRuntimeReachability: geminiRuntimeReachability,
            antigravityRuntimeReachability: antigravityRuntimeReachability,
            antigravityRefreshReachability: antigravityRefreshReachability
        ).isEmpty
    }

    static func hasRefreshableService(
        settings: AppSettings,
        hasClaudeSessionKey: Bool,
        hasClaudeOAuthCredential: Bool,
        isCodexAuthenticated: Bool,
        geminiRuntimeReachability: Bool,
        antigravityRuntimeReachability: Bool,
        antigravityRefreshReachability: Bool? = nil
    ) -> Bool {
        hasRefreshableService(
            selectionState: settings.providerSelectionState,
            hasClaudeSessionKey: hasClaudeSessionKey,
            hasClaudeOAuthCredential: hasClaudeOAuthCredential,
            isCodexAuthenticated: isCodexAuthenticated,
            geminiRuntimeReachability: geminiRuntimeReachability,
            antigravityRuntimeReachability: antigravityRuntimeReachability,
            antigravityRefreshReachability: antigravityRefreshReachability
        )
    }

    static func settingsRootTab(for service: PopoverService) -> String {
        service.rawValue
    }
}
