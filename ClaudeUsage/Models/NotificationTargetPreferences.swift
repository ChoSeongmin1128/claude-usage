import Foundation

/// Per-provider selection, separate from presentation visibility. Legacy base
/// quotas can finish importing after a partial response; new model targets stay off.
nonisolated struct NotificationTargetPreferences: Codable, Equatable, Sendable {
    struct Selection: Codable, Equatable, Sendable {
        var selectedIDs: Set<String>
        /// Missing in existing v1 payloads, where an absent selection may be an
        /// explicit opt-out. Never infer unfinished migration for those payloads.
        /// Nil also closes migration after a user's first explicit selection.
        var importedLegacyIDs: Set<String>? = nil
    }
    var version = 1
    var providers: [String: Selection] = [:]
    static let key = "notificationTargetsV1"

    func isSelected(_ id: String, provider: PopoverService) -> Bool {
        providers[provider.rawValue]?.selectedIDs.contains(id) == true
    }

    mutating func observe(_ limits: [UsageLimit], provider: PopoverService, legacySelection: (UsageLimit) -> Bool) {
        let candidates = limits.filter { $0.provider == provider && $0.canNotify }
        guard !candidates.isEmpty else { return }
        let legacyCandidates = candidates.filter { limit in
            switch provider {
            case .claude: return limit.legacyKey == "fiveHour" || limit.legacyKey == "weekly"
            case .codex: return limit.legacyKey == "base"
            case .antigravity: return limit.legacyKey != nil
            }
        }
        var selection: Selection
        if let existing = providers[provider.rawValue] {
            guard let imported = existing.importedLegacyIDs else { return }
            selection = existing
            for limit in legacyCandidates where !imported.contains(limit.id) {
                // A new Codex base period is a new target, not evidence that a
                // legacy window was missing. Only resume the known 5-hour/weekly
                // windows, identified by duration rather than primary/secondary.
                if provider == .codex, limit.periodSeconds != 18_000, limit.periodSeconds != 604_800 { continue }
                if legacySelection(limit) { selection.selectedIDs.insert(limit.id) }
            }
        } else {
            selection = Selection(selectedIDs: Set(legacyCandidates.filter(legacySelection).map(\.id)))
            // AGY's legacy selector included every visible dynamic lane. Extending
            // that import to later snapshots would automatically enable new models.
            if provider != .antigravity { selection.importedLegacyIDs = [] }
        }
        selection.importedLegacyIDs?.formUnion(legacyCandidates.map(\.id))
        providers[provider.rawValue] = selection
    }

    mutating func setSelected(_ selected: Bool, limit: UsageLimit) {
        guard limit.isIdentifiable, !selected || limit.canNotify else { return }
        var selection = providers[limit.provider.rawValue] ?? Selection(selectedIDs: [])
        if selected { selection.selectedIDs.insert(limit.id) } else { selection.selectedIDs.remove(limit.id) }
        // A user may turn off an unavailable legacy target before it can import.
        selection.importedLegacyIDs?.insert(limit.id)
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
