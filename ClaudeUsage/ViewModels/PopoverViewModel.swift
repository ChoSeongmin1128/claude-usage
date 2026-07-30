import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class PopoverViewModel: ObservableObject {
    struct ProviderShellCard: Identifiable, Sendable, Equatable {
        let kind: AppProviderKind
        let title: String
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
        let freshness: RuntimeProviderFreshness
        let sourceLabel: String?
        let accountID: String?

        func providerSelectorAccessibilityValue(
            isSelected: Bool
        ) -> String {
            var parts: [String] = []
            if isSelected {
                parts.append("선택됨")
            }
            if isLoading {
                parts.append("갱신 중")
            }
            if freshness == .stale {
                parts.append("이전 데이터")
            }
            if isAuthRequired {
                parts.append("로그인 필요")
            } else if error != nil {
                parts.append("갱신 실패")
            }
            if shouldShowWarningDot,
               !parts.contains("이전 데이터"),
               !parts.contains("로그인 필요"),
               !parts.contains("갱신 실패")
            {
                parts.append("확인 필요")
            }
            return parts.isEmpty
                ? "사용 가능"
                : parts.joined(separator: ", ")
        }
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
    @Published var antigravityRuntimeSnapshot = AntigravityRuntimeSnapshot.idle

    private let updateRuntimeState: UpdateRuntimeState
    private var cancellables = Set<AnyCancellable>()

    var onRefreshService: ((PopoverService) -> Void)?
    var onOpenSettingsForService: ((PopoverService) -> Void)?
    var onOpenSettingsPanel: ((SettingsProviderPanel) -> Void)?
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

    func openSettings(panel: SettingsProviderPanel) {
        self.onOpenSettingsPanel?(panel)
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

    func openExternalAction(
        _ action: ProviderExternalAction
    ) {
        NSWorkspace.shared.open(action.destination)
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
            let provenance = snapshot?.lastSuccessfulMetadata ?? snapshot?.lastAttemptMetadata
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
                shouldShowWarningDot: shouldShowWarningDot(snapshot: snapshot, isAuthRequired: isAuthRequired),
                freshness: snapshot?.freshness ?? .unavailable,
                sourceLabel: provenance?.sourceLabel,
                accountID: provenance?.accountID
            )
        case .codex:
            let isEnabled = settings.isProviderEnabled(.codex)
            let snapshot = snapshot(for: service)
            let provenance = snapshot?.lastSuccessfulMetadata ?? snapshot?.lastAttemptMetadata
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
                shouldShowWarningDot: shouldShowWarningDot(snapshot: snapshot, isAuthRequired: isAuthRequired),
                freshness: snapshot?.freshness ?? .unavailable,
                sourceLabel: provenance?.sourceLabel,
                accountID: provenance?.accountID
            )
        case .antigravity:
            return antigravityRuntimeServiceState(settings: settings)
        }
    }

    private func antigravityRuntimeServiceState(settings: AppSettings) -> RuntimeServiceState {
        let isEnabled = settings.isProviderEnabled(.antigravity)
        let snapshot = antigravityRuntimeSnapshot
        let summaryState = Self.resolveAntigravitySummaryState(
            snapshot: snapshot,
            isEnabled: isEnabled
        )
        let isAuthRequired = Self.antigravityRequiresAction(
            snapshot.presentationState
        )
        let shouldShowWarning = Self.antigravityShouldShowWarning(
            snapshot: snapshot,
            isEnabled: isEnabled
        )

        return RuntimeServiceState(
            service: .antigravity,
            summary: summaryState.summary,
            meta: Self.antigravityMeta(snapshot),
            lastUpdated: snapshot.lastSuccessfulAt,
            isLoading: snapshot.isLoading,
            error: nil,
            hasContent: snapshot.hasQuotaContent,
            isAuthRequired: isAuthRequired,
            shouldShowWarningDot: shouldShowWarning,
            freshness: Self.antigravityFreshness(snapshot),
            sourceLabel: Self.antigravityIdentityRail(snapshot)?.sourceLabel,
            accountID: snapshot.activeAccountID?.rawValue
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
            guard settings.isProviderEnabled(kind) else {
                return "비활성화된 상태입니다."
            }
            let state = runtimeServiceState(
                for: .antigravity,
                settings: settings
            )
            return state.meta ?? state.summary
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
            return Self.antigravityBadgeTitle(
                antigravityRuntimeSnapshot
            ) ?? baseBadge
        }
    }

    func update(
        snapshots: [RuntimeProviderSnapshot],
        overage: OverageSpendLimitResponse? = nil,
        setupPresentation: ClaudeSetupPresentation? = nil
    )
    {
        self.runtimeSnapshots = Dictionary(
            uniqueKeysWithValues: snapshots
                .filter { $0.service != .antigravity }
                .map { ($0.service, $0) }
        )
        self.claudeSetupPresentation = setupPresentation
        if let overage { self.overage = overage }
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
            return usage.usageSummaryText
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
            return error.errorDescription ?? "조회 실패"
        }
        return "데이터를 아직 불러오지 못했습니다"
    }

    private func runtimeMeta(for snapshot: RuntimeProviderSnapshot) -> String? {
        guard snapshot.hasContent else {
            return snapshot.lastUpdated.map { Self.relativeTimestamp(for: $0) }
        }
        guard let lastUpdated = snapshot.lastUpdated else {
            return nil
        }
        let relative = Self.relativeTimestamp(for: lastUpdated)
        if snapshot.isLoading {
            return "갱신 중 · \(relative) 성공"
        }
        if snapshot.error != nil {
            if snapshot.hasBackoff {
                return "\(relative) 성공 · 재시도 대기"
            }
            return "\(relative) 성공 · 갱신 실패"
        }
        return "\(relative) 갱신"
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
        return snapshot.error != nil
    }

    nonisolated static func relativeTimestamp(for date: Date, relativeTo referenceDate: Date = Date()) -> String {
        let elapsed = max(0, referenceDate.timeIntervalSince(date))
        if elapsed < 60 {
            return "방금"
        }
        if elapsed < 60 * 60 {
            return "\(Int(elapsed / 60))분 전"
        }
        if elapsed < 24 * 60 * 60 {
            return "\(Int(elapsed / (60 * 60)))시간 전"
        }
        return "\(Int(elapsed / (24 * 60 * 60)))일 전"
    }

    func localProviderSummaryState(for service: PopoverService, settings: AppSettings) -> LocalProviderSummaryState? {
        switch service {
        case .antigravity:
            return Self.resolveAntigravitySummaryState(
                snapshot: antigravityRuntimeSnapshot,
                isEnabled: settings.isProviderEnabled(.antigravity)
            )
        case .claude, .codex:
            return nil
        }
    }

    static func resolveAntigravitySummaryState(
        snapshot: AntigravityRuntimeSnapshot,
        isEnabled: Bool
    ) -> LocalProviderSummaryState {
        if !isEnabled {
            return .init(phase: .disabled, summary: "비활성화됨")
        }
        switch snapshot.readiness {
        case .bootstrapping:
            return .init(phase: .loading, summary: "초기 설정 확인 중")
        case .blocked:
            return .init(
                phase: .temporaryError,
                summary: "초기 설정 확인 필요"
            )
        case .shuttingDown:
            return .init(phase: .disabled, summary: "종료 중")
        case .idle, .ready:
            break
        }

        switch snapshot.presentationState {
        case .disabled:
            return .init(phase: .probingRuntime, summary: "사용량 조회 준비")
        case .setupRequired:
            return .init(phase: .authRequired, summary: "연결 설정 필요")
        case .refreshing:
            return .init(phase: .loading, summary: "사용량 확인 중")
        case .ready:
            return .init(
                phase: .ready,
                summary: antigravityQuotaSummary(snapshot)
            )
        case .partial:
            return .init(
                phase: .ready,
                summary: "\(antigravityQuotaSummary(snapshot)) · 일부 확인 필요"
            )
        case .stale:
            return .init(
                phase: .temporaryError,
                summary: "이전 사용량 표시 중"
            )
        case .accountMismatch:
            return .init(
                phase: .authRequired,
                summary: "선택한 계정과 세션이 다름"
            )
        case .limited:
            return .init(
                phase: .temporaryError,
                summary: "수치형 사용량 미지원"
            )
        case .identityOnly:
            return .init(
                phase: .temporaryError,
                summary: "계정 확인됨 · 수치 미지원"
            )
        case .failed(let failure):
            return .init(
                phase: antigravityFailureRequiresAction(failure)
                    ? .authRequired
                    : .temporaryError,
                summary: antigravityFailureSummary(failure)
            )
        }
    }

    private static func antigravityQuotaSummary(
        _ snapshot: AntigravityRuntimeSnapshot
    ) -> String {
        guard case .content(let presentation) =
                snapshot.quotaPresentation
        else {
            return "사용량 확인됨"
        }
        return "\(presentation.observedLaneCount)개 사용량 한도"
    }

    private static func antigravityIdentityRail(
        _ snapshot: AntigravityRuntimeSnapshot
    ) -> ProviderIdentityRailProjection? {
        guard case .content(let presentation) =
                snapshot.quotaPresentation
        else {
            return nil
        }
        return presentation.identityRail
    }

    private static func antigravityMeta(
        _ snapshot: AntigravityRuntimeSnapshot
    ) -> String? {
        if let identityRail = antigravityIdentityRail(snapshot) {
            return identityRail.freshnessLabel
        }
        return snapshot.lastAttemptAt.map {
            relativeTimestamp(for: $0)
        }
    }

    private static func antigravityFreshness(
        _ snapshot: AntigravityRuntimeSnapshot
    ) -> RuntimeProviderFreshness {
        if snapshot.isLoading {
            return .loading
        }
        guard case .content(let presentation) =
                snapshot.quotaPresentation
        else {
            return .unavailable
        }
        switch presentation.context.phase {
        case .current:
            return .fresh
        case .refreshing:
            return .loading
        case .stale:
            return .stale
        }
    }

    private static func antigravityRequiresAction(
        _ state: AntigravityPresentationState
    ) -> Bool {
        switch state {
        case .setupRequired, .accountMismatch:
            return true
        case .failed(let failure):
            return antigravityFailureRequiresAction(failure)
        case .disabled,
             .refreshing,
             .ready,
             .partial,
             .stale,
             .limited,
             .identityOnly:
            return false
        }
    }

    private static func antigravityFailureRequiresAction(
        _ failure: AntigravityFailure
    ) -> Bool {
        switch failure {
        case .selectedAccountUnavailable,
             .selectedAccountIdentityUnavailable,
             .authenticationRequired,
             .interactionRequired:
            return true
        case .cancelled,
             .appShuttingDown,
             .invalidRefreshContext,
             .generationExhausted,
             .repositoryUnavailable,
             .repositoryRevisionChanged,
             .credentialCommitFailed,
             .credentialCommitAmbiguous,
             .noEligibleSource,
             .sourceUnavailable,
             .deadlineExceeded,
             .schemaChanged,
             .transportUnavailable,
             .sourceContractViolation,
             .numericQuotaUnavailable:
            return false
        }
    }

    private static func antigravityFailureSummary(
        _ failure: AntigravityFailure
    ) -> String {
        switch failure {
        case .authenticationRequired, .interactionRequired:
            return "Google 계정 다시 연결 필요"
        case .selectedAccountUnavailable,
             .selectedAccountIdentityUnavailable:
            return "선택한 계정 확인 필요"
        case .sourceUnavailable, .noEligibleSource:
            return "사용 가능한 조회 경로 없음"
        case .schemaChanged:
            return "응답 형식 확인 필요"
        case .deadlineExceeded, .transportUnavailable:
            return "연결 일시 실패"
        case .credentialCommitFailed,
             .credentialCommitAmbiguous:
            return "계정 정보 저장 확인 필요"
        case .repositoryUnavailable,
             .repositoryRevisionChanged,
             .invalidRefreshContext,
             .generationExhausted,
             .sourceContractViolation:
            return "로컬 상태 확인 필요"
        case .numericQuotaUnavailable:
            return "수치형 사용량 미지원"
        case .cancelled:
            return "조회 취소됨"
        case .appShuttingDown:
            return "종료 중"
        }
    }

    private static func antigravityShouldShowWarning(
        snapshot: AntigravityRuntimeSnapshot,
        isEnabled: Bool
    ) -> Bool {
        guard isEnabled else { return false }
        if case .blocked = snapshot.readiness {
            return true
        }
        switch snapshot.presentationState {
        case .disabled, .refreshing, .ready:
            return false
        case .partial,
             .stale,
             .setupRequired,
             .accountMismatch,
             .limited,
             .identityOnly,
             .failed:
            return true
        }
    }

    private static func antigravityBadgeTitle(
        _ snapshot: AntigravityRuntimeSnapshot
    ) -> String? {
        if snapshot.isLoading {
            return "조회 중"
        }
        if case .blocked = snapshot.readiness {
            return "확인 필요"
        }
        switch snapshot.presentationState {
        case .ready:
            return "활성"
        case .partial, .stale, .limited, .identityOnly:
            return "일부 확인"
        case .setupRequired:
            return "연결 필요"
        case .accountMismatch, .failed:
            return "조치 필요"
        case .refreshing:
            return "조회 중"
        case .disabled:
            return "준비 중"
        }
    }
}
