import Foundation

/// Per-provider selection, separate from presentation visibility. Initial import
/// waits for identifiable numeric quota; subsequently discovered targets start off.
nonisolated struct NotificationTargetPreferences: Codable, Equatable, Sendable {
    struct Selection: Codable, Equatable, Sendable {
        var selectedIDs: Set<String>
    }
    var version = 1
    var providers: [String: Selection] = [:]
    static let key = "notificationTargetsV1"

    func isSelected(_ id: String, provider: PopoverService) -> Bool {
        providers[provider.rawValue]?.selectedIDs.contains(id) == true
    }

    mutating func observe(_ limits: [UsageLimit], provider: PopoverService, legacySelection: (UsageLimit) -> Bool) {
        let candidates = limits.filter(\.canNotify)
        guard !candidates.isEmpty else { return }
        guard providers[provider.rawValue] == nil else { return }
        providers[provider.rawValue] = Selection(selectedIDs: Set(candidates.filter(legacySelection).map(\.id)))
    }

    mutating func setSelected(_ selected: Bool, limit: UsageLimit) {
        guard limit.isIdentifiable, !selected || limit.canNotify else { return }
        var selection = providers[limit.provider.rawValue] ?? Selection(selectedIDs: [])
        if selected { selection.selectedIDs.insert(limit.id) } else { selection.selectedIDs.remove(limit.id) }
        providers[limit.provider.rawValue] = selection
    }

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: key),
            let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1
        else { return Self() }
        return value
    }
    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}
