import Foundation

@MainActor
enum CatalogDisplayAdapter {
    static func editorModel(
        service: PopoverService,
        surface: ProviderDisplaySurface,
        settings: AppSettings,
        unavailableItemIDs: Set<String> = []
    ) -> ProviderDisplayEditorModel? {
        guard UsageItemCatalogRegistry.catalog(
            for: service
        ) != nil else {
            return nil
        }

        let items = switch surface {
        case .standard:
            settings.popoverItems(for: service)
        case .compact:
            settings.compactPopoverItems(
                for: service
            )
        }

        return ProviderDisplayEditorModel(
            surface: surface,
            items: items.map { item in
                ProviderDisplayEditorItem(
                    id: item.id,
                    title: item.displayName,
                    groupTitle: nil,
                    isVisible: item.visible,
                    isAvailable:
                        !unavailableItemIDs
                            .contains(item.id)
                )
            },
            showsGroupHeadings: false,
            supportsReordering: true
        )
    }
}
