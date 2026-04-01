import Foundation

struct ServiceSelectionHelper {
    static let supportedPopoverServices: [PopoverService] = [.claude, .codex]
    static let supportedProviderKinds: [AppProviderKind] = [.claude, .codex]

    static func providerKind(for service: PopoverService) -> AppProviderKind {
        switch service {
        case .claude:
            return .claude
        case .codex:
            return .codex
        }
    }

    static func service(for kind: AppProviderKind) -> PopoverService? {
        switch kind {
        case .claude:
            return .claude
        case .codex:
            return .codex
        case .gemini, .antigravity:
            return nil
        }
    }

    static func preferredPopoverService(from rawValue: String) -> PopoverService {
        rawValue == "codex" ? .codex : .claude
    }

    static func preferredPopoverService(settings: AppSettings) -> PopoverService {
        preferredPopoverService(from: settings.activeMenuBarServiceRawValue)
    }

    static func enabledServices(settings: AppSettings) -> [PopoverService] {
        supportedPopoverServices.filter { isEnabled($0, settings: settings) }
    }

    static func enabledRuntimeProviderKinds(settings: AppSettings) -> [AppProviderKind] {
        supportedProviderKinds.filter { settings.isProviderEnabled($0) }
    }

    static func isEnabled(_ service: PopoverService, settings: AppSettings) -> Bool {
        settings.isProviderEnabled(providerKind(for: service))
    }

    static func hasAnyEnabledService(settings: AppSettings) -> Bool {
        !enabledRuntimeProviderKinds(settings: settings).isEmpty
    }

    static func hasMultipleEnabledServices(settings: AppSettings) -> Bool {
        enabledRuntimeProviderKinds(settings: settings).count > 1
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

    static func canRefreshClaude(settings: AppSettings, hasSessionKey: Bool) -> Bool {
        settings.isProviderEnabled(.claude) && hasSessionKey
    }

    static func canRefreshCodex(settings: AppSettings) -> Bool {
        settings.isProviderEnabled(.codex)
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
