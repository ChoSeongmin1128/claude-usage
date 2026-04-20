import Foundation

enum ProviderSettingsTab: String, CaseIterable, Identifiable, Sendable {
    case overview

    var id: String { rawValue }

    var title: String { "개요" }

    static func normalized(rawValue: String?, for kind: AppProviderKind) -> Self {
        let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case Self.overview.rawValue:
            return .overview
        case "auth", "status", "organizations":
            return .overview
        case "display", "popover":
            return .overview
        case "alerts":
            return .overview
        case "advanced":
            return .overview
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
            return [.overview]
        }
    }
}
