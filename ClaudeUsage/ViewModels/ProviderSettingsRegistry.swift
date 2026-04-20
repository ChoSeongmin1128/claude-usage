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
    let providerKind: AppProviderKind?
    let availability: Availability

    var id: String { panel.rawValue }
}

enum SettingsProviderRegistry {
    static let providerDescriptors: [ProviderDescriptor] = AppProviderKind.allCases.map(\.descriptor)

    static var sidebarPanels: [SettingsProviderPanelDescriptor] {
        [
            .init(panel: .common, title: "공통", icon: "slider.horizontal.3", providerKind: nil, availability: .active),
            providerPanelDescriptor(for: .claude),
            providerPanelDescriptor(for: .codex),
            providerPanelDescriptor(for: .gemini),
            providerPanelDescriptor(for: .antigravity),
        ]
    }

    static var providerShellDescriptors: [ProviderShellDescriptor] {
        providerDescriptors.map { providerShellDescriptor(for: $0.kind) }
    }

    static func descriptor(for panel: SettingsProviderPanel) -> SettingsProviderPanelDescriptor {
        sidebarPanels.first { $0.panel == panel } ?? sidebarPanels[0]
    }

    static func providerShellDescriptor(for kind: AppProviderKind) -> ProviderShellDescriptor {
        let providerDescriptor = kind.descriptor
        return ProviderShellDescriptor(
            kind: kind,
            title: providerDescriptor.settingsPanelTitle,
            icon: providerDescriptor.settingsPanelIconName,
            role: providerDescriptor.capabilities.isRuntimeProvider ? .active : .comingSoon,
            summary: providerDescriptor.settingsPanelSummary,
            detail: providerDescriptor.settingsPanelDetail,
            supportsPopoverSelection: providerDescriptor.capabilities.supportsPopoverSelection
        )
    }

    static func providerPanelDescriptor(for kind: AppProviderKind) -> SettingsProviderPanelDescriptor {
        let providerDescriptor = kind.descriptor
        let availability: SettingsProviderPanelDescriptor.Availability
        if let message = providerDescriptor.settingsComingSoonMessage {
            availability = .comingSoon(message: message)
        } else {
            availability = .active
        }

        return .init(
            panel: panel(for: kind),
            title: providerDescriptor.settingsPanelTitle,
            icon: providerDescriptor.settingsPanelIconName,
            providerKind: kind,
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
