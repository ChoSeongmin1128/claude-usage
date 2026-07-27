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

enum ProviderExposureGroup: Sendable {
    case primary
    case additionalRuntime
}

enum AppProviderKind: String, Codable, CaseIterable, Sendable, Hashable {
    case claude
    case codex
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
        case .antigravity:
            return ProviderDescriptor(
                kind: self,
                displayName: "Antigravity",
                settingsPanelTitle: "Antigravity",
                settingsPanelIconName: "antenna.radiowaves.left.and.right",
                brandAssetName: "ProviderAntigravityIcon",
                settingsPanelSummary: "계정 및 model quota",
                settingsPanelDetail: "Antigravity 계정과 model quota 상태를 확인합니다.",
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

    nonisolated var exposureGroup: ProviderExposureGroup {
        switch self {
        case .claude:
            return .primary
        case .codex, .antigravity:
            return .additionalRuntime
        }
    }

    nonisolated var requiresAdditionalProviderOptIn: Bool {
        switch exposureGroup {
        case .primary:
            return false
        case .additionalRuntime:
            return true
        }
    }

    nonisolated static var runtimeKinds: [AppProviderKind] {
        allCases.filter(\.isRuntimeProvider)
    }

    nonisolated static var shellKinds: [AppProviderKind] {
        allCases.filter(\.isShellProvider)
    }

    nonisolated static var additionalRuntimeKinds: [AppProviderKind] {
        runtimeKinds.filter(\.requiresAdditionalProviderOptIn)
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

    private enum CodingKeys: String, CodingKey {
        case states
    }

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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawStates = try container.decode([String: AppProviderState].self, forKey: .states)
        let decodedStates = Dictionary(
            uniqueKeysWithValues: rawStates.compactMap { rawValue, state in
                AppProviderKind(rawValue: rawValue).map { ($0, state) }
            }
        )
        self.init(states: decodedStates)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let rawStates = Dictionary(
            uniqueKeysWithValues: states.map { kind, state in
                (kind.rawValue, state)
            }
        )
        try container.encode(rawStates, forKey: .states)
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
    let exposedKinds: [AppProviderKind]
    let exposedRuntimeKinds: [AppProviderKind]
    let enabledKinds: [AppProviderKind]
    let runtimeEnabledKinds: [AppProviderKind]
    let shellEnabledKinds: [AppProviderKind]
    let activeKind: AppProviderKind?
    let activeRuntimeKind: AppProviderKind?
}

struct ProviderExposurePolicy: Equatable, Sendable {
    let additionalRuntimeProvidersEnabled: Bool

    nonisolated static let primaryOnly = ProviderExposurePolicy(additionalRuntimeProvidersEnabled: false)
    nonisolated static let allSupported = ProviderExposurePolicy(additionalRuntimeProvidersEnabled: true)

    nonisolated func isExposed(_ kind: AppProviderKind) -> Bool {
        !kind.requiresAdditionalProviderOptIn || additionalRuntimeProvidersEnabled
    }

    nonisolated var exposedKinds: [AppProviderKind] {
        AppProviderKind.allCases.filter(isExposed)
    }

    nonisolated var exposedRuntimeKinds: [AppProviderKind] {
        AppProviderKind.runtimeKinds.filter(isExposed)
    }
}

/// 메뉴바 게이지(퍼센트 텍스트·아이콘 fill) 색상 정책.
/// HIG는 메뉴바 아이템에 모노크롬을 권장하지만, 사용량 앱 특성상 상태색이 유용해
/// 사용자가 직접 고르게 한다.
enum MenuBarColorMode: String, CaseIterable, Identifiable, Sendable, Equatable {
    /// 현행: 항상 사용률 임계값 색상 (초록/노랑/주황/빨강)
    case always
    /// 하이브리드: 평소 모노크롬, 주의 구간(75% 이상)부터만 색상
    case warningOnly
    /// 항상 시스템 텍스트색 (가장 네이티브)
    case monochrome

    nonisolated var id: String { rawValue }

    /// warningOnly 모드에서 색상이 켜지는 사용률 (주황 시작점과 동일)
    nonisolated static let warningThreshold: Double = 75

    nonisolated var displayName: String {
        switch self {
        case .always: return "항상 색상"
        case .warningOnly: return "주의 구간만 색상"
        case .monochrome: return "모노크롬"
        }
    }

    nonisolated var detail: String {
        switch self {
        case .always: return "사용률에 따라 초록/노랑/주황/빨강으로 표시합니다."
        case .warningOnly: return "평소에는 시스템 텍스트색, 75% 이상부터 색상으로 강조합니다."
        case .monochrome: return "항상 시스템 텍스트색으로 표시합니다. 메뉴바가 가장 차분해집니다."
        }
    }
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
    let colorMode: MenuBarColorMode

    init(
        kind: AppProviderKind,
        showIcon: Bool,
        style: MenuBarStyle,
        percentageDisplay: PercentageDisplay,
        showBatteryPercent: Bool,
        resetTimeDisplay: ResetTimeDisplay,
        timeFormat: TimeFormatStyle,
        circularDisplayMode: CircularDisplayMode,
        iconMetric: IconMetric,
        colorMode: MenuBarColorMode = .always
    ) {
        self.kind = kind
        self.showIcon = showIcon
        self.style = style
        self.percentageDisplay = percentageDisplay
        self.showBatteryPercent = showBatteryPercent
        self.resetTimeDisplay = resetTimeDisplay
        self.timeFormat = timeFormat
        self.circularDisplayMode = circularDisplayMode
        self.iconMetric = iconMetric
        self.colorMode = colorMode
    }
}

enum ProviderMenuBarDisplayPreset: String, CaseIterable, Identifiable, Sendable, Equatable {
    case basic
    case battery
    case dual
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .basic:
            return "기본"
        case .battery:
            return "배터리"
        case .dual:
            return "두 한도"
        case .custom:
            return "직접 설정"
        }
    }

    var detail: String {
        switch self {
        case .basic:
            return "아이콘과 현재 사용률만 표시합니다."
        case .battery:
            return "아이콘과 배터리 형태로 남은 사용량을 표시합니다."
        case .dual:
            return "현재 한도와 보조 한도를 함께 표시합니다."
        case .custom:
            return "표시 항목을 직접 조정합니다."
        }
    }

    static func resolved(for config: ProviderMenuBarDisplayConfig) -> Self {
        if config.showIcon,
           config.style == .none,
           config.percentageDisplay == .fiveHour,
           config.resetTimeDisplay == .none {
            return .basic
        }

        if config.showIcon,
           config.style == .batteryBar,
           config.percentageDisplay == .none,
           config.resetTimeDisplay == .none,
           config.showBatteryPercent,
           config.iconMetric == .fiveHour,
           config.circularDisplayMode == .remaining {
            return .battery
        }

        if config.showIcon,
           config.style == .none,
           config.percentageDisplay == .dual,
           config.resetTimeDisplay == .none {
            return .dual
        }

        return .custom
    }
}
