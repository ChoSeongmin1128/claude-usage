import Foundation

struct ProviderCapabilities: Sendable, Equatable {
    let runtimeService: PopoverService?
    let refreshStrategy: RuntimeRefreshStrategy?
    let supportsBrowserImport: Bool
    let defaultEnabled: Bool

    nonisolated var supportsPopoverSelection: Bool {
        runtimeService != nil
    }

    nonisolated var isRuntimeProvider: Bool {
        runtimeService != nil
    }
}

struct ProviderDescriptor: Sendable, Equatable {
    let kind: AppProviderKind
    let displayName: String
    let settingsPanelTitle: String
    let settingsPanelIconName: String
    let brandAssetName: String?
    let settingsPanelSummary: String
    let settingsPanelDetail: String
    let settingsComingSoonMessage: String?
    let capabilities: ProviderCapabilities
}

enum AppProviderKind: String, Codable, CaseIterable, Sendable, Hashable {
    case claude
    case codex
    case gemini
    case antigravity

    nonisolated var descriptor: ProviderDescriptor {
        switch self {
        case .claude:
            return ProviderDescriptor(
                kind: self,
                displayName: "Claude",
                settingsPanelTitle: "Claude",
                settingsPanelIconName: "brain",
                brandAssetName: "ProviderClaudeIcon",
                settingsPanelSummary: "기본 서비스",
                settingsPanelDetail: "브라우저 로그인이나 Claude Code 로그인으로 연결할 수 있습니다.",
                settingsComingSoonMessage: nil,
                capabilities: ProviderCapabilities(
                    runtimeService: .claude,
                    refreshStrategy: .claude,
                    supportsBrowserImport: true,
                    defaultEnabled: true
                )
            )
        case .codex:
            return ProviderDescriptor(
                kind: self,
                displayName: "Codex",
                settingsPanelTitle: "Codex",
                settingsPanelIconName: "bubble.left.and.bubble.right",
                brandAssetName: "ProviderCodexIcon",
                settingsPanelSummary: "Codex 사용량",
                settingsPanelDetail: "터미널에서 codex login으로 로그인하면 메뉴바에서 바로 확인할 수 있습니다.",
                settingsComingSoonMessage: nil,
                capabilities: ProviderCapabilities(
                    runtimeService: .codex,
                    refreshStrategy: .codex,
                    supportsBrowserImport: false,
                    defaultEnabled: false
                )
            )
        case .gemini:
            return ProviderDescriptor(
                kind: self,
                displayName: "Gemini CLI",
                settingsPanelTitle: "Gemini CLI",
                settingsPanelIconName: "sparkles",
                brandAssetName: "ProviderGeminiIcon",
                settingsPanelSummary: "Gemini CLI 로그인",
                settingsPanelDetail: "Gemini CLI 로그인 상태로 사용량을 확인합니다.",
                settingsComingSoonMessage: nil,
                capabilities: ProviderCapabilities(
                    runtimeService: .gemini,
                    refreshStrategy: .gemini,
                    supportsBrowserImport: false,
                    defaultEnabled: false
                )
            )
        case .antigravity:
            return ProviderDescriptor(
                kind: self,
                displayName: "Antigravity",
                settingsPanelTitle: "Antigravity",
                settingsPanelIconName: "antenna.radiowaves.left.and.right",
                brandAssetName: "ProviderAntigravityIcon",
                settingsPanelSummary: "앱 연결",
                settingsPanelDetail: "Antigravity 앱이 열려 있으면 사용량을 확인합니다.",
                settingsComingSoonMessage: nil,
                capabilities: ProviderCapabilities(
                    runtimeService: .antigravity,
                    refreshStrategy: .antigravity,
                    supportsBrowserImport: false,
                    defaultEnabled: false
                )
            )
        }
    }

    nonisolated var displayName: String {
        descriptor.displayName
    }

    nonisolated var supportsMenuBarServiceSelection: Bool {
        descriptor.capabilities.supportsPopoverSelection
    }

    nonisolated var isRuntimeProvider: Bool {
        descriptor.capabilities.isRuntimeProvider
    }

    nonisolated var isShellProvider: Bool {
        !isRuntimeProvider
    }

    nonisolated var settingsPanelTitle: String {
        descriptor.settingsPanelTitle
    }

    nonisolated var settingsPanelIconName: String {
        descriptor.settingsPanelIconName
    }

    nonisolated var fallbackSystemSymbolName: String? {
        descriptor.settingsPanelIconName
    }

    nonisolated var brandAssetName: String? {
        descriptor.brandAssetName
    }

    nonisolated var settingsPanelSummary: String {
        descriptor.settingsPanelSummary
    }

    nonisolated var settingsPanelDetail: String {
        descriptor.settingsPanelDetail
    }

    nonisolated var settingsComingSoonMessage: String? {
        descriptor.settingsComingSoonMessage
    }

    nonisolated var runtimeService: PopoverService? {
        descriptor.capabilities.runtimeService
    }

    nonisolated var refreshStrategy: RuntimeRefreshStrategy? {
        descriptor.capabilities.refreshStrategy
    }

    nonisolated var supportsBrowserImport: Bool {
        descriptor.capabilities.supportsBrowserImport
    }

    nonisolated static var runtimeKinds: [AppProviderKind] {
        allCases.filter(\.isRuntimeProvider)
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

    static let defaultStates: [AppProviderKind: AppProviderState] = Dictionary(
        uniqueKeysWithValues: AppProviderKind.allCases.map { kind in
            let isEnabled = kind.descriptor.capabilities.defaultEnabled
            return (
                kind,
                AppProviderState(
                    isEnabled: isEnabled,
                    isActive: isEnabled && kind == .claude
                )
            )
        }
    )

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
