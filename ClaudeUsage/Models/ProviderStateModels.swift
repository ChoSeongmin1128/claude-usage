import Foundation

enum AppProviderKind: String, Codable, CaseIterable, Sendable, Hashable {
    case claude
    case codex
    case gemini
    case antigravity

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .antigravity: return "Antigravity"
        }
    }

    var supportsMenuBarServiceSelection: Bool {
        switch self {
        case .claude, .codex:
            return true
        case .gemini, .antigravity:
            return false
        }
    }
}

struct AppProviderState: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var isActive: Bool

    init(isEnabled: Bool = false, isActive: Bool = false) {
        self.isEnabled = isEnabled
        self.isActive = isActive
    }
}

struct AppProviderStateCatalog: Codable, Equatable, Sendable {
    var states: [AppProviderKind: AppProviderState]

    static let defaultStates: [AppProviderKind: AppProviderState] = [
        .claude: .init(isEnabled: true, isActive: true),
        .codex: .init(isEnabled: false, isActive: false),
        .gemini: .init(isEnabled: false, isActive: false),
        .antigravity: .init(isEnabled: false, isActive: false),
    ]

    init(states: [AppProviderKind: AppProviderState] = Self.defaultStates) {
        self.states = Self.normalized(states)
    }

    subscript(kind: AppProviderKind) -> AppProviderState {
        get { self.states[kind] ?? Self.defaultStates[kind] ?? .init() }
        set { self.states[kind] = newValue }
    }

    var enabledProviderKinds: [AppProviderKind] {
        AppProviderKind.allCases.filter { self[$0].isEnabled }
    }

    var activeProviderKind: AppProviderKind? {
        AppProviderKind.allCases.first { self[$0].isActive }
    }

    func state(for kind: AppProviderKind) -> AppProviderState {
        self[kind]
    }

    mutating func setEnabled(_ enabled: Bool, for kind: AppProviderKind) {
        var state = self[kind]
        state.isEnabled = enabled
        self[kind] = state
    }

    mutating func setActiveProvider(_ kind: AppProviderKind?) {
        for provider in AppProviderKind.allCases {
            var state = self[provider]
            state.isActive = provider == kind
            self[provider] = state
        }
    }

    func legacyMenuBarActiveService(fallback: String = "claude") -> String {
        guard let active = self.activeProviderKind else { return fallback }
        guard active.supportsMenuBarServiceSelection else { return fallback }
        return active.rawValue
    }

    static func fromLegacy(
        claudeEnabled: Bool,
        codexEnabled: Bool,
        activeService: String
    ) -> Self {
        var catalog = Self.defaultCatalog
        catalog.setEnabled(claudeEnabled, for: .claude)
        catalog.setEnabled(codexEnabled, for: .codex)
        catalog.setActiveProvider(Self.kind(from: activeService) ?? .claude)
        return catalog
    }

    static var defaultCatalog: Self {
        Self(states: Self.defaultStates)
    }

    private static func normalized(_ states: [AppProviderKind: AppProviderState]) -> [AppProviderKind: AppProviderState] {
        var normalized = Self.defaultStates
        for (kind, state) in states {
            normalized[kind] = state
        }
        return normalized
    }

    private static func kind(from rawValue: String) -> AppProviderKind? {
        AppProviderKind(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

struct ProviderSelectionState: Equatable, Sendable {
    let enabledKinds: [AppProviderKind]
    let activeKind: AppProviderKind?
}

struct ProviderMenuBarDisplayConfig: Equatable, Sendable {
    let kind: AppProviderKind
    let showIcon: Bool
    let style: MenuBarStyle
    let percentageDisplay: PercentageDisplay
    let showBatteryPercent: Bool
    let resetTimeDisplay: ResetTimeDisplay
    let timeFormat: TimeFormatStyle
    let circularDisplayMode: CircularDisplayMode
    let iconMetric: IconMetric
}
