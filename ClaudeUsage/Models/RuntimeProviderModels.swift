import Foundation

enum PopoverService: String, CaseIterable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        }
    }

    var providerKind: AppProviderKind {
        AppProviderKind(rawValue: rawValue) ?? .claude
    }

    init?(kind: AppProviderKind) {
        self.init(rawValue: kind.rawValue)
    }
}
