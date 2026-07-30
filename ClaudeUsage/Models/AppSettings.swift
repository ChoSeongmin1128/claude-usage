//
//  AppSettings.swift
//  ClaudeUsage
//
//  Phase 3: 앱 설정 모델 (UserDefaults 연동)
//

import Foundation
import Combine
import ServiceManagement
import SwiftUI

struct NotificationPreset: Codable, Identifiable, Hashable, Sendable {
    let id: String
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

    var isDualStyle: Bool {
        switch self {
        case .concentricRings, .dualBattery, .sideBySideBattery: return true
        default: return false
        }
    }
}

enum TimeFormatStyle: String, Codable, CaseIterable, Sendable {
    case h24 = "24h"
    case h12 = "12h"
    case remaining = "remaining"

    var displayName: String {
        switch self {
        case .h24: return "24시간 (18:34)"
        case .h12: return "12시간 (6:34 PM)"
        case .remaining: return "남은 시간 (2h 34m)"
        }
    }
}

enum ResetTimeDisplay: String, Codable, CaseIterable, Sendable {
    case none = "none"
    case fiveHour = "five_hour"
    case weekly = "weekly"
    case dual = "dual"

    var displayName: String {
        switch self {
        case .none: return "없음"
        case .fiveHour: return "현재 세션"
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
        case .fiveHour: return "현재 세션"
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
            return "현재 세션"
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
    static let shared: AppSettings = {
        _ = AntigravityApplicationBootstrap.prepareSettings()
        return AppSettings()
    }()
    nonisolated static let minimumRefreshInterval: TimeInterval = 15
    nonisolated static let maximumRefreshInterval: TimeInterval = 3600

    /// v2 전환 이후 더 읽지 않는 AGY 키. 초기화 경로에서 지우기만 해서
    /// 이전 값이 되살아나지 않게 한다.
    private static let legacyAntigravityModelKeys = [
        "antigravityUsageDataSource",
        "antigravityHiddenModelIDs",
        "antigravityMenuBarPrimaryModelID",
        "antigravityMenuBarSecondaryModelID",
    ]

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

    nonisolated private static func normalizedOptionalID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func loadStringSet(from defaults: UserDefaults, key: String) -> Set<String> {
        if let data = defaults.data(forKey: key),
           let values = try? JSONDecoder().decode([String].self, from: data) {
            return Set(values.compactMap(Self.normalizedOptionalID))
        }
        if let values = defaults.array(forKey: key) as? [String] {
            return Set(values.compactMap(Self.normalizedOptionalID))
        }
        return []
    }

    nonisolated private static func persistStringSet(_ values: Set<String>, to defaults: UserDefaults, key: String) {
        let normalized = values.compactMap(Self.normalizedOptionalID).sorted()
        if normalized.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: key)
        }
    }

    private let defaults: UserDefaults
    private let popoverDisplayPreferencesStore:
        PopoverDisplayPreferencesStore
    private let providerSelectionPreferencesStore:
        ProviderSelectionPreferencesStore

    var loadedProviderStatesFromDisk: Bool {
        providerSelectionPreferencesStore
            .loadedProviderStatesFromDisk
    }

    // MARK: - Published Properties

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
    @Published var refreshInterval: TimeInterval {
        didSet {
            let normalized = Self.normalizedRefreshInterval(refreshInterval)
            guard refreshInterval == normalized else {
                refreshInterval = normalized
                return
            }
            defaults.set(refreshInterval, forKey: "refreshInterval")
        }
    }
    @Published var usePerProviderRefreshIntervals: Bool {
        didSet { defaults.set(usePerProviderRefreshIntervals, forKey: "usePerProviderRefreshIntervals") }
    }
    @Published var claudeRefreshInterval: TimeInterval {
        didSet {
            let normalized = Self.normalizedRefreshInterval(claudeRefreshInterval)
            guard claudeRefreshInterval == normalized else {
                claudeRefreshInterval = normalized
                return
            }
            defaults.set(claudeRefreshInterval, forKey: "claudeRefreshInterval")
        }
    }
    @Published var codexRefreshInterval: TimeInterval {
        didSet {
            let normalized = Self.normalizedRefreshInterval(codexRefreshInterval)
            guard codexRefreshInterval == normalized else {
                codexRefreshInterval = normalized
                return
            }
            defaults.set(codexRefreshInterval, forKey: "codexRefreshInterval")
        }
    }
    @Published var antigravityRefreshInterval: TimeInterval {
        didSet {
            let normalized = Self.normalizedRefreshInterval(antigravityRefreshInterval)
            guard antigravityRefreshInterval == normalized else {
                antigravityRefreshInterval = normalized
                return
            }
            defaults.set(antigravityRefreshInterval, forKey: "antigravityRefreshInterval")
        }
    }
    func effectiveRefreshInterval(for service: PopoverService) -> TimeInterval {
        guard usePerProviderRefreshIntervals else { return Self.normalizedRefreshInterval(refreshInterval) }
        switch service {
        case .claude: return Self.normalizedRefreshInterval(claudeRefreshInterval)
        case .codex: return Self.normalizedRefreshInterval(codexRefreshInterval)
        case .antigravity: return Self.normalizedRefreshInterval(antigravityRefreshInterval)
        }
    }

    @Published var autoRefresh: Bool {
        didSet { defaults.set(autoRefresh, forKey: "autoRefresh") }
    }
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    @Published var notificationPresets: [NotificationPreset] {
        didSet {
            if let data = try? JSONEncoder().encode(notificationPresets) {
                defaults.set(data, forKey: "notificationPresets")
            }
        }
    }
    @Published var alertRemainingMode: Bool {
        didSet { defaults.set(alertRemainingMode, forKey: "alertRemainingMode") }
    }
    @Published var reducedRefreshOnBattery: Bool {
        didSet { defaults.set(reducedRefreshOnBattery, forKey: "reducedRefreshOnBattery") }
    }
    @Published var circularDisplayMode: CircularDisplayMode {
        didSet { defaults.set(circularDisplayMode.rawValue, forKey: "circularDisplayMode") }
    }
    @Published var shouldRevealClaudeAdvancedAuth: Bool = false
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
    @Published var popoverCompact: Bool {
        didSet {
            defaults.set(popoverCompact, forKey: "popoverCompact")
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isReconcilingLaunchAtLogin else { return }
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            updateLaunchAtLogin(launchAtLogin)
        }
    }
    @Published private(set) var launchAtLoginRequiresApproval = false
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
            objectWillChange.send()
            popoverDisplayPreferencesStore
                .setFullItemsByProvider(newValue)
        }
    }
    var separateCompactConfig: Bool {
        get {
            popoverDisplayPreferencesStore
                .usesSeparateCompactItems
        }
        set {
            objectWillChange.send()
            popoverDisplayPreferencesStore
                .setUsesSeparateCompactItems(newValue)
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
            objectWillChange.send()
            popoverDisplayPreferencesStore
                .setCompactItemsByProvider(newValue)
        }
    }
    @Published var showCodexIcon: Bool {
        didSet { defaults.set(showCodexIcon, forKey: "showCodexIcon") }
    }
    var additionalRuntimeProvidersEnabled: Bool {
        get {
            providerSelectionPreferencesStore
                .additionalProvidersEnabled
        }
        set {
            guard newValue
                    != additionalRuntimeProvidersEnabled
            else {
                return
            }
            objectWillChange.send()
            providerSelectionPreferencesStore
                .setAdditionalProvidersEnabled(
                    newValue
                )
            providerSelectionRevision &+= 1
        }
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
    @Published private(set) var runtimeProviderDisplayRevision: Int = 0
    @Published var codexPercentageDisplay: PercentageDisplay {
        didSet { defaults.set(codexPercentageDisplay.rawValue, forKey: "codexPercentageDisplay") }
    }
    @Published var codexResetTimeDisplay: ResetTimeDisplay {
        didSet { defaults.set(codexResetTimeDisplay.rawValue, forKey: "codexResetTimeDisplay") }
    }
    @Published var codexTimeFormat: TimeFormatStyle {
        didSet { defaults.set(codexTimeFormat.rawValue, forKey: "codexTimeFormat") }
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
        let menuBarStyle: MenuBarStyle
        let percentageDisplay: PercentageDisplay
        let showBatteryPercent: Bool
        let resetTimeDisplay: ResetTimeDisplay
        let timeFormat: TimeFormatStyle
        let circularDisplayMode: CircularDisplayMode
        let iconMetric: IconMetric
        let menuBarColorMode: MenuBarColorMode
        let refreshInterval: TimeInterval
        let usePerProviderRefreshIntervals: Bool
        let claudeRefreshInterval: TimeInterval
        let codexRefreshInterval: TimeInterval
        let antigravityRefreshInterval: TimeInterval
        let autoRefresh: Bool
        let notificationsEnabled: Bool
        let notificationPresets: [NotificationPreset]
        let alertRemainingMode: Bool
        let reducedRefreshOnBattery: Bool
        let showClaudeIcon: Bool
        let menuBarTextHighContrast: Bool
        let updateCheckInterval: UpdateCheckInterval
        let claudeAlertEnabled: Bool
        let claudeMessagesFallbackPolicy: ClaudeMessagesFallbackPolicy
        let claudeMessagesFallbackAutoDisableBelowPercent: Int
        let alertFiveHourEnabled: Bool
        let alertWeeklyEnabled: Bool
        let popoverPinned: Bool
        let popoverCompact: Bool
        let launchAtLogin: Bool
        let preferredOrganizationID: String
        let popoverItemsByProvider: [String: [PopoverItemConfig]]
        let separateCompactConfig: Bool
        let compactPopoverItemsByProvider: [String: [PopoverItemConfig]]
        let showCodexIcon: Bool
        let additionalRuntimeProvidersEnabled: Bool
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
            menuBarStyle: menuBarStyle,
            percentageDisplay: percentageDisplay,
            showBatteryPercent: showBatteryPercent,
            resetTimeDisplay: resetTimeDisplay,
            timeFormat: timeFormat,
            circularDisplayMode: circularDisplayMode,
            iconMetric: iconMetric,
            menuBarColorMode: menuBarColorMode,
            refreshInterval: refreshInterval,
            usePerProviderRefreshIntervals: usePerProviderRefreshIntervals,
            claudeRefreshInterval: claudeRefreshInterval,
            codexRefreshInterval: codexRefreshInterval,
            antigravityRefreshInterval: antigravityRefreshInterval,
            autoRefresh: autoRefresh,
            notificationsEnabled: notificationsEnabled,
            notificationPresets: notificationPresets,
            alertRemainingMode: alertRemainingMode,
            reducedRefreshOnBattery: reducedRefreshOnBattery,
            showClaudeIcon: showClaudeIcon,
            menuBarTextHighContrast: menuBarTextHighContrast,
            updateCheckInterval: updateCheckInterval,
            claudeAlertEnabled: claudeAlertEnabled,
            claudeMessagesFallbackPolicy: claudeMessagesFallbackPolicy,
            claudeMessagesFallbackAutoDisableBelowPercent: claudeMessagesFallbackAutoDisableBelowPercent,
            alertFiveHourEnabled: alertFiveHourEnabled,
            alertWeeklyEnabled: alertWeeklyEnabled,
            popoverPinned: popoverPinned,
            popoverCompact: popoverCompact,
            launchAtLogin: launchAtLogin,
            preferredOrganizationID: preferredOrganizationID,
            popoverItemsByProvider: popoverItemsByProvider,
            separateCompactConfig: separateCompactConfig,
            compactPopoverItemsByProvider: compactPopoverItemsByProvider,
            showCodexIcon: showCodexIcon,
            additionalRuntimeProvidersEnabled: additionalRuntimeProvidersEnabled,
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
        menuBarStyle = snapshot.menuBarStyle
        percentageDisplay = snapshot.percentageDisplay
        showBatteryPercent = snapshot.showBatteryPercent
        resetTimeDisplay = snapshot.resetTimeDisplay
        timeFormat = snapshot.timeFormat
        circularDisplayMode = snapshot.circularDisplayMode
        menuBarColorMode = snapshot.menuBarColorMode
        iconMetric = snapshot.iconMetric
        refreshInterval = snapshot.refreshInterval
        usePerProviderRefreshIntervals = snapshot.usePerProviderRefreshIntervals
        claudeRefreshInterval = snapshot.claudeRefreshInterval
        codexRefreshInterval = snapshot.codexRefreshInterval
        antigravityRefreshInterval = snapshot.antigravityRefreshInterval
        autoRefresh = snapshot.autoRefresh
        notificationsEnabled = snapshot.notificationsEnabled
        notificationPresets = snapshot.notificationPresets
        alertRemainingMode = snapshot.alertRemainingMode
        reducedRefreshOnBattery = snapshot.reducedRefreshOnBattery
        showClaudeIcon = snapshot.showClaudeIcon
        menuBarTextHighContrast = snapshot.menuBarTextHighContrast
        updateCheckInterval = snapshot.updateCheckInterval.normalizedForAutomaticChecks
        claudeAlertEnabled = snapshot.claudeAlertEnabled
        claudeMessagesFallbackPolicy = snapshot.claudeMessagesFallbackPolicy
        claudeMessagesFallbackAutoDisableBelowPercent = Self.normalizedMessagesFallbackThreshold(snapshot.claudeMessagesFallbackAutoDisableBelowPercent)
        alertFiveHourEnabled = snapshot.alertFiveHourEnabled
        alertWeeklyEnabled = snapshot.alertWeeklyEnabled
        popoverPinned = snapshot.popoverPinned
        popoverCompact = snapshot.popoverCompact
        launchAtLogin = snapshot.launchAtLogin
        preferredOrganizationID = snapshot.preferredOrganizationID
        popoverItemsByProvider = Self.normalizedPopoverDict(snapshot.popoverItemsByProvider)
        separateCompactConfig = snapshot.separateCompactConfig
        compactPopoverItemsByProvider = Self.normalizedPopoverDict(
            snapshot.compactPopoverItemsByProvider,
            fallback: snapshot.popoverItemsByProvider
        )
        showCodexIcon = snapshot.showCodexIcon
        additionalRuntimeProvidersEnabled = snapshot.additionalRuntimeProvidersEnabled
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
            setMenuBarStyle(config.style, for: kind)
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

    static func inferredAdditionalRuntimeProvidersEnabled(
        from defaults: UserDefaults,
        decodedProviderStates: AppProviderStateCatalog?,
        legacyCodexEnabled: Bool,
        activeService: String
    ) -> Bool {
        ProviderSelectionPreferencesStore
            .inferredAdditionalProvidersEnabled(
                from: defaults,
                decodedProviderStates:
                    decodedProviderStates,
                legacyCodexEnabled:
                    legacyCodexEnabled,
                activeService: activeService
            )
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

        if alertRemainingMode {
            return thresholds.map { max(1, min(100 - $0, 99)) }.sorted()
        }
        return thresholds.sorted()
    }

    var enabledCodexAlertThresholds: [Int] {
        enabledAlertThresholds
    }

    /// provider별 팝오버 항목 (정규화 후).
    func popoverItems(for service: PopoverService) -> [PopoverItemConfig] {
        guard let catalog =
                UsageItemCatalogRegistry.catalog(
                    for: service
                )
        else {
            return []
        }
        let normalized = catalog.normalized(popoverItemsByProvider[service.rawValue] ?? catalog.defaultItems)
        return normalized
    }

    /// provider별 간소화 팝오버 항목 (정규화 후).
    func compactPopoverItems(for service: PopoverService) -> [PopoverItemConfig] {
        guard let catalog =
                UsageItemCatalogRegistry.catalog(
                    for: service
                )
        else {
            return []
        }
        let stored = compactPopoverItemsByProvider[service.rawValue]
            ?? popoverItemsByProvider[service.rawValue]
            ?? catalog.defaultItems
        let normalized = catalog.normalized(stored)
        return normalized
    }

    /// density에 맞춰 실제로 사용할 항목 배열.
    func effectivePopoverItems(for service: PopoverService, density: PopoverDensity) -> [PopoverItemConfig] {
        if density == .compact && separateCompactConfig {
            return compactPopoverItems(for: service)
        }
        return popoverItems(for: service)
    }

    /// provider의 항목 배열 업데이트 (정규화 적용).
    func setPopoverItems(_ items: [PopoverItemConfig], for service: PopoverService) {
        guard let catalog =
                UsageItemCatalogRegistry.catalog(
                    for: service
                )
        else {
            return
        }
        var dict = popoverItemsByProvider
        dict[service.rawValue] = catalog.normalized(items)
        popoverItemsByProvider = dict
    }

    /// provider의 간소화 항목 배열 업데이트 (정규화 적용).
    func setCompactPopoverItems(_ items: [PopoverItemConfig], for service: PopoverService) {
        guard let catalog =
                UsageItemCatalogRegistry.catalog(
                    for: service
                )
        else {
            return
        }
        var dict = compactPopoverItemsByProvider
        dict[service.rawValue] = catalog.normalized(items)
        compactPopoverItemsByProvider = dict
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

    private static func legacyAlertThresholds(from defaults: UserDefaults) -> [Int] {
        if let saved = defaults.array(forKey: "alertThresholds") as? [Int], !saved.isEmpty {
            return saved
        }

        var migrated: [Int] = []
        let e1 = defaults.object(forKey: "alert1Enabled") as? Bool ?? true
        let e2 = defaults.object(forKey: "alert2Enabled") as? Bool ?? true
        let e3 = defaults.object(forKey: "alert3Enabled") as? Bool ?? true
        if e1 { migrated.append(defaults.object(forKey: "alert1Threshold") as? Int ?? 75) }
        if e2 { migrated.append(defaults.object(forKey: "alert2Threshold") as? Int ?? 90) }
        if e3 { migrated.append(defaults.object(forKey: "alert3Threshold") as? Int ?? 95) }
        return migrated.isEmpty ? [75, 90, 95] : migrated
    }

    private static func migrateNotificationPresets(from defaults: UserDefaults, commonRemainingMode: Bool) -> [NotificationPreset] {
        if let data = defaults.data(forKey: "notificationPresets"),
           let decoded = try? JSONDecoder().decode([NotificationPreset].self, from: data),
           !decoded.isEmpty {
            return decoded
        }

        let claudeThresholds = legacyAlertThresholds(from: defaults)
        let codexThresholds = defaults.array(forKey: "codexAlertThresholds") as? [Int] ?? claudeThresholds
        let codexRemainingMode = defaults.object(forKey: "codexAlertRemainingMode") as? Bool ?? commonRemainingMode

        func actualUsageThresholds(_ values: [Int], remainingMode: Bool) -> [Int] {
            values.map { value in
                let normalized = max(1, min(value, 100))
                return remainingMode ? max(1, min(100 - normalized, 99)) : normalized
            }
        }

        func storedThreshold(from actualThreshold: Int) -> Int {
            if commonRemainingMode {
                return max(1, min(100 - actualThreshold, 99))
            }
            return max(1, min(actualThreshold, 100))
        }

        let merged = Set(
            actualUsageThresholds(claudeThresholds, remainingMode: commonRemainingMode)
                + actualUsageThresholds(codexThresholds, remainingMode: codexRemainingMode)
        )
        let resolved = merged.isEmpty ? [75, 90, 95] : merged.sorted()
        return resolved.map { NotificationPreset(threshold: storedThreshold(from: $0), isEnabled: true) }
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
            $menuBarStyle.map { _ in () }.eraseToAnyPublisher(),
            $menuBarColorMode.map { _ in () }.eraseToAnyPublisher(),
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
            $codexTimeFormat.map { _ in () }.eraseToAnyPublisher(),
            $codexMenuBarStyle.map { _ in () }.eraseToAnyPublisher(),
            $codexCircularDisplayMode.map { _ in () }.eraseToAnyPublisher(),
            $codexIconMetric.map { _ in () }.eraseToAnyPublisher(),
            $codexShowBatteryPercent.map { _ in () }.eraseToAnyPublisher(),
        ]

        return Publishers.Merge(
            Publishers.MergeMany(basePublishers).eraseToAnyPublisher(),
            $runtimeProviderDisplayRevision.map { _ in () }.eraseToAnyPublisher()
        )
        .eraseToAnyPublisher()
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

        setProviderShowIcon(false, for: kind)
        setProviderPercentageDisplay(.none, for: kind)
        setProviderResetTimeDisplay(.none, for: kind)
        setMenuBarStyle(.none, for: kind)
    }

    func menuBarDisplayPreset(for kind: AppProviderKind) -> ProviderMenuBarDisplayPreset {
        guard let config = menuBarDisplayConfig(for: kind) else { return .custom }
        return ProviderMenuBarDisplayPreset.resolved(for: config)
    }

    func applyMenuBarDisplayPreset(_ preset: ProviderMenuBarDisplayPreset, for kind: AppProviderKind) {
        guard Self.ownsGenericMenuBarDisplay(kind) else { return }
        switch preset {
        case .basic:
            setProviderShowIcon(true, for: kind)
            setProviderPercentageDisplay(.fiveHour, for: kind)
            setProviderResetTimeDisplay(.none, for: kind)
            setMenuBarStyle(.none, for: kind)
        case .battery:
            setProviderShowIcon(true, for: kind)
            setProviderPercentageDisplay(.none, for: kind)
            setProviderResetTimeDisplay(.none, for: kind)
            setMenuBarStyle(.batteryBar, for: kind)
            setProviderShowBatteryPercent(true, for: kind)
            setProviderIconMetric(.fiveHour, for: kind)
            setProviderCircularDisplayMode(.remaining, for: kind)
        case .dual:
            setProviderShowIcon(true, for: kind)
            setProviderPercentageDisplay(.dual, for: kind)
            setProviderResetTimeDisplay(.none, for: kind)
            setMenuBarStyle(.none, for: kind)
        case .custom:
            break
        }
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
                colorMode: menuBarColorMode
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
                colorMode: menuBarColorMode
            )
        case .antigravity:
            // AGY 메뉴바 표시는 AntigravityDisplaySettings가 단독 소유한다.
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
        switch kind {
        case .claude:
            menuBarStyle = style
        case .codex:
            codexMenuBarStyle = style
        case .antigravity:
            // typed display 설정이 단독 소유한다. generic 키는 쓰지 않는다.
            break
        }

        // 배터리 스타일은 남은 사용량 표시가 자연스럽고, 스타일을 끄면 기본 사용량 기준으로 되돌립니다.
        if style.isBatteryStyle {
            setProviderCircularDisplayMode(.remaining, for: kind)
        } else if style == .none {
            setProviderCircularDisplayMode(.usage, for: kind)
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

    private func providerDefaultsKey(_ kind: AppProviderKind, suffix: String) -> String {
        "\(kind.rawValue).\(suffix)"
    }

    private func persistOptionalString(_ value: String?, key: String) {
        if let value = Self.normalizedOptionalID(value) {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func bumpRuntimeProviderDisplayRevision() {
        runtimeProviderDisplayRevision &+= 1
    }

    private func isMenuBarConfigVisible(_ config: ProviderMenuBarDisplayConfig) -> Bool {
        config.showIcon
            || config.percentageDisplay != .none
            || config.resetTimeDisplay != .none
            || config.style != .none
    }

    private func hasExplicitMenuBarCustomization(for kind: AppProviderKind) -> Bool {
        switch kind {
        case .claude:
            return true
        case .codex:
            return defaults.object(forKey: "showCodexIcon") != nil
                || defaults.object(forKey: "codexPercentageDisplay") != nil
                || defaults.object(forKey: "codexResetTimeDisplay") != nil
                || defaults.object(forKey: "codexMenuBarStyle") != nil
        case .antigravity:
            return defaults.object(forKey: providerDefaultsKey(kind, suffix: "showIcon")) != nil
                || defaults.object(forKey: providerDefaultsKey(kind, suffix: "percentageDisplay")) != nil
                || defaults.object(forKey: providerDefaultsKey(kind, suffix: "resetTimeDisplay")) != nil
                || defaults.object(forKey: providerDefaultsKey(kind, suffix: "menuBarStyle")) != nil
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

    private func providerBoolDefault(_ fallback: Bool, for kind: AppProviderKind, suffix: String) -> Bool {
        defaults.object(forKey: providerDefaultsKey(kind, suffix: suffix)) as? Bool ?? fallback
    }

    private func providerMenuBarStyle(for kind: AppProviderKind) -> MenuBarStyle {
        let raw = defaults.string(forKey: providerDefaultsKey(kind, suffix: "menuBarStyle")) ?? MenuBarStyle.none.rawValue
        return MenuBarStyle(rawValue: raw) ?? .none
    }

    private func providerPercentageDisplay(for kind: AppProviderKind) -> PercentageDisplay {
        let raw = defaults.string(forKey: providerDefaultsKey(kind, suffix: "percentageDisplay")) ?? PercentageDisplay.fiveHour.rawValue
        return PercentageDisplay(rawValue: raw) ?? .fiveHour
    }

    private func providerResetTimeDisplay(for kind: AppProviderKind) -> ResetTimeDisplay {
        let raw = defaults.string(forKey: providerDefaultsKey(kind, suffix: "resetTimeDisplay")) ?? ResetTimeDisplay.none.rawValue
        return ResetTimeDisplay(rawValue: raw) ?? .none
    }

    private func providerTimeFormat(for kind: AppProviderKind) -> TimeFormatStyle {
        let raw = defaults.string(forKey: providerDefaultsKey(kind, suffix: "timeFormat")) ?? TimeFormatStyle.h24.rawValue
        return TimeFormatStyle(rawValue: raw) ?? .h24
    }

    private func providerCircularDisplayMode(for kind: AppProviderKind) -> CircularDisplayMode {
        let raw = defaults.string(forKey: providerDefaultsKey(kind, suffix: "circularDisplayMode")) ?? CircularDisplayMode.usage.rawValue
        return CircularDisplayMode(rawValue: raw) ?? .usage
    }

    private func providerIconMetric(for kind: AppProviderKind) -> IconMetric {
        let raw = defaults.string(forKey: providerDefaultsKey(kind, suffix: "iconMetric")) ?? IconMetric.fiveHour.rawValue
        return IconMetric(rawValue: raw) ?? .fiveHour
    }

    // MARK: - Actions

    func resetToDefaults() {
        menuBarStyle = .none
        percentageDisplay = .fiveHour
        showBatteryPercent = true
        resetTimeDisplay = .none
        timeFormat = .h24
        circularDisplayMode = .usage
        iconMetric = .fiveHour
        refreshInterval = 30.0
        usePerProviderRefreshIntervals = false
        claudeRefreshInterval = 30.0
        codexRefreshInterval = 60.0
        antigravityRefreshInterval = 120.0
        defaults.removeObject(forKey: "usePerProviderRefreshIntervals")
        defaults.removeObject(forKey: "claudeRefreshInterval")
        defaults.removeObject(forKey: "codexRefreshInterval")
        defaults.removeObject(forKey: "antigravityRefreshInterval")
        Self.legacyAntigravityModelKeys.forEach(defaults.removeObject(forKey:))
        autoRefresh = true
        notificationsEnabled = false
        notificationPresets = Self.defaultNotificationPresets
        alertRemainingMode = false
        reducedRefreshOnBattery = true
        defaults.removeObject(forKey: "hasCompletedSetupWizard")
        showClaudeIcon = true
        menuBarTextHighContrast = false
        updateCheckInterval = .enforced
        claudeAlertEnabled = true
        claudeMessagesFallbackPolicy = .off
        claudeMessagesFallbackAutoDisableBelowPercent = Self.normalizedMessagesFallbackThreshold(20)
        alertFiveHourEnabled = true
        alertWeeklyEnabled = false
        popoverPinned = false
        popoverCompact = false
        launchAtLogin = false
        preferredOrganizationID = ""
        popoverItemsByProvider = Self.defaultPopoverItemsDict()
        separateCompactConfig = false
        compactPopoverItemsByProvider = Self.defaultPopoverItemsDict()
        showCodexIcon = true
        additionalRuntimeProvidersEnabled = false
        codexPercentageDisplay = .fiveHour
        codexResetTimeDisplay = .none
        codexTimeFormat = .h24
        codexMenuBarStyle = .none
        codexCircularDisplayMode = .usage
        codexIconMetric = .fiveHour
        codexShowBatteryPercent = true
        codexAlertEnabled = false
        clearRuntimeProviderDefaults(for: .antigravity)
        providerStates = AppProviderStateCatalog.defaultCatalog
        settingsLastTab = "common"
    }

    private func clearRuntimeProviderDefaults(for kind: AppProviderKind) {
        guard kind == .antigravity else { return }

        [
            "showIcon",
            "alertEnabled",
            "menuBarStyle",
            "percentageDisplay",
            "resetTimeDisplay",
            "timeFormat",
            "showBatteryPercent",
            "circularDisplayMode",
            "iconMetric",
        ].forEach { suffix in
            defaults.removeObject(forKey: providerDefaultsKey(kind, suffix: suffix))
        }
        defaults.removeObject(forKey: "\(kind.rawValue)PopoverPinned")
        defaults.removeObject(forKey: "\(kind.rawValue)PopoverCompact")
        defaults.removeObject(forKey: "\(kind.rawValue)SettingsLastTab")
        Self.legacyAntigravityModelKeys.forEach(defaults.removeObject(forKey:))
        bumpRuntimeProviderDisplayRevision()
    }

    // MARK: - Launch at Login

    private func updateLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .notRegistered {
                    try service.register()
                }
            } else {
                if service.status != .notRegistered {
                    try service.unregister()
                }
            }
        } catch {
            Logger.error("로그인 시 자동 시작 설정 실패: \(error)")
        }

        launchAtLoginRequiresApproval = service.status == .requiresApproval
        let actualEnabled = service.status == .enabled
        defaults.set(actualEnabled, forKey: "launchAtLogin")
        if launchAtLogin != actualEnabled {
            isReconcilingLaunchAtLogin = true
            launchAtLogin = actualEnabled
            isReconcilingLaunchAtLogin = false
        }
    }

    // MARK: - Init

    /// 기본은 standard지만 테스트에서 suite 기반 UserDefaults를 주입할 수 있다.
    /// AppSettings는 지금까지 singleton+UserDefaults.standard에 묶여 있어 어떤
    /// 초기화/마이그레이션 회귀도 테스트로 잡을 수 없었다.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

        // 마이그레이션: showPercentage/showDualPercentage → percentageDisplay
        if let pd = defaults.string(forKey: "percentageDisplay") {
            self.percentageDisplay = PercentageDisplay(rawValue: pd) ?? .fiveHour
        } else {
            let showPct = defaults.object(forKey: "showPercentage") as? Bool ?? true
            let showDual = defaults.object(forKey: "showDualPercentage") as? Bool ?? false
            if !showPct {
                self.percentageDisplay = .none
            } else if showDual {
                self.percentageDisplay = .dual
            } else {
                self.percentageDisplay = .fiveHour
            }
        }

        self.showBatteryPercent = defaults.object(forKey: "showBatteryPercent") as? Bool ?? true
        let rtd = defaults.string(forKey: "resetTimeDisplay") ?? ResetTimeDisplay.none.rawValue
        self.resetTimeDisplay = ResetTimeDisplay(rawValue: rtd) ?? .none
        let tf = defaults.string(forKey: "timeFormat") ?? TimeFormatStyle.h24.rawValue
        let resolvedTimeFormat = TimeFormatStyle(rawValue: tf) ?? .h24
        self.timeFormat = resolvedTimeFormat
        self.refreshInterval = Self.normalizedRefreshInterval(defaults.object(forKey: "refreshInterval") as? TimeInterval ?? 30.0)
        self.usePerProviderRefreshIntervals = defaults.object(forKey: "usePerProviderRefreshIntervals") as? Bool ?? false
        self.claudeRefreshInterval = Self.normalizedRefreshInterval(defaults.object(forKey: "claudeRefreshInterval") as? TimeInterval ?? 30.0)
        self.codexRefreshInterval = Self.normalizedRefreshInterval(defaults.object(forKey: "codexRefreshInterval") as? TimeInterval ?? 60.0)
        self.antigravityRefreshInterval = Self.normalizedRefreshInterval(defaults.object(forKey: "antigravityRefreshInterval") as? TimeInterval ?? 120.0)
        self.autoRefresh = defaults.object(forKey: "autoRefresh") as? Bool ?? true
        self.notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? false
        let storedAlertRemainingMode = defaults.object(forKey: "alertRemainingMode") as? Bool ?? false
        self.alertRemainingMode = storedAlertRemainingMode
        self.notificationPresets = Self.migrateNotificationPresets(from: defaults, commonRemainingMode: storedAlertRemainingMode)
        self.reducedRefreshOnBattery = defaults.object(forKey: "reducedRefreshOnBattery") as? Bool ?? true
        let cdm = defaults.string(forKey: "circularDisplayMode") ?? CircularDisplayMode.usage.rawValue
        self.circularDisplayMode = CircularDisplayMode(rawValue: cdm) ?? .usage
        let iconMetricRaw = defaults.string(forKey: "iconMetric") ?? IconMetric.fiveHour.rawValue
        self.iconMetric = IconMetric(rawValue: iconMetricRaw) ?? .fiveHour
        self.showClaudeIcon = defaults.object(forKey: "showClaudeIcon") as? Bool ?? true
        self.menuBarTextHighContrast = defaults.object(forKey: "menuBarTextHighContrast") as? Bool ?? false
        let uci = defaults.string(forKey: "updateCheckInterval") ?? UpdateCheckInterval.enforced.rawValue
        let resolvedUpdateInterval = UpdateCheckInterval(rawValue: uci)?.normalizedForAutomaticChecks ?? .enforced
        self.updateCheckInterval = resolvedUpdateInterval
        if uci != resolvedUpdateInterval.rawValue {
            defaults.set(resolvedUpdateInterval.rawValue, forKey: "updateCheckInterval")
        }
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
        // 이전 버전의 교차 계정 OAuth 우선 설정은 계정 귀속을 깨뜨릴 수 있어 폐기한다.
        defaults.removeObject(forKey: "claudePreferOAuth")
        self.alertFiveHourEnabled = defaults.object(forKey: "alertFiveHourEnabled") as? Bool ?? true
        self.alertWeeklyEnabled = defaults.object(forKey: "alertWeeklyEnabled") as? Bool ?? false
        let legacyPinned = Self.normalizedGlobalPopoverPinned(from: defaults)
        let normalizedCompact = Self.normalizedGlobalPopoverCompact(from: defaults)
        self.popoverPinned = legacyPinned
        self.popoverCompact = normalizedCompact
        defaults.set(legacyPinned, forKey: "popoverPinned")
        defaults.set(normalizedCompact, forKey: "popoverCompact")
        // 시스템 상태에서 실제 등록 여부 확인
        let launchAtLoginStatus = SMAppService.mainApp.status
        let isLaunchAtLoginEnabled = launchAtLoginStatus == .enabled
        self.launchAtLogin = isLaunchAtLoginEnabled
        self.launchAtLoginRequiresApproval = launchAtLoginStatus == .requiresApproval
        defaults.set(isLaunchAtLoginEnabled, forKey: "launchAtLogin")
        self.preferredOrganizationID = defaults.string(forKey: "preferredOrganizationID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.showCodexIcon = defaults.object(forKey: "showCodexIcon") as? Bool ?? true
        let cpd = defaults.string(forKey: "codexPercentageDisplay") ?? PercentageDisplay.fiveHour.rawValue
        self.codexPercentageDisplay = PercentageDisplay(rawValue: cpd) ?? .fiveHour
        let crd = defaults.string(forKey: "codexResetTimeDisplay") ?? ResetTimeDisplay.none.rawValue
        self.codexResetTimeDisplay = ResetTimeDisplay(rawValue: crd) ?? .none
        let codexTF = defaults.string(forKey: "codexTimeFormat") ?? resolvedTimeFormat.rawValue
        self.codexTimeFormat = TimeFormatStyle(rawValue: codexTF) ?? resolvedTimeFormat
        let cms = defaults.string(forKey: "codexMenuBarStyle") ?? MenuBarStyle.none.rawValue
        self.codexMenuBarStyle = MenuBarStyle(rawValue: cms) ?? .none
        let ccdm = defaults.string(forKey: "codexCircularDisplayMode") ?? CircularDisplayMode.usage.rawValue
        self.codexCircularDisplayMode = CircularDisplayMode(rawValue: ccdm) ?? .usage
        let codexIconMetricRaw = defaults.string(forKey: "codexIconMetric") ?? IconMetric.fiveHour.rawValue
        self.codexIconMetric = IconMetric(rawValue: codexIconMetricRaw) ?? .fiveHour
        self.codexShowBatteryPercent = defaults.object(forKey: "codexShowBatteryPercent") as? Bool ?? true
        self.codexAlertEnabled = defaults.object(forKey: "codexAlertEnabled") as? Bool ?? false
        let legacySettingsLastTab = defaults.string(forKey: "settingsLastTab") ?? "common"
        self.settingsLastTab = legacySettingsLastTab
    }

    static func normalizedGlobalPopoverPinned(from defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: "popoverPinned") as? Bool)
            ?? (defaults.object(forKey: "claudePopoverPinned") as? Bool)
            ?? (defaults.object(forKey: "codexPopoverPinned") as? Bool)
            ?? (defaults.object(forKey: "\(AppProviderKind.antigravity.rawValue)PopoverPinned") as? Bool)
            ?? false
    }

    static func normalizedGlobalPopoverCompact(from defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: "popoverCompact") as? Bool)
            ?? (defaults.object(forKey: "claudePopoverCompact") as? Bool)
            ?? (defaults.object(forKey: "codexPopoverCompact") as? Bool)
            ?? (defaults.object(forKey: "\(AppProviderKind.antigravity.rawValue)PopoverCompact") as? Bool)
            ?? false
    }
}
