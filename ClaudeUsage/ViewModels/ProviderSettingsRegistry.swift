import Foundation

enum SettingsProviderPanel: String, CaseIterable, Identifiable, Sendable {
    case common
    case claude
    case codex
    case gemini
    case antigravity

    var id: String { rawValue }
}

struct SettingsProviderPanelDescriptor: Identifiable, Sendable, Equatable {
    enum Availability: Sendable, Equatable {
        case active
        case comingSoon(message: String)

        var badgeTitle: String? {
            switch self {
            case .active:
                return nil
            case .comingSoon:
                return "준비 중"
            }
        }

        var detailMessage: String? {
            switch self {
            case .active:
                return nil
            case .comingSoon(let message):
                return message
            }
        }
    }

    let panel: SettingsProviderPanel
    let title: String
    let icon: String
    let availability: Availability

    var id: String { panel.rawValue }
}

enum SettingsProviderRegistry {
    static var sidebarPanels: [SettingsProviderPanelDescriptor] {
        [
            .init(panel: .common, title: "공통", icon: "slider.horizontal.3", availability: .active),
            providerPanelDescriptor(for: .claude),
            providerPanelDescriptor(for: .codex),
            providerPanelDescriptor(for: .gemini),
            providerPanelDescriptor(for: .antigravity),
        ]
    }

    static var providerShellDescriptors: [ProviderShellDescriptor] {
        AppProviderKind.allCases.map { providerShellDescriptor(for: $0) }
    }

    static func descriptor(for panel: SettingsProviderPanel) -> SettingsProviderPanelDescriptor {
        sidebarPanels.first { $0.panel == panel } ?? sidebarPanels[0]
    }

    static func providerShellDescriptor(for kind: AppProviderKind) -> ProviderShellDescriptor {
        .init(
            kind: kind,
            title: kind.settingsPanelTitle,
            icon: kind.settingsPanelIconName,
            role: kind.isRuntimeProvider ? .active : .comingSoon,
            summary: kind.settingsPanelSummary,
            detail: kind.settingsPanelDetail,
            supportsPopoverSelection: kind.supportsMenuBarServiceSelection
        )
    }

    static func providerPanelDescriptor(for kind: AppProviderKind) -> SettingsProviderPanelDescriptor {
        let availability: SettingsProviderPanelDescriptor.Availability
        if let message = kind.settingsComingSoonMessage {
            availability = .comingSoon(message: message)
        } else {
            availability = .active
        }

        return .init(
            panel: panel(for: kind),
            title: kind.settingsPanelTitle,
            icon: kind.settingsPanelIconName,
            availability: availability
        )
    }

    private static func panel(for kind: AppProviderKind) -> SettingsProviderPanel {
        switch kind {
        case .claude:
            return .claude
        case .codex:
            return .codex
        case .gemini:
            return .gemini
        case .antigravity:
            return .antigravity
        }
    }
}

struct ProviderShellDescriptor: Identifiable, Sendable, Equatable {
    enum Role: Sendable, Equatable {
        case active
        case comingSoon

        var badgeTitle: String? {
            switch self {
            case .active:
                return nil
            case .comingSoon:
                return "준비 중"
            }
        }
    }

    let kind: AppProviderKind
    let title: String
    let icon: String
    let role: Role
    let summary: String
    let detail: String?
    let supportsPopoverSelection: Bool

    var id: String { kind.rawValue }
}
