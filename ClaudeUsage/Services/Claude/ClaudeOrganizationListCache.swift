import Foundation

/// 설정 화면이 네트워크 실패 때 보여 줄 조직 목록. 계정과 세션 키가 같을 때만 7일까지 쓴다.
nonisolated struct ClaudeOrganizationListCache {
    private struct Entry: Codable {
        let savedAt: Date
        let organizations: [ClaudeAPIService.OrganizationSummary]
        let sessionFingerprint: String?
    }

    private static let keyPrefix = AppIdentifiers.defaultsKey("cachedOrganizations.v1")
    private static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    let cacheStorage: ClaudeAPIService.CacheStorage

    func save(_ organizations: [ClaudeAPIService.OrganizationSummary], accountID: String?, sessionFingerprint: String?)
    {
        guard !organizations.isEmpty,
            let data = try? JSONEncoder().encode(
                Entry(savedAt: Date(), organizations: organizations, sessionFingerprint: sessionFingerprint))
        else { return }
        cacheStorage.set(data, forKey: Self.key(for: accountID))
    }

    func load(accountID: String?, sessionFingerprint: String?) -> [ClaudeAPIService.OrganizationSummary]? {
        guard let data = cacheStorage.data(forKey: Self.key(for: accountID)),
            let entry = try? JSONDecoder().decode(Entry.self, from: data),
            Date().timeIntervalSince(entry.savedAt) <= Self.lifetime
        else { return nil }
        // 예전 캐시는 세션 식별자가 없어 다른 계정 것일 수 있으므로 쓰지 않는다.
        guard let cached = entry.sessionFingerprint, let sessionFingerprint, cached == sessionFingerprint else {
            Logger.debug("캐시된 Organization 목록 무시: 세션 변경 감지")
            return nil
        }
        return entry.organizations
    }

    func clear(accountID: String?) {
        cacheStorage.removeObject(forKey: Self.key(for: accountID))
    }

    private static func key(for accountID: String?) -> String {
        "\(keyPrefix).\(accountID ?? "ephemeral")"
    }
}
