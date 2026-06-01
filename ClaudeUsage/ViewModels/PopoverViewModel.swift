import Foundation
import SwiftUI
import Combine

@MainActor
final class PopoverViewModel: ObservableObject {
    struct ProviderShellCard: Identifiable, Sendable, Equatable {
        let kind: AppProviderKind
        let title: String
        let icon: String
        let summary: String
        let detail: String?
        let badgeTitle: String?
        let isSelectable: Bool

        var id: String { kind.rawValue }
    }

    struct RuntimeServiceState: Sendable {
        let service: PopoverService
        let summary: String
        let meta: String?
        let lastUpdated: Date?
        let isLoading: Bool
        let error: APIError?
        let hasContent: Bool
        let isAuthRequired: Bool
        let shouldShowWarningDot: Bool
    }

    struct LocalProviderSummaryState: Sendable, Equatable {
        let phase: LocalProviderSummaryPhase
        let summary: String
    }

    @Published var selectedService: PopoverService = .claude
    @Published var overage: OverageSpendLimitResponse?
    @Published var systemStatus: ClaudeSystemStatus?
    @Published var usageHealthSnapshot: ClaudeAPIService.UsageHealthSnapshot?
    @Published var nextUsageRetryAt: Date?
    @Published private(set) var claudeSetupPresentation: ClaudeSetupPresentation?
    @Published private(set) var runtimeSnapshots: [PopoverService: RuntimeProviderSnapshot] = [:]

    private let updateRuntimeState: UpdateRuntimeState
    private var cancellables = Set<AnyCancellable>()

    // ProviderEnvironmentDetector 결과 캐시 — SwiftUI body 렌더링 중 블로킹 호출 방지
    private var cachedAntigravityEnvStatus: ProviderEnvironmentStatus?
    // 초기값은 cache-only — 콜드 캐시면 nil 로 출발해서 환경 warm-up 후에 채워짐.
    // VM 생성 시점에 /bin/ps · SQLite · JSON 파싱을 돌리면 첫 popover/메뉴바
    // 클릭이 1초 가까이 버벅거리므로 여기서는 blocking 을 금지한다.
    private var cachedAntigravitySignals: AntigravityEnvironmentSignals?

    var onRefreshService: ((PopoverService) -> Void)?
    var onOpenSettingsForService: ((PopoverService) -> Void)?
    var onServiceSelected: ((PopoverService) -> Void)?
    var onPinChanged: ((PopoverService, Bool) -> Void)?
    var onLayoutChanged: ((PopoverService, PopoverLayoutRefreshReason) -> Void)?

    /// 수동 새로고침 throttle. 마지막 호출 시각을 service 별로 기록해 5초 이내 재호출을 무시한다.
    /// 사용자가 "조회 실패" 카드를 보고 빠르게 연타하는 패턴이 가장 자주 한도를 침범하므로,
    /// 자동 새로고침 주기(30초) 와 별개로 수동 호출에만 floor 를 적용한다.
    private var lastManualRefreshAt: [PopoverService: Date] = [:]
    /// 마지막 클릭이 throttle 로 막혔는지 — UI 가 "잠시 기다려 주세요" 표시 등에 사용 가능.
    @Published private(set) var lastManualRefreshThrottledUntil: Date?
    /// 클릭 즉시 spinner 가 돌도록 보장하는 짧은 윈도우 (외부 isLoading 토글 지연 보완).
    /// 사용자가 새로고침 버튼을 눌렀을 때 "눌렸나?" 라는 불확실성이 가장 큰 UX 손해이므로,
    /// 최소 0.5초간 spinner 를 강제로 보여 즉각 시각 피드백을 보장한다.
    @Published private(set) var manualRefreshSpinnerUntil: Date?
    private static let manualRefreshThrottleSeconds: TimeInterval = 5
    private static let manualRefreshSpinnerMinDuration: TimeInterval = 0.5

    /// 클릭 즉시 spinner 가 활성 상태인지 — PopoverView 가 ProgressView 강제 표시에 사용.
    nonisolated var isManualRefreshSpinnerActive: Bool {
        // nonisolated 라 직접 published state 접근 불가 — 메인 actor hop 없이도 동작하도록
        // until 시각만 비교. UI 가 frequent 하게 호출하지만 stale read 위험 없음 (시각 비교).
        MainActor.assumeIsolated {
            guard let until = manualRefreshSpinnerUntil else { return false }
            return Date() < until
        }
    }
    /// 팝오버의 미인증 상태에서 사용자가 한 번에 wizard 로그인 윈도우로 갈 수 있게 하는 콜백.
    /// 기본 동작: AppDelegate.showLoginWindow(startChromeImportOnOpen: true).
    var onStartClaudeLogin: (() -> Void)?

    init(updateRuntimeState: UpdateRuntimeState? = nil) {
        self.updateRuntimeState = updateRuntimeState ?? UpdateRuntimeState.shared
        self.updateRuntimeState.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        self.updateRuntimeState.bootstrapIfNeeded()
    }

    func snapshot(for service: PopoverService) -> RuntimeProviderSnapshot? {
        runtimeSnapshots[service]
    }

    var claudeUsage: ClaudeUsageResponse? {
        snapshot(for: .claude)?.claudeUsage
    }

    var codexUsage: CodexUsageResponse? {
        snapshot(for: .codex)?.codexUsage
    }

    var antigravityUsage: AntigravityUsageResponse? {
        snapshot(for: .antigravity)?.antigravityUsage
    }

    func refresh() {
        self.refresh(service: self.selectedService)
    }

    func refresh(service: PopoverService) {
        let now = Date()
        if let last = lastManualRefreshAt[service],
           now.timeIntervalSince(last) < Self.manualRefreshThrottleSeconds {
            // 직전 호출 후 N초 미만 — 사용자가 연타한 케이스. 호출 자체를 막아 한도 침범 예방.
            let unblockedAt = last.addingTimeInterval(Self.manualRefreshThrottleSeconds)
            lastManualRefreshThrottledUntil = unblockedAt
            return
        }
        lastManualRefreshAt[service] = now
        lastManualRefreshThrottledUntil = nil
        // 클릭 즉시 시각 피드백: 외부 isLoading 이 토글되기 전이라도 spinner 를 보여준다.
        let spinnerTarget = now.addingTimeInterval(Self.manualRefreshSpinnerMinDuration)
        manualRefreshSpinnerUntil = spinnerTarget
        self.onRefreshService?(service)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.manualRefreshSpinnerMinDuration * 1_000_000_000))
            guard let self else { return }
            if self.manualRefreshSpinnerUntil == spinnerTarget {
                self.manualRefreshSpinnerUntil = nil
            }
        }
    }

    func openSettings() {
        self.onOpenSettingsForService?(self.selectedService)
    }

    func openSettings(for service: PopoverService) {
        self.onOpenSettingsForService?(service)
    }

    /// 팝오버 미인증 카드의 "Claude 로그인 시작" 버튼이 호출. 콜백이 등록되지 않은 경우
    /// (예: provider 가 Claude 가 아닌 경우)에는 안전한 fallback 으로 설정 창을 연다.
    func startClaudeLogin() {
        if let onStartClaudeLogin {
            onStartClaudeLogin()
        } else {
            openSettings(for: .claude)
        }
    }

    func selectService(_ service: PopoverService) {
        guard selectedService != service else { return }
        self.selectedService = service
        self.onServiceSelected?(service)
    }

    func requestLayoutRefresh(reason: PopoverLayoutRefreshReason) {
        self.onLayoutChanged?(self.selectedService, reason)
    }

    func requestLayoutRefresh(for service: PopoverService, reason: PopoverLayoutRefreshReason) {
        self.onLayoutChanged?(service, reason)
    }

    func openUsagePage() {
        guard let url = URL(string: "https://claude.ai/settings/usage") else { return }
        NSWorkspace.shared.open(url)
    }

    func downloadLatestRelease() {
        Task {
            let url = await UpdateService.shared.latestDownloadURL()
            NSWorkspace.shared.open(url)
        }
    }

    var shouldShowUpdateButton: Bool {
        updateRuntimeState.showsPopoverButton
    }

    var updateButtonSymbolName: String {
        updateRuntimeState.popoverButtonSymbolName
    }

    var updateButtonHelpText: String {
        updateRuntimeState.popoverButtonHelpText
    }

    func performUpdatePrimaryAction() {
        updateRuntimeState.performPrimaryAction()
    }

    func providerShellCards(settings: AppSettings) -> [ProviderShellCard] {
        SettingsProviderRegistry.providerShellDescriptors
            .filter { settings.isProviderExposed($0.kind) }
            .map { descriptor in
                ProviderShellCard(
                    kind: descriptor.kind,
                    title: descriptor.title,
                    icon: descriptor.icon,
                    summary: shellSummary(for: descriptor.kind, settings: settings, baseSummary: descriptor.summary),
                    detail: shellDetail(for: descriptor.kind, settings: settings, baseDetail: descriptor.detail),
                    badgeTitle: shellBadgeTitle(for: descriptor.kind, settings: settings, baseBadge: descriptor.role.badgeTitle),
                    isSelectable: descriptor.supportsPopoverSelection
                )
            }
    }

    var hasClaudeCredential: Bool {
        claudeSetupPresentation?.progress.hasReadyCredential
            ?? usageHealthSnapshot?.runtime.credentialAvailability.hasAnyCredential
            ?? false
    }

    func runtimeServiceState(for service: PopoverService, settings: AppSettings) -> RuntimeServiceState {
        switch service {
        case .claude:
            let isEnabled = settings.isProviderEnabled(.claude)
            let snapshot = snapshot(for: service)
            let isAuthRequired = isEnabled && !(snapshot?.hasCredential ?? false) && !(snapshot?.hasContent ?? false) && !(snapshot?.isLoading ?? false)
            let summary = snapshot.map { runtimeSummary(for: $0, isEnabled: isEnabled, isAuthRequired: isAuthRequired) }
                ?? (!isEnabled ? "비활성화됨" : (isAuthRequired ? "인증 필요" : "데이터를 아직 불러오지 못했습니다"))
            let meta = snapshot.flatMap(runtimeMeta(for:))
            return RuntimeServiceState(
                service: .claude,
                summary: summary,
                meta: meta,
                lastUpdated: snapshot?.lastUpdated,
                isLoading: snapshot?.isLoading ?? false,
                error: snapshot?.error,
                hasContent: snapshot?.hasContent ?? false,
                isAuthRequired: isAuthRequired,
                shouldShowWarningDot: shouldShowWarningDot(snapshot: snapshot, isAuthRequired: isAuthRequired)
            )
        case .codex:
            let isEnabled = settings.isProviderEnabled(.codex)
            let snapshot = snapshot(for: service)
            let isAuthRequired = isEnabled && !(snapshot?.hasCredential ?? false) && !(snapshot?.hasContent ?? false) && !(snapshot?.isLoading ?? false)
            let summary = snapshot.map { runtimeSummary(for: $0, isEnabled: isEnabled, isAuthRequired: isAuthRequired) }
                ?? (!isEnabled ? "비활성화됨" : (isAuthRequired ? "인증 필요" : "데이터를 아직 불러오지 못했습니다"))
            let meta = snapshot.flatMap(runtimeMeta(for:))
            return RuntimeServiceState(
                service: .codex,
                summary: summary,
                meta: meta,
                lastUpdated: snapshot?.lastUpdated,
                isLoading: snapshot?.isLoading ?? false,
                error: snapshot?.error,
                hasContent: snapshot?.hasContent ?? false,
                isAuthRequired: isAuthRequired,
                shouldShowWarningDot: shouldShowWarningDot(snapshot: snapshot, isAuthRequired: isAuthRequired)
            )
        case .antigravity:
            return antigravityRuntimeServiceState(settings: settings)
        }
    }

    private func antigravityRuntimeServiceState(settings: AppSettings) -> RuntimeServiceState {
        let isEnabled = settings.isProviderEnabled(.antigravity)
        let environmentStatus = cachedAntigravityEnvStatus
        let signalsCached = cachedAntigravitySignals
        let signals = signalsCached ?? .empty
        let snapshot = runtimeSnapshots[.antigravity]
        let runtimeError = snapshot?.error
        // 캐시 cold 상태에서는 auth prompt 를 보류 — warm-up 끝나면 정확한 상태로 전환.
        let requiresInteractiveSetup: Bool = {
            guard signalsCached != nil else { return false }
            return AntigravitySetupPolicy.requiresInteractiveSetup(
                dataSource: .auto,
                signals: signals
            )
        }()
        let missingCredential = (environmentStatus?.credentialState ?? .missing) == .missing
        let isAuthRequired = isEnabled
            && requiresInteractiveSetup
            && missingCredential
            && !(snapshot?.hasContent ?? false)
            && !(snapshot?.isLoading ?? false)
        let summaryState = Self.resolveAntigravitySummaryState(
            snapshot: snapshot,
            environmentStatus: environmentStatus,
            signals: signals,
            isEnabled: isEnabled,
            isAuthRequired: isAuthRequired
        )

        return RuntimeServiceState(
            service: .antigravity,
            summary: summaryState.summary,
            meta: snapshot.flatMap(runtimeMeta(for:)),
            lastUpdated: snapshot?.lastUpdated,
            isLoading: snapshot?.isLoading ?? false,
            error: runtimeError,
            hasContent: antigravityUsage != nil,
            isAuthRequired: isAuthRequired,
            shouldShowWarningDot: shouldShowWarningDot(snapshot: snapshot, isAuthRequired: isAuthRequired)
        )
    }

    func overviewSummary(for kind: AppProviderKind, settings: AppSettings) -> String {
        switch kind {
        case .claude:
            return runtimeServiceState(for: .claude, settings: settings).summary
        case .codex:
            return runtimeServiceState(for: .codex, settings: settings).summary
        case .antigravity:
            return runtimeServiceState(for: .antigravity, settings: settings).summary
        }
    }

    func overviewMeta(for kind: AppProviderKind) -> String? {
        switch kind {
        case .claude:
            return runtimeServiceState(for: .claude, settings: .shared).meta
        case .codex:
            return runtimeServiceState(for: .codex, settings: .shared).meta
        case .antigravity:
            return runtimeServiceState(for: .antigravity, settings: .shared).meta
        }
    }

    func overviewCard(for kind: AppProviderKind, settings: AppSettings) -> ProviderShellCard {
        let descriptor = SettingsProviderRegistry.providerShellDescriptor(for: kind)
        return ProviderShellCard(
            kind: descriptor.kind,
            title: descriptor.title,
            icon: descriptor.icon,
            summary: overviewSummary(for: kind, settings: settings),
            detail: overviewMeta(for: kind),
            badgeTitle: descriptor.role.badgeTitle,
            isSelectable: descriptor.supportsPopoverSelection
        )
    }

    private func shellSummary(for kind: AppProviderKind, settings: AppSettings, baseSummary: String) -> String {
        switch kind {
        case .claude:
            return settings.isProviderEnabled(.claude) ? baseSummary : "비활성화됨"
        case .codex:
            return settings.isProviderEnabled(.codex) ? baseSummary : "비활성화됨"
        case .antigravity:
            return settings.isProviderEnabled(kind) ? baseSummary : "비활성화됨"
        }
    }

    private func shellDetail(for kind: AppProviderKind, settings: AppSettings, baseDetail: String?) -> String? {
        switch kind {
        case .claude:
            if settings.isProviderEnabled(.claude) {
                return baseDetail
            }
            return "현재는 설정만 유지하고 있습니다."
        case .codex:
            if settings.isProviderEnabled(.codex) {
                return baseDetail
            }
            return "현재는 설정만 유지하고 있습니다."
        case .antigravity:
            if settings.isProviderEnabled(kind) {
                // SwiftUI body 경로 — SWR (blocking 금지)
                return ProviderEnvironmentDetector.staleWhileRevalidate(for: kind)?.summary
                    ?? baseDetail
                    ?? "자격 또는 로컬 상태를 확인해 주세요."
            }
            return "비활성화된 상태입니다."
        }
    }

    private func shellBadgeTitle(for kind: AppProviderKind, settings: AppSettings, baseBadge: String?) -> String? {
        switch kind {
        case .claude:
            return settings.isProviderEnabled(.claude) ? "활성" : "비활성"
        case .codex:
            return settings.isProviderEnabled(.codex) ? "활성" : "비활성"
        case .antigravity:
            guard settings.isProviderEnabled(kind) else { return "비활성" }
            guard let service = kind.runtimeService else { return baseBadge }
            let phase = localProviderSummaryState(for: service, settings: settings)?.phase
            switch phase {
            case .disabled:
                return "비활성"
            case .loading:
                return "조회 중"
            case .backoff:
                return "재시도 대기"
            case .refreshingCredential:
                return "연결 준비"
            case .probingRuntime:
                return "연결 확인 중"
            case .waitingForApp:
                return "앱 필요"
            case .authRequired:
                return "연결 필요"
            case .temporaryError:
                return "일시 실패"
            case .ready:
                return "활성"
            case .none:
                return baseBadge
            }
        }
    }

    func update(
        snapshots: [RuntimeProviderSnapshot],
        overage: OverageSpendLimitResponse? = nil,
        setupPresentation: ClaudeSetupPresentation? = nil
    )
    {
        self.runtimeSnapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.service, $0) })
        self.claudeSetupPresentation = setupPresentation
        if let overage { self.overage = overage }

        // 환경 상태 캐시 갱신 — main thread 에서 실행되므로 blocking 금지.
        // 읽기는 이미 캐시된 값만 (백그라운드 워밍이 주기적으로 업데이트).
        self.cachedAntigravityEnvStatus = ProviderEnvironmentDetector.cachedStatus(for: .antigravity)
        // signals 도 캐시된 값만. 콜드 캐시면 nil → 백그라운드 warm-up 으로
        // 채워진 뒤 다음 update() 에서 반영됨.
        self.cachedAntigravitySignals = ProviderEnvironmentDetector.cachedAntigravitySignals()
        ProviderEnvironmentDetector.refreshAllInBackground()
    }

    private func runtimeSummary(
        for snapshot: RuntimeProviderSnapshot,
        isEnabled: Bool,
        isAuthRequired: Bool
    ) -> String {
        if !isEnabled {
            return "비활성화됨"
        }
        if isAuthRequired {
            return "인증 필요"
        }
        if let usage = snapshot.claudeUsage {
            return "현재 \(Int(usage.fiveHour.utilization.rounded()))% · 주간 \(Int((usage.sevenDay?.utilization ?? 0).rounded()))%"
        }
        if let usage = snapshot.codexUsage {
            return "현재 \(Int((usage.rateLimit?.primaryWindow?.utilization ?? 0).rounded()))% · 주간 \(Int((usage.rateLimit?.secondaryWindow?.utilization ?? 0).rounded()))%"
        }
        if let usage = snapshot.antigravityUsage {
            guard usage.hasUsageWindows else {
                return "계정 확인됨 · 수치 미지원"
            }
            return usage.modelSummary()
        }
        if snapshot.isLoading {
            return "조회 중"
        }
        if snapshot.hasBackoff,
           let nextRefreshAllowedAt = snapshot.nextRefreshAllowedAt,
           let remainingSeconds = RefreshExecutionPolicy.remainingBackoffSeconds(until: nextRefreshAllowedAt)
        {
            return "약 \(remainingSeconds)초 후 다시 시도"
        }
        if let error = snapshot.error {
            if shouldSuppressRecoverableError(error, kind: snapshot.kind),
               let environmentStatus = ProviderEnvironmentDetector.staleWhileRevalidate(for: snapshot.kind) {
                return environmentStatus.summary
            }
            return error.errorDescription ?? "조회 실패"
        }
        // SwiftUI body 경로 — SWR (blocking 금지)
        return ProviderEnvironmentDetector.staleWhileRevalidate(for: snapshot.kind)?.summary ?? "데이터를 아직 불러오지 못했습니다"
    }

    private func runtimeMeta(for snapshot: RuntimeProviderSnapshot) -> String? {
        guard snapshot.hasContent else {
            return snapshot.lastUpdated.map(relativeTimestamp(for:))
        }
        if snapshot.isLoading {
            return "갱신 중"
        }
        guard let lastUpdated = snapshot.lastUpdated else {
            return nil
        }
        let relative = relativeTimestamp(for: lastUpdated)
        if snapshot.lastAttemptState == .temporaryFailure {
            if snapshot.hasBackoff {
                return "재시도 대기 · 마지막 성공 \(relative)"
            }
            return "마지막 성공 \(relative)"
        }
        return relative
    }

    private func shouldShowWarningDot(
        snapshot: RuntimeProviderSnapshot?,
        isAuthRequired: Bool
    ) -> Bool {
        guard let snapshot else {
            return isAuthRequired
        }
        if isAuthRequired || snapshot.hasAuthError {
            return true
        }
        if snapshot.isStaleRecoverable {
            return false
        }
        return snapshot.error != nil
    }

    private func relativeTimestamp(for date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    func localProviderSummaryState(for service: PopoverService, settings: AppSettings) -> LocalProviderSummaryState? {
        switch service {
        case .antigravity:
            let isEnabled = settings.isProviderEnabled(.antigravity)
            let environmentStatus = cachedAntigravityEnvStatus
            let signalsCached = cachedAntigravitySignals
            let signals = signalsCached ?? .empty
            let snapshot = runtimeSnapshots[.antigravity]
            let requiresInteractiveSetup: Bool = {
                guard signalsCached != nil else { return false }
                return AntigravitySetupPolicy.requiresInteractiveSetup(
                    dataSource: .auto,
                    signals: signals
                )
            }()
            let missingCredential = (environmentStatus?.credentialState ?? .missing) == .missing
            let isAuthRequired = isEnabled
                && requiresInteractiveSetup
                && missingCredential
                && !(snapshot?.hasContent ?? false)
                && !(snapshot?.isLoading ?? false)
            return Self.resolveAntigravitySummaryState(
                snapshot: snapshot,
                environmentStatus: environmentStatus,
                signals: signals,
                isEnabled: isEnabled,
                isAuthRequired: isAuthRequired
            )
        case .claude, .codex:
            return nil
        }
    }

    static func resolveAntigravitySummaryState(
        snapshot: RuntimeProviderSnapshot?,
        environmentStatus: ProviderEnvironmentStatus?,
        signals: AntigravityEnvironmentSignals,
        isEnabled: Bool,
        isAuthRequired: Bool
    ) -> LocalProviderSummaryState {
        if !isEnabled {
            return .init(phase: .disabled, summary: "비활성화됨")
        }
        if let usage = snapshot?.antigravityUsage {
            guard usage.hasUsageWindows else {
                return .init(
                    phase: .ready,
                    summary: "계정 확인됨 · 수치 미지원"
                )
            }
            return .init(
                phase: .ready,
                summary: usage.modelSummary()
            )
        }
        if snapshot?.isLoading == true {
            return .init(phase: .loading, summary: "조회 중")
        }
        if let nextRefreshAllowedAt = snapshot?.nextRefreshAllowedAt,
           snapshot?.payload == nil,
           let remainingSeconds = RefreshExecutionPolicy.remainingBackoffSeconds(until: nextRefreshAllowedAt)
        {
            return .init(phase: .backoff, summary: "약 \(remainingSeconds)초 후 다시 시도")
        }
        if let error = snapshot?.error, !shouldSuppressRecoverableError(error, runtimeReachability: environmentStatus?.runtimeReachability ?? false) {
            if error.isDefinitiveAuthFailure || snapshot?.fetchState == .authFailure || isAuthRequired {
                return .init(
                    phase: .authRequired,
                    summary: antigravityAuthRequiredSummary(
                        signals: signals,
                        environmentStatus: environmentStatus
                    )
                )
            }
            return .init(phase: .temporaryError, summary: error.errorDescription ?? "일시 조회 실패")
        }
        if signals.hasOAuthCredential {
            return .init(
                phase: .probingRuntime,
                summary: signals.hasBrokenCLICommand
                    ? "계정 확인됨 · CLI 복구 필요"
                    : "계정 확인됨 · 사용량 조회 준비"
            )
        }
        if signals.hasRuntimeConnection {
            return .init(phase: .probingRuntime, summary: "앱 연결 확인 중")
        }
        let hasRelevantPersistedAuthState = signals.hasCredentialRelevant(to: .auto)
        if hasRelevantPersistedAuthState {
            if signals.hasCLIBinary {
                return .init(phase: .probingRuntime, summary: "사용량 조회 준비")
            }
            return .init(phase: .waitingForApp, summary: "앱 실행 후 연결 확인 중")
        }
        if signals.hasCLISurface {
            return .init(
                phase: signals.hasCLIBinary ? .probingRuntime : .authRequired,
                summary: signals.hasBrokenCLICommand
                    ? "CLI 복구 필요"
                    : signals.hasCLIBinary
                    ? "사용량 조회 준비"
                    : "CLI 설정 감지 · 실행 파일 필요"
            )
        }
        if snapshot?.fetchState == .authFailure || isAuthRequired {
            return .init(
                phase: .authRequired,
                summary: antigravityAuthRequiredSummary(
                    signals: signals,
                    environmentStatus: environmentStatus
                )
            )
        }
        if signals.appRunning && !signals.hasPersistedAuthState {
            return .init(phase: .authRequired, summary: environmentStatus?.summary ?? "앱 실행 또는 인증이 필요합니다")
        }
        if environmentStatus?.isDetected == true {
            return .init(phase: .waitingForApp, summary: environmentStatus?.summary ?? "앱 실행 후 연결 확인 중")
        }
        return .init(phase: .authRequired, summary: environmentStatus?.summary ?? "앱 실행 또는 인증이 필요합니다")
    }

    private static func antigravityAuthRequiredSummary(
        signals: AntigravityEnvironmentSignals,
        environmentStatus: ProviderEnvironmentStatus?
    ) -> String {
        if signals.hasOAuthCredential {
            return "Google 계정 다시 연결 필요"
        }
        if signals.hasCLIBinary {
            return signals.hasBrokenCLICommand ? "CLI 복구 필요" : "CLI 확인 필요"
        }
        return environmentStatus?.summary ?? "앱 실행 또는 인증이 필요합니다"
    }

    private static func shouldSuppressRecoverableError(_ error: APIError, runtimeReachability: Bool) -> Bool {
        error.isTemporaryFailure && runtimeReachability
    }

    private func shouldSuppressRecoverableError(_ error: APIError, kind: AppProviderKind) -> Bool {
        // SwiftUI body 경로 — SWR (blocking 금지)
        guard let status = ProviderEnvironmentDetector.staleWhileRevalidate(for: kind) else {
            return false
        }
        return Self.shouldSuppressRecoverableError(error, runtimeReachability: status.runtimeReachability)
    }
}
