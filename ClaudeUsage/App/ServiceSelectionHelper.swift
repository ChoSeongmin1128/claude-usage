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
        settings.runtimeEnabledProviderKinds.compactMap(service(for:))
    }

    static func enabledRuntimeProviderKinds(settings: AppSettings) -> [AppProviderKind] {
        settings.runtimeEnabledProviderKinds
    }

    static func isEnabled(_ service: PopoverService, settings: AppSettings) -> Bool {
        settings.isProviderEnabled(providerKind(for: service))
    }

    static func hasAnyEnabledService(settings: AppSettings) -> Bool {
        settings.hasAnyRuntimeEnabledProvider
    }

    static func hasMultipleEnabledServices(settings: AppSettings) -> Bool {
        settings.hasMultipleRuntimeEnabledProviders
    }

    static func resolvedPopoverService(settings: AppSettings) -> PopoverService {
        let preferred = preferredPopoverService(settings: settings)
        let claudeEnabled = settings.isProviderEnabled(.claude)
        let codexEnabled = settings.isProviderEnabled(.codex)

        switch (claudeEnabled, codexEnabled) {
        case (true, true):
            return preferred
        case (true, false):
            return .claude
        case (false, true):
            return .codex
        case (false, false):
            return preferred
        }
    }

    static func resolvedMenuBarService(settings: AppSettings) -> PopoverService? {
        let preferred = resolvedPopoverService(settings: settings)
        let claudeEnabled = settings.isProviderEnabled(.claude)
        let codexEnabled = settings.isProviderEnabled(.codex)

        switch preferred {
        case .claude:
            if claudeEnabled { return .claude }
            if codexEnabled { return .codex }
        case .codex:
            if codexEnabled { return .codex }
            if claudeEnabled { return .claude }
        }
        return nil
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
        settings: AppSettings,
        hasSessionKey: Bool,
        hasOAuthCredential: Bool
    ) -> Bool {
        settings.isProviderEnabled(.claude) && (hasSessionKey || hasOAuthCredential)
    }

    static func canRefreshCodex(settings: AppSettings) -> Bool {
        settings.isProviderEnabled(.codex)
    }

    static func canRefresh(
        _ service: PopoverService,
        settings: AppSettings,
        hasClaudeSessionKey: Bool,
        hasClaudeOAuthCredential: Bool,
        isCodexAuthenticated: Bool
    ) -> Bool {
        switch service {
        case .claude:
            return canRefreshClaude(
                settings: settings,
                hasSessionKey: hasClaudeSessionKey,
                hasOAuthCredential: hasClaudeOAuthCredential
            )
        case .codex:
            return canRefreshCodex(settings: settings) && isCodexAuthenticated
        }
    }

    static func refreshableServices(
        settings: AppSettings,
        hasClaudeSessionKey: Bool,
        hasClaudeOAuthCredential: Bool,
        isCodexAuthenticated: Bool
    ) -> [PopoverService] {
        supportedPopoverServices.filter {
            canRefresh(
                $0,
                settings: settings,
                hasClaudeSessionKey: hasClaudeSessionKey,
                hasClaudeOAuthCredential: hasClaudeOAuthCredential,
                isCodexAuthenticated: isCodexAuthenticated
            )
        }
    }

    static func hasRefreshableService(
        settings: AppSettings,
        hasClaudeSessionKey: Bool,
        hasClaudeOAuthCredential: Bool,
        isCodexAuthenticated: Bool
    ) -> Bool {
        !refreshableServices(
            settings: settings,
            hasClaudeSessionKey: hasClaudeSessionKey,
            hasClaudeOAuthCredential: hasClaudeOAuthCredential,
            isCodexAuthenticated: isCodexAuthenticated
        ).isEmpty
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
