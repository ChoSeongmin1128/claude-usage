import Foundation

enum MenuBarDesign: String, CaseIterable, Sendable {
    case classic
    case modern

    var title: String { self == .classic ? "클래식" : "새 디자인" }
}

enum WelcomeState: String, Sendable {
    case pending, deferred, completed
}

enum WelcomeStep: Int, CaseIterable, Sendable {
    case services, connection, appearance

    var title: String {
        switch self {
        case .services: return "서비스 선택"
        case .connection: return "연결 확인"
        case .appearance: return "메뉴바 설정"
        }
    }
}

/// Resolve before other settings stores normalize or write their defaults.
/// Only this app's persisted state counts; CLI installations and login failures do not.
struct AppExperiencePreferences {
    let design: MenuBarDesign
    let designIntroductionDismissed: Bool
    let welcomeState: WelcomeState
    let welcomeStep: WelcomeStep

    static func load(from defaults: UserDefaults, hasAccountStorage: Bool) -> Self {
        let storedDesign = defaults.string(forKey: "menuBarDesign").flatMap(MenuBarDesign.init(rawValue:))
        let legacyKeys = [
            "menuBarStyle", "percentageDisplay", "showPercentage", "popoverPinned", "popoverCompact",
            "claudePopoverPinned", "codexPopoverPinned", "refreshInterval", "claudeEnabled", "codexEnabled",
            "providerStateMigrationVersion", "popoverItemsV2", "hasCompletedSetupWizard", "settingsLastTab",
            "ClaudeUsage.claudeAccounts.v1", "ClaudeUsage.claudeAccountsMigrationVersion", "claude-session-key",
            "antigravityEnabled", "menuBarDesign", "welcomeState", "menuBarColorMode", "codexMenuBarStyle",
            "circularDisplayMode", "showClaudeIcon", "showCodexIcon", "showBatteryPercent", "timeFormat",
            "autoRefresh", "launchAtLogin", "notificationsEnabled", "SUHasLaunchedBefore", "motionPreferences",
            "popoverTransitionStyle",
        ]
        let existing = hasAccountStorage || legacyKeys.contains { defaults.object(forKey: $0) != nil }
        let result = Self(
            design: storedDesign ?? (existing ? .classic : .modern),
            designIntroductionDismissed: defaults.object(forKey: "menuBarDesignIntroductionDismissed") as? Bool
                ?? (!existing || storedDesign != nil),
            welcomeState: defaults.string(forKey: "welcomeState").flatMap(WelcomeState.init(rawValue:))
                ?? (existing ? .completed : .pending),
            welcomeStep: WelcomeStep(rawValue: defaults.integer(forKey: "welcomeStep")) ?? .services)
        defaults.set(result.design.rawValue, forKey: "menuBarDesign")
        defaults.set(result.designIntroductionDismissed, forKey: "menuBarDesignIntroductionDismissed")
        defaults.set(result.welcomeState.rawValue, forKey: "welcomeState")
        return result
    }

    static var hasLocalAccountStorage: Bool {
        FileManager.default.fileExists(
            atPath: AntigravityStoragePaths.canonicalStateDirectoryURL()
                .appendingPathComponent("accounts.json").path)
    }
}
