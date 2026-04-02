import Foundation

enum AppProviderKind: String, Codable, CaseIterable, Sendable, Hashable {
    case claude
    case codex
    case gemini
    case antigravity

    nonisolated var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .antigravity: return "Antigravity"
        }
    }

    nonisolated var supportsMenuBarServiceSelection: Bool {
        runtimeService != nil
    }

    nonisolated var isRuntimeProvider: Bool {
        supportsMenuBarServiceSelection
    }

    nonisolated var isShellProvider: Bool {
        !isRuntimeProvider
    }

    nonisolated var settingsPanelTitle: String {
        displayName
    }

    nonisolated var settingsPanelIconName: String {
        switch self {
        case .claude:
            return "brain"
        case .codex:
            return "bubble.left.and.bubble.right"
        case .gemini:
            return "sparkles"
        case .antigravity:
            return "antenna.radiowaves.left.and.right"
        }
    }

    nonisolated var settingsPanelSummary: String {
        switch self {
        case .claude:
            return "메인 usage 경로"
        case .codex:
            return "CLI / OAuth"
        case .gemini, .antigravity:
            return "런타임 연결 준비 중"
        }
    }

    nonisolated var settingsPanelDetail: String {
        switch self {
        case .claude:
            return "세션키와 OAuth를 함께 유지합니다."
        case .codex:
            return "Codex는 별도 셸과 표시 규칙을 유지합니다."
        case .gemini:
            return "설정과 표시 구조를 먼저 정리하고, 다음 단계에서 fetch/auth를 연결합니다."
        case .antigravity:
            return "Gemini와 별개 provider로 유지하면서, 별도 runtime fetch/auth를 연결합니다."
        }
    }

    nonisolated var settingsComingSoonMessage: String? {
        switch self {
        case .claude, .codex:
            return nil
        case .gemini:
            return "Gemini는 설정 패널과 표시 경로를 먼저 열어두고, runtime 연결을 이어서 붙입니다."
        case .antigravity:
            return "Antigravity는 Gemini와 별개 provider로 유지하면서 runtime 연결을 이어서 붙입니다."
        }
    }

    nonisolated var runtimeService: PopoverService? {
        PopoverService(rawValue: rawValue)
    }

    nonisolated static var runtimeKinds: [AppProviderKind] {
        allCases.filter { $0.runtimeService != nil }
    }

    nonisolated static var shellKinds: [AppProviderKind] {
        allCases.filter(\.isShellProvider)
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

    var enabledRuntimeProviderKinds: [AppProviderKind] {
        AppProviderKind.runtimeKinds.filter { self[$0].isEnabled }
    }

    var enabledShellProviderKinds: [AppProviderKind] {
        AppProviderKind.shellKinds.filter { self[$0].isEnabled }
    }

    var activeProviderKind: AppProviderKind? {
        AppProviderKind.allCases.first { self[$0].isActive }
    }

    var activeRuntimeProviderKind: AppProviderKind? {
        AppProviderKind.runtimeKinds.first { self[$0].isActive }
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
    let runtimeEnabledKinds: [AppProviderKind]
    let shellEnabledKinds: [AppProviderKind]
    let activeKind: AppProviderKind?
    let activeRuntimeKind: AppProviderKind?
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
