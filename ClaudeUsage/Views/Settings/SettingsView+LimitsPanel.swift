import SwiftUI

extension SettingsView {
    var limitsPanel: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.section) {
            commonAlertSection
            notificationThresholdSection
            Divider()
            limitsTable
        }
    }

    private var limitsTable: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            Grid(alignment: .leading, horizontalSpacing: AppDesign.Space.content, verticalSpacing: AppDesign.Space.row)
            {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    ForEach(["메뉴바", "팝오버", "알림"], id: \.self) { title in
                        Text(title)
                            .font(AppDesign.Typography.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.center)
                    }
                }
                ForEach(AppProviderKind.allCases.filter(settings.isProviderEnabled), id: \.rawValue) { provider in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    limitsServiceHeader(provider)
                    if !collapsedLimitProviders.contains(provider) {
                        ForEach(limitRows(for: provider)) { row in
                            limitsRow(row, provider: provider)
                        }
                    }
                }
            }
            .font(AppDesign.Typography.subheadline)
            .controlSize(.small)

            Text("메뉴바 칸은 숫자 표시입니다. 게이지 모양과 대표 한도는 모양에서 정합니다.")
                .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
            ForEach(AppProviderKind.allCases.filter(settings.isProviderEnabled), id: \.rawValue) { provider in
                if let note = limitsNote(for: provider) {
                    Text(note).font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func limitsServiceHeader(_ provider: AppProviderKind) -> some View {
        GridRow {
            Button {
                if collapsedLimitProviders.contains(provider) {
                    collapsedLimitProviders.remove(provider)
                } else {
                    collapsedLimitProviders.insert(provider)
                }
            } label: {
                HStack(spacing: AppDesign.Space.row) {
                    Image(systemName: collapsedLimitProviders.contains(provider) ? "chevron.right" : "chevron.down")
                        .font(AppDesign.Typography.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    ProviderBrandIconView(provider: provider, kind: .settings, size: 16)
                    Text(provider.displayName).font(AppDesign.Typography.subheadline.weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(provider.displayName) 한도 \(collapsedLimitProviders.contains(provider) ? "펼치기" : "접기")")
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            limitsCell(serviceAlertBinding(provider), help: "\(provider.displayName) 알림 받기")
                .disabled(
                    !settings.notificationsEnabled
                        || (provider == .antigravity && antigravitySettings.state.display == nil))
        }
    }

    private func limitsRow(_ row: LimitSettingsRow, provider: AppProviderKind) -> some View {
        GridRow {
            Text(row.title)
                .padding(.leading, row.isChild ? 34 : 18)
                .foregroundStyle(row.isChild ? .secondary : .primary)
                .lineLimit(1)
            if row.controlsResetCreditMenuBar {
                Picker(
                    "메뉴바에 초기화권 표시",
                    selection: Binding(
                        get: { settings.resetCreditMenuBarMode(for: provider) },
                        set: { settings.setResetCreditMenuBarMode($0, for: provider) })
                ) {
                    ForEach(ResetCreditMenuBarMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("메뉴바에 초기화권 개수(↺)를 표시할 때")
                .gridColumnAlignment(.center)
            } else {
                limitsCell(menuBarBinding(row, provider: provider), help: "메뉴바에 숫자로 표시")
            }
            limitsCell(popoverBinding(row, provider: provider), help: "팝오버에 표시")
            notificationCell(row, provider: provider)
        }
    }

    @ViewBuilder
    private func notificationCell(_ row: LimitSettingsRow, provider: AppProviderKind) -> some View {
        if let limit = row.notificationLimit {
            let selected = isNotificationSelected(limit)
            limitsCell(
                Binding(get: { selected }, set: { settings.notificationTargets.setSelected($0, limit: limit) }),
                help: !limit.isIdentifiable ? "식별 정보 확인 필요" : limit.usedPercentage == nil ? "현재 미제공" : "알림 받기"
            )
            .disabled(
                !settings.notificationsEnabled || !serviceAlertBinding(provider).wrappedValue || !limit.isIdentifiable
                    || (!limit.canNotify && !selected))
        } else if row.takesNotification {
            Text("—").foregroundStyle(.tertiary).gridColumnAlignment(.center)
                .help("사용량을 한 번 조회하면 고를 수 있습니다")
        } else {
            limitsCell(nil, help: "")
        }
    }

    @ViewBuilder
    private func limitsCell(_ binding: Binding<Bool>?, help: String) -> some View {
        if let binding {
            Toggle(help, isOn: binding)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(help)
                .gridColumnAlignment(.center)
        } else {
            Text("").gridColumnAlignment(.center)
        }
    }

    private func limitRows(for provider: AppProviderKind) -> [LimitSettingsRow] {
        let _ = runtimeEnvironmentRefreshTick
        if provider == .antigravity {
            return LimitSettingsTable.antigravityRows(
                lanes: antigravityObservedLanes.map { ($0.id.rawValue, "\($0.scopeTitle) · \($0.cadenceTitle)") },
                limits: notificationManager.inventories[.antigravity] ?? [])
        }
        guard let service = provider.runtimeService,
            let catalog = UsageItemCatalogRegistry.catalog(for: service)
        else { return [] }
        return LimitSettingsTable.rows(
            service: service, popoverItems: settings.popoverItems(for: service),
            limits: notificationManager.inventories[service] ?? [], displayName: catalog.displayName(for:))
    }

    private func limitsNote(for provider: AppProviderKind) -> String? {
        guard let service = provider.runtimeService else { return nil }
        let selected = settings.notificationTargets.providers[service.rawValue]?.selectedIDs ?? []
        let available = Set((notificationManager.inventories[service] ?? []).map(\.id))
        let missing = selected.subtracting(available).count
        return missing > 0 ? "\(provider.displayName): 현재 제공되지 않은 알림 선택 \(missing)개도 보존하고 있습니다." : nil
    }

    private func isNotificationSelected(_ limit: UsageLimit) -> Bool {
        settings.notificationTargets.providers[limit.provider.rawValue]?.selectedIDs.contains(limit.id) ?? false
    }

    private func serviceAlertBinding(_ provider: AppProviderKind) -> Binding<Bool> {
        Binding(
            get: {
                provider == .antigravity
                    ? antigravitySettings.state.display?.notifications.isEnabled ?? false
                    : settings.isProviderAlertEnabled(provider)
            },
            set: { enabled in
                if provider == .antigravity {
                    updateAntigravityDisplay { $0.notifications.isEnabled = enabled }
                } else {
                    settings.setProviderAlertEnabled(enabled, for: provider)
                }
            })
    }

    private func menuBarBinding(_ row: LimitSettingsRow, provider: AppProviderKind) -> Binding<Bool>? {
        if let laneID = row.laneID {
            guard let display = antigravitySettings.state.display else { return nil }
            let lane = AntigravityQuotaLaneID(rawValue: laneID)
            return Binding(
                get: { display.menuBar.effectiveAdditionalLaneIDs.contains(lane) },
                set: { isOn in
                    updateAntigravityDisplay {
                        var ids = $0.menuBar.effectiveAdditionalLaneIDs
                        ids.removeAll { $0 == lane }
                        if isOn { ids.append(lane) }
                        $0.menuBar.additionalLaneIDs = ids
                    }
                })
        }
        guard let slot = row.menuBarSlot, settings.menuBarDisplayConfig(for: provider) != nil else { return nil }
        return Binding(
            get: { settings.menuBarDisplayConfig(for: provider)?.percentageDisplay.contains(slot) ?? false },
            set: { isOn in
                let current = settings.menuBarDisplayConfig(for: provider)?.percentageDisplay ?? .none
                settings.setProviderPercentageDisplay(current.setting(slot, to: isOn), for: provider)
            })
    }

    private func popoverBinding(_ row: LimitSettingsRow, provider: AppProviderKind) -> Binding<Bool>? {
        if let laneID = row.laneID {
            guard let display = antigravitySettings.state.display else { return nil }
            let lane = AntigravityQuotaLaneID(rawValue: laneID)
            return Binding(
                get: { !display.standard.hiddenLaneIDs.contains(lane) },
                set: { isOn in
                    updateAntigravityDisplay {
                        if isOn {
                            $0.standard.hiddenLaneIDs.remove(lane)
                        } else {
                            $0.standard.hiddenLaneIDs.insert(lane)
                        }
                    }
                })
        }
        guard let itemID = row.popoverItemID, !row.isChild, let service = provider.runtimeService else { return nil }
        return Binding(
            get: { settings.popoverItems(for: service).first { $0.id == itemID }?.visible ?? false },
            set: { isOn in
                let items = settings.popoverItems(for: service).map {
                    $0.id == itemID ? PopoverItemConfig(id: $0.id, visible: isOn) : $0
                }
                settings.setPopoverItems(items, for: service)
            })
    }
}
