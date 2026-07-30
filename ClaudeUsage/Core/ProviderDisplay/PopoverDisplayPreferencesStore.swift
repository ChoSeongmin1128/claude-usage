import Foundation

/// Claude/Codex의 정적 catalog 기반 popover 표시 설정을 단독으로
/// 소유한다. Antigravity의 동적 lane 설정은
/// `AntigravitySettingsStore`만이 소유한다.
@MainActor
final class PopoverDisplayPreferencesStore {
    private static let fullItemsKey =
        "popoverItemsV2"
    private static let compactItemsKey =
        "compactPopoverItemsV2"
    private static let migrationVersionKey =
        "popoverItemsMigrationVersion"
    private static let currentMigrationVersion = 4

    private static let legacyClaudeFullKey =
        "popoverItems"
    private static let legacyClaudeCompactKey =
        "compactPopoverItems"
    private static let legacyCodexFullKey =
        "codexPopoverItems"
    private static let legacyCodexCompactKey =
        "codexCompactPopoverItems"

    private let defaults: UserDefaults

    private(set) var fullItemsByProvider:
        [String: [PopoverItemConfig]]
    private(set) var compactItemsByProvider:
        [String: [PopoverItemConfig]]
    private(set) var usesSeparateCompactItems: Bool

    init(defaults: UserDefaults) {
        self.defaults = defaults
        usesSeparateCompactItems =
            defaults.object(
                forKey: "separateCompactConfig"
            ) as? Bool ?? false

        let loaded = Self.load(from: defaults)
        fullItemsByProvider = loaded.full
        compactItemsByProvider = loaded.compact

        if defaults.integer(
            forKey: Self.migrationVersionKey
        ) < Self.currentMigrationVersion {
            Self.persistFull(
                loaded.full,
                to: defaults
            )
            Self.persistCompact(
                loaded.compact,
                to: defaults
            )
            defaults.set(
                Self.currentMigrationVersion,
                forKey: Self.migrationVersionKey
            )
        }
    }

    func setFullItemsByProvider(
        _ value: [String: [PopoverItemConfig]]
    ) {
        let normalized = Self.normalized(value)
        fullItemsByProvider = normalized
        Self.persistFull(normalized, to: defaults)
    }

    func setCompactItemsByProvider(
        _ value: [String: [PopoverItemConfig]],
        fallback:
            [String: [PopoverItemConfig]]? = nil
    ) {
        let normalized = Self.normalized(
            value,
            fallback: fallback
        )
        compactItemsByProvider = normalized
        Self.persistCompact(
            normalized,
            to: defaults
        )
    }

    func setUsesSeparateCompactItems(
        _ value: Bool
    ) {
        let wasSeparate = usesSeparateCompactItems
        usesSeparateCompactItems = value
        defaults.set(
            value,
            forKey: "separateCompactConfig"
        )

        if value,
           !wasSeparate,
           compactItemsByProvider
            == fullItemsByProvider
        {
            setCompactItemsByProvider(
                fullItemsByProvider
            )
        }
    }

    func items(
        for service: PopoverService,
        surface: ProviderDisplaySurface
    ) -> [PopoverItemConfig] {
        guard let catalog =
                UsageItemCatalogRegistry.catalog(
                    for: service
                )
        else {
            return []
        }

        switch surface {
        case .standard:
            return catalog.normalized(
                fullItemsByProvider[
                    service.rawValue
                ] ?? catalog.defaultItems
            )
        case .compact:
            let stored =
                compactItemsByProvider[
                    service.rawValue
                ]
                ?? fullItemsByProvider[
                    service.rawValue
                ]
                ?? catalog.defaultItems
            return catalog.normalized(stored)
        }
    }

    func setItems(
        _ items: [PopoverItemConfig],
        for service: PopoverService,
        surface: ProviderDisplaySurface
    ) {
        guard let catalog =
                UsageItemCatalogRegistry.catalog(
                    for: service
                )
        else {
            return
        }
        let normalized = catalog.normalized(items)

        switch surface {
        case .standard:
            var value = fullItemsByProvider
            value[service.rawValue] = normalized
            setFullItemsByProvider(value)
        case .compact:
            var value = compactItemsByProvider
            value[service.rawValue] = normalized
            setCompactItemsByProvider(value)
        }
    }

    static func defaultsDictionary()
        -> [String: [PopoverItemConfig]]
    {
        var value:
            [String: [PopoverItemConfig]] = [:]
        for catalog in UsageItemCatalogRegistry.all {
            value[catalog.providerID] =
                catalog.defaultItems
        }
        return value
    }

    static func normalized(
        _ value: [String: [PopoverItemConfig]],
        fallback:
            [String: [PopoverItemConfig]]? = nil
    ) -> [String: [PopoverItemConfig]] {
        var result:
            [String: [PopoverItemConfig]] = [:]
        for catalog in UsageItemCatalogRegistry.all {
            let raw =
                value[catalog.providerID]
                ?? fallback?[catalog.providerID]
                ?? catalog.defaultItems
            result[catalog.providerID] =
                catalog.normalized(raw)
        }
        return result
    }

    static func load(
        from defaults: UserDefaults
    ) -> (
        full: [String: [PopoverItemConfig]],
        compact: [String: [PopoverItemConfig]]
    ) {
        let currentFull = decodeDictionary(
            defaults.data(forKey: fullItemsKey)
        )
        let currentCompact = decodeDictionary(
            defaults.data(
                forKey: compactItemsKey
            )
        )
        let legacyClaudeFull = decodeArray(
            defaults.data(
                forKey: legacyClaudeFullKey
            )
        )
        let legacyClaudeCompact = decodeArray(
            defaults.data(
                forKey: legacyClaudeCompactKey
            )
        )
        let legacyCodexFull = decodeArray(
            defaults.data(
                forKey: legacyCodexFullKey
            )
        )
        let legacyCodexCompact = decodeArray(
            defaults.data(
                forKey: legacyCodexCompactKey
            )
        )
        let resolvedClaudeFull =
            legacyClaudeFull
            ?? migrateClaudeLegacyFlags(
                from: defaults
            )

        var full:
            [String: [PopoverItemConfig]] = [:]
        var compact:
            [String: [PopoverItemConfig]] = [:]

        for catalog in UsageItemCatalogRegistry.all {
            guard let service = PopoverService(
                rawValue: catalog.providerID
            ) else {
                continue
            }

            let legacyFull:
                [PopoverItemConfig]?
            let legacyCompact:
                [PopoverItemConfig]?
            switch service {
            case .claude:
                legacyFull = resolvedClaudeFull
                legacyCompact =
                    legacyClaudeCompact
            case .codex:
                legacyFull = legacyCodexFull
                legacyCompact =
                    legacyCodexCompact
            case .antigravity:
                continue
            }

            let key = service.rawValue
            full[key] = catalog.normalized(
                currentFull?[key]
                    ?? legacyFull
                    ?? catalog.defaultItems
            )
            compact[key] = catalog.normalized(
                currentCompact?[key]
                    ?? legacyCompact
                    ?? full[key]!
            )
        }

        return (full, compact)
    }

    static func persistFull(
        _ value: [String: [PopoverItemConfig]],
        to defaults: UserDefaults
    ) {
        if let data = try? JSONEncoder().encode(
            value
        ) {
            defaults.set(data, forKey: fullItemsKey)
        }
        if let claude = value[
            PopoverService.claude.rawValue
        ],
        let data = try? JSONEncoder().encode(claude)
        {
            defaults.set(
                data,
                forKey: legacyClaudeFullKey
            )
        }
        if let codex = value[
            PopoverService.codex.rawValue
        ],
        let data = try? JSONEncoder().encode(codex)
        {
            defaults.set(
                data,
                forKey: legacyCodexFullKey
            )
        }
    }

    static func persistCompact(
        _ value: [String: [PopoverItemConfig]],
        to defaults: UserDefaults
    ) {
        if let data = try? JSONEncoder().encode(
            value
        ) {
            defaults.set(
                data,
                forKey: compactItemsKey
            )
        }
        if let claude = value[
            PopoverService.claude.rawValue
        ],
        let data = try? JSONEncoder().encode(claude)
        {
            defaults.set(
                data,
                forKey: legacyClaudeCompactKey
            )
        }
        if let codex = value[
            PopoverService.codex.rawValue
        ],
        let data = try? JSONEncoder().encode(codex)
        {
            defaults.set(
                data,
                forKey: legacyCodexCompactKey
            )
        }
    }

    private static func migrateClaudeLegacyFlags(
        from defaults: UserDefaults
    ) -> [PopoverItemConfig]? {
        let hasModel =
            defaults.object(
                forKey: "showModelUsage"
            ) != nil
        let hasOverage =
            defaults.object(
                forKey: "showOverageUsage"
            ) != nil
        guard hasModel || hasOverage else {
            return nil
        }

        let showModel =
            defaults.object(
                forKey: "showModelUsage"
            ) as? Bool ?? true
        let showOverage =
            defaults.object(
                forKey: "showOverageUsage"
            ) as? Bool ?? true
        return [
            PopoverItemConfig(
                id: "currentSession",
                visible: true
            ),
            PopoverItemConfig(
                id: "weeklyLimit",
                visible: true
            ),
            PopoverItemConfig(
                id: "modelUsage",
                visible: showModel
            ),
            PopoverItemConfig(
                id: "overageUsage",
                visible: showOverage
            ),
        ]
    }

    private static func decodeDictionary(
        _ data: Data?
    ) -> [String: [PopoverItemConfig]]? {
        guard let data else {
            return nil
        }
        return try? JSONDecoder().decode(
            [String: [PopoverItemConfig]].self,
            from: data
        )
    }

    private static func decodeArray(
        _ data: Data?
    ) -> [PopoverItemConfig]? {
        guard let data else {
            return nil
        }
        return try? JSONDecoder().decode(
            [PopoverItemConfig].self,
            from: data
        )
    }
}
