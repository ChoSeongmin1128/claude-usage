import Foundation

struct ServiceSelectionHelper {
    static let supportedProviderKinds: [AppProviderKind] = AppProviderKind.runtimeKinds
    static let supportedPopoverServices: [PopoverService] = supportedProviderKinds.compactMap(service(for:))

    nonisolated static func providerKind(for service: PopoverService) -> AppProviderKind {
        switch service {
        case .claude:
            return .claude
        case .codex:
            return .codex
        }
    }

    nonisolated static func service(for kind: AppProviderKind) -> PopoverService? {
        switch kind {
        case .claude:
            return .claude
        case .codex:
            return .codex
        case .gemini, .antigravity:
            return nil
        }
    }

    nonisolated static func preferredPopoverService(from rawValue: String) -> PopoverService {
        rawValue == "codex" ? .codex : .claude
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
        let runtimeKinds = selectionState.runtimeEnabledKinds
        guard !runtimeKinds.isEmpty else { return nil }

        let preferred = resolvedPopoverService(settings: settings)
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
        switch service {
        case .claude:
            return settings.claudePopoverPinned
        case .codex:
            return settings.codexPopoverPinned
        }
    }

    static func canRefreshClaude(
        selectionState: ProviderSelectionState,
        hasSessionKey: Bool,
        hasOAuthCredential: Bool
    ) -> Bool {
        selectionState.runtimeEnabledKinds.contains(.claude) && (hasSessionKey || hasOAuthCredential)
    }

    static func canRefreshCodex(selectionState: ProviderSelectionState, isCodexAuthenticated: Bool) -> Bool {
        selectionState.runtimeEnabledKinds.contains(.codex) && isCodexAuthenticated
    }

    static func canRefresh(
        _ service: PopoverService,
        selectionState: ProviderSelectionState,
        hasClaudeSessionKey: Bool,
        hasClaudeOAuthCredential: Bool,
        isCodexAuthenticated: Bool
    ) -> Bool {
        switch service {
        case .claude:
            return canRefreshClaude(
                selectionState: selectionState,
                hasSessionKey: hasClaudeSessionKey,
                hasOAuthCredential: hasClaudeOAuthCredential
            )
        case .codex:
            return canRefreshCodex(
                selectionState: selectionState,
                isCodexAuthenticated: isCodexAuthenticated
            )
        }
    }

    static func refreshableServices(
        selectionState: ProviderSelectionState,
        hasClaudeSessionKey: Bool,
        hasClaudeOAuthCredential: Bool,
        isCodexAuthenticated: Bool
    ) -> [PopoverService] {
        selectionState.runtimeEnabledKinds.compactMap(service(for:)).filter {
            canRefresh(
                $0,
                selectionState: selectionState,
                hasClaudeSessionKey: hasClaudeSessionKey,
                hasClaudeOAuthCredential: hasClaudeOAuthCredential,
                isCodexAuthenticated: isCodexAuthenticated
            )
        }
    }

    static func refreshableServices(
        settings: AppSettings,
        hasClaudeSessionKey: Bool,
        hasClaudeOAuthCredential: Bool,
        isCodexAuthenticated: Bool
    ) -> [PopoverService] {
        refreshableServices(
            selectionState: settings.providerSelectionState,
            hasClaudeSessionKey: hasClaudeSessionKey,
            hasClaudeOAuthCredential: hasClaudeOAuthCredential,
            isCodexAuthenticated: isCodexAuthenticated
        )
    }

    static func hasRefreshableService(
        selectionState: ProviderSelectionState,
        hasClaudeSessionKey: Bool,
        hasClaudeOAuthCredential: Bool,
        isCodexAuthenticated: Bool
    ) -> Bool {
        !refreshableServices(
            selectionState: selectionState,
            hasClaudeSessionKey: hasClaudeSessionKey,
            hasClaudeOAuthCredential: hasClaudeOAuthCredential,
            isCodexAuthenticated: isCodexAuthenticated
        ).isEmpty
    }

    static func hasRefreshableService(
        settings: AppSettings,
        hasClaudeSessionKey: Bool,
        hasClaudeOAuthCredential: Bool,
        isCodexAuthenticated: Bool
    ) -> Bool {
        !hasRefreshableService(
            selectionState: settings.providerSelectionState,
            hasClaudeSessionKey: hasClaudeSessionKey,
            hasClaudeOAuthCredential: hasClaudeOAuthCredential,
            isCodexAuthenticated: isCodexAuthenticated
        )
    }

    static func settingsRootTab(for service: PopoverService) -> String {
        switch service {
        case .claude:
            return "claude"
        case .codex:
            return "codex"
        }
    }

    static func settingsAuthTab() -> String {
        "auth"
    }
}
