import Foundation

nonisolated enum ProviderDisplaySurface:
    String,
    CaseIterable,
    Identifiable,
    Sendable
{
    case standard
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:
            "일반 보기"
        case .compact:
            "간소화 보기"
        }
    }

    var isCompact: Bool {
        self == .compact
    }

    var showsPersistentIdentityRail: Bool {
        self == .standard
    }
}

typealias PopoverDisplayEditorMode =
    ProviderDisplaySurface

nonisolated struct ProviderDisplayEditorItem:
    Identifiable,
    Equatable,
    Sendable
{
    let id: String
    let title: String
    let groupTitle: String?
    let isVisible: Bool
    let isAvailable: Bool
}

nonisolated struct ProviderDisplayEditorModel:
    Equatable,
    Sendable
{
    let surface: ProviderDisplaySurface
    let items: [ProviderDisplayEditorItem]
    let showsGroupHeadings: Bool
    let supportsReordering: Bool
}

nonisolated struct ProviderRuntimeSummary:
    Equatable,
    Sendable
{
    enum Tone: String, Equatable, Sendable {
        case secondary
        case warning
        case critical
    }

    enum Action: String, Equatable, Sendable {
        case openSettings
        case retry
        case startClaudeLogin
        case openDisplayEditor
    }

    let icon: String?
    let tone: Tone
    let showsProgress: Bool
    let title: String
    let message: String
    let actionTitle: String?
    let action: Action?
    let actionIsProminent: Bool
}
