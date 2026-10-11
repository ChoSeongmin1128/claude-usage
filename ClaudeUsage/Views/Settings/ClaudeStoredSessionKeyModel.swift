import Combine
import Foundation

/// 설정 창이 활성 웹 계정에 저장된 세션 키를 입력값과 비교하는 곳. 키 자체는 뷰 상태에 두지 않고 지문만 들며,
/// Keychain 읽기와 이전 키 옮기기는 메인 스레드 밖에서 한다.
@MainActor
final class ClaudeStoredSessionKeyModel: ObservableObject {
    @Published private(set) var fingerprint: String?

    private let accountStore: ClaudeAccountStore
    private let sessionKeyLoader: @Sendable (String) -> String?
    private var generation = 0
    private var loadTask: Task<Void, Never>?

    init(accountStore: ClaudeAccountStore, sessionKeyLoader: @escaping @Sendable (String) -> String?) {
        self.accountStore = accountStore
        self.sessionKeyLoader = sessionKeyLoader
    }

    var hasStoredKey: Bool { fingerprint != nil }

    func matches(_ normalizedKey: String) -> Bool {
        !normalizedKey.isEmpty && ClaudeAccountStore.fingerprint(for: normalizedKey) == fingerprint
    }

    /// 활성 웹 계정이나 저장된 키가 바뀌면 다시 읽는다. 늦게 끝난 이전 읽기는 버린다.
    @discardableResult
    func reload() -> Task<Void, Never> {
        generation &+= 1
        let current = generation
        loadTask?.cancel()
        let store = accountStore
        let loader = sessionKeyLoader
        let task = Task {
            let loaded = await BlockingWork.run(qos: .userInitiated) { () -> String? in
                store.ensureLegacyMigrationIfNeeded()
                guard let accountID = store.activeWebAccount()?.id,
                    let key = loader(accountID).map(ClaudeSessionKeyInput.normalize), !key.isEmpty
                else { return nil }
                return ClaudeAccountStore.fingerprint(for: key)
            }
            guard current == generation else { return }
            fingerprint = loaded
        }
        loadTask = task
        return task
    }

    /// 진행 중인 읽기가 있으면 끝난 뒤의 값을 돌려준다.
    func loadedFingerprint() async -> String? {
        await loadTask?.value
        return fingerprint
    }

    func markSaved(_ normalizedKey: String) {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        fingerprint = ClaudeAccountStore.fingerprint(for: normalizedKey)
    }
}

nonisolated enum ClaudeSessionKeyInput {
    /// 쿠키 문자열(`sessionKey=...; ...`)이나 따옴표로 감싼 값을 붙여 넣어도 키만 남긴다.
    static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let prefixRange = value.range(of: "sessionKey=", options: [.anchored, .caseInsensitive]) {
            value = String(value[prefixRange.upperBound...])
        }

        if let semiIndex = value.firstIndex(of: ";") {
            value = String(value[..<semiIndex])
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }

        return value
    }
}
