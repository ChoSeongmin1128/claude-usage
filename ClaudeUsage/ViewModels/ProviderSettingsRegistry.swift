import Foundation

nonisolated enum SettingsProviderPanel: String, CaseIterable, Sendable {
    case welcome
    case common
    case display
    case updates
    case claude
    case codex
    case antigravity

    var providerKind: AppProviderKind? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .antigravity: .antigravity
        case .welcome, .common, .display, .updates: nil
        }
    }

    static func service(_ provider: AppProviderKind) -> Self {
        switch provider {
        case .claude: .claude
        case .codex: .codex
        case .antigravity: .antigravity
        }
    }

    /// 이전 패널 이름은 입력 경계에서만 현재 목적지로 해석한다.
    static func resolve(
        storedValue: String, fallbackProvider: AppProviderKind = .claude
    ) -> (panel: SettingsProviderPanel, provider: AppProviderKind?)? {
        if let panel = Self(rawValue: storedValue) { return (panel, panel.providerKind) }
        switch storedValue {
        case "accounts", "limits": return (.service(fallbackProvider), fallbackProvider)
        case "notifications": return (.common, nil)
        default: return nil
        }
    }
}

nonisolated enum SettingsSection: String, Hashable, Sendable {
    case connection
    case menuBar
    case limits
    case popover
}

nonisolated struct SettingsDestination: Equatable, Sendable {
    let panel: SettingsProviderPanel
    var section: SettingsSection? = nil
}

nonisolated struct SettingsProviderPanelDescriptor: Identifiable, Sendable, Equatable {
    let panel: SettingsProviderPanel
    let title: String
    let icon: String

    var id: SettingsProviderPanel { panel }
    var providerKind: AppProviderKind? { panel.providerKind }
}

enum SettingsProviderRegistry {
    nonisolated static let appPanels: [SettingsProviderPanelDescriptor] = [
        .init(panel: .common, title: "일반", icon: "gearshape"),
        .init(panel: .display, title: "표시", icon: "menubar.rectangle"),
        .init(panel: .updates, title: "업데이트", icon: "arrow.down.circle"),
    ]

    nonisolated static let servicePanels: [SettingsProviderPanelDescriptor] = [
        .init(panel: .claude, title: "Claude", icon: "person.crop.circle"),
        .init(panel: .codex, title: "Codex", icon: "person.crop.circle"),
        .init(panel: .antigravity, title: "Antigravity", icon: "person.crop.circle"),
    ]

}
