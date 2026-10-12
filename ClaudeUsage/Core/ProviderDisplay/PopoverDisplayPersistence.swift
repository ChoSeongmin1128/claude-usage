import Foundation
import CoreFoundation

/// Storage/migration state of the two existing V2 surfaces, separate from catalog rendering.
@MainActor
struct PopoverSurfaceRead {
    var context: PreferencePersistenceContext
    var items: [String: [PopoverItemConfig]]
    var opaqueIDs: [String: Set<String>] = [:]
    var mirrorFallbacks: [String: [PopoverItemConfig]] = [:]
    var unresolved = false

    init(
        defaults: UserDefaults, key: String, mirrors: [String: String],
        projection: [String: [PopoverItemConfig]]
    ) {
        context = PreferencePersistenceContext(object: defaults.object(forKey: key))
        context.checkVersion(required: false)
        items = projection
        unresolved = !context.writable
        for (id, mirror) in mirrors {
            let catalog = UsageItemCatalogRegistry.all.first { $0.providerID == id }!
            var source = context.raw[id]
            var usesMirror = false
            if source == nil, context.writable, let object = defaults.object(forKey: mirror) {
                if let data = object as? Data, let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                    source = raw
                    usesMirror = true
                    context.raw[id] = raw
                } else {
                    context.unreadable.insert([id]); unresolved = true
                }
            }
            guard let source else {
                if context.unreadable.contains([id]) { context.baseline[id] = Self.json(items[id] ?? []) }
                continue
            }
            guard let rows = source as? [Any] else {
                context.unreadable.insert([id]); unresolved = true
                context.baseline[id] = Self.json(items[id] ?? [])
                continue
            }
            let read = Self.read(rows, catalog: catalog)
            opaqueIDs[id] = read.opaque
            if !usesMirror, !read.opaque.isEmpty, let data = defaults.data(forKey: mirror),
                let mirrorRows = try? JSONSerialization.jsonObject(with: data) as? [Any],
                !Self.hasUnsupportedOrderProgress(mirrorRows)
            {
                mirrorFallbacks[id] = Self.read(mirrorRows, catalog: catalog).known.filter {
                    read.opaque.contains($0.id)
                }
            }
            unresolved = unresolved || read.failed
            context.baseline[id] = Self.json(read.known)
            if usesMirror, read.failed { items[id] = catalog.normalized(read.known) }
            if !rows.isEmpty && read.known.isEmpty {
                items[id] = []
            } else {
                items[id] = (items[id] ?? []).filter { !read.opaque.contains($0.id) }
            }
            if Self.hasUnsupportedOrderProgress(rows) { context.unreadable.insert([id]); unresolved = true }
        }
        // The baseline is the effective read-only projection. Merely editing
        // another provider must not persist catalog defaults into this provider.
        context.baseline = items.mapValues(Self.json)
    }

    // Kept inside existing item JSON so older decoders retain their schema/IDs.
    // This records per-surface progress while the overall marker is incomplete.
    static let orderProgressKey = "orderMigrationVersion"
    static let orderProgressVersion = PopoverMigrationPlan.version

    static func orderWasHandled(_ rows: [Any]) -> Bool {
        rows.contains { row in
            guard let value = (row as? [String: Any])?[orderProgressKey] as? NSNumber,
                CFGetTypeID(value) != CFBooleanGetTypeID()
            else { return false }
            return value.doubleValue == Double(orderProgressVersion)
        }
    }

    static func hasUnsupportedOrderProgress(_ rows: [Any]) -> Bool {
        rows.contains { row in
            guard let value = (row as? [String: Any])?[orderProgressKey] else { return false }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return true }
            return number.doubleValue != Double(orderProgressVersion)
        }
    }

    static func markingOrderHandled(_ rows: [Any], knownIDs: Set<String>) -> [Any] {
        guard
            let index = rows.firstIndex(where: { row in
                guard let record = row as? [String: Any], let id = record["id"] as? String else { return false }
                return knownIDs.contains(id)
            }), var record = rows[index] as? [String: Any]
        else { return rows }
        var result = rows
        record[orderProgressKey] = orderProgressVersion
        result[index] = record
        return result
    }

    static func json(_ items: [PopoverItemConfig]) -> [[String: Any]] {
        items.map { ["id": $0.id, "visible": $0.visible] }
    }

    static func read(_ rows: [Any], catalog: any UsageItemCatalog)
        -> (known: [PopoverItemConfig], opaque: Set<String>, failed: Bool)
    {
        let supported = Set(catalog.supportedIDs)
        let grouped = Dictionary(grouping: rows.compactMap { ($0 as? [String: Any])?["id"] as? String }, by: { $0 })
        let duplicates = Set(grouped.filter { $0.value.count > 1 }.keys)
        var items: [PopoverItemConfig] = []
        var opaque = duplicates
        var failed = !duplicates.isEmpty
        for row in rows {
            guard let object = row as? [String: Any], let id = object["id"] as? String else {
                failed = true; continue
            }
            guard supported.contains(id) else { opaque.insert(id); continue }
            guard !duplicates.contains(id), let bytes = try? JSONSerialization.data(withJSONObject: object),
                let item = try? JSONDecoder().decode(PopoverItemConfig.self, from: bytes)
            else {
                opaque.insert(id); failed = true; continue
            }
            items.append(item)
        }
        return (items, opaque, failed)
    }

    /// Reorder only known slots. Opaque records retain their relative order and their raw fields.
    static func mergeRows(_ original: [Any], before: [PopoverItemConfig], after: [PopoverItemConfig]) -> [Any] {
        let old = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        var originals: [String: [String: Any]] = [:]
        for row in original {
            if let record = row as? [String: Any], let id = record["id"] as? String, old[id] != nil {
                originals[id] = record
            }
        }
        var queue: [Any] = after.map { item in
            let updated: [String: Any] = ["id": item.id, "visible": item.visible]
            guard let previous = old[item.id], let raw = originals[item.id] else { return updated }
            return PreservingJSONFields.replacing(
                in: raw,
                previous: ["id": previous.id, "visible": previous.visible], updated: updated)
        }
        var result: [Any] = []
        for row in original {
            if let id = (row as? [String: Any])?["id"] as? String, old[id] != nil {
                if !queue.isEmpty { result.append(queue.removeFirst()) }
            } else {
                result.append(row)
            }
        }
        return result + queue
    }

    func prepared(_ candidate: [String: [PopoverItemConfig]], forMigration: Bool = false) -> [String: Any] {
        var raw = context.raw
        for (id, items) in candidate {
            let beforeRows = context.baseline[id] as? [[String: Any]] ?? []
            let effectiveBefore = beforeRows.compactMap { row -> PopoverItemConfig? in
                guard let id = row["id"] as? String, let visible = row["visible"] as? Bool else { return nil }
                return PopoverItemConfig(id: id, visible: visible)
            }
            let original = raw[id] as? [Any] ?? []
            let catalog = UsageItemCatalogRegistry.all.first { $0.providerID == id }!
            let stored = Self.read(original, catalog: catalog)
            let needsOrderProgress = forMigration && !Self.orderWasHandled(original)
            if context.object != nil, !needsOrderProgress,
                PreferencePersistenceContext.equal(Self.json(effectiveBefore), Self.json(items))
            {
                continue
            }
            let merged = Self.mergeRows(original, before: stored.known, after: items)
            raw[id] = Self.markingOrderHandled(merged, knownIDs: Set(items.map(\.id)))
        }
        return raw
    }

    func visibleItems(_ stored: [PopoverItemConfig], for catalog: any UsageItemCatalog) -> [PopoverItemConfig] {
        if stored.isEmpty, let rows = context.raw[catalog.providerID] as? [Any], !rows.isEmpty,
            (mirrorFallbacks[catalog.providerID] ?? []).isEmpty
        {
            return []
        }
        let protectedIDs = opaqueIDs[catalog.providerID] ?? []
        let normalized = catalog.normalized(stored).filter { !protectedIDs.contains($0.id) }
        let fallback = mirrorFallbacks[catalog.providerID] ?? []
        guard !fallback.isEmpty else { return normalized }
        let values = Dictionary(uniqueKeysWithValues: (normalized + fallback).map { ($0.id, $0) })
        let storedOrder = (context.raw[catalog.providerID] as? [Any] ?? []).compactMap {
            ($0 as? [String: Any])?["id"] as? String
        }
        var used = Set<String>()
        let ordered = (storedOrder + (normalized + fallback).map(\.id)).compactMap { id -> PopoverItemConfig? in
            guard used.insert(id).inserted else { return nil }
            return values[id]
        }
        return ordered
    }

}

@MainActor
struct PopoverMigrationPlan {
    static let version = 5
    struct Write { let key: String; let previous: Any?; let data: Data }
    let writes: [Write]
    let oldMarker: Any?
    let blocked: Bool
    static let markerKey = "popoverItemsMigrationVersion"
    static let fullKey = "popoverItemsV2"
    static let compactKey = "compactPopoverItemsV2"
    static let fullMirrors = ["claude": "popoverItems", "codex": "codexPopoverItems"]
    static let compactMirrors = ["claude": "compactPopoverItems", "codex": "codexCompactPopoverItems"]
    static var snapshotKeys: [String] {
        [fullKey, compactKey, markerKey, "separateCompactConfig"] + Array(fullMirrors.values)
            + Array(compactMirrors.values)
    }

    init(full: PopoverSurfaceRead, compact: PopoverSurfaceRead, defaults: UserDefaults) {
        oldMarker = defaults.object(forKey: Self.markerKey)
        if let marker = oldMarker {
            guard let number = marker as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue == Double(number.intValue), number.intValue >= 0
            else {
                writes = []; blocked = true; return
            }
        }
        var planned: [Write] = []
        var incomplete = full.unresolved || compact.unresolved
        for (surface, key, mirrors) in [
            (full, Self.fullKey, Self.fullMirrors),
            (compact, Self.compactKey, Self.compactMirrors),
        ] {
            guard surface.context.writable else { incomplete = true; continue }
            var updated = surface.prepared(surface.items, forMigration: true)
            // A failed provider is a fallback projection, never a default to persist.
            for path in surface.context.unreadable where path.count == 1 {
                updated[path[0]] = surface.context.raw[path[0]]
            }
            if let data = try? JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys]) {
                planned.append(Write(key: key, previous: surface.context.object, data: data))
            } else {
                incomplete = true
            }
            for (id, mirrorKey) in mirrors {
                guard !surface.context.unreadable.contains([id]) else { incomplete = true; continue }
                let previous = defaults.object(forKey: mirrorKey)
                let output: [Any]
                if let previous {
                    guard let data = previous as? Data,
                        let rows = try? JSONSerialization.jsonObject(with: data) as? [Any]
                    else {
                        incomplete = true; continue
                    }
                    guard !PopoverSurfaceRead.hasUnsupportedOrderProgress(rows) else {
                        incomplete = true; continue
                    }
                    let catalog = UsageItemCatalogRegistry.all.first { $0.providerID == id }!
                    let read = PopoverSurfaceRead.read(rows, catalog: catalog)
                    incomplete = incomplete || read.failed
                    let protectedIDs = read.opaque.union(surface.opaqueIDs[id] ?? [])
                    let merged = PopoverSurfaceRead.mergeRows(
                        rows, before: read.known.filter { !protectedIDs.contains($0.id) },
                        after: (surface.items[id] ?? []).filter { !protectedIDs.contains($0.id) })
                    output = PopoverSurfaceRead.markingOrderHandled(
                        merged,
                        knownIDs: Set((surface.items[id] ?? []).filter { !protectedIDs.contains($0.id) }.map(\.id)))
                } else {
                    output = updated[id] as? [Any] ?? []
                }
                if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) {
                    planned.append(Write(key: mirrorKey, previous: previous, data: data))
                } else {
                    incomplete = true
                }
            }
        }
        writes = planned
        blocked = incomplete
    }

    func commit(to defaults: UserDefaults) -> PreferenceSaveResult {
        guard PreferencePersistenceContext.equal(defaults.object(forKey: Self.markerKey), oldMarker) else {
            return .blocked("표시 설정이 변경되어 이전하지 않았습니다.")
        }
        var failed = false
        for write in writes {
            guard PreferencePersistenceContext.equal(defaults.object(forKey: write.key), write.previous) else {
                failed = true; continue
            }
            defaults.set(write.data, forKey: write.key)
            if defaults.data(forKey: write.key) != write.data { failed = true }
        }
        guard !failed else { return .failed("표시 설정 이전을 저장하지 못했습니다.") }
        guard !blocked else { return .blocked("읽을 수 없는 표시 설정의 원문과 이전 상태를 유지했습니다.") }
        defaults.set(Self.version, forKey: Self.markerKey)
        guard defaults.object(forKey: Self.markerKey) as? Int == Self.version else {
            PreferencePersistenceContext.restore(oldMarker, to: defaults, key: Self.markerKey)
            return .failed("표시 설정 이전을 저장하지 못했습니다.")
        }
        return .saved
    }
}
