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
    private var persistence = PreferencePersistenceContext()

    init() { persistence.baseline = knownJSON }

    init(from decoder: Decoder) throws {
        persistence = try PreferencePersistenceContext(from: decoder)
        persistence.checkVersion(required: true)
        version = persistence.read(Int.self, at: ["version"], fallback: 1)
        if let entries = persistence.raw["providers"] as? [String: Any] {
            for id in entries.keys where PopoverService(rawValue: id) != nil {
                guard let entry = entries[id] as? [String: Any] else {
                    persistence.unreadable.insert(["providers", id]); continue
                }
                if entry["selectedIDs"] == nil { persistence.unreadable.insert(["providers", id, "selectedIDs"]) }
                let selected = persistence.read(Set<String>.self, at: ["providers", id, "selectedIDs"], fallback: [])
                let imported = persistence.read(
                    Set<String>?.self,
                    at: ["providers", id, "importedLegacyIDs"], fallback: nil)
                providers[id] = Selection(selectedIDs: selected, importedLegacyIDs: imported)
            }
        } else {
            persistence.unreadable.insert(["providers"])
        }
        persistence.baseline = knownJSON
    }

    func encode(to encoder: Encoder) throws {
        guard persistence.writable || !persistence.raw.isEmpty else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Unreadable preference storage cannot be encoded as defaults"))
        }
        try PreferenceJSONValue.encode(
            persistence.writable ? persistence.merged(knownJSON) : persistence.raw,
            to: encoder)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.version == rhs.version && lhs.providers == rhs.providers }

    private var knownJSON: [String: Any] {
        var entries: [String: Any] = [:]
        for (id, selection) in providers {
            var value: [String: Any] = ["selectedIDs": selection.selectedIDs.sorted()]
            if let imported = selection.importedLegacyIDs { value["importedLegacyIDs"] = imported.sorted() }
            entries[id] = value
        }
        return ["version": version, "providers": entries]
    }

    func isSelected(_ id: String, provider: PopoverService) -> Bool {
        persistence.writable && providers[provider.rawValue]?.selectedIDs.contains(id) == true
    }

    mutating func observe(_ limits: [UsageLimit], provider: PopoverService, legacySelection: (UsageLimit) -> Bool) {
        guard persistence.canChange(["providers", provider.rawValue, "selectedIDs"]),
            persistence.canChange(["providers", provider.rawValue, "importedLegacyIDs"])
        else { return }
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
        let object = defaults.object(forKey: key)
        guard let object else { return Self() }
        guard let data = object as? Data, var value = try? JSONDecoder().decode(Self.self, from: data) else {
            var fallback = Self()
            fallback.persistence.object = object
            fallback.persistence.writable = false
            return fallback
        }
        value.persistence.object = object
        if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { value.persistence.raw = raw }
        return value
    }

    @discardableResult
    mutating func save(to defaults: UserDefaults) -> PreferenceSaveResult { commit(to: defaults, intent: .user) }

    @discardableResult
    mutating func commit(to defaults: UserDefaults, intent: PreferenceChangeIntent) -> PreferenceSaveResult {
        guard version == 1 else { return .blocked("지원하지 않는 설정 버전은 변경하지 않았습니다.") }
        let known = knownJSON
        return persistence.save(known, to: defaults, key: Self.key)
    }

    mutating func inheritPersistence(from value: Self) {
        let readable = persistence.writable
        let unreadable = persistence.unreadable
        persistence = value.persistence
        persistence.writable = persistence.writable && readable
        persistence.unreadable.formUnion(unreadable)
    }

    func resetKnown() -> Self {
        var value = self
        for id in providers.keys {
            if persistence.canChange(["providers", id, "selectedIDs"]) { value.providers[id]?.selectedIDs = [] }
            if persistence.canChange(["providers", id, "importedLegacyIDs"]) {
                value.providers[id]?.importedLegacyIDs = []
            }
        }
        return value
    }

    func restoreStorage(to defaults: UserDefaults) {
        PreferencePersistenceContext.restore(persistence.object, to: defaults, key: Self.key)
    }
}
