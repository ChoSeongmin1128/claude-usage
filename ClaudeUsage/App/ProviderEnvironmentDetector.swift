import Foundation
import SQLite3

struct ProviderEnvironmentStatus: Sendable, Equatable {
    let isDetected: Bool
    let credentialState: ProviderCredentialState
    let runtimeReachability: Bool
    let summary: String

    var canAttemptRefresh: Bool {
        runtimeReachability
    }
}

enum GeminiAuthType: String, Sendable, Equatable {
    case oauthPersonal = "oauth-personal"
    case apiKey = "api-key"
    case vertexAI = "vertex-ai"
    case unknown
}

enum GeminiCredentialState: Sendable, Equatable {
    case usable
    case refreshOnly
    case missing

    var providerCredentialState: ProviderCredentialState {
        switch self {
        case .usable:
            return .usable
        case .refreshOnly:
            return .refreshable
        case .missing:
            return .missing
        }
    }
}

struct GeminiEnvironmentSignals: Sendable, Equatable {
    let hasBinary: Bool
    let authType: GeminiAuthType
    let credentialState: GeminiCredentialState
}

struct AntigravityEnvironmentSignals: Sendable, Equatable {
    let hasStateDirectory: Bool
    let appRunning: Bool
    let runningProcess: AntigravityProcessSnapshot?
    let hasAuthStatus: Bool
    let hasOAuthToken: Bool

    var hasPersistedAuthState: Bool {
        hasAuthStatus || hasOAuthToken
    }

    var hasRuntimeConnection: Bool {
        guard let process = runningProcess else { return false }
        return process.csrfToken?.isEmpty == false && (process.extensionPort != nil || process.httpsServerPort != nil)
    }

    /// cache-miss fallback. 실제 감지 전까지 "정보 없음" 을 의미.
    static let empty = AntigravityEnvironmentSignals(
        hasStateDirectory: false,
        appRunning: false,
        runningProcess: nil,
        hasAuthStatus: false,
        hasOAuthToken: false
    )
}

extension GeminiEnvironmentSignals {
    /// cache-miss fallback. 실제 감지 전까지 "정보 없음" 을 의미.
    static let empty = GeminiEnvironmentSignals(
        hasBinary: false,
        authType: .unknown,
        credentialState: .missing
    )
}

extension Notification.Name {
    /// 백그라운드 환경 감지/갱신이 끝났을 때 브로드캐스트.
    /// SettingsView / PopoverView 가 subscribe 해서 재렌더를 트리거.
    static let providerEnvironmentUpdated = Notification.Name("com.claudeusage.providerEnvironmentUpdated")
}

enum ProviderEnvironmentDetector {

    // MARK: - Status cache (avoids repeated /bin/ps + SQLite per UI cycle)

    private struct CachedStatus {
        let status: ProviderEnvironmentStatus?
        let cachedAt: Date
    }

    private static let cacheTTL: TimeInterval = 5
    /// SWR (stale-while-revalidate) 허용 윈도우: TTL 만료 후에도 이 기간 내면
    /// 캐시 값을 그대로 반환하면서 백그라운드에서만 갱신을 예약.
    /// UI 클릭 경로가 blocking subprocess 를 절대 기다리지 않게 만드는 핵심.
    /// 5분은 너무 길어 실제 상태 변화 (로그아웃 등) 가 반영되기 전까지 UI 가
    /// 잘못된 정보를 보여 줄 위험이 커지므로 2분으로 제한.
    /// TTL=5s + background warm-up 덕에 실제 체감되는 stale window 는 훨씬 짧다.
    private static let staleAllowance: TimeInterval = 120
    // MARK: - Signals cache (antigravitySignals/geminiSignals 결과 캐시)
    // SQLite · JSON 파싱 · 파일 IO 를 포함해서 blocking 비용이 있으므로
    // UI 경로용 cachedAntigravitySignals/cachedGeminiSignals 에서 재활용.

    private struct CachedAntigravitySignals {
        let signals: AntigravityEnvironmentSignals
        let cachedAt: Date
    }

    private struct CachedGeminiSignals {
        let signals: GeminiEnvironmentSignals
        let cachedAt: Date
    }

    private static let signalsCacheTTL: TimeInterval = 5
    private nonisolated static let stateStore = MutableStateStore()

    private final class MutableStateStore: @unchecked Sendable {
        private let statusCacheLock = NSLock()
        private nonisolated(unsafe) var statusCache: [AppProviderKind: CachedStatus] = [:]
        private nonisolated(unsafe) var inflightRefresh: Set<AppProviderKind> = []

        private let signalsCacheLock = NSLock()
        private nonisolated(unsafe) var cachedAntigravitySignalsValue: CachedAntigravitySignals?
        private nonisolated(unsafe) var cachedGeminiSignalsValue: CachedGeminiSignals?
        private nonisolated(unsafe) var antigravitySignalsInflight = false
        private nonisolated(unsafe) var geminiSignalsInflight = false
        private let binaryPathCacheLock = NSLock()
        private nonisolated(unsafe) var binaryPathCache: [String: URL?] = [:]

        nonisolated func invalidateCache(for kind: AppProviderKind?) {
            statusCacheLock.lock()
            if let kind {
                statusCache.removeValue(forKey: kind)
            } else {
                statusCache.removeAll()
            }
            statusCacheLock.unlock()

            signalsCacheLock.lock()
            if kind == nil || kind == .antigravity {
                cachedAntigravitySignalsValue = nil
            }
            if kind == nil || kind == .gemini {
                cachedGeminiSignalsValue = nil
            }
            signalsCacheLock.unlock()
        }

        nonisolated func freshStatus(for kind: AppProviderKind, now: Date, ttl: TimeInterval) -> ProviderEnvironmentStatus? {
            statusCacheLock.lock()
            defer { statusCacheLock.unlock() }

            guard let cached = statusCache[kind], now.timeIntervalSince(cached.cachedAt) < ttl else {
                return nil
            }
            return cached.status
        }

        nonisolated func cachedStatus(for kind: AppProviderKind) -> ProviderEnvironmentStatus? {
            statusCacheLock.lock()
            defer { statusCacheLock.unlock() }
            return statusCache[kind]?.status
        }

        nonisolated func staleStatusSnapshot(
            for kind: AppProviderKind,
            now: Date,
            ttl: TimeInterval,
            staleAllowance: TimeInterval
        ) -> (status: ProviderEnvironmentStatus?, isMissing: Bool, needsRefresh: Bool, withinStaleWindow: Bool) {
            statusCacheLock.lock()
            defer { statusCacheLock.unlock() }

            let cached = statusCache[kind]
            let needsRefresh = cached.map { now.timeIntervalSince($0.cachedAt) >= ttl } ?? true
            let withinStaleWindow = cached.map { now.timeIntervalSince($0.cachedAt) < staleAllowance } ?? false
            return (cached?.status, cached == nil, needsRefresh, withinStaleWindow)
        }

        nonisolated func storeStatus(_ status: ProviderEnvironmentStatus?, for kind: AppProviderKind, cachedAt: Date) {
            statusCacheLock.lock()
            statusCache[kind] = CachedStatus(status: status, cachedAt: cachedAt)
            statusCacheLock.unlock()
        }

        nonisolated func beginStatusRefresh(for kind: AppProviderKind) -> Bool {
            statusCacheLock.lock()
            defer { statusCacheLock.unlock() }

            if inflightRefresh.contains(kind) {
                return false
            }
            inflightRefresh.insert(kind)
            return true
        }

        nonisolated func endStatusRefresh(_ status: ProviderEnvironmentStatus?, for kind: AppProviderKind, cachedAt: Date) {
            statusCacheLock.lock()
            statusCache[kind] = CachedStatus(status: status, cachedAt: cachedAt)
            inflightRefresh.remove(kind)
            statusCacheLock.unlock()
        }

        nonisolated func cachedAntigravitySignals(now: Date, ttl: TimeInterval) -> (signals: AntigravityEnvironmentSignals?, needsRefresh: Bool) {
            signalsCacheLock.lock()
            defer { signalsCacheLock.unlock() }

            let cached = cachedAntigravitySignalsValue
            let needsRefresh = cached.map { now.timeIntervalSince($0.cachedAt) >= ttl } ?? true
            return (cached?.signals, needsRefresh)
        }

        nonisolated func cachedGeminiSignals(now: Date, ttl: TimeInterval) -> (signals: GeminiEnvironmentSignals?, needsRefresh: Bool) {
            signalsCacheLock.lock()
            defer { signalsCacheLock.unlock() }

            let cached = cachedGeminiSignalsValue
            let needsRefresh = cached.map { now.timeIntervalSince($0.cachedAt) >= ttl } ?? true
            return (cached?.signals, needsRefresh)
        }

        nonisolated func storeAntigravitySignals(_ signals: AntigravityEnvironmentSignals, cachedAt: Date) {
            signalsCacheLock.lock()
            cachedAntigravitySignalsValue = CachedAntigravitySignals(signals: signals, cachedAt: cachedAt)
            signalsCacheLock.unlock()
        }

        nonisolated func storeGeminiSignals(_ signals: GeminiEnvironmentSignals, cachedAt: Date) {
            signalsCacheLock.lock()
            cachedGeminiSignalsValue = CachedGeminiSignals(signals: signals, cachedAt: cachedAt)
            signalsCacheLock.unlock()
        }

        nonisolated func beginAntigravitySignalsRefresh() -> Bool {
            signalsCacheLock.lock()
            defer { signalsCacheLock.unlock() }

            if antigravitySignalsInflight {
                return false
            }
            antigravitySignalsInflight = true
            return true
        }

        nonisolated func endAntigravitySignalsRefresh(_ signals: AntigravityEnvironmentSignals, cachedAt: Date) {
            signalsCacheLock.lock()
            cachedAntigravitySignalsValue = CachedAntigravitySignals(signals: signals, cachedAt: cachedAt)
            antigravitySignalsInflight = false
            signalsCacheLock.unlock()
        }

        nonisolated func beginGeminiSignalsRefresh() -> Bool {
            signalsCacheLock.lock()
            defer { signalsCacheLock.unlock() }

            if geminiSignalsInflight {
                return false
            }
            geminiSignalsInflight = true
            return true
        }

        nonisolated func endGeminiSignalsRefresh(_ signals: GeminiEnvironmentSignals, cachedAt: Date) {
            signalsCacheLock.lock()
            cachedGeminiSignalsValue = CachedGeminiSignals(signals: signals, cachedAt: cachedAt)
            geminiSignalsInflight = false
            signalsCacheLock.unlock()
        }

        nonisolated func cachedBinaryURL(named name: String) -> URL?? {
            binaryPathCacheLock.lock()
            defer { binaryPathCacheLock.unlock() }
            return binaryPathCache[name]
        }

        nonisolated func storeBinaryURL(_ url: URL?, for name: String) {
            binaryPathCacheLock.lock()
            binaryPathCache[name] = url
            binaryPathCacheLock.unlock()
        }
    }

    static func invalidateCache(for kind: AppProviderKind? = nil) {
        stateStore.invalidateCache(for: kind)
    }

    /// 동기 API (구 버전 호환). cache miss 시 여전히 blocking 이므로 UI
    /// 경로에서는 절대 사용하지 말고 백그라운드에서만 호출할 것.
    static func status(for kind: AppProviderKind) -> ProviderEnvironmentStatus? {
        let now = Date()

        if let cached = stateStore.freshStatus(for: kind, now: now, ttl: cacheTTL) {
            return cached
        }

        let result = _uncachedStatus(for: kind)
        stateStore.storeStatus(result, for: kind, cachedAt: now)

        return result
    }

    /// 캐시된 값만 반환 (subprocess 호출 절대 없음).
    /// UI 경로에서 호출해도 즉시 리턴. 캐시가 없으면 nil.
    static func cachedStatus(for kind: AppProviderKind) -> ProviderEnvironmentStatus? {
        stateStore.cachedStatus(for: kind)
    }

    /// SWR: 캐시가 있으면 즉시 반환. TTL 만료면 백그라운드 갱신 예약 후 그대로
    /// stale 값 반환. 캐시 자체가 없으면 백그라운드 갱신만 예약하고 nil.
    /// 메인 스레드는 이 함수로 호출 → subprocess blocking 0ms 보장.
    static func staleWhileRevalidate(for kind: AppProviderKind) -> ProviderEnvironmentStatus? {
        let now = Date()

        let snapshot = stateStore.staleStatusSnapshot(
            for: kind,
            now: now,
            ttl: cacheTTL,
            staleAllowance: staleAllowance
        )

        if snapshot.needsRefresh {
            scheduleBackgroundRefresh(for: kind)
        }

        // cache miss 거나 stale window 넘으면 nil 반환 (UI 는 "모름" 으로 처리)
        if snapshot.isMissing || !snapshot.withinStaleWindow {
            return snapshot.isMissing ? nil : snapshot.status
        }
        return snapshot.status
    }

    private nonisolated static func postProviderEnvironmentUpdated(for kind: AppProviderKind) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .providerEnvironmentUpdated,
                object: kind
            )
        }
    }

    /// 백그라운드에서 실제 subprocess/파일 IO 를 돌려 캐시를 갱신.
    /// 앱 시작, refresh 틱, 또는 SWR 경로에서 내부 호출로 트리거됨.
    /// 동일 kind 에 대한 동시 갱신은 inflight 플래그로 중복 차단.
    nonisolated static func refreshStatusInBackground(for kind: AppProviderKind) {
        if !stateStore.beginStatusRefresh(for: kind) {
            return
        }

        // 백그라운드 큐에서 실행 (nonisolated 전역 큐 디스패치).
        // _uncachedStatus 는 subprocess/SQLite/파일 IO 를 blocking 으로 수행하지만
        // UI 스레드 밖이므로 문제 없음.
        DispatchQueue.global(qos: .utility).async {
            // status 가 signals 를 내부에서 쓰므로 signals 캐시도 함께 갱신됨
            // (아래 _uncachedStatus → *Signals() 경로는 blocking 이지만 백그라운드).
            let signalsResult = backgroundWarmSignals(for: kind)
            let result = _uncachedStatus(for: kind, precomputedSignals: signalsResult)
            stateStore.endStatusRefresh(result, for: kind, cachedAt: Date())

            postProviderEnvironmentUpdated(for: kind)
        }
    }

    /// 백그라운드에서 antigravity/gemini signals 를 계산해 signals 캐시까지 채움.
    /// claude/codex 는 해당 없음 → nil 반환.
    private nonisolated static func backgroundWarmSignals(for kind: AppProviderKind) -> Any? {
        switch kind {
        case .antigravity:
            let signals = uncachedAntigravitySignals()
            stateStore.storeAntigravitySignals(signals, cachedAt: Date())
            return signals
        case .gemini:
            let signals = uncachedGeminiSignals()
            stateStore.storeGeminiSignals(signals, cachedAt: Date())
            return signals
        case .claude, .codex:
            return nil
        }
    }

    /// 모든 provider 에 대해 백그라운드 갱신 예약 (앱 시작 / refresh 틱에서 호출).
    nonisolated static func refreshAllInBackground() {
        for kind in [AppProviderKind.gemini, .antigravity, .codex] {
            refreshStatusInBackground(for: kind)
        }
    }

    private nonisolated static func scheduleBackgroundRefresh(for kind: AppProviderKind) {
        refreshStatusInBackground(for: kind)
    }

    private static func _uncachedStatus(
        for kind: AppProviderKind,
        precomputedSignals: Any? = nil
    ) -> ProviderEnvironmentStatus? {
        switch kind {
        case .claude:
            return nil
        case .codex:
            // NSLock 기반 캐시를 태우긴 하지만 4번 연달아 호출할 이유가 없음.
            let authenticated = CodexAuthManager.shared.isAuthenticated
            return ProviderEnvironmentStatus(
                isDetected: authenticated,
                credentialState: authenticated ? .usable : .missing,
                runtimeReachability: authenticated,
                summary: authenticated ? "CLI/OAuth 인증 감지" : "CLI/OAuth 인증 미감지"
            )
        case .gemini:
            let signals = (precomputedSignals as? GeminiEnvironmentSignals) ?? geminiSignals()
            return interpretGemini(signals: signals)
        case .antigravity:
            let signals = (precomputedSignals as? AntigravityEnvironmentSignals) ?? antigravitySignals()
            return interpretAntigravity(signals: signals)
        }
    }

    // MARK: - Cached signals (UI-path friendly)

    /// 캐시된 signals 만 반환. 캐시 miss 면 nil + 백그라운드 warm-up 예약.
    /// UI 메인 스레드는 이것만 호출해서 /bin/ps · SQLite · JSON 파싱 blocking
    /// 을 회피.
    static func cachedAntigravitySignals() -> AntigravityEnvironmentSignals? {
        let cached = stateStore.cachedAntigravitySignals(now: Date(), ttl: signalsCacheTTL)

        if cached.needsRefresh {
            refreshAntigravitySignalsInBackground()
        }
        return cached.signals
    }

    static func cachedGeminiSignals() -> GeminiEnvironmentSignals? {
        let cached = stateStore.cachedGeminiSignals(now: Date(), ttl: signalsCacheTTL)

        if cached.needsRefresh {
            refreshGeminiSignalsInBackground()
        }
        return cached.signals
    }

    nonisolated static func refreshAntigravitySignalsInBackground() {
        if !stateStore.beginAntigravitySignalsRefresh() {
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let signals = uncachedAntigravitySignals()
            stateStore.endAntigravitySignalsRefresh(signals, cachedAt: Date())

            postProviderEnvironmentUpdated(for: .antigravity)
        }
    }

    nonisolated static func refreshGeminiSignalsInBackground() {
        if !stateStore.beginGeminiSignalsRefresh() {
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let signals = uncachedGeminiSignals()
            stateStore.endGeminiSignalsRefresh(signals, cachedAt: Date())

            postProviderEnvironmentUpdated(for: .gemini)
        }
    }

    static func canAttemptRefresh(for kind: AppProviderKind) -> Bool {
        status(for: kind)?.canAttemptRefresh ?? false
    }

    /// UI 경로용. status 의 runtimeReachability 가 true 이거나 credential 이
    /// usable 이면 "interactive setup 불필요" 로 판정. signals 를 호출하지
    /// 않아 subprocess blocking 이 없음.
    /// 캐시가 없어 판정이 불가능하면 false 반환 (= 일단 "설정 불필요").
    static func requiresInteractiveSetupFromCache(for kind: AppProviderKind) -> Bool {
        switch kind {
        case .claude, .codex:
            return false
        case .gemini, .antigravity:
            guard let status = staleWhileRevalidate(for: kind) else { return false }
            if status.credentialState.hasAnyCredential { return false }
            if status.runtimeReachability { return false }
            return true
        }
    }

    static func requiresInteractiveSetup(for kind: AppProviderKind) -> Bool {
        switch kind {
        case .claude, .codex:
            return false
        case .gemini:
            let signals = geminiSignals()
            if !signals.hasBinary { return signals.credentialState == .missing }
            switch signals.authType {
            case .apiKey, .vertexAI:
                return true
            case .oauthPersonal, .unknown:
                return signals.credentialState == .missing
            }
        case .antigravity:
            let signals = antigravitySignals()
            return !signals.hasRuntimeConnection && !signals.hasPersistedAuthState
        }
    }

    static func interpretGemini(signals: GeminiEnvironmentSignals) -> ProviderEnvironmentStatus {
        switch signals.authType {
        case .apiKey:
            return ProviderEnvironmentStatus(
                isDetected: false,
                credentialState: .missing,
                runtimeReachability: false,
                summary: signals.hasBinary ? "Gemini CLI 감지됨 · 현재 인증 방식은 API 키입니다" : "Gemini CLI 미설치"
            )
        case .vertexAI:
            return ProviderEnvironmentStatus(
                isDetected: false,
                credentialState: .missing,
                runtimeReachability: false,
                summary: signals.hasBinary ? "Gemini CLI 감지됨 · 현재 인증 방식은 Vertex AI입니다" : "Gemini CLI 미설치"
            )
        case .oauthPersonal, .unknown:
            break
        }

        switch (signals.hasBinary, signals.credentialState) {
        case (true, .usable):
            return ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .usable,
                runtimeReachability: true,
                summary: "Gemini CLI OAuth 감지"
            )
        case (true, .refreshOnly):
            return ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .refreshable,
                runtimeReachability: true,
                summary: "Gemini CLI OAuth 감지 · 액세스 토큰은 갱신이 필요합니다"
            )
        case (true, .missing):
            return ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .missing,
                runtimeReachability: false,
                summary: "Gemini CLI 감지됨 · 로그인 필요"
            )
        case (false, .usable):
            return ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .usable,
                runtimeReachability: false,
                summary: "Gemini OAuth 자격 감지 · CLI 설치 경로를 확인하세요"
            )
        case (false, .refreshOnly):
            return ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .refreshable,
                runtimeReachability: false,
                summary: "Gemini OAuth 자격 감지 · CLI 설치 경로를 확인하세요"
            )
        case (false, .missing):
            return ProviderEnvironmentStatus(
                isDetected: false,
                credentialState: .missing,
                runtimeReachability: false,
                summary: "Gemini CLI 미설치"
            )
        }
    }

    static func interpretAntigravity(signals: AntigravityEnvironmentSignals) -> ProviderEnvironmentStatus {
        switch (signals.runningProcess, signals.hasPersistedAuthState, signals.appRunning, signals.hasStateDirectory) {
        case let (.some(process), _, _, _) where process.csrfToken != nil && process.extensionPort != nil:
            return ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .refreshable,
                runtimeReachability: true,
                summary: "Antigravity quota 서버 감지 · 조회를 시도할 수 있습니다"
            )
        case let (.some(process), true, _, _) where process.csrfToken != nil:
            let portSuffix = process.extensionPort.map { " · 포트 \($0)" } ?? ""
            return ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .refreshable,
                runtimeReachability: false,
                summary: "Antigravity 인증 상태 감지 · quota 서버 연결 준비 중\(portSuffix)"
            )
        case let (.some(process), _, _, _):
            let portSuffix = process.extensionPort.map { " · 포트 \($0)" } ?? ""
            return ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .unknown,
                runtimeReachability: false,
                summary: "Antigravity quota 서버 감지 · 연결 토큰 확인 중\(portSuffix)"
            )
        case (nil, true, true, _):
            return ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .unknown,
                runtimeReachability: false,
                summary: "Antigravity 앱과 인증 상태 감지 · quota 서버 연결 준비 중"
            )
        case (nil, true, false, _):
            return ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .unknown,
                runtimeReachability: false,
                summary: "Antigravity 인증 상태 감지 · 앱을 실행하면 조회를 시작합니다"
            )
        case (nil, false, true, _):
            return ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .unknown,
                runtimeReachability: false,
                summary: "Antigravity 앱 실행 중 · 로그인 또는 quota 서버 초기화를 기다리는 중입니다"
            )
        case (nil, false, false, true):
            return ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .unknown,
                runtimeReachability: false,
                summary: "Antigravity 로컬 상태 감지 · 앱 실행이 필요합니다"
            )
        case (nil, false, false, false):
            return ProviderEnvironmentStatus(
                isDetected: false,
                credentialState: .missing,
                runtimeReachability: false,
                summary: "Antigravity 상태 미감지"
            )
        }
    }

    /// Blocking. 백그라운드 경로 전용 — UI 메인 스레드에서 호출하지 말 것.
    /// /bin/ps · NSWorkspace · SQLite · 파일 IO 를 모두 포함.
    static func antigravitySignals() -> AntigravityEnvironmentSignals {
        let signals = uncachedAntigravitySignals()
        stateStore.storeAntigravitySignals(signals, cachedAt: Date())
        return signals
    }

    private nonisolated static func uncachedAntigravitySignals() -> AntigravityEnvironmentSignals {
        let hasLegacyStateDirectory = FileManager.default.fileExists(
            atPath: FileManager.default.realHomeDirectory
                .appendingPathComponent(".gemini/antigravity").path
        )
        let hasHomeStateDirectory = FileManager.default.fileExists(
            atPath: FileManager.default.realHomeDirectory
                .appendingPathComponent(".antigravity").path
        )
        let hasApplicationSupportDirectory = FileManager.default.fileExists(
            atPath: FileManager.default.realHomeDirectory
                .appendingPathComponent("Library/Application Support/Antigravity").path
        )
        let persistedState = antigravityPersistedState()
        return AntigravityEnvironmentSignals(
            hasStateDirectory: hasLegacyStateDirectory || hasHomeStateDirectory || hasApplicationSupportDirectory,
            appRunning: AntigravityStatusProbe.appProcessRunning(),
            runningProcess: AntigravityStatusProbe.runningProcess(),
            hasAuthStatus: persistedState.hasAuthStatus,
            hasOAuthToken: persistedState.hasOAuthToken
        )
    }

    private struct AntigravityPersistedState {
        let hasAuthStatus: Bool
        let hasOAuthToken: Bool
    }

    private nonisolated static func antigravityPersistedState() -> AntigravityPersistedState {
        let dbPath = FileManager.default.realHomeDirectory
            .appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb").path
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return AntigravityPersistedState(hasAuthStatus: false, hasOAuthToken: false)
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return AntigravityPersistedState(hasAuthStatus: false, hasOAuthToken: false)
        }
        defer { sqlite3_close(db) }

        func hasKey(_ key: String) -> Bool {
            var stmt: OpaquePointer?
            let sql = "SELECT 1 FROM ItemTable WHERE key=? LIMIT 1"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
            return sqlite3_step(stmt) == SQLITE_ROW
        }

        return AntigravityPersistedState(
            hasAuthStatus: hasKey("antigravityAuthStatus") || hasKey("antigravityUnifiedStateSync.userStatus"),
            hasOAuthToken: hasKey("antigravityUnifiedStateSync.oauthToken")
        )
    }

    // 바이너리 경로 캐시 — Process() 실행은 비용이 크므로 앱 생명주기 동안 한 번만 수행
    private nonisolated static func binaryExists(named name: String) -> Bool {
        resolvedBinaryURL(named: name) != nil
    }

    private nonisolated static func resolvedBinaryURL(named name: String) -> URL? {
        if let cached = stateStore.cachedBinaryURL(named: name) {
            return cached
        }

        let result = _resolvedBinaryURL(named: name)
        stateStore.storeBinaryURL(result, for: name)

        return result
    }

    private nonisolated static func _resolvedBinaryURL(named name: String) -> URL? {
        let fm = FileManager.default
        // 파일시스템 검색만으로 빠르게 해결 시도 (Process 실행 없음)
        for directory in binaryCandidateDirectories() {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        // 파일시스템에서 찾지 못한 경우에만 셸 실행 (비용이 큰 fallback)
        if let shellPath = shellBinaryPath(named: name) {
            let url = URL(fileURLWithPath: shellPath)
            if fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        return nil
    }

    private nonisolated static func shellBinaryPath(named name: String) -> String? {
        // 중요: `-l` (login shell) 플래그를 절대 사용하지 말 것.
        // login shell은 사용자의 .zprofile/.zshrc를 소싱하며,
        // 그 안에서 `claude` 같은 CLI를 자동 실행하면 child process(2.1.112 등)가
        // Documents/Music 등 macOS 보호 폴더에 접근하면서 TCC 프롬프트를 유발한다.
        // 따라서 non-login, non-interactive 모드로만 `command -v`를 호출한다.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "command -v \(name)"]

        // 사용자 profile 스크립트에 의존하지 않도록 명시적 최소 PATH 사용
        let home = FileManager.default.realHomeDirectory.path
        var env: [String: String] = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(home)/.bun/bin:\(home)/.npm/bin:\(home)/.local/bin:\(home)/bin",
            "HOME": home,
            "LANG": "C",
        ]
        if let user = ProcessInfo.processInfo.environment["USER"] {
            env["USER"] = user
        }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private nonisolated static func binaryCandidateDirectories() -> [String] {
        let home = FileManager.default.realHomeDirectory.path
        let envPaths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let fallbackPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "\(home)/.bun/bin",
            "\(home)/.npm/bin",
            "\(home)/.local/bin",
            "\(home)/bin",
        ]
        return Array(Set(envPaths + fallbackPaths))
    }

    private nonisolated static func geminiAuthType() -> GeminiAuthType {
        let settingsURL = FileManager.default.realHomeDirectory
            .appendingPathComponent(".gemini/settings.json")

        guard
            let data = try? Data(contentsOf: settingsURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let security = json["security"] as? [String: Any],
            let auth = security["auth"] as? [String: Any],
            let selectedType = auth["selectedType"] as? String
        else {
            return .unknown
        }

        return GeminiAuthType(rawValue: selectedType) ?? .unknown
    }

    /// Blocking. 백그라운드 경로 전용.
    /// CLI 탐색 + JSON 파싱 포함.
    static func geminiSignals() -> GeminiEnvironmentSignals {
        let signals = uncachedGeminiSignals()
        stateStore.storeGeminiSignals(signals, cachedAt: Date())
        return signals
    }

    private nonisolated static func uncachedGeminiSignals() -> GeminiEnvironmentSignals {
        GeminiEnvironmentSignals(
            hasBinary: binaryExists(named: "gemini"),
            authType: geminiAuthType(),
            credentialState: geminiCredentialState()
        )
    }

    private nonisolated static func geminiCredentialState() -> GeminiCredentialState {
        let credsURL = FileManager.default.realHomeDirectory
            .appendingPathComponent(".gemini/oauth_creds.json")
        guard
            let data = try? Data(contentsOf: credsURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .missing
        }

        let accessToken = (json["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshToken = (json["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let expiryDate: Date? = {
            if let expiryMs = json["expiry_date"] as? Double {
                return Date(timeIntervalSince1970: expiryMs / 1000)
            }
            if let expiryMs = json["expiry_date"] as? Int {
                return Date(timeIntervalSince1970: Double(expiryMs) / 1000)
            }
            return nil
        }()

        let hasUsableAccessToken = {
            guard let accessToken, !accessToken.isEmpty else { return false }
            guard let expiryDate else { return true }
            return expiryDate > Date()
        }()

        if hasUsableAccessToken {
            return .usable
        }
        if let refreshToken, !refreshToken.isEmpty {
            return .refreshOnly
        }
        return .missing
    }
}
