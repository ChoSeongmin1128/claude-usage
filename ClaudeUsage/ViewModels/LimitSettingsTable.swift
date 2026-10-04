import Foundation

nonisolated enum LimitMenuBarSlot: Sendable, Equatable {
    case fiveHour, weekly
}

/// 한도 표의 한 줄. 같은 한도의 메뉴바, 팝오버, 알림 설정을 한 줄에 모은다.
nonisolated struct LimitSettingsRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    var isChild = false
    var menuBarSlot: LimitMenuBarSlot?
    var popoverItemID: String?
    var laneID: String?
    var notificationLimit: UsageLimit?
    /// 조회 전이라 아직 알림 대상이 없지만 조회되면 생기는 줄
    var takesNotification = false
    var controlsResetCreditMenuBar = false
}

nonisolated enum LimitSettingsTable {
    static func rows(
        service: PopoverService, popoverItems: [PopoverItemConfig], limits: [UsageLimit],
        displayName: (String) -> String?
    ) -> [LimitSettingsRow] {
        popoverItems.flatMap { item -> [LimitSettingsRow] in
            let name = displayName(item.id) ?? item.id
            func row(
                _ title: String = name, slot: LimitMenuBarSlot? = nil, limit: UsageLimit? = nil, takes: Bool = false
            )
                -> LimitSettingsRow
            {
                LimitSettingsRow(
                    id: item.id, title: title, menuBarSlot: slot, popoverItemID: item.id, notificationLimit: limit,
                    takesNotification: takes)
            }
            func children(_ matches: (UsageLimit) -> Bool) -> [LimitSettingsRow] {
                limits.filter(matches).map {
                    LimitSettingsRow(
                        id: "\(item.id)/\($0.id)", title: $0.title, isChild: true, notificationLimit: $0,
                        takesNotification: true)
                }
            }
            switch (service, item.id) {
            case (.claude, "currentSession"):
                return [row(slot: .fiveHour, limit: limits.first { $0.scope == "five_hour" }, takes: true)]
            case (.claude, "weeklyLimit"):
                return [row(slot: .weekly, limit: limits.first { $0.scope == "seven_day" }, takes: true)]
            case (.claude, "modelUsage"):
                return [row()] + children(\.isModelScoped)
            case (.codex, "codexPrimary"), (.codex, "codexSecondary"):
                let isPrimary = item.id == "codexPrimary"
                let limit = limits.first {
                    $0.scope == "general" && $0.windowSlot == (isPrimary ? "primary" : "secondary")
                }
                let fallback = isPrimary ? "기본 한도" : "보조 한도"
                return [
                    row(
                        limit.map { "\($0.title) 한도" } ?? fallback, slot: isPrimary ? .fiveHour : .weekly, limit: limit,
                        takes: true)
                ]
            case (.codex, "codexModelLimits"):
                return [row()] + children { $0.scope.hasPrefix("model:") }
            case (.claude, "claudeResetCredits"), (.codex, "codexResetCredits"):
                var resetRow = row()
                resetRow.controlsResetCreditMenuBar = true
                return [resetRow]
            default:
                return [row()]
            }
        }
    }

    static func antigravityRows(lanes: [(id: String, title: String)], limits: [UsageLimit]) -> [LimitSettingsRow] {
        lanes.map { lane in
            LimitSettingsRow(
                id: lane.id, title: lane.title, laneID: lane.id,
                notificationLimit: limits.first { $0.scope == lane.id }, takesNotification: true)
        }
    }

}

extension PercentageDisplay {
    nonisolated func contains(_ slot: LimitMenuBarSlot) -> Bool {
        switch (self, slot) {
        case (.dual, _), (.fiveHour, .fiveHour), (.weekly, .weekly): return true
        default: return false
        }
    }

    nonisolated func setting(_ slot: LimitMenuBarSlot, to isOn: Bool) -> PercentageDisplay {
        let fiveHour = slot == .fiveHour ? isOn : contains(.fiveHour)
        let weekly = slot == .weekly ? isOn : contains(.weekly)
        switch (fiveHour, weekly) {
        case (true, true): return .dual
        case (true, false): return .fiveHour
        case (false, true): return .weekly
        case (false, false): return .none
        }
    }
}
