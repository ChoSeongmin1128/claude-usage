import Foundation

enum ProviderSettingsTab: String, CaseIterable, Identifiable, Sendable {
    case overview
    case display
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            return "개요"
        case .display:
            return "표시"
        case .advanced:
            return "문제 해결"
        }
    }

    static func normalized(rawValue: String?, for kind: AppProviderKind) -> Self {
        let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let normalized, let tab = Self(rawValue: normalized), tabs(for: kind).contains(tab) {
            return tab
        }

        switch normalized {
        case "auth", "status", "organizations":
            return .overview
        case "display", "popover":
            return .display
        case "alerts":
            return .overview
        case "advanced":
            return .advanced
        default:
            switch kind {
            case .claude, .codex, .gemini, .antigravity:
                return .overview
            }
        }
    }

    static func tabs(for kind: AppProviderKind) -> [Self] {
        switch kind {
        case .claude, .codex, .gemini, .antigravity:
            return [.overview, .display, .advanced]
        }
    }
}
