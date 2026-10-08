import Foundation

nonisolated struct ResetCreditSeenReceipt: Equatable, Hashable, Sendable {
    let service: PopoverService
    let accountKey: String
    let revision: Int
}

nonisolated enum ResetCreditSeenStore {
    static let key = AppIdentifiers.defaultsKey("resetCreditState.v2")

    struct Record: Codable, Equatable, Sendable {
        var count: Int
        var knownIDs: Set<String>
        var identityDetailsComplete: Bool
        var revision = 0
        var isNew = false
    }

    struct State: Codable, Equatable, Sendable {
        var version = 2
        var records: [String: Record] = [:]
    }

    static func observe(
        summary: ResetCreditSummary?, count: Int?, accountKey: String?, defaults: UserDefaults = .standard
    ) {
        guard let accountKey, !accountKey.isEmpty, let count, count >= 0 else { return }
        var state = load(defaults)
        let ids = Set(summary?.items.compactMap(\.id) ?? [])
        let previous = state.records[accountKey]
        let complete = count == 0 || summary?.identityDetailsComplete == true
        var record = previous ?? Record(count: count, knownIDs: ids, identityDetailsComplete: complete)
        if let previous {
            let addedIDs = previous.identityDetailsComplete && complete && !ids.subtracting(previous.knownIDs).isEmpty
            if count > previous.count || addedIDs {
                record.revision += 1
                record.isNew = true
            }
            record.count = count
            record.knownIDs.formUnion(ids)
            record.identityDetailsComplete = complete
        }
        if count == 0 {
            record.isNew = false
            record.knownIDs = []
        }
        guard record != previous else { return }
        state.records[accountKey] = record
        save(state, defaults)
    }

    static func receipt(
        service: PopoverService, accountKey: String?, defaults: UserDefaults = .standard
    ) -> ResetCreditSeenReceipt? {
        guard let accountKey, let record = load(defaults).records[accountKey] else { return nil }
        return ResetCreditSeenReceipt(service: service, accountKey: accountKey, revision: record.revision)
    }

    static func isNew(accountKey: String?, defaults: UserDefaults = .standard) -> Bool {
        accountKey.flatMap { load(defaults).records[$0] }?.isNew ?? false
    }

    static func markSeen(_ receipt: ResetCreditSeenReceipt, defaults: UserDefaults = .standard) {
        var state = load(defaults)
        guard var record = state.records[receipt.accountKey], record.revision == receipt.revision,
            record.isNew
        else { return }
        record.isNew = false
        state.records[receipt.accountKey] = record
        save(state, defaults)
    }

    static func remove(accountKey: String, defaults: UserDefaults = .standard) {
        var state = load(defaults)
        guard state.records.removeValue(forKey: accountKey) != nil else { return }
        save(state, defaults)
    }

    static func removeWebSession(reference: String, defaults: UserDefaults = .standard) {
        let prefix = RuntimeProviderFetchMetadata.webSessionOwnerPrefix(reference: reference)
        var state = load(defaults)
        let retained = state.records.filter { !$0.key.hasPrefix(prefix) }
        guard retained.count != state.records.count else { return }
        state.records = retained
        save(state, defaults)
    }

    private static func load(_ defaults: UserDefaults) -> State {
        guard let data = defaults.data(forKey: key), let state = try? JSONDecoder().decode(State.self, from: data),
            state.version == 2
        else { return State() }
        return state
    }

    private static func save(_ state: State, _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) }
    }
}
