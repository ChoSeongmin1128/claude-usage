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
                return "Coming soon"
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
    static let sidebarPanels: [SettingsProviderPanelDescriptor] = [
        .init(panel: .common, title: "공통", icon: "slider.horizontal.3", availability: .active),
        .init(panel: .claude, title: "Claude", icon: "brain", availability: .active),
        .init(panel: .codex, title: "Codex", icon: "bubble.left.and.bubble.right", availability: .active),
        .init(
            panel: .gemini,
            title: "Gemini",
            icon: "sparkles",
            availability: .comingSoon(message: "Gemini 패널은 다음 단계에서 연결할 예정입니다.")
        ),
        .init(
            panel: .antigravity,
            title: "Antigravity",
            icon: "antenna.radiowaves.left.and.right",
            availability: .comingSoon(message: "Antigravity 패널은 Gemini와 별개 provider로 연결할 예정입니다.")
        ),
    ]

    static let providerShellDescriptors: [ProviderShellDescriptor] = [
        .init(
            kind: .claude,
            title: "Claude",
            icon: "brain",
            role: .active,
            summary: "메인 usage 경로",
            detail: "세션키와 OAuth를 함께 유지합니다.",
            supportsPopoverSelection: true
        ),
        .init(
            kind: .codex,
            title: "Codex",
            icon: "bubble.left.and.bubble.right",
            role: .active,
            summary: "CLI / OAuth",
            detail: "Codex는 별도 셸과 표시 규칙을 유지합니다.",
            supportsPopoverSelection: true
        ),
        .init(
            kind: .gemini,
            title: "Gemini",
            icon: "sparkles",
            role: .comingSoon,
            summary: "연결 준비 중",
            detail: "실동작 fetcher 없이 shell만 먼저 노출합니다.",
            supportsPopoverSelection: false
        ),
        .init(
            kind: .antigravity,
            title: "Antigravity",
            icon: "antenna.radiowaves.left.and.right",
            role: .comingSoon,
            summary: "연결 준비 중",
            detail: "Gemini와 별개 provider로 분리해서 다룹니다.",
            supportsPopoverSelection: false
        ),
    ]

    static func descriptor(for panel: SettingsProviderPanel) -> SettingsProviderPanelDescriptor {
        sidebarPanels.first { $0.panel == panel } ?? sidebarPanels[0]
    }

    static func providerShellDescriptor(for kind: AppProviderKind) -> ProviderShellDescriptor {
        providerShellDescriptors.first { $0.kind == kind } ?? providerShellDescriptors[0]
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
                return "Coming soon"
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
