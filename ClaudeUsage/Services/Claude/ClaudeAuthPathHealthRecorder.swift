import Foundation

/// 세션 키와 OAuth 경로의 시도, 성공, 실패 기록. 계정마다 UserDefaults에 남기고 검증 상태와 진단 화면이 읽는다.
nonisolated struct ClaudeAuthPathHealthRecorder {
    enum Path: Sendable { case session, oauth }

    private struct PathState: Codable {
        var lastAttemptAt: Date?
        var lastSuccessAt: Date?
        var lastFailureAt: Date?
        var lastErrorMessage: String?
        var consecutiveFailures = 0
        var totalAttempts = 0
        var totalFailures = 0

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
            lastSuccessAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
            lastFailureAt = try container.decodeIfPresent(Date.self, forKey: .lastFailureAt)
            lastErrorMessage = try container.decodeIfPresent(String.self, forKey: .lastErrorMessage)
            consecutiveFailures = try container.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
            totalAttempts = try container.decodeIfPresent(Int.self, forKey: .totalAttempts) ?? 0
            totalFailures = try container.decodeIfPresent(Int.self, forKey: .totalFailures) ?? 0
        }
    }

    private struct Store: Codable {
        var session = PathState()
        var oauth = PathState()
        var lastOverallSuccessAt: Date?
    }

    private static let keyPrefix = AppIdentifiers.defaultsKey("authPathHealth.v1")
    private let cacheStorage: ClaudeAPIService.CacheStorage
    private let accountID: String?
    private var store: Store

    init(accountID: String?, cacheStorage: ClaudeAPIService.CacheStorage) {
        self.accountID = accountID
        self.cacheStorage = cacheStorage
        store =
            cacheStorage.data(forKey: Self.key(for: accountID))
            .flatMap { try? JSONDecoder().decode(Store.self, from: $0) } ?? Store()
    }

    static func removeHistory(for accountID: String, cacheStorage: ClaudeAPIService.CacheStorage) {
        cacheStorage.removeObject(forKey: key(for: accountID))
    }

    var lastOverallSuccessAt: Date? { store.lastOverallSuccessAt }

    mutating func reset() { store = Store() }

    mutating func recordOverallSuccess() {
        store.lastOverallSuccessAt = Date()
        persist()
    }

    mutating func recordAttempt(_ path: Path) {
        update(path) { state in
            state.lastAttemptAt = Date()
            state.totalAttempts += 1
        }
    }

    mutating func recordSuccess(_ path: Path) {
        update(path) { state in
            state.lastSuccessAt = Date()
            state.lastErrorMessage = nil
            state.consecutiveFailures = 0
        }
    }

    mutating func recordFailure(_ path: Path, error: APIError) {
        update(path) { state in
            state.lastFailureAt = Date()
            state.lastErrorMessage = error.localizedDescription
            state.consecutiveFailures += 1
            state.totalFailures += 1
        }
    }

    func snapshot(_ path: Path) -> ClaudeAPIService.AuthPathHealthSnapshot {
        let state = self.state(path)
        return ClaudeAPIService.AuthPathHealthSnapshot(
            lastAttemptAt: state.lastAttemptAt, lastSuccessAt: state.lastSuccessAt,
            lastFailureAt: state.lastFailureAt, lastErrorMessage: state.lastErrorMessage,
            consecutiveFailures: state.consecutiveFailures, totalAttempts: state.totalAttempts,
            totalFailures: state.totalFailures)
    }

    /// 마지막 결과가 실패면 실패, 성공한 적이 있으면 검증됨, 자격 증명만 있으면 발견됨이다.
    func validationState(_ path: Path, credentialAvailable: Bool) -> ClaudeCredentialValidationState {
        guard credentialAvailable else { return .unavailable }
        let state = self.state(path)
        if let lastFailureAt = state.lastFailureAt, state.lastSuccessAt.map({ lastFailureAt > $0 }) ?? true {
            return .failed
        }
        return state.lastSuccessAt == nil ? .detected : .verified
    }

    private func state(_ path: Path) -> PathState {
        switch path {
        case .session: store.session
        case .oauth: store.oauth
        }
    }

    private mutating func update(_ path: Path, _ change: (inout PathState) -> Void) {
        switch path {
        case .session: change(&store.session)
        case .oauth: change(&store.oauth)
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        cacheStorage.set(data, forKey: Self.key(for: accountID))
    }

    private static func key(for accountID: String?) -> String {
        "\(keyPrefix).\(accountID ?? "ephemeral")"
    }
}
