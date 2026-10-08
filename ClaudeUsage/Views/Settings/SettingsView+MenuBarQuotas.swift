import SwiftUI

extension SettingsView {
    func providerUsageLimits(_ provider: AppProviderKind) -> [UsageLimit] {
        switch provider {
        case .claude: return claudeLastUsage?().map(UsageLimitCatalog.claude) ?? []
        case .codex: return codexLastUsage?().map(UsageLimitCatalog.codex) ?? []
        case .antigravity: return notificationManager.inventories[.antigravity] ?? []
        }
    }

    func effectiveMenuBarSelection(_ provider: AppProviderKind) -> MenuBarQuotaSelection? {
        settings.menuBarQuotaSelection(
            for: provider, limits: providerUsageLimits(provider),
            codexUsage: provider == .codex ? codexLastUsage?() : nil)
    }

    func quotaNumberBinding(_ row: LimitSettingsRow, provider: AppProviderKind) -> Binding<Bool>? {
        if let laneID = row.laneID { return antigravityQuotaBinding(laneID, surface: .percentage) }
        if let id = row.quotaID { return quotaBinding(id, provider: provider, surface: .percentage) }
        guard settings.menuBarDisplayConfig(for: provider)?.quotaSelection == nil,
            providerUsageLimits(provider).isEmpty, let slot = row.menuBarSlot
        else { return nil }
        return Binding(
            get: { settings.menuBarDisplayConfig(for: provider)?.percentageDisplay.contains(slot) ?? false },
            set: { value in
                let current = settings.menuBarDisplayConfig(for: provider)?.percentageDisplay ?? .none
                settings.setProviderPercentageDisplay(current.setting(slot, to: value), for: provider)
            })
    }

    func menuBarResetBinding(_ row: LimitSettingsRow, provider: AppProviderKind) -> Binding<Bool>? {
        if let laneID = row.laneID { return antigravityQuotaBinding(laneID, surface: .reset) }
        if let id = row.quotaID { return quotaBinding(id, provider: provider, surface: .reset) }
        guard settings.menuBarDisplayConfig(for: provider)?.quotaSelection == nil,
            providerUsageLimits(provider).isEmpty, let slot = row.menuBarSlot
        else { return nil }
        return Binding(
            get: {
                let mode = settings.menuBarDisplayConfig(for: provider)?.resetTimeDisplay ?? .none
                return mode == .dual || (slot == .fiveHour ? mode == .fiveHour : mode == .weekly)
            },
            set: { value in
                let mode = settings.menuBarDisplayConfig(for: provider)?.resetTimeDisplay ?? .none
                let selected: PercentageDisplay
                switch mode {
                case .none: selected = .none
                case .fiveHour: selected = .fiveHour
                case .weekly: selected = .weekly
                case .dual: selected = .dual
                }
                let next: ResetTimeDisplay
                switch selected.setting(slot, to: value) {
                case .none: next = .none
                case .fiveHour: next = .fiveHour
                case .weekly: next = .weekly
                case .dual: next = .dual
                }
                settings.setProviderResetTimeDisplay(next, for: provider)
            })
    }

    func quotaCellUnavailable(
        _ row: LimitSettingsRow, provider: AppProviderKind, surface: MenuBarQuotaSelection.Surface
    ) -> Bool {
        let selected: Bool?
        switch surface {
        case .percentage: selected = quotaNumberBinding(row, provider: provider)?.wrappedValue
        case .reset: selected = menuBarResetBinding(row, provider: provider)?.wrappedValue
        case .gauge: selected = quotaGaugeBinding(row, provider: provider)?.wrappedValue
        }
        if selected == true { return false }
        if let lane = row.laneID {
            return antigravityObservedLanes.first { $0.id.rawValue == lane }?.value.usedPercentage == nil
        }
        guard row.quotaID != nil else { return false }
        return row.notificationLimit?.canNotify != true
    }

    private func quotaBinding(_ id: String, provider: AppProviderKind, surface: MenuBarQuotaSelection.Surface)
        -> Binding<Bool>
    {
        Binding(
            get: {
                guard let selection = effectiveMenuBarSelection(provider) else { return false }
                return selection.ids(for: surface).contains(id)
            },
            set: { value in
                guard var selection = effectiveMenuBarSelection(provider) else { return }
                selection.setSelected(value, id: id, surface: surface, limits: providerUsageLimits(provider))
                if surface == .gauge {
                    saveGaugeSelection(
                        MenuBarGaugeSelection(
                            ids: selection.gaugeIDs, titles: selection.titles,
                            layout: gaugeSelection(provider).layout), provider: provider)
                } else {
                    settings.setMenuBarQuotaSelection(selection, for: provider)
                }
            })
    }

    private func antigravityQuotaBinding(_ rawID: String, surface: MenuBarQuotaSelection.Surface) -> Binding<Bool>? {
        guard surface != .gauge, antigravitySettings.state.display != nil else { return nil }
        let id = AntigravityQuotaLaneID(rawValue: rawID)
        return Binding(
            get: { antigravityTextSelection(surface).contains(id) },
            set: { value in
                var ids = antigravityTextSelection(surface)
                ids.removeAll { $0 == id }
                if value { ids.append(id) }
                updateAntigravityDisplay {
                    if surface == .percentage {
                        $0.menuBar.percentageLaneIDs = ids
                    } else {
                        $0.menuBar.resetLaneIDs = ids
                    }
                }
            })
    }

    private func antigravityTextSelection(_ surface: MenuBarQuotaSelection.Surface) -> [AntigravityQuotaLaneID] {
        guard let display = antigravitySettings.state.display else { return [] }
        let explicit = surface == .percentage ? display.menuBar.percentageLaneIDs : display.menuBar.resetLaneIDs
        if let explicit { return explicit }
        let shows =
            surface == .percentage
            ? display.menuBar.showsSelectedLanePercentage : display.menuBar.showsSelectedLaneResetTime
        guard shows, case .content(let presentation) = antigravitySettings.state.quotaPresentation else { return [] }
        let primary = presentation.menuBar.selectedLaneID
        return [primary].compactMap { $0 } + display.menuBar.effectiveAdditionalLaneIDs.filter { $0 != primary }
    }

    func gaugeSelection(_ provider: AppProviderKind) -> MenuBarGaugeSelection {
        guard provider == .antigravity else {
            let selection = effectiveMenuBarSelection(provider) ?? MenuBarQuotaSelection()
            var gauges = MenuBarGaugeSelection(
                ids: selection.gaugeIDs, titles: selection.titles,
                layout: settings.menuBarDisplayConfig(for: provider)?.gaugeSelection?.layout
                    ?? .legacy(settings.menuBarDisplayConfig(for: provider)?.style ?? .none))
            for limit in providerUsageLimits(provider) where selection.gaugeIDs.contains(limit.id) {
                gauges.titles[limit.id] = limit.shortTitle
            }
            return gauges
        }
        guard let display = antigravitySettings.state.display else { return MenuBarGaugeSelection(ids: []) }
        let fallback: [AntigravityQuotaLaneID]
        if case .fixed(let id) = display.menuBar.laneSelection {
            fallback = [id]
        } else if case .content(let presentation) = antigravitySettings.state.quotaPresentation {
            fallback = [presentation.menuBar.selectedLaneID].compactMap { $0 }
        } else {
            fallback = []
        }
        var titles = display.menuBar.gaugeTitles ?? [:]
        for lane in antigravityObservedLanes { titles[lane.id.rawValue] = lane.menuLabel }
        return MenuBarGaugeSelection(
            ids: (display.menuBar.style == .none ? [] : display.menuBar.gaugeLaneIDs ?? fallback).map(\.rawValue),
            titles: titles)
    }

    func quotaGaugeBinding(_ row: LimitSettingsRow, provider: AppProviderKind) -> Binding<Bool>? {
        guard let id = row.laneID ?? row.quotaID else { return nil }
        if provider != .antigravity { return quotaBinding(id, provider: provider, surface: .gauge) }
        return Binding(
            get: { gaugeSelection(provider).ids?.contains(id) == true },
            set: { selected in
                var next = gaugeSelection(provider)
                var ids = next.ids ?? []
                ids.removeAll { $0 == id }
                if selected {
                    let used =
                        row.laneID.flatMap { raw in
                            antigravityObservedLanes.first { $0.id.rawValue == raw }?.value.usedPercentage
                        } ?? row.notificationLimit?.usedPercentage
                    guard used != nil else { return }
                    ids.append(id)
                    next.titles[id] =
                        row.laneID.flatMap { raw in
                            antigravityObservedLanes.first { $0.id.rawValue == raw }?.menuLabel
                        } ?? row.notificationLimit?.shortTitle ?? row.title
                }
                next.ids = ids
                saveGaugeSelection(next, provider: provider)
            })
    }

    private func saveGaugeSelection(_ selection: MenuBarGaugeSelection, provider: AppProviderKind) {
        let ids = selection.ids ?? []
        if provider == .antigravity {
            updateAntigravityDisplay {
                $0.menuBar.gaugeLaneIDs = ids.map(AntigravityQuotaLaneID.init(rawValue:))
                $0.menuBar.gaugeTitles = selection.titles.filter { ids.contains($0.key) }
                if !ids.isEmpty && $0.menuBar.style == .none { $0.menuBar.style = .batteryBar }
            }
        } else {
            var stored = selection
            stored.titles = selection.titles.filter { ids.contains($0.key) }
            settings.setMenuBarGaugeSelection(stored, for: provider)
            if !ids.isEmpty && settings.menuBarDisplayConfig(for: provider)?.style == MenuBarStyle.none {
                settings.setMenuBarStyle(.batteryBar, for: provider)
            }
        }
    }

    func gaugeShapeBinding(_ provider: AppProviderKind) -> Binding<MenuBarStyle> {
        Binding(
            get: { settings.menuBarDisplayConfig(for: provider)?.style.gaugeShape ?? .none },
            set: { shape in
                guard let config = settings.menuBarDisplayConfig(for: provider) else { return }
                var selection = config.gaugeSelection ?? MenuBarGaugeSelection(layout: .legacy(config.style))
                if shape == .none {
                    selection.ids = []
                    selection.titles = [:]
                }
                if shape == .circular && selection.layout == .stacked { selection.layout = .concentric }
                if shape == .batteryBar && selection.layout == .concentric { selection.layout = .stacked }
                settings.setMenuBarGaugeSelection(selection, for: provider)
                let style: MenuBarStyle
                if selection.ids == nil && config.style.isDualStyle {
                    style =
                        shape == .circular
                        ? .concentricRings
                        : selection.layout == .horizontal ? .sideBySideBattery : .dualBattery
                } else {
                    style = shape
                }
                settings.setMenuBarStyle(style, for: provider)
            })
    }

    func gaugeOrderControls(_ provider: AppProviderKind) -> some View {
        let selection = gaugeSelection(provider)
        let ids = selection.ids ?? []
        return VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            if !ids.isEmpty {
                Text("게이지 순서").font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    HStack {
                        Text(selection.titles[id] ?? "선택한 한도").lineLimit(1)
                        Spacer()
                        Button {
                            var next = gaugeSelection(provider)
                            next.move(id, by: -1)
                            saveGaugeSelection(next, provider: provider)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(index == 0)
                        .accessibilityLabel("\(selection.titles[id] ?? "한도") 앞으로 이동")
                        Button {
                            var next = gaugeSelection(provider)
                            next.move(id, by: 1)
                            saveGaugeSelection(next, provider: provider)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(index == ids.count - 1)
                        .accessibilityLabel("\(selection.titles[id] ?? "한도") 뒤로 이동")
                    }
                }
                if provider != .antigravity, ids.count == 2 {
                    Toggle(
                        "두 게이지 겹쳐 보기",
                        isOn: Binding(
                            get: { gaugeSelection(provider).layout != .horizontal },
                            set: { overlapped in
                                var next = gaugeSelection(provider)
                                let shape =
                                    settings.menuBarDisplayConfig(for: provider)?.style.gaugeShape ?? .batteryBar
                                next.layout =
                                    overlapped ? (shape == .circular ? .concentric : .stacked) : .horizontal
                                saveGaugeSelection(next, provider: provider)
                            })
                    )
                    .toggleStyle(.checkbox)
                }
                if ids.count >= 3 {
                    Text("이름을 붙여 가로로 표시합니다. 많이 선택하면 다른 메뉴바 항목이 가려질 수 있습니다.")
                        .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(provider == .antigravity && antigravitySettings.state.activity.isBusy)
    }
}
