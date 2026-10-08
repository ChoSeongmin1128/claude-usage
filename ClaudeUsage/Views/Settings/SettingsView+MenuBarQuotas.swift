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
        let selected =
            surface == .percentage
            ? quotaNumberBinding(row, provider: provider)?.wrappedValue
            : menuBarResetBinding(row, provider: provider)?.wrappedValue
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
                return (surface == .percentage ? selection.percentageIDs : selection.resetIDs).contains(id)
            },
            set: { value in
                guard var selection = effectiveMenuBarSelection(provider) else { return }
                selection.setSelected(value, id: id, surface: surface, limits: providerUsageLimits(provider))
                settings.setMenuBarQuotaSelection(selection, for: provider)
            })
    }

    private func antigravityQuotaBinding(_ rawID: String, surface: MenuBarQuotaSelection.Surface) -> Binding<Bool>? {
        guard antigravitySettings.state.display != nil else { return nil }
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

    func gaugeQuotaRow(_ provider: AppProviderKind, index: Int, title: String) -> some View {
        let limits = providerUsageLimits(provider)
        let selection = effectiveMenuBarSelection(provider) ?? MenuBarQuotaSelection()
        let selected = selection.gaugeIDs.indices.contains(index) ? selection.gaugeIDs[index] : ""
        return GridRow {
            Text(title)
            Picker(
                title,
                selection: Binding(
                    get: { selected },
                    set: { id in
                        guard var next = effectiveMenuBarSelection(provider) else { return }
                        if id.isEmpty {
                            next.gaugeIDs = Array(next.gaugeIDs.prefix(index))
                        } else if let limit = limits.first(where: { $0.id == id }), limit.canNotify {
                            if index == 0 {
                                next.gaugeIDs = [id] + Array(next.gaugeIDs.dropFirst().prefix(1))
                            } else if let first = next.gaugeIDs.first {
                                next.gaugeIDs = [first, id]
                            }
                            next.titles[id] = limit.title
                        }
                        settings.setMenuBarQuotaSelection(next, for: provider)
                    })
            ) {
                Text("없음").tag("")
                ForEach(limits) { limit in
                    Text(limit.title).tag(limit.id).disabled(!limit.canNotify)
                }
                if !selected.isEmpty && !limits.contains(where: { $0.id == selected }) {
                    Text("\(selection.titles[selected] ?? "한도") (데이터 없음)").tag(selected)
                }
            }
            .labelsHidden()
            .disabled(index > 0 && selection.gaugeIDs.isEmpty)
            .help(index > 0 && selection.gaugeIDs.isEmpty ? "첫 번째 게이지를 먼저 선택해 주세요." : "게이지에 표시할 한도")
        }
    }
}
