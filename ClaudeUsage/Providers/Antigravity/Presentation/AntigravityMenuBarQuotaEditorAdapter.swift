import AppKit
import Foundation

/// The editor uses provider-neutral ordering, while lane identities, percentage
/// basis, risk tones and responsive text remain owned by Antigravity.
nonisolated enum AntigravityMenuBarQuotaEditorAdapter {
    static func editorModel(
        settings: AntigravityDisplaySettings, presentation: AntigravityQuotaPresentation?
    ) -> MenuBarQuotaEditorModel {
        let lanes = observedLanes(presentation)
        let selection = effectiveSelection(settings: settings, presentation: presentation)
        let arrangement =
            settings.menuBar.arrangement
            ?? MenuBarQuotaArrangement.baseline(selection: selection, layout: .horizontal)
        let items = lanes.map { lane in
            MenuBarQuotaEditorItem(
                id: lane.id.rawValue, title: title(for: lane), usedPercentage: lane.value.usedPercentage,
                canSelect: !selectableSurfaces(for: lane).isEmpty,
                selectableSurfaces: selectableSurfaces(for: lane))
        }
        return MenuBarQuotaEditorModel(
            provider: .antigravity, items: items, selection: selection,
            arrangement: arrangement.resolved(selection: selection), shape: shape(settings.menuBar.style))
    }

    static func applying(
        _ action: MenuBarQuotaEditorAction, settings: AntigravityDisplaySettings,
        presentation: AntigravityQuotaPresentation?
    ) -> AntigravityDisplaySettings {
        let model = editorModel(settings: settings, presentation: presentation)
        let updated = model.applying(action)
        guard updated != model else { return settings }
        let explicit: [MenuBarQuotaSelection.Surface]
        switch action {
        case .setSurface(_, let surface, _): explicit = [surface]
        case .remove(let id):
            explicit = [.gauge, .percentage, .reset].filter { model.selection.ids(for: $0).contains(id) }
        default: explicit = []
        }
        return storing(updated, in: settings, explicitSurfaces: explicit)
    }

    static func settingLayout(
        _ layout: MenuBarGaugeLayout, settings: AntigravityDisplaySettings,
        presentation: AntigravityQuotaPresentation?
    ) -> AntigravityDisplaySettings {
        let model = editorModel(settings: settings, presentation: presentation)
        let arrangement = model.arrangement.settingLayout(layout, selection: model.selection)
        guard arrangement != model.arrangement else { return settings }
        return storing(
            MenuBarQuotaEditorModel(
                provider: model.provider, items: model.items, selection: model.selection,
                arrangement: arrangement, shape: model.shape), in: settings)
    }

    static func settingShape(
        _ requestedShape: MenuBarStyle, settings: AntigravityDisplaySettings,
        presentation: AntigravityQuotaPresentation?
    ) -> AntigravityDisplaySettings {
        let newShape = requestedShape.gaugeShape
        if settings.menuBar.arrangement == nil,
            !observedLanes(presentation).contains(where: { $0.value.usedPercentage != nil })
        {
            var updated = settings
            updated.menuBar.style = newShape == .circular ? .circular : newShape == .none ? .none : .batteryBar
            if newShape == .none { updated.menuBar.gaugeLaneIDs = [] }
            return updated
        }
        let model = editorModel(settings: settings, presentation: presentation)
        var selection = model.selection
        var arrangement = model.arrangement
        if newShape == .none {
            selection.gaugeIDs = []
        } else if selection.gaugeIDs.isEmpty {
            let eligible = model.items.filter { $0.canSelect && $0.selectableSurfaces.contains(.gauge) }
            let firstSelected = arrangement.orderedIDs.first { id in eligible.contains { $0.id == id } }
            if let first = firstSelected {
                selection.gaugeIDs = [first]
                selection.titles[first] = eligible.first { $0.id == first }?.title
            }
        }
        arrangement = arrangement.resolved(selection: selection)
        let layout = arrangement.gaugeLayout.adapted(to: requestedShape)
        arrangement = arrangement.settingLayout(layout, selection: selection)
        let updated = MenuBarQuotaEditorModel(
            provider: model.provider, items: model.items, selection: selection,
            arrangement: arrangement, shape: newShape)
        guard updated != model else { return settings }
        return storing(updated, in: settings, explicitSurfaces: newShape == .none ? [.gauge] : [])
    }

    /// Nil preserves the legacy automatic representative and its fallback path.
    /// Merely opening settings does not pin today's representative lane.
    @MainActor
    static func renderedUnits(
        settings: AntigravityDisplaySettings, presentation: AntigravityQuotaPresentation,
        design: MenuBarDesign, colorMode: MenuBarColorMode, highlightedID: String? = nil,
        appearance: NSAppearance, secondaryColor: NSColor = .secondaryLabelColor, now: Date = Date(),
        locale: Locale = Locale(identifier: "ko_KR"),
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> [MenuBarQuotaRenderedUnit]? {
        guard settings.menuBar.arrangement != nil else { return nil }
        let model = editorModel(settings: settings, presentation: presentation)
        return renderedUnits(
            model: model, settings: settings, presentation: presentation, design: design, colorMode: colorMode,
            highlightedID: highlightedID, appearance: appearance, secondaryColor: secondaryColor, now: now,
            locale: locale, timeZone: timeZone)
    }

    /// The preview also renders a legacy-derived arrangement without saving it.
    @MainActor
    static func renderedUnits(
        model: MenuBarQuotaEditorModel, settings: AntigravityDisplaySettings,
        presentation: AntigravityQuotaPresentation?, design: MenuBarDesign, colorMode: MenuBarColorMode,
        highlightedID: String? = nil, appearance: NSAppearance, secondaryColor: NSColor = .secondaryLabelColor,
        now: Date = Date(),
        locale: Locale = Locale(identifier: "ko_KR"), timeZone: TimeZone = .autoupdatingCurrent
    ) -> [MenuBarQuotaRenderedUnit] {
        let items = renderItems(
            model: model, settings: settings, presentation: presentation, colorMode: colorMode,
            now: now, locale: locale, timeZone: timeZone)
        return MenuBarStatusComposer.quotaUnits(
            items: items, selection: model.selection, arrangement: model.arrangement, shape: model.shape,
            showGaugePercent: settings.menuBar.showsGaugePercentage,
            showsLabels: settings.menuBar.showsGaugeLabels == true, design: design,
            highlightedID: highlightedID, appearance: appearance, secondaryColor: secondaryColor)
    }

    @MainActor
    static func renderItems(
        model: MenuBarQuotaEditorModel, settings: AntigravityDisplaySettings,
        presentation: AntigravityQuotaPresentation?, colorMode: MenuBarColorMode, now: Date = Date(),
        locale: Locale = Locale(identifier: "ko_KR"), timeZone: TimeZone = .autoupdatingCurrent
    ) -> [MenuBarQuotaRenderItem] {
        let lanes = observedLanes(presentation)
        return model.arrangement.resolved(selection: model.selection).orderedIDs.map { id in
            renderItem(
                id: id, lane: lanes.first { $0.id.rawValue == id }, selection: model.selection,
                intent: settings.menuBar, colorMode: colorMode, now: now, locale: locale, timeZone: timeZone)
        }
    }

    private static func effectiveSelection(
        settings: AntigravityDisplaySettings, presentation: AntigravityQuotaPresentation?
    ) -> MenuBarQuotaSelection {
        let intent = settings.menuBar
        let lanes = observedLanes(presentation)
        var representative: [AntigravityQuotaLaneID] = []
        if let selected = presentation?.menuBar.selectedLaneID {
            representative.append(selected)
        }
        for id in intent.effectiveAdditionalLaneIDs
        where !representative.contains(id)
            && lanes.contains(where: { $0.id == id && $0.value.usedPercentage != nil })
        {
            representative.append(id)
        }
        let gauges =
            intent.gaugeLaneIDs
            ?? (intent.style == .none ? [] : Array(representative.prefix(1)))
        let numbers =
            intent.percentageLaneIDs
            ?? (intent.showsSelectedLanePercentage ? representative : [])
        let times =
            intent.resetLaneIDs
            ?? (intent.showsSelectedLaneResetTime ? representative : [])
        var titles = intent.gaugeTitles ?? [:]
        for lane in lanes { titles[lane.id.rawValue] = title(for: lane) }
        let known = AntigravityDisplayAdapter.editorItems(
            settings: settings, presentation: presentation, surface: .standard)
        for item in known where titles[item.id.rawValue] == nil { titles[item.id.rawValue] = item.title }
        return MenuBarQuotaSelection(
            percentageIDs: numbers.map(\.rawValue), resetIDs: times.map(\.rawValue),
            gaugeIDs: gauges.map(\.rawValue), titles: titles)
    }

    private static func storing(
        _ model: MenuBarQuotaEditorModel, in settings: AntigravityDisplaySettings,
        explicitSurfaces: [MenuBarQuotaSelection.Surface] = []
    ) -> AntigravityDisplaySettings {
        var updated = settings
        let selection = model.selection
        let arrangement = model.arrangement.resolved(selection: selection)
        func laneIDs(for surface: MenuBarQuotaSelection.Surface) -> [AntigravityQuotaLaneID] {
            arrangement.orderedIDs.filter { selection.ids(for: surface).contains($0) }
                .map { AntigravityQuotaLaneID(rawValue: $0) }
        }
        func storedIDs(_ surface: MenuBarQuotaSelection.Surface, previous: [AntigravityQuotaLaneID]?)
            -> [AntigravityQuotaLaneID]?
        {
            let ids = laneIDs(for: surface)
            return previous == nil && ids.isEmpty && !explicitSurfaces.contains(surface) ? nil : ids
        }
        updated.menuBar.gaugeLaneIDs = storedIDs(.gauge, previous: settings.menuBar.gaugeLaneIDs)
        updated.menuBar.percentageLaneIDs = storedIDs(.percentage, previous: settings.menuBar.percentageLaneIDs)
        updated.menuBar.resetLaneIDs = storedIDs(.reset, previous: settings.menuBar.resetLaneIDs)
        updated.menuBar.gaugeTitles = selection.titles.filter { selection.selectedIDs.contains($0.key) }
        updated.menuBar.arrangement = arrangement
        updated.menuBar.style =
            model.shape.gaugeShape == .circular
            ? .circular : model.shape == .none ? .none : .batteryBar
        // The old representative policy remains a downgrade mirror. Explicit
        // surface arrays and arrangement own A selection and order.
        return updated
    }

    private static func observedLanes(
        _ presentation: AntigravityQuotaPresentation?
    ) -> [AntigravityQuotaLanePresentation] {
        var seen = Set<AntigravityQuotaLaneID>()
        return (presentation?.allGroups.flatMap(\.lanes) ?? []).filter { seen.insert($0.id).inserted }
    }

    private static func title(for lane: AntigravityQuotaLanePresentation) -> String {
        "\(lane.scopeTitle) / \(lane.cadenceTitle)"
    }

    private static func selectableSurfaces(
        for lane: AntigravityQuotaLanePresentation
    ) -> [MenuBarQuotaSelection.Surface] {
        if case .unavailable(.disabled) = lane.value { return [] }
        if lane.value.usedPercentage != nil { return [.gauge, .percentage, .reset] }
        return lane.resetAt == nil ? [] : [.reset]
    }

    private static func shape(_ style: AntigravityDisplaySettings.MenuBarPresentationIntent.Style) -> MenuBarStyle {
        switch style {
        case .none: .none
        case .batteryBar: .batteryBar
        case .circular: .circular
        }
    }

    @MainActor
    private static func renderItem(
        id: String, lane: AntigravityQuotaLanePresentation?, selection: MenuBarQuotaSelection,
        intent: AntigravityDisplaySettings.MenuBarPresentationIntent, colorMode: MenuBarColorMode,
        now: Date, locale: Locale, timeZone: TimeZone
    ) -> MenuBarQuotaRenderItem {
        let title = lane.map(title(for:)) ?? selection.titles[id] ?? "선택한 한도"
        let tone = lane?.tone ?? .neutral
        let status = color(for: tone)
        let isWarning = tone == .warning || tone == .critical
        let monochrome = colorMode == .monochrome || (colorMode == .warningOnly && !isWarning)
        let gauge = MenuBarIconRenderer.Gauge(
            value: MenuBarGaugeValue(
                id: id, title: lane?.menuLabel ?? title, usedPercentage: lane?.value.usedPercentage,
                basis: lane?.basis ?? .antigravity(intent)),
            color: monochrome || colorMode == .statusNumber ? .labelColor : status,
            monochrome: monochrome, textColor: colorMode == .statusNumber ? status : nil)
        guard let lane else {
            let text = "\(title) 데이터 없음"
            return MenuBarQuotaRenderItem(
                id: id, title: title, gauge: gauge,
                percentageText: selection.percentageIDs.contains(id) ? text : nil,
                resetText: selection.resetIDs.contains(id) && !selection.percentageIDs.contains(id) ? text : nil)
        }
        let number = lane.percentageText ?? unavailableText(lane.value)
        let hasNumber = selection.percentageIDs.contains(id)
        let hasTime = selection.resetIDs.contains(id)
        let reset =
            hasTime
            ? AntigravityQuotaPresentationMapper.menuBarResetText(
                lane, timeFormat: intent.timeFormat, now: now, locale: locale, timeZone: timeZone) : nil
        return MenuBarQuotaRenderItem(
            id: id, title: title, gauge: gauge,
            percentageText: hasNumber ? "\(lane.menuLabel) \(number)" : nil,
            condensedPercentageText: hasNumber ? number : nil,
            resetText: reset.map { hasNumber ? $0 : "\(lane.menuLabel) \($0)" },
            condensedResetText: hasNumber && lane.percentageText != nil ? "" : reset)
    }

    private static func unavailableText(_ value: AntigravityQuotaValuePresentation) -> String {
        switch value {
        case .unavailable(let reason): reason.displayText
        case .available: "사용량 알 수 없음"
        }
    }

    @MainActor
    private static func color(for tone: AntigravityQuotaRiskTone) -> NSColor {
        switch tone {
        case .neutral: .secondaryLabelColor
        case .healthy: .systemGreen
        case .attention: .systemYellow
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }
}
