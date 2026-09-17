import Foundation

/// One atomic payload stores canonical used-percent thresholds. The legacy keys
/// are read only during import and kept for older installations; IDs and disabled
/// rules survive migration. Display mode never changes these values.
nonisolated struct NotificationThresholdStorage: Codable {
    let schemaVersion: Int
    let presets: [NotificationPreset]
    static let key = "notificationRulesV2"

    static func load(from defaults: UserDefaults) -> [NotificationPreset]? {
        guard let data = defaults.data(forKey: key),
            let stored = try? JSONDecoder().decode(Self.self, from: data), stored.schemaVersion == 2
        else { return nil }
        return stored.presets
    }

    static func save(_ presets: [NotificationPreset], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(Self(schemaVersion: 2, presets: presets)) else { return }
        defaults.set(data, forKey: key)
    }

    static func importLegacy(_ presets: [NotificationPreset], remaining: Bool) -> [NotificationPreset] {
        presets.map {
            var preset = $0
            preset.threshold = remaining ? max(1, min(100 - $0.threshold, 99)) : max(1, min($0.threshold, 100))
            return preset
        }
    }
}
