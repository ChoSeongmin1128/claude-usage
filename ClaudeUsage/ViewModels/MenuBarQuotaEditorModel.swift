import Foundation

nonisolated struct MenuBarQuotaEditorItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let usedPercentage: Double?
    var canSelect: Bool
    var selectableSurfaces: [MenuBarQuotaSelection.Surface] = [.gauge, .percentage, .reset]
}

nonisolated enum MenuBarQuotaEditorAction: Sendable {
    case add(String)
    case remove(String)
    case setSurface(String, MenuBarQuotaSelection.Surface, Bool)
    case reorderQuotas([String])
    case reorderUnits([[String]])
}

nonisolated enum MenuBarQuotaRole: Equatable, Sendable {
    case single, outer, inner, top, bottom

    var title: String {
        switch self {
        case .single: "별도"
        case .outer: "바깥쪽"
        case .inner: "안쪽"
        case .top: "위쪽"
        case .bottom: "아래쪽"
        }
    }
}

nonisolated struct MenuBarQuotaEditorModel: Equatable, Sendable {
    let provider: AppProviderKind
    let items: [MenuBarQuotaEditorItem]
    let selection: MenuBarQuotaSelection
    let arrangement: MenuBarQuotaArrangement
    let shape: MenuBarStyle

    var selectedItems: [MenuBarQuotaEditorItem] {
        arrangement.resolved(selection: selection).orderedIDs.map { id in
            items.first { $0.id == id }
                ?? MenuBarQuotaEditorItem(
                    id: id, title: selection.titles[id] ?? "한도", usedPercentage: nil, canSelect: false)
        }
    }

    var availableItems: [MenuBarQuotaEditorItem] {
        items.filter { !selection.selectedIDs.contains($0.id) && $0.canSelect }
    }

    func role(for id: String) -> MenuBarQuotaRole? {
        guard selection.gaugeIDs.contains(id), arrangement.gaugeLayout != .horizontal else { return nil }
        let group = arrangement.resolved(selection: selection).gaugeGroups.first { $0.contains(id) } ?? [id]
        guard group.count == 2 else { return .single }
        let first = group.first == id
        switch arrangement.gaugeLayout {
        case .horizontal: return .single
        case .concentric: return first ? .outer : .inner
        case .stacked: return first ? .top : .bottom
        }
    }

    func summary(for id: String) -> String {
        [
            selection.gaugeIDs.contains(id) ? (shape.gaugeShape == .circular ? "원형 게이지" : "배터리") : nil,
            selection.percentageIDs.contains(id) ? "숫자" : nil,
            selection.resetIDs.contains(id) ? "초기화 시간" : nil,
        ].compactMap { $0 }.joined(separator: " + ")
    }

    func applying(_ action: MenuBarQuotaEditorAction) -> Self {
        var selected = selection
        var nextArrangement = arrangement
        var nextShape = shape
        func enable(_ id: String, surface: MenuBarQuotaSelection.Surface) {
            guard let item = items.first(where: { $0.id == id }), item.canSelect,
                item.selectableSurfaces.contains(surface)
            else { return }
            selected.setSelected(true, id: id, surface: surface, title: item.title)
            if surface == .gauge && nextShape == .none { nextShape = .batteryBar }
        }
        switch action {
        case .add(let id):
            guard !selected.selectedIDs.contains(id), let item = availableItems.first(where: { $0.id == id }) else {
                return self
            }
            let preferred: [MenuBarQuotaSelection.Surface] =
                shape == .none
                ? [.percentage, .reset, .gauge] : [.gauge, .percentage, .reset]
            if let surface = preferred.first(where: { item.selectableSurfaces.contains($0) }) {
                if UsageLimitCatalog.isBasicID(id, provider: provider) {
                    if surface == .percentage { selected.legacyPercentageDisplay = nil }
                    if surface == .reset { selected.legacyResetTimeDisplay = nil }
                }
                enable(id, surface: surface)
            }
        case .remove(let id):
            if selected.percentageIDs.contains(id) { selected.legacyPercentageDisplay = nil }
            if selected.resetIDs.contains(id) { selected.legacyResetTimeDisplay = nil }
            selected.gaugeIDs.removeAll { $0 == id }
            selected.percentageIDs.removeAll { $0 == id }
            selected.resetIDs.removeAll { $0 == id }
            selected.titles[id] = nil
        case .setSurface(let id, let surface, let enabled):
            guard selected.selectedIDs.contains(id) else { return self }
            if enabled {
                guard let item = items.first(where: { $0.id == id }), item.canSelect,
                    item.selectableSurfaces.contains(surface)
                else { return self }
            }
            if surface == .percentage { selected.legacyPercentageDisplay = nil }
            if surface == .reset { selected.legacyResetTimeDisplay = nil }
            if enabled {
                enable(id, surface: surface)
            } else {
                selected.setSelected(false, id: id, surface: surface)
            }
        case .reorderQuotas(let ids): nextArrangement = nextArrangement.reorderingQuotas(ids, selection: selected)
        case .reorderUnits(let ids): nextArrangement = nextArrangement.reorderingUnits(ids, selection: selected)
        }
        let addedGauges = selected.gaugeIDs.filter { !selection.gaugeIDs.contains($0) }
        nextArrangement = nextArrangement.resolved(selection: selected)
        if nextArrangement.gaugeLayout != .horizontal {
            for id in addedGauges {
                nextArrangement.gaugeGroups.removeAll { $0 == [id] }
                if let index = nextArrangement.gaugeGroups.lastIndex(where: { $0.count == 1 }) {
                    nextArrangement.gaugeGroups[index].append(id)
                } else {
                    nextArrangement.gaugeGroups.append([id])
                }
            }
            nextArrangement = nextArrangement.resolved(selection: selected)
        }
        return Self(
            provider: provider, items: items, selection: selected, arrangement: nextArrangement, shape: nextShape)
    }

    func reordering(_ ids: [String]) -> Self {
        Self(
            provider: provider, items: items, selection: selection,
            arrangement: arrangement.reorderingQuotas(ids, selection: selection), shape: shape)
    }
}
