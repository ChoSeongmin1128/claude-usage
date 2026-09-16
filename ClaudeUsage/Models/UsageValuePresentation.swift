import Foundation

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
        style != .none && circularDisplayMode == .remaining ? .remaining : .used
    }
}
