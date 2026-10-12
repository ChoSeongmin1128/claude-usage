import Foundation

nonisolated struct AntigravityLaneEditorItem:
    Identifiable,
    Equatable,
    Sendable
{
    let id: AntigravityQuotaLaneID
    let title: String
    let groupTitle: String
    let isVisible: Bool
    let isAvailable: Bool
}

nonisolated enum AntigravityDisplayAdapter {
    /// Projection only: hover edits reuse lane operations on a detached compact intent.
    /// The caller saves that intent through saveHover, never saveDisplay.
    static func hoverEditorSettings(
        _ settings: AntigravityDisplaySettings,
        hover: AntigravityHoverDisplayPreferences,
        presentation: AntigravityQuotaPresentation?
    ) -> AntigravityDisplaySettings {
        var projection = settings
        projection.compact = hover.effectiveSelection(compact: settings.compact)
        let lanes = presentation?.allGroups.flatMap(\.lanes) ?? []
        let visible: [AntigravityQuotaLaneID]
        if hover.selection == nil {
            visible = presentation?.compact.metrics.map(\.laneID) ?? []
        } else {
            visible = AntigravityQuotaPresentationMapper.displayedLanes(intent: projection.compact, from: lanes).map(
                \.id)
        }
        let allIDs = editorItems(settings: projection, presentation: presentation, surface: .compact).map(\.id)
        if hover.selection == nil {
            projection.compact.hiddenLaneIDs.formUnion(allIDs.filter { !visible.contains($0) })
        } else if projection.compact.orderedLaneIDs.allSatisfy({ projection.compact.hiddenLaneIDs.contains($0) }) {
            // Explicit empty selection does not start displaying new lanes from a later report.
            projection.compact.hiddenLaneIDs.formUnion(allIDs)
        }
        projection.compact.orderedLaneIDs = visible + allIDs.filter { !visible.contains($0) }
        return projection
    }

    static func editorItems(
        settings: AntigravityDisplaySettings,
        presentation: AntigravityQuotaPresentation?,
        surface: ProviderDisplaySurface
    ) -> [AntigravityLaneEditorItem] {
        let intent = intent(
            for: surface,
            in: settings
        )
        let observedLanes =
            presentation?.allGroups.flatMap(\.lanes)
                ?? []
        var observedByID: [
            AntigravityQuotaLaneID:
                AntigravityQuotaLanePresentation
        ] = [:]
        var observedGroupByID: [
            AntigravityQuotaLaneID: String
        ] = [:]
        for group in presentation?.allGroups ?? [] {
            for lane in group.lanes
            where observedByID[lane.id] == nil {
                observedByID[lane.id] = lane
                observedGroupByID[lane.id] =
                    group.title
            }
        }

        var orderedIDs = intent.orderedLaneIDs
        appendMissing(
            AntigravityDisplaySettings.builtInLaneIDs,
            to: &orderedIDs
        )
        appendMissing(
            observedLanes.map(\.id),
            to: &orderedIDs
        )
        appendMissing(
            intent.hiddenLaneIDs.sorted {
                $0.rawValue.localizedStandardCompare(
                    $1.rawValue
                ) == .orderedAscending
            },
            to: &orderedIDs
        )

        return orderedIDs.map { laneID in
            let observed = observedByID[laneID]
            let known = knownDescriptor(for: laneID)
            return AntigravityLaneEditorItem(
                id: laneID,
                title: observed.map {
                    "\($0.scopeTitle) · \($0.cadenceTitle)"
                } ?? known.title,
                groupTitle:
                    observedGroupByID[laneID]
                        ?? known.groupTitle,
                isVisible:
                    !intent.hiddenLaneIDs.contains(
                        laneID
                    ),
                isAvailable:
                    observed?.value.usedPercentage
                        != nil
            )
        }
    }

    static func editorModel(
        settings: AntigravityDisplaySettings,
        presentation: AntigravityQuotaPresentation?,
        surface: ProviderDisplaySurface
    ) -> ProviderDisplayEditorModel {
        ProviderDisplayEditorModel(
            surface: surface,
            items: editorItems(
                settings: settings,
                presentation: presentation,
                surface: surface
            )
            .map { item in
                ProviderDisplayEditorItem(
                    id: item.id.rawValue,
                    title: item.title,
                    groupTitle: item.groupTitle,
                    isVisible: item.isVisible,
                    isAvailable: item.isAvailable
                )
            },
            showsGroupHeadings:
                surface == .standard,
            supportsReordering: true
        )
    }

    static func settingVisibility(
        _ isVisible: Bool,
        for laneID: AntigravityQuotaLaneID,
        surface: ProviderDisplaySurface,
        presentation: AntigravityQuotaPresentation?,
        in settings: AntigravityDisplaySettings
    ) -> AntigravityDisplaySettings {
        var updated = settings
        var intent = normalizedIntent(
            for: surface,
            presentation: presentation,
            in: updated
        )
        if isVisible {
            intent.hiddenLaneIDs.remove(laneID)
        } else {
            intent.hiddenLaneIDs.insert(laneID)
        }
        set(intent, for: surface, in: &updated)
        return updated
    }

    static func moving(
        _ laneID: AntigravityQuotaLaneID,
        offset: Int,
        surface: ProviderDisplaySurface,
        presentation: AntigravityQuotaPresentation?,
        in settings: AntigravityDisplaySettings
    ) -> AntigravityDisplaySettings {
        var updated = settings
        var intent = normalizedIntent(
            for: surface,
            presentation: presentation,
            in: updated
        )
        guard let sourceIndex =
                intent.orderedLaneIDs.firstIndex(
                    of: laneID
                )
        else {
            return settings
        }
        let targetIndex = min(
            max(0, sourceIndex + offset),
            intent.orderedLaneIDs.count - 1
        )
        guard targetIndex != sourceIndex else {
            return settings
        }
        let moved = intent.orderedLaneIDs.remove(
            at: sourceIndex
        )
        intent.orderedLaneIDs.insert(
            moved,
            at: targetIndex
        )
        intent.orderingPolicy = .manual
        set(intent, for: surface, in: &updated)
        return updated
    }

    static func settingOrderingPolicy(
        _ policy:
            AntigravityDisplaySettings.LaneOrderingPolicy,
        surface: ProviderDisplaySurface,
        presentation: AntigravityQuotaPresentation?,
        in settings: AntigravityDisplaySettings
    ) -> AntigravityDisplaySettings {
        var updated = settings
        var intent = normalizedIntent(
            for: surface,
            presentation: presentation,
            in: updated
        )
        intent.orderingPolicy = policy
        set(intent, for: surface, in: &updated)
        return updated
    }

    private static func normalizedIntent(
        for surface: ProviderDisplaySurface,
        presentation: AntigravityQuotaPresentation?,
        in settings: AntigravityDisplaySettings
    ) -> AntigravityDisplaySettings
        .LaneListPresentationIntent
    {
        var value = intent(
            for: surface,
            in: settings
        )
        let editorIDs = editorItems(
            settings: settings,
            presentation: presentation,
            surface: surface
        )
        .map(\.id)
        value.orderedLaneIDs = editorIDs
        return value
    }

    private static func intent(
        for surface: ProviderDisplaySurface,
        in settings: AntigravityDisplaySettings
    ) -> AntigravityDisplaySettings
        .LaneListPresentationIntent
    {
        switch surface {
        case .standard:
            settings.standard
        case .compact, .hover:
            settings.compact
        }
    }

    private static func set(
        _ intent:
            AntigravityDisplaySettings
                .LaneListPresentationIntent,
        for surface: ProviderDisplaySurface,
        in settings: inout AntigravityDisplaySettings
    ) {
        switch surface {
        case .standard:
            settings.standard = intent
        case .compact, .hover:
            settings.compact = intent
        }
    }

    private static func appendMissing(
        _ candidates: [AntigravityQuotaLaneID],
        to orderedIDs:
            inout [AntigravityQuotaLaneID]
    ) {
        var seen = Set(orderedIDs)
        for candidate in candidates
        where seen.insert(candidate).inserted {
            orderedIDs.append(candidate)
        }
    }

    private static func knownDescriptor(
        for laneID: AntigravityQuotaLaneID
    ) -> (title: String, groupTitle: String) {
        switch laneID {
        case .geminiFiveHour:
            ("Gemini · 5시간", "Gemini")
        case .geminiWeekly:
            ("Gemini · 주간", "Gemini")
        case .thirdPartyFiveHour:
            ("Claude · GPT · 5시간", "Claude · GPT")
        case .thirdPartyWeekly:
            ("Claude · GPT · 주간", "Claude · GPT")
        default:
            (laneID.rawValue, "기타 한도")
        }
    }
}
