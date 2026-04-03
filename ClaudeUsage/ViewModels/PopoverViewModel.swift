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
            let meta = snapshot?.lastUpdated.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) }
            return RuntimeServiceState(
                service: .claude,
                summary: summary,
                meta: meta,
                lastUpdated: snapshot?.lastUpdated,
                isLoading: snapshot?.isLoading ?? false,
                error: snapshot?.error,
                hasContent: snapshot?.hasContent ?? false,
                isAuthRequired: isAuthRequired,
                shouldShowWarningDot: isAuthRequired || snapshot?.hasAuthError == true || snapshot?.error != nil
            )
        case .codex:
            let isEnabled = settings.isProviderEnabled(.codex)
            let snapshot = snapshot(for: service)
            let isAuthRequired = isEnabled && !(snapshot?.hasCredential ?? false) && !(snapshot?.hasContent ?? false) && !(snapshot?.isLoading ?? false)
            let summary = snapshot.map { runtimeSummary(for: $0, isEnabled: isEnabled, isAuthRequired: isAuthRequired) }
                ?? (!isEnabled ? "비활성화됨" : (isAuthRequired ? "인증 필요" : "데이터를 아직 불러오지 못했습니다"))
            let meta = snapshot?.lastUpdated.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) }
            return RuntimeServiceState(
                service: .codex,
                summary: summary,
                meta: meta,
                lastUpdated: snapshot?.lastUpdated,
                isLoading: snapshot?.isLoading ?? false,
                error: snapshot?.error,
                hasContent: snapshot?.hasContent ?? false,
                isAuthRequired: isAuthRequired,
                shouldShowWarningDot: isAuthRequired || snapshot?.hasAuthError == true || snapshot?.error != nil
            )
        case .gemini:
            return geminiRuntimeServiceState(settings: settings)
        case .antigravity:
            return antigravityRuntimeServiceState(settings: settings)
        }
    }

    private func geminiRuntimeServiceState(settings: AppSettings) -> RuntimeServiceState {
        let isEnabled = settings.isProviderEnabled(.gemini)
        let environmentStatus = ProviderEnvironmentDetector.status(for: .gemini)
        let signals = ProviderEnvironmentDetector.geminiSignals()
        let snapshot = runtimeSnapshots[.gemini]
        let runtimeError = snapshot?.error
        let requiresInteractiveSetup = ProviderEnvironmentDetector.requiresInteractiveSetup(for: .gemini)
        let missingCredential = (environmentStatus?.credentialState ?? .missing) == .missing
        let isAuthRequired = isEnabled && requiresInteractiveSetup && missingCredential
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
            meta: snapshot?.lastUpdated.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) },
            lastUpdated: snapshot?.lastUpdated,
            isLoading: snapshot?.isLoading ?? false,
            error: runtimeError,
            hasContent: geminiUsage != nil,
            isAuthRequired: isAuthRequired,
            shouldShowWarningDot: isAuthRequired || (runtimeError?.isDefinitiveAuthFailure ?? false)
        )
    }

    private func antigravityRuntimeServiceState(settings: AppSettings) -> RuntimeServiceState {
        let isEnabled = settings.isProviderEnabled(.antigravity)
        let environmentStatus = ProviderEnvironmentDetector.status(for: .antigravity)
        let signals = ProviderEnvironmentDetector.antigravitySignals()
        let snapshot = runtimeSnapshots[.antigravity]
        let runtimeError = snapshot?.error
        let requiresInteractiveSetup = ProviderEnvironmentDetector.requiresInteractiveSetup(for: .antigravity)
        let missingCredential = (environmentStatus?.credentialState ?? .missing) == .missing
        let isAuthRequired = isEnabled && requiresInteractiveSetup && missingCredential
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
            meta: snapshot?.lastUpdated.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) },
            lastUpdated: snapshot?.lastUpdated,
            isLoading: snapshot?.isLoading ?? false,
            error: runtimeError,
            hasContent: antigravityUsage != nil,
            isAuthRequired: isAuthRequired,
            shouldShowWarningDot: isAuthRequired || (runtimeError?.isDefinitiveAuthFailure ?? false)
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
                return ProviderEnvironmentDetector.status(for: kind)?.summary
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
    }

    func preferredPopoverSize(for service: PopoverService, settings: AppSettings) -> CGSize {
        let compact = settings.isPopoverCompact(for: service.providerKind)
        let phase = contentPhase(for: service, settings: settings)
        let rowCount = visibleContentRowCount(for: service, compact: compact, settings: settings)
        return CGSize(
            width: PopoverView.preferredPopoverWidth(compact: compact),
            height: PopoverLayoutMetrics.preferredPopoverHeight(
                compact: compact,
                phase: phase,
                rowCount: rowCount
            )
        )
    }

    func contentPhase(for service: PopoverService, settings: AppSettings) -> PopoverContentPhase {
        let runtimeState = runtimeServiceState(for: service, settings: settings)
        if runtimeState.isAuthRequired {
            return .authRequired
        }
        if runtimeState.isLoading && !runtimeState.hasContent {
            return .loading
        }
        if runtimeState.error != nil && !runtimeState.hasContent {
            return .error
        }
        if runtimeState.hasContent {
            return .content
        }
        return .empty
    }

    private func visibleContentRowCount(
        for service: PopoverService,
        compact: Bool,
        settings: AppSettings
    ) -> Int {
        switch service {
        case .claude:
            let items = compact ? settings.effectiveCompactItems : settings.popoverItems
            var count = 0
            for item in items where item.visible {
                switch item.id {
                case "currentSession":
                    if claudeUsage != nil { count += 1 }
                case "weeklyLimit":
                    if claudeUsage?.sevenDay != nil { count += 1 }
                case "modelUsage":
                    if claudeUsage?.sevenDaySonnet != nil { count += 1 }
                    if claudeUsage?.sevenDayOpus != nil { count += 1 }
                case "overageUsage":
                    if overage?.isEnabled == true { count += 1 }
                default:
                    break
                }
            }
            return max(count, claudeUsage != nil ? 1 : 0)

        case .codex:
            let items = compact ? settings.effectiveCompactCodexItems : settings.codexPopoverItems
            let visibleCount = items.filter(\.visible).count
            return max(visibleCount, codexUsage != nil ? 1 : 0)

        case .gemini:
            var count = 0
            if geminiUsage?.primaryWindow != nil { count += 1 }
            if geminiUsage?.secondaryWindow != nil { count += 1 }
            if geminiUsage?.tertiaryWindow != nil { count += 1 }
            if !compact, (geminiUsage?.accountEmail != nil || geminiUsage?.accountPlan != nil) { count += 1 }
            return max(count, geminiUsage != nil ? 1 : 0)

        case .antigravity:
            var count = 0
            if antigravityUsage?.primaryWindow != nil { count += 1 }
            if antigravityUsage?.secondaryWindow != nil { count += 1 }
            if antigravityUsage?.tertiaryWindow != nil { count += 1 }
            if !compact, (antigravityUsage?.accountEmail != nil || antigravityUsage?.accountPlan != nil) { count += 1 }
            return max(count, antigravityUsage != nil ? 1 : 0)
        }
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
        if snapshot.isLoading {
            return "조회 중"
        }
        if snapshot.hasBackoff,
           snapshot.payload == nil,
           let nextRefreshAllowedAt = snapshot.nextRefreshAllowedAt,
           let remainingSeconds = RefreshExecutionPolicy.remainingBackoffSeconds(until: nextRefreshAllowedAt)
        {
            return "약 \(remainingSeconds)초 후 다시 시도"
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
        if let error = snapshot.error {
            if shouldSuppressRecoverableError(error, kind: snapshot.kind),
               let environmentStatus = ProviderEnvironmentDetector.status(for: snapshot.kind) {
                return environmentStatus.summary
            }
            return error.errorDescription ?? "조회 실패"
        }
        return ProviderEnvironmentDetector.status(for: snapshot.kind)?.summary ?? "데이터를 아직 불러오지 못했습니다"
    }

    func localProviderSummaryState(for service: PopoverService, settings: AppSettings) -> LocalProviderSummaryState? {
        switch service {
        case .gemini:
            let isEnabled = settings.isProviderEnabled(.gemini)
            let environmentStatus = ProviderEnvironmentDetector.status(for: .gemini)
            let signals = ProviderEnvironmentDetector.geminiSignals()
            let requiresInteractiveSetup = ProviderEnvironmentDetector.requiresInteractiveSetup(for: .gemini)
            let missingCredential = (environmentStatus?.credentialState ?? .missing) == .missing
            let isAuthRequired = isEnabled && requiresInteractiveSetup && missingCredential
            return Self.resolveGeminiSummaryState(
                snapshot: runtimeSnapshots[.gemini],
                environmentStatus: environmentStatus,
                signals: signals,
                isEnabled: isEnabled,
                isAuthRequired: isAuthRequired
            )
        case .antigravity:
            let isEnabled = settings.isProviderEnabled(.antigravity)
            let environmentStatus = ProviderEnvironmentDetector.status(for: .antigravity)
            let signals = ProviderEnvironmentDetector.antigravitySignals()
            let requiresInteractiveSetup = ProviderEnvironmentDetector.requiresInteractiveSetup(for: .antigravity)
            let missingCredential = (environmentStatus?.credentialState ?? .missing) == .missing
            let isAuthRequired = isEnabled && requiresInteractiveSetup && missingCredential
            return Self.resolveAntigravitySummaryState(
                snapshot: runtimeSnapshots[.antigravity],
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
        guard let status = ProviderEnvironmentDetector.status(for: kind) else {
            return false
        }
        return Self.shouldSuppressRecoverableError(error, runtimeReachability: status.runtimeReachability)
    }
}
