import Foundation

/// Legacy is a migration state: preserve each provider's existing presentation
/// until the user explicitly chooses one common basis. New installations use remaining.
nonisolated enum UsageDisplayMode: String, Codable, CaseIterable, Sendable {
    case legacy, used, remaining

    var basis: UsageValueBasis? {
        switch self {
        case .legacy: return nil
        case .used: return .used
        case .remaining: return .remaining
        }
    }

    var title: String {
        switch self {
        case .legacy: return "기존 선택 유지"
        case .used: return "사용한 양"
        case .remaining: return "남은 양"
        }
    }
}

/// The display basis changes the number and fill, never the underlying risk.
nonisolated enum UsageValueBasis: String, Sendable, Equatable {
    case used
    case remaining

    var label: String { self == .used ? "사용" : "남음" }

    func percentage(fromUsed percentage: Double?) -> Double? {
        guard let percentage, percentage.isFinite else { return nil }
        let used = min(100, max(0, percentage))
        return self == .used ? used : 100 - used
    }

    func text(fromUsed percentage: Double?) -> String {
        guard let value = self.percentage(fromUsed: percentage) else { return "—" }
        return String(format: "%.0f%%", value)
    }

    func spokenValue(fromUsed percentage: Double?) -> String {
        guard let value = self.percentage(fromUsed: percentage) else { return "사용량 알 수 없음" }
        return "\(Int(value.rounded()))퍼센트 \(label)"
    }

    static func antigravity(_ intent: AntigravityDisplaySettings.MenuBarPresentationIntent) -> Self {
        intent.style == .circular && intent.circularValue == .remaining ? .remaining : .used
    }
}

extension AppSettings {
    func usageValueBasis(for service: PopoverService) -> UsageValueBasis {
        guard let config = menuBarDisplayConfig(for: service.providerKind) else { return .used }
        return config.usageValueBasis
    }
}

extension ProviderMenuBarDisplayConfig {
    var usageValueBasis: UsageValueBasis {
        basisOverride ?? (style != .none && circularDisplayMode == .remaining ? .remaining : .used)
    }
}
