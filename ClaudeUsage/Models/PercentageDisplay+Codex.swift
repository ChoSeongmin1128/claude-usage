import Foundation

nonisolated enum LimitMenuBarSlot: Sendable, Equatable {
    case fiveHour, weekly
}

extension PercentageDisplay {
    nonisolated func effectiveCodexSelection(usage: CodexUsageResponse?) -> PercentageDisplay {
        guard let usage else { return self }
        switch (usage.hasSessionWindow, usage.weeklyWindow != nil) {
        case (true, true): return self
        case (true, false): return contains(.fiveHour) ? .fiveHour : .none
        case (false, true): return self == .none ? .none : .weekly
        case (false, false): return .none
        }
    }

    nonisolated func contains(_ slot: LimitMenuBarSlot) -> Bool {
        switch (self, slot) {
        case (.dual, _), (.fiveHour, .fiveHour), (.weekly, .weekly): return true
        default: return false
        }
    }

}
