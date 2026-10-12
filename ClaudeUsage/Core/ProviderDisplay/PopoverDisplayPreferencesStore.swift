import CoreFoundation
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
    private static let currentMigrationVersion = PopoverMigrationPlan.version

    private static let legacyClaudeFullKey =
        "popoverItems"
    private static let legacyClaudeCompactKey =
        "compactPopoverItems"
    private static let legacyCodexFullKey =
        "codexPopoverItems"
    private static let legacyCodexCompactKey =
        "codexCompactPopoverItems"

    private let defaults: UserDefaults
    private let hoverPreferences: PopoverHoverPreferences
    private var fullRead: PopoverSurfaceRead!
    private var compactRead: PopoverSurfaceRead!
    private(set) var lastSaveResult: PreferenceSaveResult = .unchanged
    struct Snapshot { let objects: [String: Any] }

    private(set) var fullItemsByProvider: [String: [PopoverItemConfig]] = [:]
    private(set) var compactItemsByProvider: [String: [PopoverItemConfig]] = [:]
    private(set) var usesSeparateCompactItems = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        hoverPreferences = PopoverHoverPreferences(defaults: defaults)
        reload()
        if defaults.integer(forKey: Self.migrationVersionKey) < Self.currentMigrationVersion {
            let plan = PopoverMigrationPlan(full: fullRead, compact: compactRead, defaults: defaults)
            lastSaveResult = plan.commit(to: defaults)
            reload()
        }
    }

    private func reload() {
        let loaded = Self.load(from: defaults)
        fullRead = PopoverSurfaceRead(
            defaults: defaults, key: Self.fullItemsKey,
            mirrors: PopoverMigrationPlan.fullMirrors, projection: loaded.full)
        compactRead = PopoverSurfaceRead(
            defaults: defaults, key: Self.compactItemsKey,
            mirrors: PopoverMigrationPlan.compactMirrors, projection: loaded.compact)
        fullItemsByProvider = fullRead.items
        compactItemsByProvider = compactRead.items
        if let marker = defaults.object(forKey: Self.migrationVersionKey) {
            if let number = marker as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue == Double(number.intValue),
                (0...Self.currentMigrationVersion).contains(number.intValue)
            {
                // Known migration state; each root retains its own protection.
            } else {
                fullRead.context.writable = false
                compactRead.context.writable = false
            }
        }
        usesSeparateCompactItems = defaults.object(forKey: "separateCompactConfig") as? Bool ?? false
    }

    func snapshot() -> Snapshot {
        Snapshot(
            objects: Dictionary(
                uniqueKeysWithValues: PopoverMigrationPlan.snapshotKeys.compactMap { key in
                    defaults.object(forKey: key).map { (key, $0) }
                }))
    }

    func restore(_ snapshot: Snapshot) {
        for key in PopoverMigrationPlan.snapshotKeys {
            PreferencePersistenceContext.restore(snapshot.objects[key], to: defaults, key: key)
        }
        reload()
    }

    func restoreKnownDefaults() {
        func readableDefaults(_ read: PopoverSurfaceRead) -> [String: [PopoverItemConfig]] {
            var candidate = read.items
            for catalog in UsageItemCatalogRegistry.all where read.context.canChange([catalog.providerID]) {
                candidate[catalog.providerID] = catalog.defaultItems.filter {
                    !(read.opaqueIDs[catalog.providerID] ?? []).contains($0.id)
                }
            }
            return candidate
        }
        _ = setFullItemsByProvider(readableDefaults(fullRead))
        _ = setCompactItemsByProvider(readableDefaults(compactRead))
    }

    @discardableResult
    func setFullItemsByProvider(_ value: [String: [PopoverItemConfig]]) -> PreferenceSaveResult {
        saveSurface(value, compact: false)
    }

    @discardableResult
    func setCompactItemsByProvider(
        _ value: [String: [PopoverItemConfig]],
        fallback: [String: [PopoverItemConfig]]? = nil
    ) -> PreferenceSaveResult {
        saveSurface(value, compact: true)
    }

    private func saveSurface(_ value: [String: [PopoverItemConfig]], compact: Bool) -> PreferenceSaveResult {
        var read = compact ? compactRead! : fullRead!
        var candidate = Self.normalized(value)
        for (id, fallback) in read.mirrorFallbacks {
            let catalog = UsageItemCatalogRegistry.all.first { $0.providerID == id }!
            let currentOrder = read.visibleItems(read.items[id] ?? [], for: catalog).map(\.id)
            let proposedOrder = (value[id] ?? []).map(\.id)
            for item in value[id] ?? [] {
                if let current = fallback.first(where: { $0.id == item.id }),
                    current != item || currentOrder.firstIndex(of: item.id) != proposedOrder.firstIndex(of: item.id)
                {
                    let result = PreferenceSaveResult.blocked("읽을 수 없는 표시 항목은 변경하지 않고 이전 설정을 유지했습니다.")
                    lastSaveResult = result
                    return result
                }
            }
        }
        for catalog in UsageItemCatalogRegistry.all {
            let id = catalog.providerID
            if value[id]?.isEmpty == true, let raw = read.context.raw[id] as? [Any], !raw.isEmpty {
                candidate[id] = []
            } else {
                candidate[id]?.removeAll { (read.opaqueIDs[id] ?? []).contains($0.id) }
            }
        }
        let known: [String: Any] = candidate.mapValues(PopoverSurfaceRead.json)
        let changedProviders = Set(
            candidate.keys.filter {
                !PreferencePersistenceContext.equal(read.context.baseline[$0], known[$0])
            })
        let prepared = read.prepared(candidate)
        let key = compact ? Self.compactItemsKey : Self.fullItemsKey
        let mirrors = compact ? PopoverMigrationPlan.compactMirrors : PopoverMigrationPlan.fullMirrors
        let previous = snapshot()
        let result = read.context.save(known, to: defaults, key: key, preparedRaw: prepared)
        guard result.accepted else { lastSaveResult = result; return result }
        for (id, mirrorKey) in mirrors where changedProviders.contains(id) {
            guard !read.context.unreadable.contains([id]) else { continue }
            let object = defaults.object(forKey: mirrorKey)
            let output: [Any]
            if let object {
                guard let data = object as? Data,
                    let rows = try? JSONSerialization.jsonObject(with: data) as? [Any]
                else { continue }
                let catalog = UsageItemCatalogRegistry.all.first { $0.providerID == id }!
                guard !PopoverSurfaceRead.hasUnsupportedOrderProgress(rows) else {
                    restore(previous)
                    lastSaveResult = .blocked("지원하지 않는 표시 이전 정보의 원문을 유지했습니다.")
                    return lastSaveResult
                }
                let old = PopoverSurfaceRead.read(rows, catalog: catalog)
                let protectedIDs = old.opaque.union(read.opaqueIDs[id] ?? [])
                let merged = PopoverSurfaceRead.mergeRows(
                    rows, before: old.known.filter { !protectedIDs.contains($0.id) },
                    after: (candidate[id] ?? []).filter { !protectedIDs.contains($0.id) })
                output = PopoverSurfaceRead.markingOrderHandled(
                    merged,
                    knownIDs: Set((candidate[id] ?? []).filter { !protectedIDs.contains($0.id) }.map(\.id)))
            } else {
                output = prepared[id] as? [Any] ?? []
            }
            guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) else {
                restore(previous); lastSaveResult = .failed("표시 설정을 저장하지 못했습니다."); return lastSaveResult
            }
            defaults.set(data, forKey: mirrorKey)
            guard defaults.data(forKey: mirrorKey) == data else {
                restore(previous); lastSaveResult = .failed("표시 설정을 저장하지 못했습니다."); return lastSaveResult
            }
        }
        read.items = candidate
        if compact {
            compactRead = read; compactItemsByProvider = candidate
        } else {
            fullRead = read; fullItemsByProvider = candidate
        }
        lastSaveResult = result
        return result
    }

    private func effectiveFullDictionary() -> [String: [PopoverItemConfig]] {
        var result: [String: [PopoverItemConfig]] = [:]
        for catalog in UsageItemCatalogRegistry.all {
            guard let service = PopoverService(rawValue: catalog.providerID) else { continue }
            let current = items(for: service, surface: .standard)
            result[catalog.providerID] =
                current.isEmpty
                ? catalog.defaultItems.map { PopoverItemConfig(id: $0.id, visible: false) } : current
        }
        return result
    }

    @discardableResult
    func setUsesSeparateCompactItems(_ value: Bool, copyCurrentItems: Bool = true) -> PreferenceSaveResult {
        let oldFlag = defaults.object(forKey: "separateCompactConfig")
        if let oldFlag {
            guard let flag = oldFlag as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                return .blocked("저장된 간소화 설정을 읽을 수 없어 변경하지 않았습니다.")
            }
        }
        guard value != usesSeparateCompactItems else { return .unchanged }
        let previous = snapshot()
        if value, copyCurrentItems {
            let result = setCompactItemsByProvider(effectiveFullDictionary())
            guard result.accepted else { return result }
        }
        defaults.set(value, forKey: "separateCompactConfig")
        guard defaults.object(forKey: "separateCompactConfig") as? Bool == value else {
            restore(previous)
            return .failed("간소화 설정을 저장하지 못했습니다.")
        }
        usesSeparateCompactItems = value
        lastSaveResult = .saved
        return .saved
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
            return fullRead.visibleItems(fullItemsByProvider[service.rawValue] ?? catalog.defaultItems, for: catalog)
        case .hover:
            return hoverPreferences.items(for: catalog)
        case .compact:
            let stored =
                compactItemsByProvider[
                    service.rawValue
                ]
                ?? fullItemsByProvider[
                    service.rawValue
                ]
                ?? catalog.defaultItems
            return compactRead.visibleItems(stored, for: catalog)
        }
    }

    func setItems(
        _ items: [PopoverItemConfig],
        for service: PopoverService,
        surface: ProviderDisplaySurface
    ) throws {
        guard let catalog =
                UsageItemCatalogRegistry.catalog(
                    for: service
                )
        else {
            return
        }
        let normalized = catalog.normalized(items)

        switch surface {
        case .hover:
            try hoverPreferences.setItems(items, for: catalog)
        case .standard:
            var value = fullItemsByProvider
            value[service.rawValue] = normalized
            let result = setFullItemsByProvider(value)
            if let message = result.message {
                throw NSError(
                    domain: "PopoverDisplayPreferences", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message])
            }
        case .compact:
            let previous = snapshot()
            var value = usesSeparateCompactItems ? compactItemsByProvider : effectiveFullDictionary()
            value[service.rawValue] = normalized
            let result = setCompactItemsByProvider(value)
            guard result.accepted else {
                throw NSError(
                    domain: "PopoverDisplayPreferences", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: result.message ?? "표시 설정을 저장하지 못했습니다."])
            }
            let flagResult = setUsesSeparateCompactItems(true, copyCurrentItems: false)
            if let message = flagResult.message {
                restore(previous)
                throw NSError(
                    domain: "PopoverDisplayPreferences", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
    }

    func setHoverItems(_ items: [PopoverItemConfig], for service: PopoverService) throws {
        guard let catalog = UsageItemCatalogRegistry.catalog(for: service) else { return }
        try hoverPreferences.setItems(items, for: catalog)
    }

    func hoverSnapshot() -> PopoverHoverPreferences.Snapshot { hoverPreferences.snapshot() }
    func restoreHover(_ snapshot: PopoverHoverPreferences.Snapshot) { hoverPreferences.restore(snapshot) }
    func restoreHoverDefaults() { hoverPreferences.restoreDefaults() }

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
        let migrateDefaultOrder = defaults.integer(forKey: migrationVersionKey) < currentMigrationVersion
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
            full[key] = reconciledItems(
                currentFull?[key] ?? legacyFull ?? catalog.defaultItems,
                catalog: catalog,
                migrateDefaultOrder: migrateDefaultOrder
                    && !orderWasHandled(in: defaults, key: fullItemsKey, provider: key))
            compact[key] = reconciledItems(
                currentCompact?[key] ?? legacyCompact ?? full[key]!,
                catalog: catalog,
                migrateDefaultOrder: migrateDefaultOrder
                    && !orderWasHandled(in: defaults, key: compactItemsKey, provider: key))
        }

        return (full, compact)
    }

    private static func orderWasHandled(in defaults: UserDefaults, key: String, provider: String) -> Bool {
        if let data = defaults.data(forKey: key),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = root[provider] as? [Any]
        {
            return PopoverSurfaceRead.orderWasHandled(rows)
        }
        let mirrors = key == Self.fullItemsKey ? PopoverMigrationPlan.fullMirrors : PopoverMigrationPlan.compactMirrors
        guard let mirror = mirrors[provider], let data = defaults.data(forKey: mirror),
            let rows = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return false }
        return PopoverSurfaceRead.orderWasHandled(rows)
    }

    /// 기존 기본 순서로 저장된 목록만 한 번 옮긴다. 이후 사용자 재정렬은 normalized만 적용한다.
    private static func reconciledItems(
        _ items: [PopoverItemConfig], catalog: any UsageItemCatalog, migrateDefaultOrder: Bool
    ) -> [PopoverItemConfig] {
        let normalized = catalog.normalized(items)
        guard migrateDefaultOrder else { return normalized }
        let knownDefaultOrders: [[String]]
        switch catalog.providerID {
        case PopoverService.claude.rawValue:
            knownDefaultOrders = [
                ["currentSession", "weeklyLimit", "modelUsage", "claudeResetCredits", "overageUsage"]
            ]
        case PopoverService.codex.rawValue:
            knownDefaultOrders = [
                ["codexPrimary", "codexSecondary", "codexModelLimits", "codexResetCredits", "codexCredits"],
                [
                    "codexPrimary", "codexSecondary", "codexSpendLimit", "codexModelLimits", "codexResetCredits",
                    "codexCredits",
                ],
            ]
        default:
            return normalized
        }
        let storedIDs = Set(items.map(\.id))
        let storedOrder = normalized.filter { storedIDs.contains($0.id) }.map(\.id)
        guard knownDefaultOrders.contains(storedOrder) else { return normalized }
        let byID = Dictionary(uniqueKeysWithValues: normalized.map { ($0.id, $0) })
        return catalog.defaultItems.compactMap { byID[$0.id] }
    }

    @discardableResult
    static func persistFull(_ value: [String: [PopoverItemConfig]], to defaults: UserDefaults) -> PreferenceSaveResult {
        PopoverDisplayPreferencesStore(defaults: defaults).setFullItemsByProvider(value)
    }

    @discardableResult
    static func persistCompact(_ value: [String: [PopoverItemConfig]], to defaults: UserDefaults)
        -> PreferenceSaveResult
    {
        PopoverDisplayPreferencesStore(defaults: defaults).setCompactItemsByProvider(value)
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
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var result: [String: [PopoverItemConfig]] = [:]
        for (id, value) in root {
            guard let rows = value as? [Any] else { continue }
            result[id] = rows.compactMap { row in
                guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.fragmentsAllowed]) else {
                    return nil
                }
                return try? JSONDecoder().decode(PopoverItemConfig.self, from: data)
            }
        }
        return result
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
