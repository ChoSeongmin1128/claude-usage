import Combine
import Foundation

@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()
    @Published private(set) var inventories: [PopoverService: [UsageLimit]] = [:]
    private var owners: [PopoverService: String] = [:]
    private var trackers: [String: Tracker] = [:]
    private let settings: AppSettings
    private let deliverer: NotificationDelivering

    init(deliverer: NotificationDelivering = UserNotificationDeliverer(), settings: AppSettings = .shared) {
        self.deliverer = deliverer
        self.settings = settings
    }

    func requestPermission() { deliverer.requestPermission() }

    func updateAccountBoundary(_ provider: PopoverService, accountID: String?) {
        let trimmed = accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed?.isEmpty == false ? trimmed : nil
        guard owners[provider] != normalized else { return }
        owners[provider] = normalized
        inventories[provider] = []
        trackers = trackers.filter { $0.value.provider != provider }
    }

    func checkClaude(_ usage: ClaudeUsageResponse, accountID: String?, policy: ClaudeNotificationPolicy?) {
        check(
            provider: .claude, accountID: accountID, limits: UsageLimitCatalog.claude(usage),
            isEnabled: settings.claudeAlertEnabled, policy: policy
        ) { limit in
            switch limit.legacyKey {
            case "fiveHour": return self.settings.alertFiveHourEnabled
            case "weekly": return self.settings.alertWeeklyEnabled
            default: return false
            }
        }
    }

    func checkCodex(_ usage: CodexUsageResponse, accountID: String?) {
        check(
            provider: .codex, accountID: accountID, limits: UsageLimitCatalog.codex(usage),
            isEnabled: settings.codexAlertEnabled
        ) { $0.legacyKey == "base" }
    }

    func checkAntigravityThresholds(snapshot: AntigravityRuntimeSnapshot) {
        let quota: AntigravityQuotaSnapshot
        // Display-only, stale or in-flight snapshots must not emit new alerts.
        switch snapshot.presentationState {
        case .ready(let current), .partial(let current, _): quota = current
        case .refreshing(let previous):
            if previous == nil { updateAccountBoundary(.antigravity, accountID: nil) }
            return
        case .stale: return
        default: updateAccountBoundary(.antigravity, accountID: nil); return
        }
        guard let display = snapshot.settings?.display else { return }
        let identity = quota.identity ?? quota.provenance.accountIdentity
        let parts = [snapshot.activeAccountID?.rawValue, identity?.stableAccountID, identity?.email?.lowercased()]
            .map { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.compactMap { $0 }.filter { !$0.isEmpty }
        let owner = parts.isEmpty ? nil : String(data: (try? JSONEncoder().encode(parts)) ?? Data(), encoding: .utf8)
        check(
            provider: .antigravity, accountID: owner, limits: UsageLimitCatalog.antigravity(quota),
            isEnabled: display.notifications.isEnabled
        ) { limit in
            guard let raw = limit.legacyKey else { return false }
            return !display.standard.hiddenLaneIDs.contains(AntigravityQuotaLaneID(rawValue: raw))
        }
    }

    /// The provider adapter owns source interpretation; the evaluator owns one
    /// account-scoped history for each stable quota ID, regardless of UI ordering.
    func check(
        provider: PopoverService, accountID: String?, limits: [UsageLimit], isEnabled: Bool,
        policy: ClaudeNotificationPolicy? = nil, legacySelection: (UsageLimit) -> Bool
    ) {
        updateAccountBoundary(provider, accountID: accountID)
        guard owners[provider] != nil else { return }
        let limits = limits.filter { $0.provider == provider }
        var selection = settings.notificationTargets
        selection.observe(limits, provider: provider, legacySelection: legacySelection)
        if selection != settings.notificationTargets { settings.notificationTargets = selection }
        let currentIDs = Set(limits.map(\.id))
        let absent = (inventories[provider] ?? []).filter { !currentIDs.contains($0.id) }.map { $0.unavailable() }
        let inventory = limits + absent
        if inventories[provider] != inventory { inventories[provider] = inventory }
        let freshPolicy = policy?.isFreshEnoughForNotifications == true ? policy : nil
        var crossings: [(UsageLimit, Int)] = []
        for limit in limits {
            guard limit.canNotify, let used = limit.usedPercentage else { continue }
            let selected = selection.isSelected(limit.id, provider: provider)
            let enabled = isEnabled && settings.notificationsEnabled && selected
            var tracker = trackers[limit.id] ?? Tracker(provider: provider)
            let thresholds = settings.enabledAlertThresholds.filter { threshold in
                !(provider == .claude && limit.legacyKey != nil
                    && freshPolicy?.shouldSuppressLowUrgencyThresholds == true && threshold < 90)
            }
            let decision = UsageWindowAlertPolicy.evaluate(
                previousPercentage: tracker.previous, currentPercentage: used, resetAt: nil,
                thresholds: thresholds, alertedThresholds: tracker.alerted,
                isFirstCheck: tracker.previous == nil || !tracker.wasEnabled || !enabled)
            tracker.previous = used
            tracker.wasEnabled = enabled
            tracker.alerted = decision.alertedThresholds
            trackers[limit.id] = tracker
            if enabled, let threshold = decision.thresholdToAlert { crossings.append((limit, threshold)) }
        }
        guard let highest = crossings.map({ $0.1 }).max() else { return }
        let basis = settings.notificationValueBasis
        let severity = highest >= 95 ? "경고" : highest >= 90 ? "주의" : "안내"
        let title = "\(provider.providerKind.displayName) \(basis == .remaining ? "잔여 한도" : "사용량") \(severity)"
        let body = crossings.map { limit, threshold in
            let amount = basis == .remaining ? 100 - threshold : threshold
            let sentence =
                basis == .remaining ? "\(limit.title)의 \(amount)%가 남았습니다" : "\(limit.title)의 \(amount)%를 사용했습니다"
            if provider == .claude, limit.legacyKey != nil,
                let guidance = freshPolicy?.guidanceSuffix(
                    threshold: threshold, alertRemainingMode: basis == .remaining)
            {
                return sentence + ". " + guidance
            }
            return sentence
        }.joined(separator: "\n")
        deliverer.deliver(title: title, body: body)
    }

    private struct Tracker {
        let provider: PopoverService
        var previous: Double?
        var alerted: Set<Int> = []
        var wasEnabled = false
    }
}
