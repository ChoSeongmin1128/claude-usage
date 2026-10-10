import Foundation

nonisolated struct MenuBarQuotaUnit: Identifiable, Equatable, Sendable {
    let quotaIDs: [String]
    let gaugeIDs: [String]
    var id: [String] { quotaIDs }
}

nonisolated struct MenuBarQuotaArrangement: Codable, Equatable, Sendable {
    var orderedIDs: [String]
    var gaugeGroups: [[String]]
    var gaugeLayout: MenuBarGaugeLayout

    static func baseline(selection: MenuBarQuotaSelection, layout: MenuBarGaugeLayout) -> Self {
        let order = unique(selection.gaugeIDs + selection.percentageIDs + selection.resetIDs)
        let effective = selection.gaugeIDs.count == 2 ? layout : .horizontal
        return Self(
            orderedIDs: order,
            gaugeGroups: effective == .horizontal
                ? selection.gaugeIDs.map { [$0] } : [selection.gaugeIDs],
            gaugeLayout: effective)
    }

    var isValid: Bool {
        orderedIDs == Self.unique(orderedIDs)
            && orderedIDs.allSatisfy { !$0.isEmpty }
            && gaugeGroups.allSatisfy { !$0.isEmpty && $0.count <= 2 }
            && gaugeGroups.flatMap { $0 } == Self.unique(gaugeGroups.flatMap { $0 })
            && Set(gaugeGroups.flatMap { $0 }).isSubset(of: Set(orderedIDs))
    }

    func resolved(selection: MenuBarQuotaSelection) -> Self {
        let active = selection.selectedIDs
        let gaugeIDs = Set(selection.gaugeIDs)
        let order = Self.unique(
            orderedIDs.filter { active.contains($0) }
                + selection.gaugeIDs + selection.percentageIDs + selection.resetIDs)
        var seen = Set<String>()
        var groups: [[String]] = []
        for group in gaugeGroups {
            let remaining = group.filter { gaugeIDs.contains($0) && seen.insert($0).inserted }
            groups += Self.pairs(remaining)
        }
        groups += order.filter { gaugeIDs.contains($0) && !seen.contains($0) }.map { [$0] }
        var result = Self(orderedIDs: order, gaugeGroups: groups, gaugeLayout: gaugeLayout)
        if gaugeLayout != .horizontal {
            result.orderedIDs = result.units(selection: selection).flatMap(\.quotaIDs)
        }
        return result
    }

    func units(selection: MenuBarQuotaSelection) -> [MenuBarQuotaUnit] {
        let gauges = Set(selection.gaugeIDs)
        var emitted = Set<String>()
        return orderedIDs.compactMap { id in
            guard selection.selectedIDs.contains(id), emitted.insert(id).inserted else { return nil }
            let grouped =
                gaugeLayout == .horizontal
                ? [id] : gaugeGroups.first { $0.contains(id) } ?? [id]
            let ids = grouped.filter { selection.selectedIDs.contains($0) }
            emitted.formUnion(ids)
            return MenuBarQuotaUnit(quotaIDs: ids, gaugeIDs: ids.filter { gauges.contains($0) })
        }
    }

    func settingLayout(_ layout: MenuBarGaugeLayout, selection: MenuBarQuotaSelection) -> Self {
        var result = resolved(selection: selection)
        result.gaugeLayout = layout
        if layout != .horizontal, gaugeLayout == .horizontal || !result.gaugeGroups.contains(where: { $0.count == 2 }) {
            result.gaugeGroups = Self.pairs(result.orderedIDs.filter { selection.gaugeIDs.contains($0) })
        }
        return result.resolved(selection: selection)
    }

    func reorderingQuotas(_ ids: [String], selection: MenuBarQuotaSelection) -> Self {
        var result = resolved(selection: selection)
        guard ids == Self.unique(ids), Set(ids).isSubset(of: selection.selectedIDs) else { return result }
        result.orderedIDs = ids + result.orderedIDs.filter { !ids.contains($0) }
        if result.gaugeLayout != .horizontal {
            let gauges = result.orderedIDs.filter { selection.gaugeIDs.contains($0) }
            let sizes = result.gaugeGroups.map(\.count)
            var offset = 0
            result.gaugeGroups = sizes.compactMap { size in
                let end = min(offset + size, gauges.count)
                guard offset < end else { return nil }
                defer { offset = end }
                return Array(gauges[offset..<end])
            }
            result.gaugeGroups += gauges.dropFirst(offset).map { [$0] }
        }
        return result.resolved(selection: selection)
    }

    func reorderingUnits(_ ids: [[String]], selection: MenuBarQuotaSelection) -> Self {
        var result = resolved(selection: selection)
        let current = result.units(selection: selection)
        guard ids.count == current.count, Set(ids) == Set(current.map(\.quotaIDs)) else { return result }
        result.orderedIDs = ids.flatMap { $0 }
        if result.gaugeLayout != .horizontal {
            result.gaugeGroups = ids.map { $0.filter { selection.gaugeIDs.contains($0) } }.filter { !$0.isEmpty }
        }
        return result.resolved(selection: selection)
    }

    private static func pairs(_ ids: [String]) -> [[String]] {
        stride(from: 0, to: ids.count, by: 2).map { Array(ids[$0..<min($0 + 2, ids.count)]) }
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
