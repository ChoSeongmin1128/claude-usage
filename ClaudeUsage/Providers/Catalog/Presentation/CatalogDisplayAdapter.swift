import Foundation

@MainActor
enum CatalogDisplayAdapter {
    static func editorModel(
        service: PopoverService,
        surface: ProviderDisplaySurface,
        settings: AppSettings,
        unavailableItemIDs: Set<String> = [],
        codexUsage: CodexUsageResponse? = nil
    ) -> ProviderDisplayEditorModel? {
        guard UsageItemCatalogRegistry.catalog(
            for: service
        ) != nil else {
            return nil
        }

        let storedItems =
            switch surface {
        case .standard:
            settings.popoverItems(for: service)
        case .compact:
            settings.compactPopoverItems(
                for: service
            )
        }

        let items =
            service == .codex
            ? CodexItemCatalog().settingsItems(from: storedItems, usage: codexUsage) : storedItems

        return ProviderDisplayEditorModel(
            surface: surface,
            items: items.map { item in
                ProviderDisplayEditorItem(
                    id: item.id,
                    title: item.displayName,
                    groupTitle: nil,
                    isVisible: item.visible,
                    isAvailable:
                        service == .codex || !unavailableItemIDs.contains(item.id)
                )
            },
            showsGroupHeadings: false,
            supportsReordering: true
        )
    }

    static func moveItems(
        _ stored: [PopoverItemConfig], sourceID: String, offset: Int, projectedIDs: [String]
    ) -> [PopoverItemConfig] {
        guard let sourceIndex = projectedIDs.firstIndex(of: sourceID),
            projectedIDs.indices.contains(sourceIndex + offset)
        else { return stored }
        return moveItems(
            stored, sourceID: sourceID, targetID: projectedIDs[sourceIndex + offset], projectedIDs: projectedIDs)
    }

    static func moveItems(
        _ stored: [PopoverItemConfig], sourceID: String, targetID: String, projectedIDs: [String]
    ) -> [PopoverItemConfig] {
        guard let sourceIndex = projectedIDs.firstIndex(of: sourceID),
            let targetIndex = projectedIDs.firstIndex(of: targetID), sourceIndex != targetIndex
        else { return stored }
        var orderedIDs = projectedIDs
        let moved = orderedIDs.remove(at: sourceIndex)
        orderedIDs.insert(moved, at: targetIndex)
        let projectedSet = Set(projectedIDs)
        let positions = stored.indices.filter { projectedSet.contains(stored[$0].id) }
        guard positions.count == orderedIDs.count, projectedSet.count == orderedIDs.count else { return stored }
        let byID = Dictionary(uniqueKeysWithValues: positions.map { (stored[$0].id, stored[$0]) })
        var result = stored
        for (position, id) in zip(positions, orderedIDs) {
            guard let item = byID[id] else { return stored }
            result[position] = item
        }
        return result
    }
}
