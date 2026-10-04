import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class PopoverViewModel: ObservableObject {
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

        var failureHelpText: String? {
            guard case .claudeCodeExecutableNotFound? = error else { return nil }
            return ClaudeCodeCredentialIssue.executableNotFoundExplanation
        }

        func providerSelectorAccessibilityValue(
            isSelected: Bool
        ) -> String {
            var parts: [String] = []
            var hasProblemLabel = false
            if isSelected {
                parts.append("선택됨")
            }
            if isLoading {
                parts.append("갱신 중")
            }
            if freshness == .stale {
                parts.append(UsageStatusLabel.previousValue)
                hasProblemLabel = true
            }
            if isAuthRequired {
                parts.append("로그인 필요")
                hasProblemLabel = true
            } else if error != nil {
                parts.append("갱신 실패")
                hasProblemLabel = true
            }
            if shouldShowWarningDot, !hasProblemLabel {
                parts.append(summary)
            }
            return parts.isEmpty
                ? "연결됨"
                : parts.joined(separator: ", ")
        }
    }

    struct LocalProviderSummaryState: Sendable, Equatable {
        let phase: LocalProviderSummaryPhase
        let summary: String
    }

    @Published var isDesignIntroductionPresented = false
    @Published var selectedService: PopoverService = .claude
    var overage: OverageSpendLimitResponse? { snapshot(for: .claude)?.claudeOverage }
    @Published var systemStatus: ClaudeSystemStatus?
    @Published var usageHealthSnapshot: ClaudeAPIService.UsageHealthSnapshot?
    @Published var nextUsageRetryAt: Date?
    /// 계정이 2개 이상인 서비스만 들어 있다.
    @Published var multiAccount: [PopoverService: MultiAccountPresentation] = [:]
    var accountActions = PopoverAccountActions()
    @Published private(set) var claudeSetupPresentation: ClaudeSetupPresentation?
    @Published private(set) var runtimeSnapshots: [PopoverService: RuntimeProviderSnapshot] = [:]
    @Published var antigravityRuntimeSnapshot = AntigravityRuntimeSnapshot.idle {
        didSet {
            scheduleAvailabilityRefresh(for: .antigravity)
        }
    }

    private let updateRuntimeState: UpdateRuntimeState
    private var cancellables = Set<AnyCancellable>()

    var onRefreshService: ((PopoverService) -> Void)?
    var onOpenSettingsForService: ((PopoverService) -> Void)?
    var onOpenSettingsPanel: ((SettingsProviderPanel) -> Void)?
    var onServiceSelected: ((PopoverService) -> Void)?
    var onPinChanged: ((PopoverService, Bool) -> Void)?
    var onLayoutChanged: ((PopoverService, PopoverLayoutRefreshReason) -> Void)?

    /// 수동 새로고침을 눌렀지만 아직 끝나지 않은 요청. 같은 서비스의 연타를 무시한다.
    @Published private var manualRequestedAt: [PopoverService: Date] = [:]
    private var availabilityTasks: [PopoverService: Task<Void, Never>] = [:]
    private let now: () -> Date
    private static let manualRequestTimeout: TimeInterval = 30

    func manualRefreshAvailableAt(for service: PopoverService) -> Date? {
        let instant = now()
        if let requested = manualRequestedAt[service],
            isAwaitingCompletion(service, requestedAt: requested, now: instant)
        {
            return requested.addingTimeInterval(Self.manualRequestTimeout)
        }
        return AdaptiveRefreshPolicy.manualRefreshBlockedUntil(
            lastCompletedAt: lastCompletedAt(for: service), retryAllowedAt: retryAllowedAt(for: service), now: instant)
    }

    func refreshHelp(for service: PopoverService, isLoading: Bool) -> String {
        if isLoading { return "사용량 갱신 중" }
        let instant = now()
        if let requested = manualRequestedAt[service],
            isAwaitingCompletion(service, requestedAt: requested, now: instant)
        {
            return "사용량 갱신 중"
        }
        if let retry = retryAllowedAt(for: service), retry > instant {
            return "약 \(Int(retry.timeIntervalSince(instant).rounded(.up)))초 후 다시 시도"
        }
        if manualRefreshAvailableAt(for: service) != nil { return "방금 갱신됨" }
        return "\(service.displayName) 사용량 새로고침"
    }

    private func lastCompletedAt(for service: PopoverService) -> Date? {
        service == .antigravity ? antigravityRuntimeSnapshot.lastSuccessfulAt : snapshot(for: service)?.displayUpdatedAt
    }

    private func retryAllowedAt(for service: PopoverService) -> Date? {
        service == .antigravity ? nil : snapshot(for: service)?.nextRefreshAllowedAt
    }

    private func isAwaitingCompletion(_ service: PopoverService, requestedAt: Date, now: Date) -> Bool {
        guard now.timeIntervalSince(requestedAt) < Self.manualRequestTimeout else { return false }
        if let completed = lastCompletedAt(for: service), completed >= requestedAt { return false }
        if snapshot(for: service)?.lastAttemptState == .temporaryFailure, snapshot(for: service)?.isLoading == false,
            service != .antigravity
        {
            return false
        }
        return true
    }

    /// 막힌 구간이 끝나면 버튼이 다시 켜지도록 화면을 갱신한다.
    private func scheduleAvailabilityRefresh(for service: PopoverService) {
        availabilityTasks[service]?.cancel()
        guard let until = manualRefreshAvailableAt(for: service) else { return }
        let delay = max(0.05, until.timeIntervalSince(now()))
        availabilityTasks[service] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.objectWillChange.send()
            self.scheduleAvailabilityRefresh(for: service)
        }
    }

    /// 팝오버의 미인증 상태에서 "다시 연결". 처음 설정과 같은 순서로 연결을 시도한다.
    var onStartClaudeLogin: (() -> Void)?

    init(updateRuntimeState: UpdateRuntimeState? = nil, now: @escaping () -> Date = Date.init) {
        self.now = now
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

    /// 헤더 새로고침과 상태 패널의 다시 시도 버튼이 같은 기준으로 켜지고 꺼진다.
    func canRefresh(service: PopoverService) -> Bool {
        let isLoading =
            service == .antigravity ? antigravityRuntimeSnapshot.isLoading : snapshot(for: service)?.isLoading ?? false
        return !isLoading && manualRefreshAvailableAt(for: service) == nil
    }

    func refresh(service: PopoverService) {
        guard canRefresh(service: service) else { return }
        manualRequestedAt[service] = now()
        onRefreshService?(service)
        scheduleAvailabilityRefresh(for: service)
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

    /// 팝오버 미인증 카드의 "로그인 시작" 버튼이 호출. 콜백이 등록되지 않은 경우
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

    var hasClaudeCredential: Bool {
        claudeSetupPresentation?.progress.hasReadyCredential
            ?? usageHealthSnapshot?.runtime.credentialAvailability.hasAnyCredential
            ?? false
    }

    var claudeCodeCredentialIssue: ClaudeCodeCredentialIssue? {
        guard usageHealthSnapshot?.activeAccount?.kind != .webSession else { return nil }
        if case .claudeCodeExecutableNotFound? = snapshot(for: .claude)?.error { return .executableNotFound }
        return usageHealthSnapshot?.runtime.claudeCodeCredentialIssue
    }

    func authRequiredStatusLabel(for service: PopoverService) -> String {
        guard service == .claude else { return "로그인 필요" }
        switch claudeCodeCredentialIssue {
        case .reconnectRequired: return "다시 연결 필요"
        case .executableNotFound: return "Claude Code 없음"
        case .reauthenticationRequired, nil: return "로그인 필요"
        }
    }

    func runtimeServiceState(for service: PopoverService, settings: AppSettings) -> RuntimeServiceState {
        switch service {
        case .claude:
            let isEnabled = settings.isProviderEnabled(.claude)
            let snapshot = snapshot(for: service)
            let provenance = snapshot?.lastSuccessfulMetadata ?? snapshot?.lastAttemptMetadata
            let isAuthRequired = isEnabled && !(snapshot?.hasCredential ?? false) && !(snapshot?.hasContent ?? false) && !(snapshot?.isLoading ?? false)
            let summary = snapshot.map { runtimeSummary(for: $0, isEnabled: isEnabled, isAuthRequired: isAuthRequired) }
                ?? (!isEnabled ? "사용 꺼짐" : (isAuthRequired ? "로그인 필요" : "확인 전"))
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
                ?? (!isEnabled ? "사용 꺼짐" : (isAuthRequired ? "로그인 필요" : "확인 전"))
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
            accountID: nil
        )
    }

    func update(
        snapshots: [RuntimeProviderSnapshot],
        setupPresentation: ClaudeSetupPresentation? = nil
    )
    {
        let oldAccounts = runtimeSnapshots.mapValues { $0.lastSuccessfulMetadata?.accountID }
        self.runtimeSnapshots = Dictionary(
            uniqueKeysWithValues: snapshots
                .filter { $0.service != .antigravity }
                .map { ($0.service, $0) }
        )
        self.claudeSetupPresentation = setupPresentation
        for service in [PopoverService.claude, .codex] {
            if oldAccounts[service] ?? nil != snapshot(for: service)?.lastSuccessfulMetadata?.accountID {
                manualRequestedAt[service] = nil
            }
            scheduleAvailabilityRefresh(for: service)
        }
    }

    private func runtimeSummary(
        for snapshot: RuntimeProviderSnapshot,
        isEnabled: Bool,
        isAuthRequired: Bool
    ) -> String {
        if !isEnabled {
            return "사용 꺼짐"
        }
        if isAuthRequired {
            return "로그인 필요"
        }
        if let usage = snapshot.claudeUsage {
            return usage.usageSummaryText
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
        return "확인 전"
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
        if case .claudeCodeExecutableNotFound? = snapshot.error {
            return "\(relative) 성공 · Claude Code 없음"
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
        TimeFormatter.elapsed(since: date, now: referenceDate)
    }

    static func resolveAntigravitySummaryState(
        snapshot: AntigravityRuntimeSnapshot,
        isEnabled: Bool
    ) -> LocalProviderSummaryState {
        if !isEnabled {
            return .init(phase: .disabled, summary: "사용 꺼짐")
        }
        switch snapshot.readiness {
        case .bootstrapping:
            return .init(phase: .loading, summary: "확인 중")
        case .blocked:
            return .init(
                phase: .temporaryError,
                summary: "설정 오류"
            )
        case .shuttingDown:
            return .init(phase: .disabled, summary: "종료 중")
        case .idle, .ready:
            break
        }

        switch snapshot.presentationState {
        case .disabled:
            return .init(phase: .probingRuntime, summary: "확인 전")
        case .setupRequired:
            return .init(phase: .authRequired, summary: "로그인 필요")
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
                summary: "\(antigravityQuotaSummary(snapshot)) · 일부만 표시"
            )
        case .stale:
            return .init(
                phase: .temporaryError,
                summary: UsageStatusLabel.previousValue
            )
        case .accountMismatch:
            return .init(
                phase: .authRequired,
                summary: "계정이 다름"
            )
        case .limited:
            return .init(
                phase: .temporaryError,
                summary: "한도 수치 없음"
            )
        case .identityOnly:
            return .init(
                phase: .temporaryError,
                summary: "한도 수치 없음"
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
            return "연결됨"
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
        case .authenticationRequired,
            .interactionRequired,
            .cliReportFailed:
            return true
        case .cancelled, .accountChanged,
             .appShuttingDown,
             .invalidRefreshContext,
             .generationExhausted,
             .noEligibleSource,
             .sourceUnavailable,
             .deadlineExceeded,
             .schemaChanged,
             .transportUnavailable,
             .sourceContractViolation,
             .localAuthentication,
             .numericQuotaUnavailable,
             .runtimeUnavailable:
            return false
        }
    }

    private static func antigravityFailureSummary(
        _ failure: AntigravityFailure
    ) -> String {
        AntigravityPopoverPresentationAdapter.failureSummary(failure).title
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
}
