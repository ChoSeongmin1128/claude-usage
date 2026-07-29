//
//  NotificationManager.swift
//  ClaudeUsage
//
//  Phase 4: macOS 알림 관리 (5시간/주간 세션 별도 추적)
//

import Foundation

enum SessionType: String {
    case fiveHour
    case weekly
    case codexPrimary
    case codexSecondary
    case antigravityPrimary
    case antigravitySecondary
    case antigravityTertiary

    var displayName: String {
        switch self {
        case .fiveHour, .codexPrimary:
            return "현재 세션"
        case .weekly:
            return "주간"
        case .codexSecondary:
            return "주간 세션"
        case .antigravityPrimary:
            return "Gemini Pro lane"
        case .antigravitySecondary:
            return "Gemini Flash lane"
        case .antigravityTertiary:
            return "Claude lane"
        }
    }

    var providerName: String {
        switch self {
        case .fiveHour, .weekly:
            return "Claude"
        case .codexPrimary, .codexSecondary:
            return "Codex"
        case .antigravityPrimary, .antigravitySecondary, .antigravityTertiary:
            return "Antigravity"
        }
    }
}

final class NotificationManager {
    static let shared = NotificationManager()

    private enum ThresholdPresentationMode {
        case used
        case remaining
    }

    private var trackers: [SessionType: SessionTracker] = [
        .fiveHour: SessionTracker(),
        .weekly: SessionTracker(),
        .codexPrimary: SessionTracker(),
        .codexSecondary: SessionTracker(),
    ]
    private var antigravityTrackers:
        [AntigravityQuotaLaneID: SessionTracker] = [:]
    private var hasAntigravityAccountBoundary = false
    private var antigravityAccountBoundary:
        AntigravityNotificationAccountBoundary?

    private let deliverer: NotificationDelivering

    init(deliverer: NotificationDelivering = UserNotificationDeliverer()) {
        self.deliverer = deliverer
    }

    // MARK: - Permission

    func requestPermission() {
        deliverer.requestPermission()
    }

    // MARK: - Threshold Check

    func checkThreshold(
        session: SessionType,
        percentage: Double,
        resetAt: String?,
        claudePolicy: ClaudeNotificationPolicy? = nil
    ) {
        let settings = AppSettings.shared

        guard settings.notificationsEnabled else { return }

        // 해당 세션 알림이 꺼져 있으면 무시
        switch session {
        case .fiveHour:
            guard settings.claudeAlertEnabled, settings.alertFiveHourEnabled else { return }
        case .weekly:
            guard settings.claudeAlertEnabled, settings.alertWeeklyEnabled else { return }
        case .codexPrimary, .codexSecondary:
            guard settings.codexAlertEnabled else { return }
        case .antigravityPrimary, .antigravitySecondary, .antigravityTertiary:
            // Stage 8 callers use `checkAntigravityThresholds(snapshot:)`.
            // Keep these cases temporarily so the Stage 9 call-site cutover
            // can remove the legacy enum and calls atomically.
            return
        }

        guard let tracker = trackers[session] else { return }
        let thresholds: [Int] = {
            switch session {
            case .codexPrimary, .codexSecondary:
                return settings.enabledCodexAlertThresholds
            case .fiveHour, .weekly:
                return settings.enabledAlertThresholds
            case .antigravityPrimary, .antigravitySecondary, .antigravityTertiary:
                return []
            }
        }()
        let normalizedClaudePolicy = claudePolicy?.isFreshEnoughForNotifications == true ? claudePolicy : nil
        let serviceName = session.providerName
        let thresholdMode: ThresholdPresentationMode = settings.alertRemainingMode ? .remaining : .used
        let effectiveThresholds = thresholds.filter {
            !shouldSuppressThreshold(
                $0,
                session: session,
                claudePolicy: normalizedClaudePolicy
            )
        }
        let decision = UsageWindowAlertPolicy.evaluate(
            previousPercentage: tracker.lastPercentage,
            currentPercentage: percentage,
            resetAt: resetAt,
            thresholds: effectiveThresholds,
            alertedThresholds: tracker.alertedThresholds,
            isFirstCheck: tracker.isFirstCheck
        )

        if tracker.isFirstCheck {
            Logger.info("\(session.displayName) 첫 실행 기록: \(Int(percentage))%")
        } else if resetAt != tracker.lastResetAt {
            Logger.debug(
                "\(session.displayName) 갱신 예상 시각 변경: \(tracker.lastResetAt ?? "nil") -> \(resetAt ?? "nil")"
            )
        }

        tracker.isFirstCheck = false
        tracker.lastPercentage = percentage
        tracker.lastResetAt = resetAt
        tracker.alertedThresholds = decision.alertedThresholds

        if let threshold = decision.thresholdToAlert {
            let title = thresholdAlertTitle(
                serviceName: serviceName,
                threshold: threshold,
                presentationMode: thresholdMode)
            let guidanceSuffix = (session == .fiveHour || session == .weekly)
                ? normalizedClaudePolicy?.guidanceSuffix(
                    threshold: threshold,
                    alertRemainingMode: settings.alertRemainingMode)
                : nil
            let body = thresholdAlertBody(
                session: session,
                threshold: threshold,
                presentationMode: thresholdMode,
                guidanceSuffix: guidanceSuffix)
            sendNotification(title: title, body: body)
        }
    }

    /// Evaluates every currently available Antigravity quota lane as one
    /// refresh transaction and emits at most one aggregate notification.
    ///
    /// Lane state is keyed by the stable upstream-derived lane identifier,
    /// never by presentation order. Selected OAuth refreshes use the canonical
    /// repository account as their boundary, while ambient local refreshes use
    /// the identity observed from that local session. An unidentifiable local
    /// session cannot safely inherit another account's notification history.
    func checkAntigravityThresholds(
        snapshot: AntigravityRuntimeSnapshot
    ) {
        guard
            let accountBoundary =
                antigravityNotificationAccountBoundary(
                    for: snapshot
                )
        else {
            resetAntigravityAccountBoundary()
            return
        }
        updateAntigravityAccountBoundary(accountBoundary)

        let settings = AppSettings.shared
        guard settings.notificationsEnabled else { return }
        guard
            snapshot.settings?.display.notifications.isEnabled == true
        else {
            return
        }
        guard case let .content(presentation) =
            snapshot.quotaPresentation
        else {
            return
        }

        let lanes = availableAntigravityLanes(in: presentation)
        let availableLaneIDs = Set(lanes.map(\.id))
        antigravityTrackers = antigravityTrackers.filter {
            availableLaneIDs.contains($0.key)
        }

        let thresholds = settings.enabledAlertThresholds
        let presentationMode: ThresholdPresentationMode =
            settings.alertRemainingMode ? .remaining : .used
        var crossings: [AntigravityThresholdCrossing] = []

        for lane in lanes {
            guard case let .available(usedPercentage, _) = lane.value else {
                continue
            }

            let tracker = antigravityTrackers[lane.id]
                ?? SessionTracker()
            let decision = UsageWindowAlertPolicy.evaluate(
                previousPercentage: tracker.lastPercentage,
                currentPercentage: usedPercentage,
                resetAt: nil,
                thresholds: thresholds,
                alertedThresholds: tracker.alertedThresholds,
                isFirstCheck: tracker.isFirstCheck
            )

            tracker.isFirstCheck = false
            tracker.lastPercentage = usedPercentage
            tracker.alertedThresholds = decision.alertedThresholds
            antigravityTrackers[lane.id] = tracker

            if let threshold = decision.thresholdToAlert {
                crossings.append(
                    AntigravityThresholdCrossing(
                        laneLabel: lane.compactLabel,
                        threshold: threshold
                    )
                )
            }
        }

        guard
            let highestThreshold = crossings.map(\.threshold).max()
        else {
            return
        }

        sendNotification(
            title: thresholdAlertTitle(
                serviceName: "Antigravity",
                threshold: highestThreshold,
                presentationMode: presentationMode
            ),
            body: antigravityAggregateBody(
                crossings: crossings,
                presentationMode: presentationMode
            )
        )
    }

    // MARK: - Private

    private final class SessionTracker {
        var alertedThresholds: Set<Int> = []
        var lastPercentage: Double?
        var lastResetAt: String?
        var isFirstCheck = true
    }

    private struct AntigravityThresholdCrossing {
        let laneLabel: String
        let threshold: Int
    }

    private enum AntigravityNotificationAccountBoundary:
        Equatable
    {
        case selectedOAuth(AntigravityAccountID)
        case ambientLocal(
            stableAccountID: String?,
            normalizedEmail: String?
        )
    }

    private func updateAntigravityAccountBoundary(
        _ boundary: AntigravityNotificationAccountBoundary
    ) {
        guard
            !hasAntigravityAccountBoundary
                || antigravityAccountBoundary != boundary
        else {
            return
        }

        antigravityTrackers.removeAll()
        antigravityAccountBoundary = boundary
        hasAntigravityAccountBoundary = true
    }

    private func resetAntigravityAccountBoundary() {
        antigravityTrackers.removeAll()
        antigravityAccountBoundary = nil
        hasAntigravityAccountBoundary = false
    }

    private func antigravityNotificationAccountBoundary(
        for snapshot: AntigravityRuntimeSnapshot
    ) -> AntigravityNotificationAccountBoundary? {
        guard snapshot.settings != nil else {
            return nil
        }

        if let accountID = snapshot.activeAccountID {
            return .selectedOAuth(accountID)
        }

        guard
            let identity =
                antigravityObservedIdentity(
                    from: snapshot.presentationState
                )
        else {
            return nil
        }
        let stableAccountID = normalizedIdentityValue(
            identity.stableAccountID
        )
        let normalizedEmail = normalizedIdentityValue(
            identity.email
        )?.lowercased()
        guard stableAccountID != nil || normalizedEmail != nil else {
            return nil
        }
        return .ambientLocal(
            stableAccountID: stableAccountID,
            normalizedEmail: normalizedEmail
        )
    }

    private func antigravityObservedIdentity(
        from state: AntigravityPresentationState
    ) -> ProviderAccountIdentity? {
        let snapshot: AntigravityQuotaSnapshot?
        switch state {
        case .ready(let current),
             .partial(let current, _),
             .stale(let current, _):
            snapshot = current
        case .refreshing(let previous):
            snapshot = previous
        case .disabled,
             .setupRequired,
             .accountMismatch,
             .limited,
             .identityOnly,
             .failed:
            snapshot = nil
        }
        return snapshot?.identity
            ?? snapshot?.provenance.accountIdentity
    }

    private func normalizedIdentityValue(
        _ value: String?
    ) -> String? {
        guard
            let normalized = value?
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
            !normalized.isEmpty
        else {
            return nil
        }
        return normalized
    }

    private func availableAntigravityLanes(
        in presentation: AntigravityQuotaPresentation
    ) -> [AntigravityQuotaLanePresentation] {
        var seenLaneIDs: Set<AntigravityQuotaLaneID> = []

        return presentation.groups
            .flatMap(\.lanes)
            .filter { lane in
                guard case .available = lane.value else { return false }
                return seenLaneIDs.insert(lane.id).inserted
            }
    }

    private func antigravityAggregateBody(
        crossings: [AntigravityThresholdCrossing],
        presentationMode: ThresholdPresentationMode
    ) -> String {
        crossings.map { crossing in
            let percentage = displayThresholdValue(
                crossing.threshold,
                mode: presentationMode
            )
            switch presentationMode {
            case .used:
                return "\(crossing.laneLabel): \(percentage)% 사용"
            case .remaining:
                return "\(crossing.laneLabel): \(percentage)% 남음"
            }
        }
        .joined(separator: "\n")
    }

    private func shouldSuppressThreshold(
        _ threshold: Int,
        session: SessionType,
        claudePolicy: ClaudeNotificationPolicy?
    ) -> Bool {
        guard session == .fiveHour || session == .weekly else { return false }
        guard let claudePolicy else { return false }
        return claudePolicy.shouldSuppressLowUrgencyThresholds && threshold < 90
    }

    private func thresholdAlertTitle(
        serviceName: String,
        threshold: Int,
        presentationMode: ThresholdPresentationMode
    ) -> String {
        switch presentationMode {
        case .used:
            return threshold >= 95 ? "\(serviceName) 사용량 경고"
                : threshold >= 90 ? "\(serviceName) 사용량 주의"
                : "\(serviceName) 사용량 안내"
        case .remaining:
            let remaining = displayThresholdValue(threshold, mode: presentationMode)
            return remaining <= 5 ? "\(serviceName) 잔여 한도 경고"
                : remaining <= 10 ? "\(serviceName) 잔여 한도 주의"
                : "\(serviceName) 잔여 한도 안내"
        }
    }

    private func thresholdAlertBody(
        session: SessionType,
        threshold: Int,
        presentationMode: ThresholdPresentationMode,
        guidanceSuffix: String?
    ) -> String {
        let displayThreshold = displayThresholdValue(threshold, mode: presentationMode)
        let baseMessage: String
        switch presentationMode {
        case .used:
            baseMessage = "\(session.displayName)의 \(displayThreshold)%를 사용했습니다"
        case .remaining:
            baseMessage = "\(session.displayName)의 \(displayThreshold)%가 남았습니다"
        }

        guard let guidanceSuffix else { return baseMessage }
        return "\(baseMessage). \(guidanceSuffix)"
    }

    private func displayThresholdValue(
        _ threshold: Int,
        mode: ThresholdPresentationMode
    ) -> Int {
        switch mode {
        case .used:
            return threshold
        case .remaining:
            return max(1, min(100 - threshold, 99))
        }
    }

    // MARK: - Send Notification

    private func sendNotification(title: String, body: String) {
        deliverer.deliver(title: title, body: body)
    }

}
