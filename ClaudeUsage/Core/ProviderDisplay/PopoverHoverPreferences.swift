import CoreFoundation
import Foundation

nonisolated enum HoverDisplayPreferencesError: Error, Equatable, Sendable {
    case unreadableStorage, changedElsewhere, writeFailed

    var message: String {
        switch self {
        case .unreadableStorage: "저장된 호버 설정을 읽을 수 없어 변경하지 않았습니다."
        case .changedElsewhere: "호버 설정이 다른 곳에서 변경되었습니다. 다시 확인해 주세요."
        case .writeFailed: "호버 표시 항목을 저장하지 못했습니다."
        }
    }
}

@MainActor
final class PopoverHoverPreferences {
    nonisolated static let key = AppIdentifiers.defaultsKey("hoverDisplayPreferences.v1")
    struct Snapshot { let object: Any? }
    private let defaults: UserDefaults
    private var storedObject: Any?
    private var root: [String: Any]?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        reload()
    }

    func items(for catalog: any UsageItemCatalog) -> [PopoverItemConfig] {
        guard let raw = (root?["providers"] as? [String: Any])?[catalog.providerID] else {
            return catalog.defaultHoverItems
        }
        guard let loaded = decoded(raw, catalog: catalog) else { return catalog.defaultHoverItems }
        return normalized(loaded.elements, catalog: catalog)
    }

    func setItems(_ items: [PopoverItemConfig], for catalog: any UsageItemCatalog) throws {
        guard let root, var providers = root["providers"] as? [String: Any] else {
            throw HoverDisplayPreferencesError.unreadableStorage
        }
        let unreadable: [Any]
        if let raw = providers[catalog.providerID] {
            guard let loaded = decoded(raw, catalog: catalog) else {
                throw HoverDisplayPreferencesError.unreadableStorage
            }
            unreadable = loaded.unreadable
        } else {
            unreadable = []
        }
        let array = encodedItems(
            normalized(items, catalog: catalog), raw: providers[catalog.providerID], preserving: unreadable)
        providers[catalog.providerID] = array
        var updated = root
        updated["providers"] = providers
        try save(updated)
    }

    // Reset only our known providers. Future fields and unreadable records survive.
    func restoreDefaults() {
        guard let root, var providers = root["providers"] as? [String: Any] else { return }
        for catalog in UsageItemCatalogRegistry.all {
            let unreadable: [Any]
            if let raw = providers[catalog.providerID] {
                guard let loaded = decoded(raw, catalog: catalog) else { continue }
                unreadable = loaded.unreadable
            } else {
                continue
            }
            let array = encodedItems(
                catalog.defaultHoverItems, raw: providers[catalog.providerID], preserving: unreadable)
            providers[catalog.providerID] = array
        }
        var updated = root
        updated["providers"] = providers
        guard storedObject != nil else { return }
        try? save(updated)
    }

    func snapshot() -> Snapshot { Snapshot(object: defaults.object(forKey: Self.key)) }

    func restore(_ snapshot: Snapshot) {
        if let object = snapshot.object {
            defaults.set(object, forKey: Self.key)
        } else {
            defaults.removeObject(forKey: Self.key)
        }
        reload()
    }

    private func reload() {
        storedObject = defaults.object(forKey: Self.key)
        if storedObject == nil {
            root = ["version": 1, "providers": [:]]
            return
        }
        guard let data = storedObject as? Data,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = object["version"] as? NSNumber,
            CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
            object["providers"] is [String: Any]
        else { root = nil; return }
        root = object
    }

    private func encodedItems(_ items: [PopoverItemConfig], raw: Any?, preserving unreadable: [Any]) -> [Any] {
        var originals: [String: [String: Any]] = [:]
        for object in raw as? [Any] ?? [] {
            guard let record = object as? [String: Any],
                let data = try? JSONSerialization.data(withJSONObject: record),
                let item = try? JSONDecoder().decode(PopoverItemConfig.self, from: data), originals[item.id] == nil
            else { continue }
            originals[item.id] = record
        }
        return items.map { item -> Any in
            var record = originals[item.id] ?? [:]
            record["id"] = item.id
            record["visible"] = item.visible
            return record
        } + unreadable
    }

    private func decoded(_ raw: Any, catalog: any UsageItemCatalog) -> PreservingJSONArray.Decoded<PopoverItemConfig>? {
        guard raw is [Any], let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        let supported = Set(catalog.supportedIDs)
        var seen = Set<String>()
        return PreservingJSONArray.decode(
            PopoverItemConfig.self, from: data,
            accepting: {
                supported.contains($0.id) && seen.insert($0.id).inserted
            })
    }

    private func normalized(_ items: [PopoverItemConfig], catalog: any UsageItemCatalog) -> [PopoverItemConfig] {
        let storedIDs = Set(items.map(\.id))
        return catalog.normalized(items).map { item in
            PopoverItemConfig(id: item.id, visible: storedIDs.contains(item.id) && item.visible)
        }
    }

    private func save(_ root: [String: Any]) throws {
        let current = defaults.object(forKey: Self.key)
        guard current == nil && storedObject == nil || (current as? NSObject)?.isEqual(storedObject) == true else {
            throw HoverDisplayPreferencesError.changedElsewhere
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        defaults.set(data, forKey: Self.key)
        guard defaults.data(forKey: Self.key) == data else {
            if let storedObject {
                defaults.set(storedObject, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
            throw HoverDisplayPreferencesError.writeFailed
        }
        reload()
    }
}
