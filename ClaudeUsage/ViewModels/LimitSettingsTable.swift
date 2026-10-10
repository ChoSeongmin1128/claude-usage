import Foundation

nonisolated struct LimitSettingsRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    var quotaID: String?
    var notificationLimit: UsageLimit?
    /// 조회 전이라 아직 알림 대상이 없지만 조회되면 생기는 줄
    var takesNotification = false
    var controlsResetCreditMenuBar = false

}

nonisolated enum LimitSettingsTable {
    static func rows(
        service: PopoverService, popoverItems: [PopoverItemConfig], limits: [UsageLimit],
        displayName: (String) -> String?, codexUsage: CodexUsageResponse? = nil
    ) -> [LimitSettingsRow] {
        popoverItems.flatMap { item -> [LimitSettingsRow] in
            let name = displayName(item.id) ?? item.id
            func row(
                _ title: String = name, limit: UsageLimit? = nil, takes: Bool = false
            )
                -> LimitSettingsRow
            {
                LimitSettingsRow(
                    id: item.id, title: title, quotaID: limit?.id, notificationLimit: limit,
                    takesNotification: takes)
            }
            func children(_ matches: (UsageLimit) -> Bool) -> [LimitSettingsRow] {
                limits.filter(matches).map {
                    LimitSettingsRow(
                        id: "\(item.id)/\($0.id)", title: $0.title, quotaID: $0.id,
                        notificationLimit: $0,
                        takesNotification: true)
                }
            }
            switch (service, item.id) {
            case (.claude, "currentSession"):
                return [row(limit: limits.first { $0.scope == "five_hour" }, takes: true)]
            case (.claude, "weeklyLimit"):
                return [row(limit: limits.first { $0.scope == "seven_day" }, takes: true)]
            case (.claude, "modelUsage"):
                return [row()] + children(\.isModelScoped)
            case (.codex, "codexPrimary"), (.codex, "codexSecondary"):
                let isPrimary = item.id == "codexPrimary"
                if let codexUsage {
                    let selection =
                        isPrimary
                        ? codexUsage.sessionWindowWithSourceSlot : codexUsage.weeklyWindowWithSourceSlot
                    guard let selection else { return [] }
                    let limit = limits.first { $0.scope == "general" && $0.windowSlot == selection.slot }
                    let title = selection.window.adaptiveTitle(
                        expectedSeconds: isPrimary ? 18_000 : 604_800,
                        fallback: isPrimary ? "5시간 한도" : "주간 한도")
                    return [row(title, limit: limit, takes: true)]
                }
                let limit = limits.first {
                    $0.scope == "general" && $0.windowSlot == (isPrimary ? "primary" : "secondary")
                }
                let fallback = isPrimary ? "기본 한도" : "보조 한도"
                return [
                    row(
                        limit.map { "\($0.title) 한도" } ?? fallback, limit: limit,
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

    static func antigravityRows(
        lanes: [(id: String, title: String)], limits: [UsageLimit], selectedIDs: [AntigravityQuotaLaneID] = [],
        titles: [String: String] = [:]
    ) -> [LimitSettingsRow] {
        var rows = lanes.map { lane in
            LimitSettingsRow(
                id: lane.id, title: lane.title,
                notificationLimit: limits.first { $0.scope == lane.id }, takesNotification: true)
        }
        let observed = Set(lanes.map(\.id))
        for (index, id) in selectedIDs.enumerated() where !observed.contains(id.rawValue) {
            let title =
                titles[id.rawValue] ?? AntigravityDisplaySettings.MenuBarPresentationIntent.missingTextTitle(at: index)
            rows.append(LimitSettingsRow(id: id.rawValue, title: title + " (데이터 없음)"))
        }
        return rows
    }

}
