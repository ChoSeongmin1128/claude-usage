import Combine
import CoreFoundation
import Foundation

nonisolated enum MenuBarPresetStoreError: Error, Equatable {
    case invalidName, duplicateName, invalidDisplay, unavailableStorage, changedElsewhere, writeFailed, missingPreset

    var message: String {
        switch self {
        case .invalidName: "이름은 1~32글자로 입력해 주세요."
        case .duplicateName: "같은 이름의 프리셋이 있습니다."
        case .invalidDisplay: "이 표시 설정을 프리셋으로 저장할 수 없습니다."
        case .unavailableStorage: "저장된 프리셋을 읽을 수 없어 변경하지 않았습니다."
        case .changedElsewhere: "프리셋이 다른 곳에서 변경되었습니다. 다시 확인해 주세요."
        case .writeFailed: "프리셋을 저장하지 못했습니다. 다시 시도해 주세요."
        case .missingPreset: "이 프리셋은 삭제되었거나 변경되었습니다."
        }
    }
}

@MainActor
final class MenuBarPresetStore: ObservableObject {
    nonisolated static let key = AppIdentifiers.defaultsKey("menuBarDisplayPresets.v1")
    struct Snapshot { let object: Any? }

    @Published private(set) var presets: [MenuBarUserPreset] = []
    @Published private(set) var references: [AppProviderKind: MenuBarPresetReference] = [:]
    @Published private(set) var isWritable = true
    private let defaults: UserDefaults
    private var storedObject: Any?
    private var root: [String: Any] = [:]
    private var unreadable: [Any] = []
    private var originalRecords: [UUID: [String: Any]] = [:]
    private var rawReferences: [String: Any] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        reload()
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

    func reload() {
        storedObject = defaults.object(forKey: Self.key)
        presets = []
        references = [:]
        unreadable = []
        rawReferences = [:]
        originalRecords = [:]
        root = ["version": 1, "presets": [], "applied": [:]]
        isWritable = storedObject == nil
        var ids = Set<UUID>()
        var names = Set<String>()
        guard let data = storedObject as? Data,
            let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = decoded["version"] as? NSNumber,
            CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1, version.doubleValue == 1,
            let raw = decoded["presets"] as? [Any], let applied = decoded["applied"] as? [String: Any],
            let array = try? JSONSerialization.data(withJSONObject: raw),
            let loaded = PreservingJSONArray.decode(
                MenuBarUserPreset.self, from: array,
                accepting: { preset in
                    preset.isValid && ids.insert(preset.id).inserted
                        && names.insert(preset.provider.rawValue + ":" + MenuBarPresetName.comparisonKey(preset.name))
                            .inserted
                        && !MenuBarBuiltinPreset.allCases.contains { builtin in
                            builtin.supports(preset.provider)
                                && MenuBarPresetName.comparisonKey(builtin.title)
                                    == MenuBarPresetName.comparisonKey(preset.name)
                        }
                })
        else { return }
        root = decoded
        unreadable = loaded.unreadable
        presets = loaded.elements
        let accepted = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
        for object in raw {
            guard let record = object as? [String: Any],
                let data = try? JSONSerialization.data(withJSONObject: record),
                let preset = try? JSONDecoder().decode(MenuBarUserPreset.self, from: data),
                accepted[preset.id] == preset, originalRecords[preset.id] == nil
            else { continue }
            originalRecords[preset.id] = record
        }
        rawReferences = applied
        for (key, object) in applied {
            guard let provider = AppProviderKind(rawValue: key),
                let data = try? JSONSerialization.data(withJSONObject: object),
                let reference = try? JSONDecoder().decode(MenuBarPresetReference.self, from: data), reference.isValid
            else { continue }
            references[provider] = reference
        }
        isWritable = true
    }

    @discardableResult
    func add(name: String, provider: AppProviderKind, display: MenuBarPresetDisplay) throws -> MenuBarUserPreset {
        let name = try validatedName(name, provider: provider)
        guard display.isValid(for: provider) else { throw MenuBarPresetStoreError.invalidDisplay }
        let preset = MenuBarUserPreset(id: UUID(), provider: provider, name: name, display: display)
        var references = rawReferences
        references[provider.rawValue] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(MenuBarPresetReference.user(preset)))
        try persist(presets: presets + [preset], references: references)
        return preset
    }

    func rename(_ id: UUID, name: String) throws {
        guard let index = presets.firstIndex(where: { $0.id == id }) else {
            throw MenuBarPresetStoreError.missingPreset
        }
        let name = try validatedName(name, provider: presets[index].provider, excluding: id)
        var updated = presets
        updated[index].name = name
        try persist(presets: updated, references: rawReferences)
    }

    func update(_ id: UUID, display: MenuBarPresetDisplay) throws {
        guard let index = presets.firstIndex(where: { $0.id == id }) else {
            throw MenuBarPresetStoreError.missingPreset
        }
        guard display.isValid(for: presets[index].provider) else { throw MenuBarPresetStoreError.invalidDisplay }
        var updated = presets
        updated[index].display = display
        try persist(presets: updated, references: rawReferences)
    }

    func delete(_ id: UUID) throws {
        guard presets.contains(where: { $0.id == id }) else { throw MenuBarPresetStoreError.missingPreset }
        try persist(presets: presets.filter { $0.id != id }, references: rawReferences, deleting: id)
    }

    func record(_ reference: MenuBarPresetReference, for provider: AppProviderKind) throws {
        guard reference.isValid else { throw MenuBarPresetStoreError.invalidDisplay }
        let data = try JSONEncoder().encode(reference)
        var updated = rawReferences
        updated[provider.rawValue] = try JSONSerialization.jsonObject(with: data)
        try persist(presets: presets, references: updated)
    }

    private func validatedName(_ name: String, provider: AppProviderKind, excluding id: UUID? = nil) throws -> String {
        guard let normalized = MenuBarPresetName.normalized(name) else { throw MenuBarPresetStoreError.invalidName }
        let key = MenuBarPresetName.comparisonKey(normalized)
        let names =
            MenuBarPresetCatalog.presets(for: provider).map(\.title)
            + presets.filter { $0.provider == provider && $0.id != id }.map(\.name)
        guard !names.contains(where: { MenuBarPresetName.comparisonKey($0) == key }) else {
            throw MenuBarPresetStoreError.duplicateName
        }
        return normalized
    }

    private func persist(presets: [MenuBarUserPreset], references: [String: Any], deleting deletedID: UUID? = nil)
        throws
    {
        try validateWrite()
        var entries: [Any] = []
        for preset in presets {
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preset))
            guard let encodedRecord = encoded as? [String: Any] else { throw MenuBarPresetStoreError.writeFailed }
            if let original = originalRecords[preset.id], let before = self.presets.first(where: { $0.id == preset.id })
            {
                let previous = try JSONSerialization.jsonObject(with: JSONEncoder().encode(before))
                entries.append(PreservingJSONFields.replacing(in: original, previous: previous, updated: encodedRecord))
            } else {
                entries.append(encodedRecord)
            }
        }
        entries += unreadable.filter { object in
            guard let deletedID, let record = object as? [String: Any], let id = record["id"] as? String else {
                return true
            }
            return UUID(uuidString: id) != deletedID
        }
        var updated = root
        updated["presets"] = entries
        updated["applied"] = references
        let encoded = try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys])
        defaults.set(encoded, forKey: Self.key)
        guard defaults.data(forKey: Self.key) == encoded else {
            if let storedObject {
                defaults.set(storedObject, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
            throw MenuBarPresetStoreError.writeFailed
        }
        reload()
    }

    func validateWrite() throws {
        guard isWritable else { throw MenuBarPresetStoreError.unavailableStorage }
        let current = defaults.object(forKey: Self.key)
        let unchanged = current == nil && storedObject == nil || (current as? NSObject)?.isEqual(storedObject) == true
        guard unchanged else { throw MenuBarPresetStoreError.changedElsewhere }
    }
}
