import CoreFoundation
import Foundation

/// Separate from display schema 2 so older releases cannot erase hover choices.
nonisolated struct AntigravityHoverDisplayPreferences: Equatable, Sendable {
    static let key = "antigravity.hoverDisplaySettings.v1"
    let stored: AntigravitySettingsStoredData
    let selection: AntigravityDisplaySettings.LaneListPresentationIntent?
    let isWritable: Bool

    static let inherited = Self(stored: .missing)

    init(stored: AntigravitySettingsStoredData) {
        self.stored = stored
        if stored == .missing {
            selection = nil
            isWritable = true
            return
        }
        guard case .data(let data) = stored,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = root["version"] as? NSNumber,
            CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
            let raw = root["selection"] as? [String: Any],
            let selectedData = try? JSONSerialization.data(withJSONObject: raw),
            let selection = try? JSONDecoder().decode(
                AntigravityDisplaySettings.LaneListPresentationIntent.self, from: selectedData),
            selection.isValid
        else { selection = nil; isWritable = false; return }
        self.selection = selection
        isWritable = true
    }

    func effectiveSelection(compact: AntigravityDisplaySettings.LaneListPresentationIntent)
        -> AntigravityDisplaySettings.LaneListPresentationIntent
    { selection ?? compact }

    func encoding(_ selection: AntigravityDisplaySettings.LaneListPresentationIntent) throws -> Data {
        guard isWritable else { throw HoverDisplayPreferencesError.unreadableStorage }
        guard selection.isValid else { throw AntigravitySettingsStoreError.invalidValue(.display) }
        var root: [String: Any] = [:]
        if case .data(let data) = stored {
            root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        var fields = root["selection"] as? [String: Any] ?? [:]
        let encoded = try JSONEncoder().encode(selection)
        let known = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        fields.merge(known) { _, new in new }
        root["version"] = 1
        root["selection"] = fields
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}
