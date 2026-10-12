//
//  AppSettings.swift
//  ClaudeUsage
//
//  Phase 3: 앱 설정 모델 (UserDefaults 연동)
//

import Foundation
import Combine
import SwiftUI

nonisolated struct NotificationPreset: Codable, Identifiable, Hashable, Sendable {
    let id: String
    /// Canonical used percentage, independent of the display basis.
    var threshold: Int
    var isEnabled: Bool

    init(id: String = UUID().uuidString, threshold: Int, isEnabled: Bool = true) {
        self.id = id
        self.threshold = max(1, min(threshold, 100))
        self.isEnabled = isEnabled
    }
}

enum MenuBarStyle: String, Codable, CaseIterable, Sendable {
    case none = "none"
    case batteryBar = "battery_bar"
    case circular = "circular"
    case concentricRings = "concentric_rings"
    case dualBattery = "dual_battery"
    case sideBySideBattery = "side_by_side_battery"

    var isBatteryStyle: Bool {
        switch self {
        case .batteryBar, .dualBattery, .sideBySideBattery: return true
        case .none, .circular, .concentricRings: return false
        }
    }

    var displayName: String {
        switch self {
        case .none: return "없음"
        case .batteryBar: return "배터리바"
        case .circular: return "원형"
        case .concentricRings: return "동심원"
        case .dualBattery: return "이중 배터리"
        case .sideBySideBattery: return "좌우 배터리"
        }
    }

    nonisolated var gaugeShape: MenuBarStyle {
        switch self {
        case .dualBattery, .sideBySideBattery: .batteryBar
        case .concentricRings: .circular
        default: self
        }
    }

    nonisolated var isDualStyle: Bool {
        switch self {
        case .concentricRings, .dualBattery, .sideBySideBattery: return true
        default: return false
        }
    }
}

nonisolated enum TimeFormatStyle: String, Codable, CaseIterable, Sendable {
    case h24 = "24h"
    case h12 = "12h"
    case remaining = "remaining"

    init?(rawValue: String) {
        switch rawValue {
        case "24h": self = .h24
        case "12h": self = .h12
        case "remaining", "remaining_clock", "remaining_total_clock": self = .remaining
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .h24: return "초기화 시각, 24시간"
        case .h12: return "초기화 시각, 12시간"
        case .remaining: return "남은 시간, 단위 표시"
        }
    }

    var isRemaining: Bool { self == .remaining }
}

enum ResetTimeDisplay: String, Codable, CaseIterable, Sendable {
    case none = "none"
    case fiveHour = "five_hour"
    case weekly = "weekly"
    case dual = "dual"

    var displayName: String {
        switch self {
        case .none: return "없음"
        case .fiveHour: return "5시간 한도"
        case .weekly: return "주간"
        case .dual: return "동시 표시"
        }
    }
}

enum PercentageDisplay: String, Codable, CaseIterable, Sendable {
    case none = "pct_none"
    case fiveHour = "pct_five_hour"
    case weekly = "pct_weekly"
    case dual = "pct_dual"

    var displayName: String {
        switch self {
        case .none: return "없음"
        case .fiveHour: return "5시간 한도"
        case .weekly: return "주간"
        case .dual: return "동시 표시"
        }
    }
}

enum CircularDisplayMode: String, Codable, CaseIterable, Sendable {
    case usage = "usage"
    case remaining = "remaining"

    var displayName: String {
        switch self {
        case .usage: return "사용량"
        case .remaining: return "남은 사용량"
        }
    }
}

enum IconMetric: String, Codable, CaseIterable, Sendable {
    case fiveHour = "five_hour"
    case weekly = "weekly"

    var displayName: String {
        switch self {
        case .fiveHour:
            return "5시간 한도"
        case .weekly:
            return "주간"
        }
    }
}

struct PopoverItemConfig: Codable, Sendable, Equatable {
    let id: String
    var visible: Bool

    init(id: String, visible: Bool) {
        self.id = id
        self.visible = visible
    }

    /// Catalog 등록에서 지원하는 모든 항목 ID를 조회해 displayName을 반환합니다.
    /// provider-specific catalog가 소유권을 가지므로 여기서는 순회만 수행.
    var displayName: String {
        for catalog in UsageItemCatalogRegistry.all {
            if let name = catalog.displayName(for: id) {
                return name
            }
        }
        return id
    }
}

enum UpdateCheckInterval: String, Codable, CaseIterable, Sendable {
    case automatic = "automatic"
    // Legacy persisted values. Runtime scheduling normalizes every value to `automatic`.
    case off = "off"
    case onLaunch = "on_launch"
    case hourly = "hourly"

    nonisolated static let allCases: [UpdateCheckInterval] = [.automatic]
    nonisolated static let enforced: UpdateCheckInterval = .automatic
    nonisolated static let enforcedTimerInterval: TimeInterval = 1800

    var displayName: String {
        "30분마다"
    }

    var normalizedForAutomaticChecks: UpdateCheckInterval {
        .enforced
    }

    var timerInterval: TimeInterval? {
        Self.enforcedTimerInterval
    }
}

enum ClaudeMessagesFallbackPolicy: String, Codable, CaseIterable, Sendable {
    case off = "off"
    case manual = "manual"
    case automatic = "automatic"

    var displayName: String {
        switch self {
        case .off: return "끄기"
        case .manual: return "수동 보조"
        case .automatic: return "자동 보조"
        }
    }
}

class AppSettings: ObservableObject {
    static let shared = AppSettings()
    nonisolated static let minimumRefreshInterval: TimeInterval = 15
    nonisolated static let maximumRefreshInterval: TimeInterval = 3600

    /// AGY 설정이 typed 설정으로 옮겨진 뒤 더 읽지 않는 키. 초기화 경로에서 지우기만 해서
    /// 이전 값이 되살아나지 않게 한다.
    private static let legacyAntigravityKeys =
        [
            "antigravityUsageDataSource",
            "antigravityHiddenModelIDs",
            "antigravityMenuBarPrimaryModelID",
            "antigravityMenuBarSecondaryModelID",
            "antigravityPopoverPinned",
            "antigravityPopoverCompact",
            "antigravitySettingsLastTab",
        ]
        + [
            "showIcon", "alertEnabled", "menuBarStyle", "percentageDisplay", "resetTimeDisplay", "timeFormat",
            "showBatteryPercent", "circularDisplayMode", "iconMetric",
        ].map { "antigravity.\($0)" }

    static func defaultPopoverItemsDict() -> [String: [PopoverItemConfig]] {
        PopoverDisplayPreferencesStore
            .defaultsDictionary()
    }

    static func normalizedPopoverDict(
        _ dict: [String: [PopoverItemConfig]],
        fallback: [String: [PopoverItemConfig]]? = nil
    ) -> [String: [PopoverItemConfig]] {
        PopoverDisplayPreferencesStore.normalized(
            dict,
            fallback: fallback
        )
    }

    static func loadPopoverItemsByProvider(
        from defaults: UserDefaults
    ) -> (full: [String: [PopoverItemConfig]], compact: [String: [PopoverItemConfig]]) {
        PopoverDisplayPreferencesStore.load(
            from: defaults
        )
    }

    static func persistPopoverItemsByProvider(
        _ dict: [String: [PopoverItemConfig]],
        to defaults: UserDefaults
    ) {
        PopoverDisplayPreferencesStore.persistFull(
            dict,
            to: defaults
        )
    }

    static func persistCompactPopoverItemsByProvider(
        _ dict: [String: [PopoverItemConfig]],
        to defaults: UserDefaults
    ) {
        PopoverDisplayPreferencesStore
            .persistCompact(dict, to: defaults)
    }

    private static func normalizedMessagesFallbackThreshold(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }

    private let defaults: UserDefaults
    let menuBarPresets: MenuBarPresetStore
    private let launchAtLoginController: LaunchAtLoginController
    private let popoverDisplayPreferencesStore:
        PopoverDisplayPreferencesStore
    private let providerSelectionPreferencesStore:
        ProviderSelectionPreferencesStore

    // MARK: - Published Properties

    @Published var menuBarDesign: MenuBarDesign {
        didSet {
            defaults.set(menuBarDesign.rawValue, forKey: "menuBarDesign")
            menuBarDesignIntroductionDismissed = true
        }
    }
    @Published var menuBarDesignIntroductionDismissed: Bool {
        didSet { defaults.set(menuBarDesignIntroductionDismissed, forKey: "menuBarDesignIntroductionDismissed") }
    }
    @Published var welcomeState: WelcomeState {
        didSet { defaults.set(welcomeState.rawValue, forKey: "welcomeState") }
    }
    @Published var welcomeStep: WelcomeStep {
        didSet { defaults.set(welcomeStep.rawValue, forKey: "welcomeStep") }
    }

    @Published var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
    }
    /// 메뉴바 게이지 색상 정책 (전체 provider 공통)
    @Published var menuBarColorMode: MenuBarColorMode {
        didSet { defaults.set(menuBarColorMode.rawValue, forKey: "menuBarColorMode") }
    }
    @Published var percentageDisplay: PercentageDisplay {
        didSet { defaults.set(percentageDisplay.rawValue, forKey: "percentageDisplay") }
    }
    @Published var showBatteryPercent: Bool {
        didSet { defaults.set(showBatteryPercent, forKey: "showBatteryPercent") }
    }
    @Published var resetTimeDisplay: ResetTimeDisplay {
        didSet { defaults.set(resetTimeDisplay.rawValue, forKey: "resetTimeDisplay") }
    }
    @Published var timeFormat: TimeFormatStyle {
        didSet { defaults.set(timeFormat.rawValue, forKey: "timeFormat") }
    }
    @Published var autoRefresh: Bool {
        didSet { defaults.set(autoRefresh, forKey: "autoRefresh") }
    }
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    @Published var notificationPresets: [NotificationPreset] {
        didSet { NotificationThresholdStorage.save(notificationPresets, to: defaults) }
    }
    @Published var menuBarQuotaPreferences: MenuBarQuotaPreferences {
        didSet { menuBarQuotaPreferences.save(to: defaults) }
    }
    @Published private var storedNotificationTargets: NotificationTargetPreferences
    @Published private(set) var preferenceSaveError: String?
    var notificationTargets: NotificationTargetPreferences {
        get { storedNotificationTargets }
        set { _ = commitNotificationTargets(newValue, intent: .automatic) }
    }

    @discardableResult
    func commitNotificationTargets(_ value: NotificationTargetPreferences, intent: PreferenceChangeIntent)
        -> PreferenceSaveResult
    {
        var candidate = value
        candidate.inheritPersistence(from: storedNotificationTargets)
        let result = candidate.commit(to: defaults, intent: intent)
        if result.accepted, result == .saved || candidate != storedNotificationTargets {
            storedNotificationTargets = candidate
        }
        if case .user = intent { preferenceSaveError = result.message }
        return result
    }

    @discardableResult
    func setNotificationSelected(_ selected: Bool, limit: UsageLimit) -> PreferenceSaveResult {
        var candidate = notificationTargets
        candidate.setSelected(selected, limit: limit)
        return commitNotificationTargets(candidate, intent: .user)
    }
    @Published private(set) var resetCreditMenuBarModes: [String: String] {
        didSet { defaults.set(resetCreditMenuBarModes, forKey: Self.resetCreditMenuBarKey) }
    }
    static let resetCreditMenuBarKey = AppIdentifiers.defaultsKey("resetCreditMenuBar")

    func resetCreditMenuBarMode(for kind: AppProviderKind) -> ResetCreditMenuBarMode {
        resetCreditMenuBarModes[kind.rawValue].flatMap(ResetCreditMenuBarMode.init(rawValue:)) ?? .off
    }

    func setResetCreditMenuBarMode(_ mode: ResetCreditMenuBarMode, for kind: AppProviderKind) {
        resetCreditMenuBarModes[kind.rawValue] = mode.rawValue
    }
    private(set) var usageDisplayModeRevision: UInt64 = 0
    @Published var usageDisplayMode: UsageDisplayMode {
        didSet {
            guard usageDisplayMode != oldValue else { return }
            usageDisplayModeRevision += 1
            defaults.set(usageDisplayMode.rawValue, forKey: "usageDisplayMode")
        }
    }
    var notificationValueBasis: UsageValueBasis {
        usageDisplayMode.basis ?? (alertRemainingMode ? .remaining : .used)
    }

    func displayedNotificationThreshold(_ preset: NotificationPreset) -> Int {
        notificationValueBasis == .remaining ? 100 - preset.threshold : preset.threshold
    }

    func setDisplayedNotificationThreshold(_ value: Int, id: String, basis: UsageValueBasis? = nil) {
        guard let index = notificationPresets.firstIndex(where: { $0.id == id }) else { return }
        let used = (basis ?? notificationValueBasis) == .remaining ? 100 - value : value
        let threshold = max(1, min(used, 100))
        // 편집기는 사라질 때 모든 칸을 다시 넣는다. 값이 같으면 저장하지 않아 열기만으로 기록하지 않는다.
        guard notificationPresets[index].threshold != threshold else { return }
        notificationPresets[index].threshold = threshold
    }
    @Published var alertRemainingMode: Bool {
        didSet { defaults.set(alertRemainingMode, forKey: "alertRemainingMode") }
    }
    @Published var circularDisplayMode: CircularDisplayMode {
        didSet { defaults.set(circularDisplayMode.rawValue, forKey: "circularDisplayMode") }
    }
    @Published var shouldRevealClaudeAdvancedAuth: Bool = false
    /// Ephemeral navigation request; never resets the persisted one-time introduction.
    @Published var designComparisonRequested = false
    @Published var iconMetric: IconMetric {
        didSet { defaults.set(iconMetric.rawValue, forKey: "iconMetric") }
    }
    @Published var showClaudeIcon: Bool {
        didSet { defaults.set(showClaudeIcon, forKey: "showClaudeIcon") }
    }
    @Published var menuBarTextHighContrast: Bool {
        didSet { defaults.set(menuBarTextHighContrast, forKey: "menuBarTextHighContrast") }
    }
    @Published var claudeAlertEnabled: Bool {
        didSet { defaults.set(claudeAlertEnabled, forKey: "claudeAlertEnabled") }
    }
    @Published var claudeMessagesFallbackPolicy: ClaudeMessagesFallbackPolicy {
        didSet { defaults.set(claudeMessagesFallbackPolicy.rawValue, forKey: "claudeMessagesFallbackPolicy") }
    }
    @Published var claudeMessagesFallbackAutoDisableBelowPercent: Int {
        didSet { defaults.set(claudeMessagesFallbackAutoDisableBelowPercent, forKey: "claudeMessagesFallbackAutoDisableBelowPercent") }
    }
    @Published var alertFiveHourEnabled: Bool {
        didSet { defaults.set(alertFiveHourEnabled, forKey: "alertFiveHourEnabled") }
    }
    @Published var alertWeeklyEnabled: Bool {
        didSet { defaults.set(alertWeeklyEnabled, forKey: "alertWeeklyEnabled") }
    }
    @Published var updateCheckInterval: UpdateCheckInterval {
        didSet { defaults.set(updateCheckInterval.normalizedForAutomaticChecks.rawValue, forKey: "updateCheckInterval") }
    }
    // 런타임 전용 (UserDefaults 저장 안함)
    @Published var availableUpdate: UpdateInfo?

    @Published var popoverPinned: Bool {
        didSet { defaults.set(popoverPinned, forKey: "popoverPinned") }
    }
    @Published var motion: AppMotionPreferences {
        didSet { motion.persist(to: defaults) }
    }
    @Published var popoverCompact: Bool {
        didSet {
            defaults.set(popoverCompact, forKey: "popoverCompact")
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isReconcilingLaunchAtLogin, oldValue != launchAtLogin else { return }
            setLaunchAtLogin(launchAtLogin)
        }
    }
    @Published private(set) var launchAtLoginState: LaunchAtLoginState

    private var isReconcilingLaunchAtLogin = false
    @Published var preferredOrganizationID: String {
        didSet { defaults.set(preferredOrganizationID, forKey: "preferredOrganizationID") }
    }
    /// 호출부 migration 동안 유지하는 compatibility facade.
    /// 실제 권위와 persistence는 `PopoverDisplayPreferencesStore`에 있다.
    var popoverItemsByProvider:
        [String: [PopoverItemConfig]]
    {
        get {
            popoverDisplayPreferencesStore
                .fullItemsByProvider
        }
        set {
            let result = popoverDisplayPreferencesStore.setFullItemsByProvider(newValue)
            preferenceSaveError = result.message
            if result.accepted { objectWillChange.send() }
        }
    }
    var separateCompactConfig: Bool {
        get {
            popoverDisplayPreferencesStore
                .usesSeparateCompactItems
        }
        set {
            let result = popoverDisplayPreferencesStore.setUsesSeparateCompactItems(newValue)
            preferenceSaveError = result.message
            if result.accepted { objectWillChange.send() }
        }
    }
    var compactPopoverItemsByProvider:
        [String: [PopoverItemConfig]]
    {
        get {
            popoverDisplayPreferencesStore
                .compactItemsByProvider
        }
        set {
            let result = popoverDisplayPreferencesStore.setCompactItemsByProvider(newValue)
            preferenceSaveError = result.message
            if result.accepted { objectWillChange.send() }
        }
    }
    @Published var showCodexIcon: Bool {
        didSet { defaults.set(showCodexIcon, forKey: "showCodexIcon") }
    }
    var providerStates: AppProviderStateCatalog {
        get {
            providerSelectionPreferencesStore
                .providerStates
        }
        set {
            guard newValue != providerStates else {
                return
            }
            objectWillChange.send()
            providerSelectionPreferencesStore
                .setProviderStates(newValue)
            providerSelectionRevision &+= 1
        }
    }
    var menuBarActiveServiceSelectionRawValue: String {
        get {
            providerSelectionPreferencesStore
                .menuBarActiveServiceRawValue
        }
        set {
            guard newValue
                    != menuBarActiveServiceSelectionRawValue
            else {
                return
            }
            objectWillChange.send()
            providerSelectionPreferencesStore
                .setMenuBarActiveServiceRawValue(
                    newValue
                )
            providerSelectionRevision &+= 1
        }
    }
    @Published private(set) var providerSelectionRevision:
        Int = 0
    @Published var codexPercentageDisplay: PercentageDisplay {
        didSet { defaults.set(codexPercentageDisplay.rawValue, forKey: "codexPercentageDisplay") }
    }
    @Published var codexResetTimeDisplay: ResetTimeDisplay {
        didSet { defaults.set(codexResetTimeDisplay.rawValue, forKey: "codexResetTimeDisplay") }
    }
    /// 시간 형식은 2.8.0부터 모든 서비스가 하나를 쓴다(TimeFormatUnification).
    var codexTimeFormat: TimeFormatStyle {
        get { timeFormat }
        set { timeFormat = newValue }
    }
    @Published var codexMenuBarStyle: MenuBarStyle {
        didSet { defaults.set(codexMenuBarStyle.rawValue, forKey: "codexMenuBarStyle") }
    }
    @Published var codexCircularDisplayMode: CircularDisplayMode {
        didSet { defaults.set(codexCircularDisplayMode.rawValue, forKey: "codexCircularDisplayMode") }
    }
    @Published var codexIconMetric: IconMetric {
        didSet { defaults.set(codexIconMetric.rawValue, forKey: "codexIconMetric") }
    }
    @Published var codexShowBatteryPercent: Bool {
        didSet { defaults.set(codexShowBatteryPercent, forKey: "codexShowBatteryPercent") }
    }
    @Published var codexAlertEnabled: Bool {
        didSet { defaults.set(codexAlertEnabled, forKey: "codexAlertEnabled") }
    }
    @Published var settingsLastTab: String {
        didSet { defaults.set(settingsLastTab, forKey: "settingsLastTab") }
    }

    nonisolated static func normalizedRefreshInterval(
        _ interval: TimeInterval,
        fallback: TimeInterval = 30
    ) -> TimeInterval {
        guard interval.isFinite else { return fallback }
        return min(max(interval, minimumRefreshInterval), maximumRefreshInterval)
    }

    // MARK: - Snapshot

    struct Snapshot {
        let antigravityHoverObject: Any?
        let hoverPreferences: PopoverHoverPreferences.Snapshot
        let menuBarPresets: MenuBarPresetStore.Snapshot
        let popoverPreferences: PopoverDisplayPreferencesStore.Snapshot
        let resetCreditMenuBarModes: [String: String]
        let menuBarDesign: MenuBarDesign
        let menuBarDesignIntroductionDismissed: Bool
        let welcomeState: WelcomeState
        let welcomeStep: WelcomeStep
        let menuBarStyle: MenuBarStyle
        let percentageDisplay: PercentageDisplay
        let showBatteryPercent: Bool
        let resetTimeDisplay: ResetTimeDisplay
        let timeFormat: TimeFormatStyle
        let circularDisplayMode: CircularDisplayMode
        let iconMetric: IconMetric
        let menuBarColorMode: MenuBarColorMode
        let autoRefresh: Bool
        let notificationsEnabled: Bool
        let notificationPresets: [NotificationPreset]
        let notificationTargets: NotificationTargetPreferences
        let menuBarQuotaPreferences: MenuBarQuotaPreferences
        let alertRemainingMode: Bool
        let usageDisplayMode: UsageDisplayMode
        let showClaudeIcon: Bool
        let menuBarTextHighContrast: Bool
        let updateCheckInterval: UpdateCheckInterval
        let claudeAlertEnabled: Bool
        let claudeMessagesFallbackPolicy: ClaudeMessagesFallbackPolicy
        let claudeMessagesFallbackAutoDisableBelowPercent: Int
        let alertFiveHourEnabled: Bool
        let alertWeeklyEnabled: Bool
        let popoverPinned: Bool
        let motion: AppMotionPreferences
        let popoverCompact: Bool
        let launchAtLogin: Bool
        let preferredOrganizationID: String
        let popoverItemsByProvider: [String: [PopoverItemConfig]]
        let separateCompactConfig: Bool
        let compactPopoverItemsByProvider: [String: [PopoverItemConfig]]
        let showCodexIcon: Bool
        let codexPercentageDisplay: PercentageDisplay
        let codexResetTimeDisplay: ResetTimeDisplay
        let codexTimeFormat: TimeFormatStyle
        let codexMenuBarStyle: MenuBarStyle
        let codexCircularDisplayMode: CircularDisplayMode
        let codexIconMetric: IconMetric
        let codexShowBatteryPercent: Bool
        let codexAlertEnabled: Bool
        let providerStates: AppProviderStateCatalog
        let menuBarActiveServiceRawValue: String
        let runtimeProviderDisplayConfigs: [AppProviderKind: ProviderMenuBarDisplayConfig]
        let providerAlertEnabledStates: [AppProviderKind: Bool]
        let settingsLastTab: String
    }

    func createSnapshot() -> Snapshot {
        Snapshot(
            antigravityHoverObject: defaults.object(forKey: AntigravityHoverDisplayPreferences.key),
            hoverPreferences: popoverDisplayPreferencesStore.hoverSnapshot(),
            menuBarPresets: menuBarPresets.snapshot(),
            popoverPreferences: popoverDisplayPreferencesStore.snapshot(),
            resetCreditMenuBarModes: resetCreditMenuBarModes,
            menuBarDesign: menuBarDesign,
            menuBarDesignIntroductionDismissed: menuBarDesignIntroductionDismissed,
            welcomeState: welcomeState, welcomeStep: welcomeStep,
            menuBarStyle: menuBarStyle,
            percentageDisplay: percentageDisplay,
            showBatteryPercent: showBatteryPercent,
            resetTimeDisplay: resetTimeDisplay,
            timeFormat: timeFormat,
            circularDisplayMode: circularDisplayMode,
            iconMetric: iconMetric,
            menuBarColorMode: menuBarColorMode,
            autoRefresh: autoRefresh,
            notificationsEnabled: notificationsEnabled,
            notificationPresets: notificationPresets,
            notificationTargets: notificationTargets,
            menuBarQuotaPreferences: menuBarQuotaPreferences,
            alertRemainingMode: alertRemainingMode,
            usageDisplayMode: usageDisplayMode,
            showClaudeIcon: showClaudeIcon,
            menuBarTextHighContrast: menuBarTextHighContrast,
            updateCheckInterval: updateCheckInterval,
            claudeAlertEnabled: claudeAlertEnabled,
            claudeMessagesFallbackPolicy: claudeMessagesFallbackPolicy,
            claudeMessagesFallbackAutoDisableBelowPercent: claudeMessagesFallbackAutoDisableBelowPercent,
            alertFiveHourEnabled: alertFiveHourEnabled,
            alertWeeklyEnabled: alertWeeklyEnabled,
            popoverPinned: popoverPinned,
            motion: motion,
            popoverCompact: popoverCompact,
            launchAtLogin: launchAtLogin,
            preferredOrganizationID: preferredOrganizationID,
            popoverItemsByProvider: popoverItemsByProvider,
            separateCompactConfig: separateCompactConfig,
            compactPopoverItemsByProvider: compactPopoverItemsByProvider,
            showCodexIcon: showCodexIcon,
            codexPercentageDisplay: codexPercentageDisplay,
            codexResetTimeDisplay: codexResetTimeDisplay,
            codexTimeFormat: codexTimeFormat,
            codexMenuBarStyle: codexMenuBarStyle,
            codexCircularDisplayMode: codexCircularDisplayMode,
            codexIconMetric: codexIconMetric,
            codexShowBatteryPercent: codexShowBatteryPercent,
            codexAlertEnabled: codexAlertEnabled,
            providerStates: providerStates,
            menuBarActiveServiceRawValue: activeMenuBarServiceRawValue,
            runtimeProviderDisplayConfigs: Dictionary(
                uniqueKeysWithValues: AppProviderKind.runtimeKinds.compactMap { kind in
                    menuBarDisplayConfig(for: kind).map { (kind, $0) }
                }
            ),
            providerAlertEnabledStates: Dictionary(
                uniqueKeysWithValues: AppProviderKind.runtimeKinds.map { kind in
                    (kind, isProviderAlertEnabled(kind))
                }
            ),
            settingsLastTab: settingsLastTab
        )
    }

    func restore(from snapshot: Snapshot) {
        if let object = snapshot.antigravityHoverObject {
            defaults.set(object, forKey: AntigravityHoverDisplayPreferences.key)
        } else {
            defaults.removeObject(forKey: AntigravityHoverDisplayPreferences.key)
        }
        popoverDisplayPreferencesStore.restoreHover(snapshot.hoverPreferences)
        menuBarPresets.restore(snapshot.menuBarPresets)
        resetCreditMenuBarModes = snapshot.resetCreditMenuBarModes
        menuBarDesign = snapshot.menuBarDesign
        menuBarDesignIntroductionDismissed = snapshot.menuBarDesignIntroductionDismissed
        welcomeState = snapshot.welcomeState
        welcomeStep = snapshot.welcomeStep
        menuBarStyle = snapshot.menuBarStyle
        percentageDisplay = snapshot.percentageDisplay
        showBatteryPercent = snapshot.showBatteryPercent
        resetTimeDisplay = snapshot.resetTimeDisplay
        timeFormat = snapshot.timeFormat
        circularDisplayMode = snapshot.circularDisplayMode
        menuBarColorMode = snapshot.menuBarColorMode
        iconMetric = snapshot.iconMetric
        autoRefresh = snapshot.autoRefresh
        notificationsEnabled = snapshot.notificationsEnabled
        notificationPresets = snapshot.notificationPresets
        snapshot.notificationTargets.restoreStorage(to: defaults)
        storedNotificationTargets = NotificationTargetPreferences.load(from: defaults)
        menuBarQuotaPreferences = snapshot.menuBarQuotaPreferences
        alertRemainingMode = snapshot.alertRemainingMode
        usageDisplayMode = snapshot.usageDisplayMode
        showClaudeIcon = snapshot.showClaudeIcon
        menuBarTextHighContrast = snapshot.menuBarTextHighContrast
        updateCheckInterval = snapshot.updateCheckInterval.normalizedForAutomaticChecks
        claudeAlertEnabled = snapshot.claudeAlertEnabled
        claudeMessagesFallbackPolicy = snapshot.claudeMessagesFallbackPolicy
        claudeMessagesFallbackAutoDisableBelowPercent = Self.normalizedMessagesFallbackThreshold(snapshot.claudeMessagesFallbackAutoDisableBelowPercent)
        alertFiveHourEnabled = snapshot.alertFiveHourEnabled
        alertWeeklyEnabled = snapshot.alertWeeklyEnabled
        popoverPinned = snapshot.popoverPinned
        motion = snapshot.motion
        popoverCompact = snapshot.popoverCompact
        launchAtLogin = snapshot.launchAtLogin
        preferredOrganizationID = snapshot.preferredOrganizationID
        popoverDisplayPreferencesStore.restore(snapshot.popoverPreferences)
        showCodexIcon = snapshot.showCodexIcon
        codexPercentageDisplay = snapshot.codexPercentageDisplay
        codexResetTimeDisplay = snapshot.codexResetTimeDisplay
        codexTimeFormat = snapshot.codexTimeFormat
        codexMenuBarStyle = snapshot.codexMenuBarStyle
        codexCircularDisplayMode = snapshot.codexCircularDisplayMode
        codexIconMetric = snapshot.codexIconMetric
        codexShowBatteryPercent = snapshot.codexShowBatteryPercent
        codexAlertEnabled = snapshot.codexAlertEnabled
        providerStates = snapshot.providerStates
        menuBarActiveServiceSelectionRawValue = snapshot.menuBarActiveServiceRawValue
        for (kind, config) in snapshot.runtimeProviderDisplayConfigs {
            setProviderShowIcon(config.showIcon, for: kind)
            setStoredMenuBarStyle(config.style, for: kind)
            setProviderPercentageDisplay(config.percentageDisplay, for: kind)
            setProviderShowBatteryPercent(config.showBatteryPercent, for: kind)
            setProviderResetTimeDisplay(config.resetTimeDisplay, for: kind)
            setProviderTimeFormat(config.timeFormat, for: kind)
            setProviderCircularDisplayMode(config.circularDisplayMode, for: kind)
            setProviderIconMetric(config.iconMetric, for: kind)
        }
        for (kind, isEnabled) in snapshot.providerAlertEnabledStates {
            setProviderAlertEnabled(isEnabled, for: kind)
        }
        settingsLastTab = snapshot.settingsLastTab
    }

    // MARK: - Computed

    var sortedNotificationPresets: [NotificationPreset] {
        notificationPresets.sorted { lhs, rhs in
            if lhs.threshold == rhs.threshold {
                return lhs.id < rhs.id
            }
            return lhs.threshold < rhs.threshold
        }
    }

    /// 실제 사용량 기준 임계값 (NotificationManager에서 사용)
    var enabledAlertThresholds: [Int] {
        let thresholds = sortedNotificationPresets
            .filter(\.isEnabled)
            .map(\.threshold)

        return thresholds.sorted()
    }

    /// provider별 팝오버 항목 (정규화 후).
    func popoverItems(for service: PopoverService) -> [PopoverItemConfig] {
        popoverDisplayPreferencesStore.items(for: service, surface: .standard)
    }

    /// Separate compact editing starts from the effective full list.
    func compactPopoverItems(for service: PopoverService) -> [PopoverItemConfig] {
        popoverDisplayPreferencesStore.items(for: service, surface: separateCompactConfig ? .compact : .standard)
    }

    func displayItems(for service: PopoverService, surface: ProviderDisplaySurface) -> [PopoverItemConfig] {
        switch surface {
        case .standard: popoverItems(for: service)
        case .compact: compactPopoverItems(for: service)
        case .hover: popoverDisplayPreferencesStore.items(for: service, surface: .hover)
        }
    }

    func setDisplayItems(_ items: [PopoverItemConfig], for service: PopoverService, surface: ProviderDisplaySurface)
        throws
    {
        try popoverDisplayPreferencesStore.setItems(items, for: service, surface: surface)
        objectWillChange.send()
    }

    /// density에 맞춰 실제로 사용할 항목 배열.
    func effectivePopoverItems(for service: PopoverService, density: PopoverDensity) -> [PopoverItemConfig] {
        density == .compact ? compactPopoverItems(for: service) : popoverItems(for: service)
    }

    /// provider의 항목 배열 업데이트 (정규화 적용).
    func setPopoverItems(_ items: [PopoverItemConfig], for service: PopoverService) {
        commitDisplayItems(items, for: service, surface: .standard)
    }

    func setCompactPopoverItems(_ items: [PopoverItemConfig], for service: PopoverService) {
        commitDisplayItems(items, for: service, surface: .compact)
    }

    private func commitDisplayItems(
        _ items: [PopoverItemConfig], for service: PopoverService,
        surface: ProviderDisplaySurface
    ) {
        do {
            try setDisplayItems(items, for: service, surface: surface)
            preferenceSaveError = nil
        } catch { preferenceSaveError = error.localizedDescription }
    }

    /// SwiftUI 바인딩.
    func popoverItemsBinding(for service: PopoverService, isCompact: Bool) -> Binding<[PopoverItemConfig]> {
        Binding(
            get: {
                isCompact
                    ? self.compactPopoverItems(for: service)
                    : self.popoverItems(for: service)
            },
            set: { newValue in
                if isCompact {
                    self.setCompactPopoverItems(newValue, for: service)
                } else {
                    self.setPopoverItems(newValue, for: service)
                }
            }
        )
    }

    var providerExposurePolicy: ProviderExposurePolicy {
        .allSupported
    }

    var enabledProviderKinds: [AppProviderKind] {
        providerStates.enabledProviderKinds.filter(isProviderExposed)
    }

    var runtimeEnabledProviderKinds: [AppProviderKind] {
        providerStates.enabledRuntimeProviderKinds.filter(isProviderExposed)
    }

    var shellEnabledProviderKinds: [AppProviderKind] {
        providerStates.enabledShellProviderKinds.filter(isProviderExposed)
    }

    var hasAnyEnabledProvider: Bool {
        !enabledProviderKinds.isEmpty
    }

    var hasMultipleEnabledProviders: Bool {
        enabledProviderKinds.count > 1
    }

    var hasAnyRuntimeEnabledProvider: Bool {
        !runtimeEnabledProviderKinds.isEmpty
    }

    var hasMultipleRuntimeEnabledProviders: Bool {
        runtimeEnabledProviderKinds.count > 1
    }

    static var defaultNotificationPresets: [NotificationPreset] {
        [75, 90, 95].map { NotificationPreset(threshold: $0, isEnabled: true) }
    }

    var activeProviderKind: AppProviderKind? {
        guard let active = providerStates.activeProviderKind,
              isProviderExposed(active) else {
            return nil
        }
        return active
    }

    var activeRuntimeProviderKind: AppProviderKind? {
        guard let active = providerStates.activeRuntimeProviderKind,
              isProviderExposed(active) else {
            return nil
        }
        return active
    }

    var activeMenuBarServiceRawValue: String {
        guard let service = PopoverService(
            rawValue: menuBarActiveServiceSelectionRawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ), isProviderExposed(service.providerKind) else {
            return runtimeEnabledProviderKinds.first?.runtimeService?.rawValue ?? "claude"
        }
        return service.rawValue
    }

    var claudeEnabled: Bool {
        providerStates.state(for: .claude).isEnabled
    }

    var codexEnabled: Bool {
        isProviderEnabled(.codex)
    }

    var menuBarActiveService: String {
        activeMenuBarServiceRawValue
    }

    var providerSelectionState: ProviderSelectionState {
        let exposurePolicy = providerExposurePolicy
        return ProviderSelectionState(
            exposedKinds: exposurePolicy.exposedKinds,
            exposedRuntimeKinds: exposurePolicy.exposedRuntimeKinds,
            enabledKinds: enabledProviderKinds,
            runtimeEnabledKinds: runtimeEnabledProviderKinds,
            shellEnabledKinds: shellEnabledProviderKinds,
            activeKind: activeProviderKind,
            activeRuntimeKind: activeRuntimeProviderKind
        )
    }

    func isProviderExposed(_ kind: AppProviderKind) -> Bool {
        providerExposurePolicy.isExposed(kind)
    }

    var exposedRuntimeProviderKinds: [AppProviderKind] {
        providerExposurePolicy.exposedRuntimeKinds
    }

    var menuBarDisplayChangePublisher: AnyPublisher<Void, Never> {
        let basePublishers: [AnyPublisher<Void, Never>] = [
            $menuBarDesign.map { _ in () }.eraseToAnyPublisher(),
            $usageDisplayMode.map { _ in () }.eraseToAnyPublisher(),
            $menuBarStyle.map { _ in () }.eraseToAnyPublisher(),
            $menuBarColorMode.map { _ in () }.eraseToAnyPublisher(),
            $resetCreditMenuBarModes.map { _ in () }.eraseToAnyPublisher(),
            $menuBarQuotaPreferences.map { _ in () }.eraseToAnyPublisher(),
            $percentageDisplay.map { _ in () }.eraseToAnyPublisher(),
            $showBatteryPercent.map { _ in () }.eraseToAnyPublisher(),
            $resetTimeDisplay.map { _ in () }.eraseToAnyPublisher(),
            $timeFormat.map { _ in () }.eraseToAnyPublisher(),
            $circularDisplayMode.map { _ in () }.eraseToAnyPublisher(),
            $iconMetric.map { _ in () }.eraseToAnyPublisher(),
            $showClaudeIcon.map { _ in () }.eraseToAnyPublisher(),
            $menuBarTextHighContrast.map { _ in () }.eraseToAnyPublisher(),
            $showCodexIcon.map { _ in () }.eraseToAnyPublisher(),
            $codexPercentageDisplay.map { _ in () }.eraseToAnyPublisher(),
            $codexResetTimeDisplay.map { _ in () }.eraseToAnyPublisher(),
            $codexMenuBarStyle.map { _ in () }.eraseToAnyPublisher(),
            $codexCircularDisplayMode.map { _ in () }.eraseToAnyPublisher(),
            $codexIconMetric.map { _ in () }.eraseToAnyPublisher(),
            $codexShowBatteryPercent.map { _ in () }.eraseToAnyPublisher(),
        ]
        return Publishers.MergeMany(basePublishers).eraseToAnyPublisher()
    }

    func providerState(for kind: AppProviderKind) -> AppProviderState {
        providerStates.state(for: kind)
    }

    func isProviderEnabled(_ kind: AppProviderKind) -> Bool {
        guard isProviderExposed(kind) else { return false }
        return providerStates.state(for: kind).isEnabled
    }

    func setProviderEnabled(_ enabled: Bool, for kind: AppProviderKind) {
        let wasEnabled = providerStates.state(for: kind).isEnabled
        var catalog = providerStates
        catalog.setEnabled(enabled, for: kind)
        providerStates = catalog
        if enabled && !wasEnabled {
            applyMinimalVisiblePresetIfNeeded(for: kind)
        }
    }

    func isProviderVisibleInMenuBar(_ kind: AppProviderKind) -> Bool {
        guard let config = menuBarDisplayConfig(for: kind) else { return false }
        return isMenuBarConfigVisible(config)
    }

    func setProviderMenuBarVisible(_ visible: Bool, for kind: AppProviderKind) {
        if visible {
            applyMenuBarDisplayPreset(.basic, for: kind)
            return
        }

        if menuBarQuotaPreferences.providers[kind.rawValue] != nil
            || menuBarQuotaPreferences.gauges?[kind.rawValue] != nil
        {
            setMenuBarQuotaSelection(MenuBarQuotaSelection(), for: kind)
        }
        setProviderShowIcon(false, for: kind)
        setProviderPercentageDisplay(.none, for: kind)
        setProviderResetTimeDisplay(.none, for: kind)
        setMenuBarStyle(.none, for: kind)
    }

    func menuBarDisplayPreset(for kind: AppProviderKind) -> ProviderMenuBarDisplayPreset {
        guard let config = menuBarDisplayConfig(for: kind) else { return .custom }
        let current = CatalogMenuBarPresetDisplay(config: config, resetCredits: resetCreditMenuBarMode(for: kind))
        let choices: [(ProviderMenuBarDisplayPreset, MenuBarBuiltinPreset)] = [
            (.basic, .number), (.battery, .battery), (.dual, .twoLimits),
        ]
        for (legacy, builtin) in choices {
            let definition = MenuBarPresetCatalog.catalogDisplay(builtin, provider: kind)
            if config.style == definition.style,
                MenuBarPresetCatalog.matches(current, definition, config: config, limits: [], codexUsage: nil)
            {
                return legacy
            }
        }
        return .custom
    }

    func applyMenuBarDisplayPreset(_ preset: ProviderMenuBarDisplayPreset, for kind: AppProviderKind) {
        guard Self.ownsGenericMenuBarDisplay(kind), preset != .custom else { return }
        let builtin: MenuBarBuiltinPreset =
            switch preset {
            case .basic: .number
            case .battery: .battery
            case .dual: .twoLimits
            case .custom: .number
            }
        applyMenuBarPresetDisplay(MenuBarPresetCatalog.catalogDisplay(builtin, provider: kind), for: kind)
        try? menuBarPresets.record(.builtin(builtin), for: kind)
    }

    func applyMenuBarPresetDisplay(_ value: CatalogMenuBarPresetDisplay, for kind: AppProviderKind) {
        guard Self.ownsGenericMenuBarDisplay(kind), value.isValid else { return }
        setProviderShowIcon(value.showsLogo, for: kind)
        setStoredMenuBarStyle(value.style, for: kind)
        setProviderPercentageDisplay(value.percentage, for: kind)
        setProviderShowBatteryPercent(value.gaugeNumber, for: kind)
        setProviderResetTimeDisplay(value.resetTime, for: kind)
        setProviderIconMetric(value.iconMetric, for: kind)
        if let resetCredits = ResetCreditMenuBarMode(rawValue: value.resetCredits) {
            setResetCreditMenuBarMode(resetCredits, for: kind)
        }
        var preferences = menuBarQuotaPreferences
        preferences.providers[kind.rawValue] = value.selection
        if value.gauges != nil || preferences.gauges != nil {
            var gauges = preferences.gauges ?? [:]
            gauges[kind.rawValue] = value.gauges
            preferences.gauges = gauges.isEmpty ? nil : gauges
        }
        if preferences != menuBarQuotaPreferences { menuBarQuotaPreferences = preferences }
    }

    func setActiveProvider(_ kind: AppProviderKind?) {
        var catalog = providerStates
        catalog.setActiveProvider(kind)
        providerStates = catalog
    }

    func setActiveMenuBarService(_ service: PopoverService?) {
        let fallback = runtimeEnabledProviderKinds.first?.runtimeService?.rawValue ?? "claude"
        let rawValue = service?.rawValue ?? fallback
        let normalizedService = PopoverService(rawValue: rawValue)
        let normalized = normalizedService.map { isProviderExposed($0.providerKind) ? $0.rawValue : fallback } ?? fallback
        if menuBarActiveServiceSelectionRawValue != normalized {
            menuBarActiveServiceSelectionRawValue = normalized
        }
    }

    func menuBarDisplayConfig(for kind: AppProviderKind) -> ProviderMenuBarDisplayConfig? {
        switch kind {
        case .claude:
            return ProviderMenuBarDisplayConfig(
                kind: .claude,
                showIcon: showClaudeIcon,
                style: menuBarStyle,
                percentageDisplay: percentageDisplay,
                showBatteryPercent: showBatteryPercent,
                resetTimeDisplay: resetTimeDisplay,
                timeFormat: timeFormat,
                circularDisplayMode: circularDisplayMode,
                iconMetric: iconMetric,
                colorMode: menuBarColorMode, design: menuBarDesign, basisOverride: usageDisplayMode.basis,
                quotaSelection: menuBarQuotaPreferences.providers[kind.rawValue],
                gaugeSelection: menuBarQuotaPreferences.gauges?[kind.rawValue]
            )
        case .codex:
            return ProviderMenuBarDisplayConfig(
                kind: .codex,
                showIcon: showCodexIcon,
                style: codexMenuBarStyle,
                percentageDisplay: codexPercentageDisplay,
                showBatteryPercent: codexShowBatteryPercent,
                resetTimeDisplay: codexResetTimeDisplay,
                timeFormat: codexTimeFormat,
                circularDisplayMode: codexCircularDisplayMode,
                iconMetric: codexIconMetric,
                colorMode: menuBarColorMode, design: menuBarDesign, basisOverride: usageDisplayMode.basis,
                quotaSelection: menuBarQuotaPreferences.providers[kind.rawValue],
                gaugeSelection: menuBarQuotaPreferences.gauges?[kind.rawValue]
            )
        case .antigravity:
            // AGY의 서비스별 표시는 typed 설정이 소유하며 공통 표시 기준은 runtime mapper에 별도로 전달한다.
            return nil
        }
    }

    /// AGY의 메뉴바 표시 상태는 `AntigravityDisplaySettings.menuBar`가 단독으로
    /// 소유하고, 렌더링도 그 값만 읽는다. generic per-provider 키로 쓰면 아무도
    /// 읽지 않는 상태만 남으므로 이 표면에서는 AGY를 받지 않는다. 반대로
    /// provider 활성화와 메뉴바 노출은 공용 설정이므로 그대로 둔다.
    private static func ownsGenericMenuBarDisplay(_ kind: AppProviderKind) -> Bool {
        kind != .antigravity
    }

    func menuBarStyle(for kind: AppProviderKind) -> MenuBarStyle? {
        menuBarDisplayConfig(for: kind)?.style
    }

    func setProviderShowIcon(_ enabled: Bool, for kind: AppProviderKind) {
        switch kind {
        case .claude:
            showClaudeIcon = enabled
        case .codex:
            showCodexIcon = enabled
        case .antigravity:
            // typed display 설정이 단독 소유한다. generic 키는 쓰지 않는다.
            break
        }
    }

    func isProviderAlertEnabled(_ kind: AppProviderKind) -> Bool {
        switch kind {
        case .claude:
            return claudeAlertEnabled
        case .codex:
            return codexAlertEnabled
        case .antigravity:
            // AGY 알림 on/off는 AntigravityDisplaySettings.notifications가
            // 단독 소유하고 NotificationManager도 그 값만 본다.
            return false
        }
    }

    func setProviderAlertEnabled(_ enabled: Bool, for kind: AppProviderKind) {
        switch kind {
        case .claude:
            claudeAlertEnabled = enabled
        case .codex:
            codexAlertEnabled = enabled
        case .antigravity:
            // typed 설정이 단독 소유한다. generic 키는 쓰지 않는다.
            break
        }
    }

    func setMenuBarStyle(_ style: MenuBarStyle, for kind: AppProviderKind) {
        if let selected = menuBarQuotaPreferences.providers[kind.rawValue], selected.arrangement != nil {
            setMenuBarQuotaSelection(selected.settingGaugeStyle(style), for: kind)
        }
        setStoredMenuBarStyle(style, for: kind)

        // 배터리 스타일은 남은 사용량 표시가 자연스럽고, 스타일을 끄면 기본 사용량 기준으로 되돌립니다.
        if style.isBatteryStyle {
            setProviderCircularDisplayMode(.remaining, for: kind)
        } else if style == .none {
            setProviderCircularDisplayMode(.usage, for: kind)
        }
    }

    private func setStoredMenuBarStyle(_ style: MenuBarStyle, for kind: AppProviderKind) {
        switch kind {
        case .claude:
            menuBarStyle = style
        case .codex:
            codexMenuBarStyle = style
        case .antigravity:
            // typed display 설정이 단독 소유한다. generic 키는 쓰지 않는다.
            break
        }
    }

    func setProviderPercentageDisplay(_ display: PercentageDisplay, for kind: AppProviderKind) {
        switch kind {
        case .claude:
            percentageDisplay = display
        case .codex:
            codexPercentageDisplay = display
        case .antigravity:
            // typed display 설정이 단독 소유한다. generic 키는 쓰지 않는다.
            break
        }
    }

    func setProviderResetTimeDisplay(_ display: ResetTimeDisplay, for kind: AppProviderKind) {
        switch kind {
        case .claude:
            resetTimeDisplay = display
        case .codex:
            codexResetTimeDisplay = display
        case .antigravity:
            // typed display 설정이 단독 소유한다. generic 키는 쓰지 않는다.
            break
        }
    }

    func setProviderTimeFormat(_ format: TimeFormatStyle, for kind: AppProviderKind) {
        switch kind {
        case .claude:
            timeFormat = format
        case .codex:
            codexTimeFormat = format
        case .antigravity:
            // typed display 설정이 단독 소유한다. generic 키는 쓰지 않는다.
            break
        }
    }

    func setProviderShowBatteryPercent(_ enabled: Bool, for kind: AppProviderKind) {
        switch kind {
        case .claude:
            showBatteryPercent = enabled
        case .codex:
            codexShowBatteryPercent = enabled
        case .antigravity:
            // typed display 설정이 단독 소유한다. generic 키는 쓰지 않는다.
            break
        }
    }

    func setProviderCircularDisplayMode(_ mode: CircularDisplayMode, for kind: AppProviderKind) {
        switch kind {
        case .claude:
            circularDisplayMode = mode
        case .codex:
            codexCircularDisplayMode = mode
        case .antigravity:
            // typed display 설정이 단독 소유한다. generic 키는 쓰지 않는다.
            break
        }
    }

    func setProviderIconMetric(_ metric: IconMetric, for kind: AppProviderKind) {
        switch kind {
        case .claude:
            iconMetric = metric
        case .codex:
            codexIconMetric = metric
        case .antigravity:
            // typed display 설정이 단독 소유한다. generic 키는 쓰지 않는다.
            break
        }
    }

    private func isMenuBarConfigVisible(_ config: ProviderMenuBarDisplayConfig) -> Bool {
        let gaugeVisible =
            config.style != .none
            && (config.gaugeSelection?.ids.map { !$0.isEmpty } ?? config.quotaSelection.map { !$0.gaugeIDs.isEmpty }
                ?? true)
        let numberVisible =
            config.quotaSelection.map(\.hasPercentageIntent) ?? (config.percentageDisplay != .none)
        let resetVisible = config.quotaSelection.map(\.hasResetIntent) ?? (config.resetTimeDisplay != .none)
        return config.showIcon || gaugeVisible || numberVisible || resetVisible
    }

    private func hasExplicitMenuBarCustomization(for kind: AppProviderKind) -> Bool {
        if menuBarQuotaPreferences.providers[kind.rawValue] != nil
            || menuBarQuotaPreferences.gauges?[kind.rawValue] != nil
        {
            return true
        }
        switch kind {
        case .claude:
            return true
        case .codex:
            return defaults.object(forKey: "showCodexIcon") != nil
                || defaults.object(forKey: "codexPercentageDisplay") != nil
                || defaults.object(forKey: "codexResetTimeDisplay") != nil
                || defaults.object(forKey: "codexMenuBarStyle") != nil
        case .antigravity:
            // 메뉴바 표시를 AGY typed 설정이 소유해 이 경로에서 기본 표시를 적용하지 않는다.
            return true
        }
    }

    private func applyMinimalVisiblePresetIfNeeded(for kind: AppProviderKind) {
        guard !hasExplicitMenuBarCustomization(for: kind) else { return }
        guard let config = menuBarDisplayConfig(for: kind), !isMenuBarConfigVisible(config) else { return }

        applyMinimalVisiblePreset(force: false, for: kind)
    }

    private func applyMinimalVisiblePreset(force: Bool, for kind: AppProviderKind) {
        if !force, let config = menuBarDisplayConfig(for: kind), isMenuBarConfigVisible(config) {
            return
        }
        applyMenuBarDisplayPreset(.basic, for: kind)
    }

    // MARK: - Actions

    /// 표시, 알림, 동작 설정을 처음 설치한 상태로 되돌린다. 계정 연결, 서비스 사용 여부, 조직 선택,
    /// 로그인 시 자동 시작은 사용자의 환경이라 건드리지 않는다.
    func resetToDefaults() {
        menuBarColorMode = .always
        timeFormat = .h24
        circularDisplayMode = .usage
        autoRefresh = true
        notificationsEnabled = false
        notificationPresets = Self.defaultNotificationPresets
        _ = commitNotificationTargets(notificationTargets.resetKnown(), intent: .automatic)
        menuBarQuotaPreferences = MenuBarQuotaPreferences()
        alertRemainingMode = false
        usageDisplayMode = .remaining
        defaults.removeObject(forKey: "hasCompletedSetupWizard")
        menuBarTextHighContrast = false
        updateCheckInterval = .enforced
        claudeAlertEnabled = true
        claudeMessagesFallbackPolicy = .off
        claudeMessagesFallbackAutoDisableBelowPercent = Self.normalizedMessagesFallbackThreshold(20)
        alertFiveHourEnabled = true
        alertWeeklyEnabled = false
        popoverPinned = false
        popoverCompact = false
        motion = AppMotionPreferences()
        popoverDisplayPreferencesStore.restoreHoverDefaults()
        popoverDisplayPreferencesStore.restoreKnownDefaults()
        separateCompactConfig = false
        codexTimeFormat = .h24
        codexCircularDisplayMode = .usage
        codexAlertEnabled = false
        Self.legacyAntigravityKeys.forEach(defaults.removeObject(forKey:))
        for provider in [AppProviderKind.claude, .codex] {
            applyMenuBarPresetDisplay(MenuBarPresetCatalog.catalogDisplay(.number, provider: provider), for: provider)
            // Unreadable/future preset data remains untouched even during an explicit display reset.
            try? menuBarPresets.record(.builtin(.number), for: provider)
        }
        settingsLastTab = "common"
    }

    // MARK: - Launch at Login

    func setLaunchAtLogin(_ requested: Bool) {
        applyLaunchAtLoginState(launchAtLoginController.request(requested))
    }

    func refreshLaunchAtLoginStatus() {
        applyLaunchAtLoginState(launchAtLoginController.refresh(launchAtLoginState))
    }

    func openLoginItemSettings() { launchAtLoginController.openSystemSettings() }

    private func applyLaunchAtLoginState(_ state: LaunchAtLoginState) {
        if launchAtLoginState != state { launchAtLoginState = state }
        // Keep the legacy saved Boolean as actual authorization, not a pending request.
        // 설정을 열거나 앱으로 돌아올 때마다 같은 값을 다시 쓰지 않는다.
        if defaults.object(forKey: "launchAtLogin") as? Bool != state.isEnabled {
            defaults.set(state.isEnabled, forKey: "launchAtLogin")
        }
        guard launchAtLogin != state.isEnabled else { return }
        isReconcilingLaunchAtLogin = true
        launchAtLogin = state.isEnabled
        isReconcilingLaunchAtLogin = false
    }

    // MARK: - Init

    /// 기본은 standard지만 테스트에서 suite 기반 UserDefaults를 주입할 수 있다.
    /// AppSettings는 지금까지 singleton+UserDefaults.standard에 묶여 있어 어떤
    /// 초기화/마이그레이션 회귀도 테스트로 잡을 수 없었다.
    init(
        defaults: UserDefaults = .standard, hasExistingAccountStorage: Bool? = nil,
        launchAtLoginController: LaunchAtLoginController? = nil
    ) {
        let loginController = launchAtLoginController ?? LaunchAtLoginController()
        let loginState = loginController.initialState()
        self.launchAtLoginController = loginController
        let experience = AppExperiencePreferences.load(
            from: defaults,
            hasAccountStorage: hasExistingAccountStorage
                ?? (defaults === UserDefaults.standard && !AppRuntimeEnvironment.isRunningUnitTests
                    && AppExperiencePreferences.hasLocalAccountStorage))
        AppSettingsMigration.run(defaults: defaults, isExistingInstall: experience.isExistingInstall)
        self.usageDisplayMode =
            defaults.string(forKey: AppSettingsMigration.usageDisplayModeKey).flatMap(UsageDisplayMode.init(rawValue:))
            ?? .remaining
        self.menuBarDesign = experience.design
        self.menuBarDesignIntroductionDismissed = experience.designIntroductionDismissed
        self.welcomeState = experience.welcomeState
        self.welcomeStep = experience.welcomeStep
        self.defaults = defaults
        self.menuBarPresets = MenuBarPresetStore(defaults: defaults)
        self.popoverDisplayPreferencesStore =
            PopoverDisplayPreferencesStore(
                defaults: defaults
            )
        self.providerSelectionPreferencesStore =
            ProviderSelectionPreferencesStore(
                defaults: defaults
            )
        let style = defaults.string(forKey: "menuBarStyle") ?? MenuBarStyle.none.rawValue
        self.menuBarStyle = MenuBarStyle(rawValue: style) ?? .none

        let colorMode = defaults.string(forKey: "menuBarColorMode") ?? MenuBarColorMode.always.rawValue
        self.menuBarColorMode = MenuBarColorMode(rawValue: colorMode) ?? .always

        self.percentageDisplay = AppSettingsMigration.percentageDisplay(from: defaults)

        self.showBatteryPercent = defaults.object(forKey: "showBatteryPercent") as? Bool ?? true
        let rtd = defaults.string(forKey: "resetTimeDisplay") ?? ResetTimeDisplay.none.rawValue
        self.resetTimeDisplay = ResetTimeDisplay(rawValue: rtd) ?? .none
        self.timeFormat = defaults.string(forKey: "timeFormat").flatMap(TimeFormatStyle.init(rawValue:)) ?? .h24
        self.autoRefresh = defaults.object(forKey: "autoRefresh") as? Bool ?? true
        self.notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? false
        self.alertRemainingMode = defaults.object(forKey: "alertRemainingMode") as? Bool ?? false
        self.storedNotificationTargets = NotificationTargetPreferences.load(from: defaults)
        self.menuBarQuotaPreferences = MenuBarQuotaPreferences.load(from: defaults)
        self.resetCreditMenuBarModes =
            defaults.dictionary(forKey: Self.resetCreditMenuBarKey) as? [String: String] ?? [:]
        self.notificationPresets = AppSettingsMigration.notificationPresets(from: defaults)
        let cdm = defaults.string(forKey: "circularDisplayMode") ?? CircularDisplayMode.usage.rawValue
        self.circularDisplayMode = CircularDisplayMode(rawValue: cdm) ?? .usage
        let iconMetricRaw = defaults.string(forKey: "iconMetric") ?? IconMetric.fiveHour.rawValue
        self.iconMetric = IconMetric(rawValue: iconMetricRaw) ?? .fiveHour
        self.showClaudeIcon = defaults.object(forKey: "showClaudeIcon") as? Bool ?? true
        self.menuBarTextHighContrast = defaults.object(forKey: "menuBarTextHighContrast") as? Bool ?? false
        self.updateCheckInterval =
            defaults.string(forKey: AppSettingsMigration.updateCheckIntervalKey).flatMap(
                UpdateCheckInterval.init(rawValue:))
            ?? .enforced
        if let storedClaudeAlertEnabled = defaults.object(forKey: "claudeAlertEnabled") as? Bool {
            self.claudeAlertEnabled = storedClaudeAlertEnabled
        } else {
            self.claudeAlertEnabled = (defaults.object(forKey: "alertFiveHourEnabled") as? Bool ?? true)
                || (defaults.object(forKey: "alertWeeklyEnabled") as? Bool ?? false)
        }
        let fallbackPolicyRaw = defaults.string(forKey: "claudeMessagesFallbackPolicy") ?? ClaudeMessagesFallbackPolicy.off.rawValue
        self.claudeMessagesFallbackPolicy = ClaudeMessagesFallbackPolicy(rawValue: fallbackPolicyRaw) ?? .off
        let storedFallbackThreshold = defaults.object(forKey: "claudeMessagesFallbackAutoDisableBelowPercent") as? Int ?? 20
        self.claudeMessagesFallbackAutoDisableBelowPercent = Self.normalizedMessagesFallbackThreshold(storedFallbackThreshold)
        self.alertFiveHourEnabled = defaults.object(forKey: "alertFiveHourEnabled") as? Bool ?? true
        self.alertWeeklyEnabled = defaults.object(forKey: "alertWeeklyEnabled") as? Bool ?? false
        self.popoverPinned = defaults.object(forKey: "popoverPinned") as? Bool ?? false
        self.popoverCompact = defaults.object(forKey: "popoverCompact") as? Bool ?? false
        self.motion = AppMotionPreferences.load(from: defaults)
        // 시스템 상태에서 실제 등록 여부 확인
        self.launchAtLoginState = loginState
        self.launchAtLogin = loginState.isEnabled
        defaults.set(loginState.isEnabled, forKey: "launchAtLogin")
        self.preferredOrganizationID = defaults.string(forKey: "preferredOrganizationID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.showCodexIcon = defaults.object(forKey: "showCodexIcon") as? Bool ?? true
        let cpd = defaults.string(forKey: "codexPercentageDisplay") ?? PercentageDisplay.fiveHour.rawValue
        self.codexPercentageDisplay = PercentageDisplay(rawValue: cpd) ?? .fiveHour
        let crd = defaults.string(forKey: "codexResetTimeDisplay") ?? ResetTimeDisplay.none.rawValue
        self.codexResetTimeDisplay = ResetTimeDisplay(rawValue: crd) ?? .none
        let cms = defaults.string(forKey: "codexMenuBarStyle") ?? MenuBarStyle.none.rawValue
        self.codexMenuBarStyle = MenuBarStyle(rawValue: cms) ?? .none
        let ccdm = defaults.string(forKey: "codexCircularDisplayMode") ?? CircularDisplayMode.usage.rawValue
        self.codexCircularDisplayMode = CircularDisplayMode(rawValue: ccdm) ?? .usage
        let codexIconMetricRaw = defaults.string(forKey: "codexIconMetric") ?? IconMetric.fiveHour.rawValue
        self.codexIconMetric = IconMetric(rawValue: codexIconMetricRaw) ?? .fiveHour
        self.codexShowBatteryPercent = defaults.object(forKey: "codexShowBatteryPercent") as? Bool ?? true
        self.codexAlertEnabled = defaults.object(forKey: "codexAlertEnabled") as? Bool ?? false
        self.settingsLastTab = defaults.string(forKey: "settingsLastTab") ?? "common"
        // 각 저장소가 이전 키를 옮긴 뒤에 지운다.
        RetiredAppDefaults.remove(from: defaults)
    }
}
