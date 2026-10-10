import AppKit
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

    var antigravityEditorPresentation: AntigravityQuotaPresentation? {
        guard case .content(let value) = antigravitySettings.state.quotaPresentation else { return nil }
        return value
    }

    func menuBarQuotaEditorModel(for provider: AppProviderKind) -> MenuBarQuotaEditorModel? {
        if provider == .antigravity {
            guard let display = antigravitySettings.state.display else { return nil }
            return AntigravityMenuBarQuotaEditorAdapter.editorModel(
                settings: display, presentation: antigravityEditorPresentation)
        }
        guard let config = settings.menuBarDisplayConfig(for: provider),
            let selection = effectiveMenuBarSelection(provider)
        else { return nil }
        let items = providerUsageLimits(provider).filter(\.isIdentifiable).map { limit in
            let surfaces: [MenuBarQuotaSelection.Surface] =
                limit.usedPercentage != nil
                ? [.gauge, .percentage, .reset] : limit.resetAt == nil ? [] : [.reset]
            return MenuBarQuotaEditorItem(
                id: limit.id, title: limit.title, usedPercentage: limit.usedPercentage,
                canSelect: !surfaces.isEmpty, selectableSurfaces: surfaces)
        }
        return MenuBarQuotaEditorModel(
            provider: provider, items: items, selection: selection,
            arrangement: (selection.arrangement
                ?? .baseline(selection: selection, layout: config.gaugeSelection?.layout ?? .legacy(config.style)))
                .resolved(selection: selection),
            shape: config.style.gaugeShape)
    }

    @ViewBuilder
    func providerMenuBarQuotaEditor(for provider: AppProviderKind) -> some View {
        if let model = menuBarQuotaEditorModel(for: provider) {
            MenuBarQuotaEditor(
                model: model,
                previewsEditedArrangement: previewShowsEditedLayout(for: provider),
                renderPreview: { arrangement, highlighted in
                    quotaEditorPreview(
                        model: model, arrangement: arrangement, highlightedID: highlighted)
                },
                onAction: { applyMenuBarQuotaAction($0, for: provider) })
        } else {
            Text("사용량이 확인되면 한도를 고를 수 있습니다.")
                .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
        }
    }

    private func previewShowsEditedLayout(for provider: AppProviderKind) -> Bool {
        switch provider {
        case .claude:
            return settings.menuBarDisplayConfig(for: provider)?.quotaSelection?.arrangement == nil
                || claudeLastUsage?() == nil || !hasReadyClaudeCredential
        case .codex:
            return settings.menuBarDisplayConfig(for: provider)?.quotaSelection?.arrangement == nil
                || codexLastUsage?() == nil || codexAuthStatus != .authenticated
        case .antigravity:
            return antigravitySettings.state.display?.menuBar.arrangement == nil
                || antigravityEditorPresentation == nil || antigravitySettings.state.display?.menuBar.isVisible != true
        }
    }

    func applyMenuBarQuotaAction(_ action: MenuBarQuotaEditorAction, for provider: AppProviderKind) {
        guard let model = menuBarQuotaEditorModel(for: provider) else { return }
        if provider == .antigravity {
            guard let display = antigravitySettings.state.display else { return }
            let updated = AntigravityMenuBarQuotaEditorAdapter.applying(
                action, settings: display, presentation: antigravityEditorPresentation)
            if updated != display { updateAntigravityDisplay { $0 = updated } }
            return
        }
        let updated = model.applying(action)
        guard updated != model else { return }
        saveMenuBarQuotaModel(updated)
    }

    private func saveMenuBarQuotaModel(_ model: MenuBarQuotaEditorModel) {
        var selected = model.selection
        selected.arrangement = model.arrangement
        settings.setMenuBarQuotaSelection(selected, for: model.provider)
        if model.shape != settings.menuBarDisplayConfig(for: model.provider)?.style.gaugeShape {
            settings.setMenuBarStyle(model.shape, for: model.provider)
        }
    }

    private func quotaEditorPreview(
        model: MenuBarQuotaEditorModel, arrangement: MenuBarQuotaArrangement, highlightedID: String?
    ) -> MenuBarQuotaPreviewLayout {
        let secondaryColor = MenuBarIconFactory.secondaryTextColor(highContrast: settings.menuBarTextHighContrast)
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance
        let edited = MenuBarQuotaEditorModel(
            provider: model.provider, items: model.items, selection: model.selection,
            arrangement: arrangement, shape: model.shape)
        if model.provider == .antigravity, let display = antigravitySettings.state.display {
            let units = AntigravityMenuBarQuotaEditorAdapter.renderedUnits(
                model: edited, settings: display, presentation: antigravityEditorPresentation,
                design: settings.menuBarDesign, colorMode: settings.menuBarColorMode,
                highlightedID: highlightedID, appearance: appearance, secondaryColor: secondaryColor)
            let snapshot = antigravityEditorPresentation.flatMap {
                MenuBarStatusComposer.antigravitySnapshot(
                    presentation: $0.menuBar, context: $0.context,
                    icon: ProviderBrandIconResolver.image(for: .antigravity, kind: .menuBar, appearance: appearance),
                    appearance: appearance, design: settings.menuBarDesign, colorMode: settings.menuBarColorMode)
            }
            if let snapshot {
                return MenuBarStatusComposer.quotaPreviewLayout(
                    snapshot: snapshot, units: units, secondaryColor: secondaryColor, appearance: appearance)
            }
            return MenuBarQuotaPreviewLayout(units: units)
        }
        guard var config = settings.menuBarDisplayConfig(for: model.provider) else {
            return MenuBarQuotaPreviewLayout(units: [])
        }
        var selected = model.selection
        selected.arrangement = arrangement
        config = config.settingQuotaSelection(selected)
        let projection = MenuBarQuotaProjection(
            config: config, limits: providerUsageLimits(model.provider),
            codexUsage: model.provider == .codex ? codexLastUsage?() : nil)
        let units = MenuBarStatusComposer.quotaUnits(
            projection: projection, arrangement: arrangement, config: config,
            highlightedID: highlightedID, appearance: appearance, secondaryColor: secondaryColor)
        let icon = ProviderBrandIconResolver.image(for: model.provider, kind: .menuBar, appearance: appearance)
        let snapshot: MenuBarProviderSnapshot
        if model.provider == .claude {
            snapshot = MenuBarStatusComposer.claudeSnapshot(
                config: config, usage: claudeLastUsage?(), error: nil, hasAuthError: false,
                hasCredential: hasReadyClaudeCredential, secondaryColor: secondaryColor,
                icon: icon, appearance: appearance)
        } else {
            snapshot = MenuBarStatusComposer.codexSnapshot(
                config: config, usage: codexLastUsage?(), error: codexLastError?(), hasAuthError: false,
                isAuthenticated: codexAuthStatus == .authenticated, secondaryColor: secondaryColor,
                icon: icon, appearance: appearance)
        }
        return MenuBarStatusComposer.quotaPreviewLayout(
            snapshot: snapshot, units: units, secondaryColor: secondaryColor, appearance: appearance)
    }

    func gaugeSelection(_ provider: AppProviderKind) -> MenuBarGaugeSelection {
        guard let model = menuBarQuotaEditorModel(for: provider) else { return MenuBarGaugeSelection(ids: []) }
        let labels =
            provider == .antigravity
            ? antigravitySettings.state.display?.menuBar.showsGaugeLabels
            : settings.menuBarDisplayConfig(for: provider)?.gaugeSelection?.showsLabels
        return MenuBarGaugeSelection(
            ids: model.selection.gaugeIDs, titles: model.selection.titles,
            layout: model.arrangement.gaugeLayout, showsLabels: labels)
    }

    func gaugeShapeBinding(_ provider: AppProviderKind) -> Binding<MenuBarStyle> {
        Binding(
            get: { menuBarQuotaEditorModel(for: provider)?.shape ?? .none },
            set: { shape in
                guard let model = menuBarQuotaEditorModel(for: provider), shape != model.shape else { return }
                if provider == .antigravity, let display = antigravitySettings.state.display {
                    let updated = AntigravityMenuBarQuotaEditorAdapter.settingShape(
                        shape, settings: display, presentation: antigravityEditorPresentation)
                    if updated != display { updateAntigravityDisplay { $0 = updated } }
                    return
                }
                if providerUsageLimits(provider).isEmpty,
                    let config = settings.menuBarDisplayConfig(for: provider),
                    config.quotaSelection == nil, config.gaugeSelection?.ids == nil
                {
                    var gauge = config.gaugeSelection ?? MenuBarGaugeSelection(layout: .legacy(config.style))
                    if shape == .none { gauge.ids = []; gauge.titles = [:] }
                    if shape == .circular && gauge.layout == .stacked { gauge.layout = .concentric }
                    if shape == .batteryBar && gauge.layout == .concentric { gauge.layout = .stacked }
                    let style =
                        gauge.ids == nil && config.style.isDualStyle
                        ? (shape == .circular
                            ? MenuBarStyle.concentricRings
                            : gauge.layout == .horizontal ? .sideBySideBattery : .dualBattery) : shape
                    settings.setMenuBarGaugeSelection(gauge, for: provider)
                    settings.setMenuBarStyle(style, for: provider)
                    return
                }
                var selected = model.selection
                if shape == .none {
                    selected.gaugeIDs = []
                } else if selected.gaugeIDs.isEmpty,
                    let id = model.selectedItems.first(where: { $0.usedPercentage != nil })?.id
                {
                    selected.gaugeIDs = [id]
                }
                selected.arrangement = model.arrangement
                selected = selected.settingGaugeStyle(shape)
                saveMenuBarQuotaModel(
                    MenuBarQuotaEditorModel(
                        provider: provider, items: model.items, selection: selected,
                        arrangement: selected.arrangement ?? model.arrangement, shape: shape))
            })
    }

    func gaugeLayoutBinding(_ provider: AppProviderKind) -> Binding<MenuBarGaugeLayout> {
        Binding(
            get: { menuBarQuotaEditorModel(for: provider)?.arrangement.gaugeLayout ?? .horizontal },
            set: { layout in
                guard let model = menuBarQuotaEditorModel(for: provider) else { return }
                if provider == .antigravity, let display = antigravitySettings.state.display {
                    let updated = AntigravityMenuBarQuotaEditorAdapter.settingLayout(
                        layout, settings: display, presentation: antigravityEditorPresentation)
                    if updated != display { updateAntigravityDisplay { $0 = updated } }
                } else {
                    let arrangement = model.arrangement.settingLayout(layout, selection: model.selection)
                    guard arrangement != model.arrangement else { return }
                    saveMenuBarQuotaModel(
                        MenuBarQuotaEditorModel(
                            provider: provider, items: model.items, selection: model.selection,
                            arrangement: arrangement, shape: model.shape))
                }
            })
    }

    func gaugeLabelsBinding(_ provider: AppProviderKind) -> Binding<Bool> {
        Binding(
            get: { gaugeSelection(provider).showsLabels == true },
            set: { value in
                if provider == .antigravity {
                    updateAntigravityDisplay { $0.menuBar.showsGaugeLabels = value }
                } else {
                    var selected = gaugeSelection(provider)
                    selected.showsLabels = value
                    settings.setMenuBarGaugeSelection(selected, for: provider)
                }
            })
    }

    @ViewBuilder
    func menuBarGaugeArrangementControls(for provider: AppProviderKind) -> some View {
        if let model = menuBarQuotaEditorModel(for: provider), model.selection.gaugeIDs.count >= 2 {
            HStack {
                Text("게이지 배치")
                Picker("게이지 배치", selection: gaugeLayoutBinding(provider)) {
                    Text("나란히").tag(MenuBarGaugeLayout.horizontal)
                    if model.shape.gaugeShape == .circular {
                        Text("동심원 (둘씩)").tag(MenuBarGaugeLayout.concentric)
                    } else {
                        Text("두 줄 (둘씩)").tag(MenuBarGaugeLayout.stacked)
                    }
                }.labelsHidden().fixedSize()
            }
            if model.selection.gaugeIDs.count >= 3 {
                Toggle("게이지 이름 표시", isOn: gaugeLabelsBinding(provider)).toggleStyle(.switch)
            }
        }
    }
}
