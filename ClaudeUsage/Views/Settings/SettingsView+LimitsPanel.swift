import SwiftUI

extension SettingsView {
    func providerLimitsSection(for provider: AppProviderKind) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            Text("한도와 알림").font(AppDesign.Typography.headline)
            settingsToggleRow("\(provider.displayName) 알림 받기", isOn: serviceAlertBinding(provider))
                .disabled(
                    !settings.notificationsEnabled
                        || (provider == .antigravity && antigravitySettings.state.display == nil))
            if !settings.notificationsEnabled {
                Button("알림 설정 열기") { navigate(to: SettingsDestination(panel: .common)) }
                    .buttonStyle(.link).controlSize(.small)
            }
            Grid(alignment: .leading, horizontalSpacing: AppDesign.Space.content, verticalSpacing: AppDesign.Space.row)
            {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    ForEach(["메뉴바 숫자", "알림"], id: \.self) { title in
                        Text(title)
                            .font(AppDesign.Typography.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.center)
                    }
                }
                ForEach(limitRows(for: provider)) { row in limitsRow(row, provider: provider) }
            }
            .font(AppDesign.Typography.subheadline)
            .controlSize(.small)
        }
    }

    private func limitsRow(_ row: LimitSettingsRow, provider: AppProviderKind) -> some View {
        GridRow {
            Text(row.title)
                .padding(.leading, row.isChild ? 18 : 0)
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
                limitsCell(menuBarBinding(row, provider: provider), help: "메뉴바에 숫자로 표시", row: row.title)
            }
            notificationCell(row, provider: provider)
        }
    }

    @ViewBuilder
    private func notificationCell(_ row: LimitSettingsRow, provider: AppProviderKind) -> some View {
        if let limit = row.notificationLimit {
            let selected = isNotificationSelected(limit)
            limitsCell(
                Binding(get: { selected }, set: { settings.notificationTargets.setSelected($0, limit: limit) }),
                help: !limit.isIdentifiable
                    ? "구분할 수 없는 한도라 고를 수 없습니다" : limit.usedPercentage == nil ? "데이터 없음" : "알림 받기",
                row: row.title
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
    private func limitsCell(_ binding: Binding<Bool>?, help: String, row: String? = nil) -> some View {
        if let binding {
            // 열 이름만 읽히면 어느 줄의 칸인지 알 수 없어 줄 이름을 앞에 붙인다.
            Toggle([row, help].compactMap { $0 }.joined(separator: ", "), isOn: binding)
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

}
