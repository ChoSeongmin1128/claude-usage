import Foundation

enum SettingsProviderPanel: String, CaseIterable, Identifiable, Sendable {
    case common
    case claude
    case codex
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
    nonisolated static let providerDescriptors: [ProviderDescriptor] = AppProviderKind.allCases.map(\.descriptor)

    nonisolated static var sidebarPanels: [SettingsProviderPanelDescriptor] {
        sidebarPanels(exposurePolicy: .allSupported)
    }

    nonisolated static func sidebarPanels(exposurePolicy: ProviderExposurePolicy) -> [SettingsProviderPanelDescriptor] {
        let providerPanels = AppProviderKind.allCases
            .filter(exposurePolicy.isExposed)
            .map(providerPanelDescriptor)
        return [
            .init(panel: .common, title: "공통", icon: "slider.horizontal.3", providerKind: nil, availability: .active),
        ] + providerPanels
    }

    nonisolated static var providerShellDescriptors: [ProviderShellDescriptor] {
        providerDescriptors.map { providerShellDescriptor(for: $0.kind) }
    }

    nonisolated static func descriptor(for panel: SettingsProviderPanel) -> SettingsProviderPanelDescriptor {
        sidebarPanels.first { $0.panel == panel } ?? sidebarPanels[0]
    }

    nonisolated static func providerShellDescriptor(for kind: AppProviderKind) -> ProviderShellDescriptor {
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

    nonisolated static func providerPanelDescriptor(for kind: AppProviderKind) -> SettingsProviderPanelDescriptor {
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

    nonisolated private static func panel(for kind: AppProviderKind) -> SettingsProviderPanel {
        switch kind {
        case .claude:
            return .claude
        case .codex:
            return .codex
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
