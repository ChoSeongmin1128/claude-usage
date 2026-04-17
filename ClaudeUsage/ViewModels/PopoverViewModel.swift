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

    // ProviderEnvironmentDetector 결과 캐시 — SwiftUI body 렌더링 중 블로킹 호출 방지
    private var cachedGeminiEnvStatus: ProviderEnvironmentStatus?
    private var cachedAntigravityEnvStatus: ProviderEnvironmentStatus?
    private var cachedGeminiSignals = ProviderEnvironmentDetector.geminiSignals()
    private var cachedAntigravitySignals = ProviderEnvironmentDetector.antigravitySignals()

    var onRefreshService: ((PopoverService) -> Void)?
    var onOpenSettingsForService: ((PopoverService) -> Void)?
    var onServiceSelected: ((PopoverService) -> Void)?
    var onPinChanged: ((PopoverService, Bool) -> Void)?
    var onLayoutChanged: ((PopoverService, PopoverLayoutRefreshReason) -> Void)?

    func snapshot(for service: PopoverService) -> RuntimeProviderSnapshot? {
        runtimeSnapshots[service]
    }

    var claudeUsage: ClaudeUsageResponse? {
        snapshot(for: .claude)?.claudeUsage
    }

    var codexUsage: CodexUsageResponse? {
        snapshot(for: .codex)?.codexUsage
    }

    var geminiUsage: GeminiUsageResponse? {
        snapshot(for: .gemini)?.geminiUsage
    }

    var antigravityUsage: AntigravityUsageResponse? {
        snapshot(for: .antigravity)?.antigravityUsage
    }

    func refresh() {
        self.onRefreshService?(self.selectedService)
    }

    func refresh(service: PopoverService) {
        self.onRefreshService?(service)
    }

    func openSettings() {
        self.onOpenSettingsForService?(self.selectedService)
    }

    func openSettings(for service: PopoverService) {
        self.onOpenSettingsForService?(service)
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

    func providerShellCards(settings: AppSettings) -> [ProviderShellCard] {
        SettingsProviderRegistry.providerShellDescriptors.map { descriptor in
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
        case .gemini:
            return geminiRuntimeServiceState(settings: settings)
        case .antigravity:
            return antigravityRuntimeServiceState(settings: settings)
        }
    }

    private func geminiRuntimeServiceState(settings: AppSettings) -> RuntimeServiceState {
        let isEnabled = settings.isProviderEnabled(.gemini)
        let environmentStatus = cachedGeminiEnvStatus
        let signals = cachedGeminiSignals
        let snapshot = runtimeSnapshots[.gemini]
        let runtimeError = snapshot?.error
        let requiresInteractiveSetup: Bool = {
            if !signals.hasBinary { return signals.credentialState == .missing }
            switch signals.authType {
            case .apiKey, .vertexAI: return true
            case .oauthPersonal, .unknown: return signals.credentialState == .missing
            }
        }()
        let missingCredential = (environmentStatus?.credentialState ?? .missing) == .missing
        let isAuthRequired = isEnabled
            && requiresInteractiveSetup
            && missingCredential
            && !(snapshot?.hasContent ?? false)
            && !(snapshot?.isLoading ?? false)
        let summaryState = Self.resolveGeminiSummaryState(
            snapshot: snapshot,
            environmentStatus: environmentStatus,
            signals: signals,
            isEnabled: isEnabled,
            isAuthRequired: isAuthRequired
        )

        return RuntimeServiceState(
            service: .gemini,
            summary: summaryState.summary,
            meta: snapshot.flatMap(runtimeMeta(for:)),
            lastUpdated: snapshot?.lastUpdated,
            isLoading: snapshot?.isLoading ?? false,
            error: runtimeError,
            hasContent: geminiUsage != nil,
            isAuthRequired: isAuthRequired,
            shouldShowWarningDot: shouldShowWarningDot(snapshot: snapshot, isAuthRequired: isAuthRequired)
        )
    }

    private func antigravityRuntimeServiceState(settings: AppSettings) -> RuntimeServiceState {
        let isEnabled = settings.isProviderEnabled(.antigravity)
        let environmentStatus = cachedAntigravityEnvStatus
        let signals = cachedAntigravitySignals
        let snapshot = runtimeSnapshots[.antigravity]
        let runtimeError = snapshot?.error
        let requiresInteractiveSetup = !signals.hasRuntimeConnection && !signals.hasPersistedAuthState
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
        case .gemini:
            return runtimeServiceState(for: .gemini, settings: settings).summary
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
        case .gemini:
            return runtimeServiceState(for: .gemini, settings: .shared).meta
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
        case .gemini, .antigravity:
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
        case .gemini, .antigravity:
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
        case .gemini, .antigravity:
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
                return kind == .gemini ? "갱신 필요" : "연결 준비"
            case .probingRuntime:
                return "연결 확인 중"
            case .waitingForApp:
                return "앱 필요"
            case .authRequired:
                return kind == .gemini ? "로그인 필요" : "연결 필요"
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
        self.cachedGeminiEnvStatus = ProviderEnvironmentDetector.cachedStatus(for: .gemini)
        self.cachedAntigravityEnvStatus = ProviderEnvironmentDetector.cachedStatus(for: .antigravity)
        // signals 는 대부분 FS/파일 접근이라 빠르지만 Gemini 의 바이너리
        // lookup 이 최초 1회 /bin/sh 를 호출하므로 백그라운드에서 업데이트.
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
        if let usage = snapshot.geminiUsage {
            let tertiary = usage.tertiaryWindow.map { " · Lite \(Int($0.usedPercent.rounded()))%" } ?? ""
            return "Pro \(Int(usage.primaryPercentage.rounded()))% · Flash \(Int(usage.secondaryPercentage.rounded()))%\(tertiary)"
        }
        if let usage = snapshot.antigravityUsage {
            let tertiary = usage.tertiaryWindow.map { " · Flash \(Int($0.usedPercent.rounded()))%" } ?? ""
            return "Claude \(Int(usage.primaryPercentage.rounded()))% · Pro \(Int(usage.secondaryPercentage.rounded()))%\(tertiary)"
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
        case .gemini:
            let isEnabled = settings.isProviderEnabled(.gemini)
            let environmentStatus = cachedGeminiEnvStatus
            let signals = cachedGeminiSignals
            let snapshot = runtimeSnapshots[.gemini]
            let requiresInteractiveSetup: Bool = {
                if !signals.hasBinary { return signals.credentialState == .missing }
                switch signals.authType {
                case .apiKey, .vertexAI: return true
                case .oauthPersonal, .unknown: return signals.credentialState == .missing
                }
            }()
            let missingCredential = (environmentStatus?.credentialState ?? .missing) == .missing
            let isAuthRequired = isEnabled
                && requiresInteractiveSetup
                && missingCredential
                && !(snapshot?.hasContent ?? false)
                && !(snapshot?.isLoading ?? false)
            return Self.resolveGeminiSummaryState(
                snapshot: snapshot,
                environmentStatus: environmentStatus,
                signals: signals,
                isEnabled: isEnabled,
                isAuthRequired: isAuthRequired
            )
        case .antigravity:
            let isEnabled = settings.isProviderEnabled(.antigravity)
            let environmentStatus = cachedAntigravityEnvStatus
            let signals = cachedAntigravitySignals
            let snapshot = runtimeSnapshots[.antigravity]
            let requiresInteractiveSetup = !signals.hasRuntimeConnection && !signals.hasPersistedAuthState
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

    static func resolveGeminiSummaryState(
        snapshot: RuntimeProviderSnapshot?,
        environmentStatus: ProviderEnvironmentStatus?,
        signals: GeminiEnvironmentSignals,
        isEnabled: Bool,
        isAuthRequired: Bool
    ) -> LocalProviderSummaryState {
        if !isEnabled {
            return .init(phase: .disabled, summary: "비활성화됨")
        }
        if let usage = snapshot?.geminiUsage {
            return .init(
                phase: .ready,
                summary: "Pro \(Int(usage.primaryPercentage.rounded()))% · Flash \(Int(usage.secondaryPercentage.rounded()))%"
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
        if environmentStatus?.credentialState == .refreshable, environmentStatus?.runtimeReachability == true {
            return .init(phase: .refreshingCredential, summary: "토큰 갱신 후 연결 확인 중")
        }
        if environmentStatus?.runtimeReachability == true {
            return .init(phase: .probingRuntime, summary: "연결 확인 중")
        }
        if let error = snapshot?.error, !shouldSuppressRecoverableError(error, runtimeReachability: environmentStatus?.runtimeReachability ?? false) {
            if error.isDefinitiveAuthFailure || snapshot?.fetchState == .authFailure || isAuthRequired {
                return .init(phase: .authRequired, summary: "로그인 필요")
            }
            return .init(phase: .temporaryError, summary: error.errorDescription ?? "일시 조회 실패")
        }
        if snapshot?.fetchState == .authFailure || isAuthRequired {
            return .init(phase: .authRequired, summary: "로그인 필요")
        }
        if signals.credentialState == .missing {
            return .init(phase: .authRequired, summary: environmentStatus?.summary ?? "로그인 필요")
        }
        return .init(phase: .probingRuntime, summary: environmentStatus?.summary ?? "Gemini 조회를 준비 중입니다")
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
            return .init(
                phase: .ready,
                summary: "Claude \(Int(usage.primaryPercentage.rounded()))% · Pro \(Int(usage.secondaryPercentage.rounded()))%"
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
        if signals.hasRuntimeConnection {
            return .init(phase: .probingRuntime, summary: "quota 서버 연결 확인 중")
        }
        if signals.hasPersistedAuthState {
            return .init(phase: .waitingForApp, summary: "앱 실행 후 연결 확인 중")
        }
        if let error = snapshot?.error, !shouldSuppressRecoverableError(error, runtimeReachability: environmentStatus?.runtimeReachability ?? false) {
            if error.isDefinitiveAuthFailure || snapshot?.fetchState == .authFailure || isAuthRequired {
                return .init(phase: .authRequired, summary: environmentStatus?.summary ?? "앱 실행 또는 인증이 필요합니다")
            }
            return .init(phase: .temporaryError, summary: error.errorDescription ?? "일시 조회 실패")
        }
        if snapshot?.fetchState == .authFailure || isAuthRequired {
            return .init(phase: .authRequired, summary: environmentStatus?.summary ?? "앱 실행 또는 인증이 필요합니다")
        }
        if signals.appRunning && !signals.hasPersistedAuthState {
            return .init(phase: .authRequired, summary: environmentStatus?.summary ?? "앱 실행 또는 인증이 필요합니다")
        }
        if environmentStatus?.isDetected == true {
            return .init(phase: .waitingForApp, summary: environmentStatus?.summary ?? "앱 실행 후 연결 확인 중")
        }
        return .init(phase: .authRequired, summary: environmentStatus?.summary ?? "앱 실행 또는 인증이 필요합니다")
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
