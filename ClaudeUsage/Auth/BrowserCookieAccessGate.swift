import Foundation
import os.lock

enum BrowserCookieAccessGate {
    private struct State {
        var loaded = false
        var deniedUntil: Date?
    }

    nonisolated private static let lock = OSAllocatedUnfairLock<State>(initialState: State())
    nonisolated private static let defaultsKey = "browserCookieAccessDeniedUntil"
    nonisolated private static let cooldownInterval: TimeInterval = 60 * 60 * 6 // 6시간

    /// Chrome 쿠키 접근을 시도해도 되는지 확인합니다.
    /// Keychain 프롬프트가 필요한 경우 6시간 쿨다운을 설정하고 false를 반환합니다.
    nonisolated static func shouldAttemptChromeAccess(now: Date = Date()) -> Bool {
        lock.withLock { state in
            loadIfNeeded(&state)

            if let blockedUntil = state.deniedUntil, blockedUntil > now {
                Logger.debug("Chrome 쿠키 접근 차단 중 (해제: \(blockedUntil))")
                return false
            }

            // 쿨다운 만료 시 초기화
            if state.deniedUntil != nil {
                state.deniedUntil = nil
                persist(state)
            }

            // Chrome Safe Storage 키체인 접근 사전 검사
            if chromeSafeStorageRequiresInteraction() {
                state.deniedUntil = now.addingTimeInterval(cooldownInterval)
                persist(state)
                Logger.info("Chrome Safe Storage 접근 시 UI 프롬프트 필요 — 6시간 쿨다운 설정")
                return false
            }

            return true
        }
    }

    /// 접근 거부를 기록합니다 (외부에서 SecItem 오류 감지 시).
    nonisolated static func recordDenied(now: Date = Date()) {
        lock.withLock { state in
            loadIfNeeded(&state)
            state.deniedUntil = now.addingTimeInterval(cooldownInterval)
            persist(state)
        }
        Logger.info("Chrome 쿠키 접근 거부 기록 — 6시간 쿨다운 설정")
    }

    // MARK: - Chrome Safe Storage preflight

    nonisolated private static let safeStorageLabels: [(service: String, account: String)] = [
        ("Chrome Safe Storage", "Chrome"),
        ("Chromium Safe Storage", "Chromium"),
        ("Google Chrome Safe Storage", "Chrome"),
    ]

    private nonisolated static func chromeSafeStorageRequiresInteraction() -> Bool {
        for label in safeStorageLabels {
            switch KeychainAccessPreflight.checkGenericPassword(
                service: label.service,
                account: label.account
            ) {
            case .allowed:
                return false
            case .interactionRequired:
                return true
            case .notFound, .failure:
                continue
            }
        }
        return false
    }

    // MARK: - Persistence

    private nonisolated static func loadIfNeeded(_ state: inout State) {
        guard !state.loaded else { return }
        state.loaded = true
        if let timestamp = UserDefaults.standard.object(forKey: defaultsKey) as? Double {
            state.deniedUntil = Date(timeIntervalSince1970: timestamp)
        }
    }

    private nonisolated static func persist(_ state: State) {
        if let deniedUntil = state.deniedUntil {
            UserDefaults.standard.set(deniedUntil.timeIntervalSince1970, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }
}
