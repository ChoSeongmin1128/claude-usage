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
    case off = "off"
    case onLaunch = "on_launch"
    case hourly = "hourly"

    var displayName: String {
        switch self {
        case .off: return "끄기"
        case .onLaunch: return "앱 시작 시"
        case .hourly: return "1시간마다"
        }
    }

    var timerInterval: TimeInterval? {
        switch self {
        case .off: return nil
        case .onLaunch: return nil
        case .hourly: return 3600
        }
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
    private static let providerStateMigrationVersionKey = "providerStateMigrationVersion"
    private static let currentProviderStateMigrationVersion = 1

    // MARK: - Popover items 저장 키
    // 구 키는 다운그레이드 보호를 위해 dual-write로 유지합니다.
    // TODO(sunset 3.0.0): 아래 migrateLegacyPopoverItems/persist dual-write 경로를 제거하고
    //   popoverItems, codexPopoverItems, compactPopoverItems, codexCompactPopoverItems
    //   구 키 사용처를 완전히 정리합니다.
    private static let popoverItemsByProviderKey = "popoverItemsV2"
    private static let compactPopoverItemsByProviderKey = "compactPopoverItemsV2"
    private static let popoverItemsMigrationVersionKey = "popoverItemsMigrationVersion"
    private static let currentPopoverItemsMigrationVersion = 2
    // 구 키 (v1, dual-write 대상)
    private static let legacyClaudePopoverKey = "popoverItems"
    private static let legacyClaudeCompactPopoverKey = "compactPopoverItems"
    private static let legacyCodexPopoverKey = "codexPopoverItems"
    private static let legacyCodexCompactPopoverKey = "codexCompactPopoverItems"

    static func defaultPopoverItemsDict() -> [String: [PopoverItemConfig]] {
        var dict: [String: [PopoverItemConfig]] = [:]
        for service in PopoverService.allCases {
            let catalog = UsageItemCatalogRegistry.catalog(for: service)
            dict[service.rawValue] = catalog.defaultItems
        }
        return dict
    }

    /// 저장된 dict를 모든 provider에 대해 정규화.
    static func normalizedPopoverDict(
        _ dict: [String: [PopoverItemConfig]],
        fallback: [String: [PopoverItemConfig]]? = nil
    ) -> [String: [PopoverItemConfig]] {
        var result: [String: [PopoverItemConfig]] = [:]
        for service in PopoverService.allCases {
            let catalog = UsageItemCatalogRegistry.catalog(for: service)
            let raw = dict[service.rawValue]
                ?? fallback?[service.rawValue]
                ?? catalog.defaultItems
            result[service.rawValue] = catalog.normalized(raw)
        }
        return result
    }

    /// V2 dict 키 + 구 V1 배열 키에서 통합 로딩.
    /// - V2가 있으면 V2 우선
    /// - V2가 없고 V1만 있으면 V1 → dict 변환
    /// - 둘 다 없으면 기본값
    static func loadPopoverItemsByProvider(
        from defaults: UserDefaults
    ) -> (full: [String: [PopoverItemConfig]], compact: [String: [PopoverItemConfig]]) {
        let v2Full = decodeDict(defaults.data(forKey: popoverItemsByProviderKey))
        let v2Compact = decodeDict(defaults.data(forKey: compactPopoverItemsByProviderKey))

        // V1 legacy 배열 로드 (Claude/Codex만 존재)
        let legacyClaudeFull = decodeArray(defaults.data(forKey: legacyClaudePopoverKey))
        let legacyClaudeCompact = decodeArray(defaults.data(forKey: legacyClaudeCompactPopoverKey))
        let legacyCodexFull = decodeArray(defaults.data(forKey: legacyCodexPopoverKey))
        let legacyCodexCompact = decodeArray(defaults.data(forKey: legacyCodexCompactPopoverKey))

        // showModelUsage/showOverageUsage 초-legacy 마이그레이션
        let legacyClaudeFullResolved = legacyClaudeFull ?? Self.migrateClaudeLegacyBoolFlags(from: defaults)

        var full: [String: [PopoverItemConfig]] = [:]
        var compact: [String: [PopoverItemConfig]] = [:]

        for service in PopoverService.allCases {
            let catalog = UsageItemCatalogRegistry.catalog(for: service)
            let key = service.rawValue

            // Full
            let fullCandidate: [PopoverItemConfig]?
            if let v2 = v2Full?[key] {
                fullCandidate = v2
            } else {
                switch service {
                case .claude: fullCandidate = legacyClaudeFullResolved
                case .codex: fullCandidate = legacyCodexFull
                case .gemini, .antigravity: fullCandidate = nil
                }
            }
            full[key] = catalog.normalized(fullCandidate ?? catalog.defaultItems)

            // Compact
            let compactCandidate: [PopoverItemConfig]?
            if let v2c = v2Compact?[key] {
                compactCandidate = v2c
            } else {
                switch service {
                case .claude: compactCandidate = legacyClaudeCompact
                case .codex: compactCandidate = legacyCodexCompact
                case .gemini, .antigravity: compactCandidate = nil
                }
            }
            compact[key] = catalog.normalized(compactCandidate ?? full[key]!)
        }

        return (full, compact)
    }

    private static func migrateClaudeLegacyBoolFlags(from defaults: UserDefaults) -> [PopoverItemConfig]? {
        // showModelUsage/showOverageUsage는 v1 이전 (Claude-only) 배열이 저장되기 전의 bool 토글.
        // 해당 키들이 하나라도 존재해야 마이그레이션을 시도합니다. 전부 nil이면 기본값 사용.
        let hasModel = defaults.object(forKey: "showModelUsage") != nil
        let hasOverage = defaults.object(forKey: "showOverageUsage") != nil
        guard hasModel || hasOverage else { return nil }
        let showModel = defaults.object(forKey: "showModelUsage") as? Bool ?? true
        let showOverage = defaults.object(forKey: "showOverageUsage") as? Bool ?? true
        return [
            PopoverItemConfig(id: "currentSession", visible: true),
            PopoverItemConfig(id: "weeklyLimit", visible: true),
            PopoverItemConfig(id: "modelUsage", visible: showModel),
            PopoverItemConfig(id: "overageUsage", visible: showOverage),
        ]
    }

    private static func decodeDict(_ data: Data?) -> [String: [PopoverItemConfig]]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([String: [PopoverItemConfig]].self, from: data)
    }

    private static func decodeArray(_ data: Data?) -> [PopoverItemConfig]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([PopoverItemConfig].self, from: data)
    }

    /// V2 dict 저장 + Claude/Codex 슬롯은 구 키로도 dual-write (다운그레이드 보호).
    static func persistPopoverItemsByProvider(
        _ dict: [String: [PopoverItemConfig]],
        to defaults: UserDefaults
    ) {
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: popoverItemsByProviderKey)
        }
        if let claude = dict[PopoverService.claude.rawValue],
           let data = try? JSONEncoder().encode(claude) {
            defaults.set(data, forKey: legacyClaudePopoverKey)
        }
        if let codex = dict[PopoverService.codex.rawValue],
           let data = try? JSONEncoder().encode(codex) {
            defaults.set(data, forKey: legacyCodexPopoverKey)
        }
    }

    static func persistCompactPopoverItemsByProvider(
        _ dict: [String: [PopoverItemConfig]],
        to defaults: UserDefaults
    ) {
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: compactPopoverItemsByProviderKey)
        }
        if let claude = dict[PopoverService.claude.rawValue],
           let data = try? JSONEncoder().encode(claude) {
            defaults.set(data, forKey: legacyClaudeCompactPopoverKey)
        }
        if let codex = dict[PopoverService.codex.rawValue],
           let data = try? JSONEncoder().encode(codex) {
            defaults.set(data, forKey: legacyCodexCompactPopoverKey)
        }
    }

    private static func normalizedMessagesFallbackThreshold(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }

    private let defaults = UserDefaults.standard
    let loadedProviderStatesFromDisk: Bool

    // MARK: - Published Properties

    @Published var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
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
        didSet { defaults.set(refreshInterval, forKey: "refreshInterval") }
    }
    @Published var usePerProviderRefreshIntervals: Bool {
        didSet { defaults.set(usePerProviderRefreshIntervals, forKey: "usePerProviderRefreshIntervals") }
    }
    @Published var claudeRefreshInterval: TimeInterval {
        didSet { defaults.set(claudeRefreshInterval, forKey: "claudeRefreshInterval") }
    }
    @Published var codexRefreshInterval: TimeInterval {
        didSet { defaults.set(codexRefreshInterval, forKey: "codexRefreshInterval") }
    }
    @Published var geminiRefreshInterval: TimeInterval {
        didSet { defaults.set(geminiRefreshInterval, forKey: "geminiRefreshInterval") }
    }
    @Published var antigravityRefreshInterval: TimeInterval {
        didSet { defaults.set(antigravityRefreshInterval, forKey: "antigravityRefreshInterval") }
    }

    func effectiveRefreshInterval(for service: PopoverService) -> TimeInterval {
        guard usePerProviderRefreshIntervals else { return refreshInterval }
        switch service {
        case .claude: return claudeRefreshInterval
        case .codex: return codexRefreshInterval
        case .gemini: return geminiRefreshInterval
        case .antigravity: return antigravityRefreshInterval
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
        didSet { defaults.set(updateCheckInterval.rawValue, forKey: "updateCheckInterval") }
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
    @Published var claudePopoverPinned: Bool {
        didSet { defaults.set(claudePopoverPinned, forKey: "claudePopoverPinned") }
    }
    @Published var codexPopoverPinned: Bool {
        didSet { defaults.set(codexPopoverPinned, forKey: "codexPopoverPinned") }
    }
    @Published var claudePopoverCompact: Bool {
        didSet { defaults.set(claudePopoverCompact, forKey: "claudePopoverCompact") }
    }
    @Published var codexPopoverCompact: Bool {
        didSet { defaults.set(codexPopoverCompact, forKey: "codexPopoverCompact") }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            updateLaunchAtLogin(launchAtLogin)
        }
    }
    @Published var preferredOrganizationID: String {
        didSet { defaults.set(preferredOrganizationID, forKey: "preferredOrganizationID") }
    }
    /// provider별 팝오버 항목 (키=`PopoverService.rawValue`).
    /// 저장: `popoverItemsV2` (신규 통합 키). 다운그레이드 보호용으로 구 키
    /// (`popoverItems`, `codexPopoverItems`)에도 dual-write.
    @Published var popoverItemsByProvider: [String: [PopoverItemConfig]] {
        didSet {
            Self.persistPopoverItemsByProvider(popoverItemsByProvider, to: defaults)
        }
    }
    @Published var separateCompactConfig: Bool {
        didSet {
            defaults.set(separateCompactConfig, forKey: "separateCompactConfig")
            if separateCompactConfig {
                // 분리 모드 전환: 기본 설정을 복사하여 시작
                compactPopoverItemsByProvider = popoverItemsByProvider
            }
        }
    }
    /// provider별 간소화 팝오버 항목 (키=`PopoverService.rawValue`).
    @Published var compactPopoverItemsByProvider: [String: [PopoverItemConfig]] {
        didSet {
            Self.persistCompactPopoverItemsByProvider(compactPopoverItemsByProvider, to: defaults)
        }
    }
    @Published var showCodexIcon: Bool {
        didSet { defaults.set(showCodexIcon, forKey: "showCodexIcon") }
    }
    @Published var providerStates: AppProviderStateCatalog {
        didSet {
            if let data = try? JSONEncoder().encode(providerStates) {
                defaults.set(data, forKey: "providerStates")
            }
        }
    }
    @Published var menuBarActiveServiceSelectionRawValue: String {
        didSet { defaults.set(menuBarActiveServiceSelectionRawValue, forKey: "menuBarActiveService") }
    }
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

    // MARK: - Snapshot

    struct Snapshot {
        let menuBarStyle: MenuBarStyle
        let percentageDisplay: PercentageDisplay
        let showBatteryPercent: Bool
        let resetTimeDisplay: ResetTimeDisplay
        let timeFormat: TimeFormatStyle
        let circularDisplayMode: CircularDisplayMode
        let iconMetric: IconMetric
        let refreshInterval: TimeInterval
        let usePerProviderRefreshIntervals: Bool
        let claudeRefreshInterval: TimeInterval
        let codexRefreshInterval: TimeInterval
        let geminiRefreshInterval: TimeInterval
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
        let claudePopoverPinned: Bool
        let codexPopoverPinned: Bool
        let claudePopoverCompact: Bool
        let codexPopoverCompact: Bool
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
        let providerPopoverPinnedStates: [AppProviderKind: Bool]
        let providerPopoverCompactStates: [AppProviderKind: Bool]
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
            refreshInterval: refreshInterval,
            usePerProviderRefreshIntervals: usePerProviderRefreshIntervals,
            claudeRefreshInterval: claudeRefreshInterval,
            codexRefreshInterval: codexRefreshInterval,
            geminiRefreshInterval: geminiRefreshInterval,
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
            claudePopoverPinned: claudePopoverPinned,
            codexPopoverPinned: codexPopoverPinned,
            claudePopoverCompact: claudePopoverCompact,
            codexPopoverCompact: codexPopoverCompact,
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
            providerPopoverPinnedStates: Dictionary(
                uniqueKeysWithValues: AppProviderKind.runtimeKinds.map { kind in
                    (kind, isPopoverPinned(for: kind))
                }
            ),
            providerPopoverCompactStates: Dictionary(
                uniqueKeysWithValues: AppProviderKind.runtimeKinds.map { kind in
                    (kind, isPopoverCompact(for: kind))
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
        iconMetric = snapshot.iconMetric
        refreshInterval = snapshot.refreshInterval
        usePerProviderRefreshIntervals = snapshot.usePerProviderRefreshIntervals
        claudeRefreshInterval = snapshot.claudeRefreshInterval
        codexRefreshInterval = snapshot.codexRefreshInterval
        geminiRefreshInterval = snapshot.geminiRefreshInterval
        antigravityRefreshInterval = snapshot.antigravityRefreshInterval
        autoRefresh = snapshot.autoRefresh
        notificationsEnabled = snapshot.notificationsEnabled
        notificationPresets = snapshot.notificationPresets
        alertRemainingMode = snapshot.alertRemainingMode
        reducedRefreshOnBattery = snapshot.reducedRefreshOnBattery
        showClaudeIcon = snapshot.showClaudeIcon
        menuBarTextHighContrast = snapshot.menuBarTextHighContrast
        updateCheckInterval = snapshot.updateCheckInterval
        claudeAlertEnabled = snapshot.claudeAlertEnabled
        claudeMessagesFallbackPolicy = snapshot.claudeMessagesFallbackPolicy
        claudeMessagesFallbackAutoDisableBelowPercent = Self.normalizedMessagesFallbackThreshold(snapshot.claudeMessagesFallbackAutoDisableBelowPercent)
        alertFiveHourEnabled = snapshot.alertFiveHourEnabled
        alertWeeklyEnabled = snapshot.alertWeeklyEnabled
        popoverPinned = snapshot.popoverPinned
        popoverCompact = snapshot.popoverCompact
        claudePopoverPinned = snapshot.claudePopoverPinned
        codexPopoverPinned = snapshot.codexPopoverPinned
        claudePopoverCompact = snapshot.claudePopoverCompact
        codexPopoverCompact = snapshot.codexPopoverCompact
        launchAtLogin = snapshot.launchAtLogin
        preferredOrganizationID = snapshot.preferredOrganizationID
        popoverItemsByProvider = Self.normalizedPopoverDict(snapshot.popoverItemsByProvider)
        separateCompactConfig = snapshot.separateCompactConfig
        compactPopoverItemsByProvider = Self.normalizedPopoverDict(
            snapshot.compactPopoverItemsByProvider,
            fallback: snapshot.popoverItemsByProvider
        )
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
            setMenuBarStyle(config.style, for: kind)
            setProviderPercentageDisplay(config.percentageDisplay, for: kind)
            setProviderShowBatteryPercent(config.showBatteryPercent, for: kind)
            setProviderResetTimeDisplay(config.resetTimeDisplay, for: kind)
            setProviderTimeFormat(config.timeFormat, for: kind)
            setProviderCircularDisplayMode(config.circularDisplayMode, for: kind)
            setProviderIconMetric(config.iconMetric, for: kind)
        }
        for (kind, isPinned) in snapshot.providerPopoverPinnedStates {
            setPopoverPinned(isPinned, for: kind)
        }
        for (kind, isCompact) in snapshot.providerPopoverCompactStates {
            setPopoverCompact(isCompact, for: kind)
        }
        for (kind, isEnabled) in snapshot.providerAlertEnabledStates {
            setProviderAlertEnabled(isEnabled, for: kind)
        }
        settingsLastTab = snapshot.settingsLastTab
    }

    private static func migrateLegacyProviderFieldsIfNeeded(from catalog: AppProviderStateCatalog, defaults: UserDefaults) {
        let storedVersion = defaults.integer(forKey: Self.providerStateMigrationVersionKey)
        guard storedVersion < Self.currentProviderStateMigrationVersion else { return }
        defaults.set(catalog.state(for: .claude).isEnabled, forKey: "claudeEnabled")
        defaults.set(catalog.state(for: .codex).isEnabled, forKey: "codexEnabled")
        defaults.set(catalog.legacyMenuBarActiveService(fallback: "claude"), forKey: "menuBarActiveService")
        defaults.set(Self.currentProviderStateMigrationVersion, forKey: Self.providerStateMigrationVersionKey)
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
        let catalog = UsageItemCatalogRegistry.catalog(for: service)
        return catalog.normalized(popoverItemsByProvider[service.rawValue] ?? catalog.defaultItems)
    }

    /// provider별 간소화 팝오버 항목 (정규화 후).
    func compactPopoverItems(for service: PopoverService) -> [PopoverItemConfig] {
        let catalog = UsageItemCatalogRegistry.catalog(for: service)
        let stored = compactPopoverItemsByProvider[service.rawValue]
            ?? popoverItemsByProvider[service.rawValue]
            ?? catalog.defaultItems
        return catalog.normalized(stored)
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
        let catalog = UsageItemCatalogRegistry.catalog(for: service)
        var dict = popoverItemsByProvider
        dict[service.rawValue] = catalog.normalized(items)
        popoverItemsByProvider = dict
    }

    /// provider의 간소화 항목 배열 업데이트 (정규화 적용).
    func setCompactPopoverItems(_ items: [PopoverItemConfig], for service: PopoverService) {
        let catalog = UsageItemCatalogRegistry.catalog(for: service)
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

    var enabledProviderKinds: [AppProviderKind] {
        providerStates.enabledProviderKinds
    }

    var runtimeEnabledProviderKinds: [AppProviderKind] {
        providerStates.enabledRuntimeProviderKinds
    }

    var shellEnabledProviderKinds: [AppProviderKind] {
        providerStates.enabledShellProviderKinds
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
        providerStates.activeProviderKind
    }

    var activeRuntimeProviderKind: AppProviderKind? {
        providerStates.activeRuntimeProviderKind
    }

    var activeMenuBarServiceRawValue: String {
        let normalized = PopoverService(
            rawValue: menuBarActiveServiceSelectionRawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )?.rawValue
        return normalized ?? providerStates.legacyMenuBarActiveService(fallback: "claude")
    }

    var claudeEnabled: Bool {
        providerStates.state(for: .claude).isEnabled
    }

    var codexEnabled: Bool {
        providerStates.state(for: .codex).isEnabled
    }

    var menuBarActiveService: String {
        activeMenuBarServiceRawValue
    }

    var providerSelectionState: ProviderSelectionState {
        ProviderSelectionState(
            enabledKinds: enabledProviderKinds,
            runtimeEnabledKinds: runtimeEnabledProviderKinds,
            shellEnabledKinds: shellEnabledProviderKinds,
            activeKind: activeProviderKind,
            activeRuntimeKind: activeRuntimeProviderKind
        )
    }

    var menuBarDisplayChangePublisher: AnyPublisher<Void, Never> {
        let basePublishers: [AnyPublisher<Void, Never>] = [
            $menuBarStyle.map { _ in () }.eraseToAnyPublisher(),
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
        providerStates.state(for: kind).isEnabled
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
            applyMinimalVisiblePreset(force: true, for: kind)
            return
        }

        setProviderShowIcon(false, for: kind)
        setProviderPercentageDisplay(.none, for: kind)
        setProviderResetTimeDisplay(.none, for: kind)
        setMenuBarStyle(.none, for: kind)
    }

    func setActiveProvider(_ kind: AppProviderKind?) {
        var catalog = providerStates
        catalog.setActiveProvider(kind)
        providerStates = catalog
    }

    func setActiveMenuBarService(_ service: PopoverService?) {
        let fallback = providerStates.legacyMenuBarActiveService(fallback: "claude")
        let rawValue = service?.rawValue ?? fallback
        let normalized = PopoverService(rawValue: rawValue)?.rawValue ?? fallback
        if menuBarActiveServiceSelectionRawValue != normalized {
            menuBarActiveServiceSelectionRawValue = normalized
        }
    }

    func isPopoverPinned(for kind: AppProviderKind) -> Bool {
        switch kind {
        case .claude:
            return claudePopoverPinned
        case .codex:
            return codexPopoverPinned
        case .gemini, .antigravity:
            return defaults.object(forKey: "\(kind.rawValue)PopoverPinned") as? Bool ?? popoverPinned
        }
    }

    func setPopoverPinned(_ isPinned: Bool, for kind: AppProviderKind) {
        switch kind {
        case .claude:
            claudePopoverPinned = isPinned
        case .codex:
            codexPopoverPinned = isPinned
        case .gemini, .antigravity:
            objectWillChange.send()
            defaults.set(isPinned, forKey: "\(kind.rawValue)PopoverPinned")
        }
    }

    func isPopoverCompact(for kind: AppProviderKind) -> Bool {
        switch kind {
        case .claude:
            return claudePopoverCompact
        case .codex:
            return codexPopoverCompact
        case .gemini, .antigravity:
            return defaults.object(forKey: "\(kind.rawValue)PopoverCompact") as? Bool ?? popoverCompact
        }
    }

    func setPopoverCompact(_ isCompact: Bool, for kind: AppProviderKind) {
        switch kind {
        case .claude:
            if claudePopoverCompact != isCompact {
                claudePopoverCompact = isCompact
            }
        case .codex:
            if codexPopoverCompact != isCompact {
                codexPopoverCompact = isCompact
            }
        case .gemini, .antigravity:
            objectWillChange.send()
            defaults.set(isCompact, forKey: "\(kind.rawValue)PopoverCompact")
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
                iconMetric: iconMetric
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
                iconMetric: codexIconMetric
            )
        case .gemini, .antigravity:
            return ProviderMenuBarDisplayConfig(
                kind: kind,
                showIcon: providerBoolDefault(true, for: kind, suffix: "showIcon"),
                style: providerMenuBarStyle(for: kind),
                percentageDisplay: providerPercentageDisplay(for: kind),
                showBatteryPercent: providerBoolDefault(true, for: kind, suffix: "showBatteryPercent"),
                resetTimeDisplay: providerResetTimeDisplay(for: kind),
                timeFormat: providerTimeFormat(for: kind),
                circularDisplayMode: providerCircularDisplayMode(for: kind),
                iconMetric: providerIconMetric(for: kind)
            )
        }
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
        case .gemini, .antigravity:
            objectWillChange.send()
            defaults.set(enabled, forKey: providerDefaultsKey(kind, suffix: "showIcon"))
            bumpRuntimeProviderDisplayRevision()
        }
    }

    func isProviderAlertEnabled(_ kind: AppProviderKind) -> Bool {
        switch kind {
        case .claude:
            return claudeAlertEnabled
        case .codex:
            return codexAlertEnabled
        case .gemini, .antigravity:
            return providerBoolDefault(false, for: kind, suffix: "alertEnabled")
        }
    }

    func setProviderAlertEnabled(_ enabled: Bool, for kind: AppProviderKind) {
        switch kind {
        case .claude:
            claudeAlertEnabled = enabled
        case .codex:
            codexAlertEnabled = enabled
        case .gemini, .antigravity:
            objectWillChange.send()
            defaults.set(enabled, forKey: providerDefaultsKey(kind, suffix: "alertEnabled"))
        }
    }

    func setMenuBarStyle(_ style: MenuBarStyle, for kind: AppProviderKind) {
        switch kind {
        case .claude:
            menuBarStyle = style
        case .codex:
            codexMenuBarStyle = style
        case .gemini, .antigravity:
            objectWillChange.send()
            defaults.set(style.rawValue, forKey: providerDefaultsKey(kind, suffix: "menuBarStyle"))
            bumpRuntimeProviderDisplayRevision()
        }

        // 배터리 스타일로 변경 시 circularDisplayMode를 .remaining으로 자동 설정
        if style.isBatteryStyle {
            setProviderCircularDisplayMode(.remaining, for: kind)
        }
    }

    func setProviderPercentageDisplay(_ display: PercentageDisplay, for kind: AppProviderKind) {
        switch kind {
        case .claude:
            percentageDisplay = display
        case .codex:
            codexPercentageDisplay = display
        case .gemini, .antigravity:
            objectWillChange.send()
            defaults.set(display.rawValue, forKey: providerDefaultsKey(kind, suffix: "percentageDisplay"))
            bumpRuntimeProviderDisplayRevision()
        }
    }

    func setProviderResetTimeDisplay(_ display: ResetTimeDisplay, for kind: AppProviderKind) {
        switch kind {
        case .claude:
            resetTimeDisplay = display
        case .codex:
            codexResetTimeDisplay = display
        case .gemini, .antigravity:
            objectWillChange.send()
            defaults.set(display.rawValue, forKey: providerDefaultsKey(kind, suffix: "resetTimeDisplay"))
            bumpRuntimeProviderDisplayRevision()
        }
    }

    func setProviderTimeFormat(_ format: TimeFormatStyle, for kind: AppProviderKind) {
        switch kind {
        case .claude:
            timeFormat = format
        case .codex:
            codexTimeFormat = format
        case .gemini, .antigravity:
            objectWillChange.send()
            defaults.set(format.rawValue, forKey: providerDefaultsKey(kind, suffix: "timeFormat"))
            bumpRuntimeProviderDisplayRevision()
        }
    }

    func setProviderShowBatteryPercent(_ enabled: Bool, for kind: AppProviderKind) {
        switch kind {
        case .claude:
            showBatteryPercent = enabled
        case .codex:
            codexShowBatteryPercent = enabled
        case .gemini, .antigravity:
            objectWillChange.send()
            defaults.set(enabled, forKey: providerDefaultsKey(kind, suffix: "showBatteryPercent"))
            bumpRuntimeProviderDisplayRevision()
        }
    }

    func setProviderCircularDisplayMode(_ mode: CircularDisplayMode, for kind: AppProviderKind) {
        switch kind {
        case .claude:
            circularDisplayMode = mode
        case .codex:
            codexCircularDisplayMode = mode
        case .gemini, .antigravity:
            objectWillChange.send()
            defaults.set(mode.rawValue, forKey: providerDefaultsKey(kind, suffix: "circularDisplayMode"))
            bumpRuntimeProviderDisplayRevision()
        }
    }

    func setProviderIconMetric(_ metric: IconMetric, for kind: AppProviderKind) {
        switch kind {
        case .claude:
            iconMetric = metric
        case .codex:
            codexIconMetric = metric
        case .gemini, .antigravity:
            objectWillChange.send()
            defaults.set(metric.rawValue, forKey: providerDefaultsKey(kind, suffix: "iconMetric"))
            bumpRuntimeProviderDisplayRevision()
        }
    }

    private func providerDefaultsKey(_ kind: AppProviderKind, suffix: String) -> String {
        "\(kind.rawValue).\(suffix)"
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
        case .gemini, .antigravity:
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
        setProviderShowIcon(true, for: kind)
        setProviderPercentageDisplay(.fiveHour, for: kind)
        setProviderResetTimeDisplay(.none, for: kind)
        setMenuBarStyle(.none, for: kind)
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
        geminiRefreshInterval = 60.0
        antigravityRefreshInterval = 120.0
        defaults.removeObject(forKey: "usePerProviderRefreshIntervals")
        defaults.removeObject(forKey: "claudeRefreshInterval")
        defaults.removeObject(forKey: "codexRefreshInterval")
        defaults.removeObject(forKey: "geminiRefreshInterval")
        defaults.removeObject(forKey: "antigravityRefreshInterval")
        autoRefresh = true
        notificationsEnabled = true
        notificationPresets = Self.defaultNotificationPresets
        alertRemainingMode = false
        reducedRefreshOnBattery = true
        defaults.removeObject(forKey: "hasCompletedSetupWizard")
        showClaudeIcon = true
        menuBarTextHighContrast = false
        updateCheckInterval = .hourly
        claudeAlertEnabled = true
        claudeMessagesFallbackPolicy = .off
        claudeMessagesFallbackAutoDisableBelowPercent = Self.normalizedMessagesFallbackThreshold(20)
        alertFiveHourEnabled = true
        alertWeeklyEnabled = false
        popoverPinned = false
        popoverCompact = false
        claudePopoverPinned = false
        codexPopoverPinned = false
        claudePopoverCompact = false
        codexPopoverCompact = false
        launchAtLogin = false
        preferredOrganizationID = ""
        popoverItemsByProvider = Self.defaultPopoverItemsDict()
        separateCompactConfig = false
        compactPopoverItemsByProvider = Self.defaultPopoverItemsDict()
        showCodexIcon = true
        codexPercentageDisplay = .fiveHour
        codexResetTimeDisplay = .none
        codexTimeFormat = .h24
        codexMenuBarStyle = .none
        codexCircularDisplayMode = .usage
        codexIconMetric = .fiveHour
        codexShowBatteryPercent = true
        codexAlertEnabled = false
        clearRuntimeProviderDefaults(for: .gemini)
        clearRuntimeProviderDefaults(for: .antigravity)
        providerStates = AppProviderStateCatalog.defaultCatalog
        settingsLastTab = "common"
    }

    private func clearRuntimeProviderDefaults(for kind: AppProviderKind) {
        guard kind == .gemini || kind == .antigravity else { return }

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
        bumpRuntimeProviderDisplayRevision()
    }

    // MARK: - Launch at Login

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Logger.error("로그인 시 자동 시작 설정 실패: \(error)")
        }
    }

    // MARK: - Init

    private init() {
        let style = defaults.string(forKey: "menuBarStyle") ?? MenuBarStyle.none.rawValue
        self.menuBarStyle = MenuBarStyle(rawValue: style) ?? .none

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
        self.refreshInterval = defaults.object(forKey: "refreshInterval") as? TimeInterval ?? 30.0
        self.usePerProviderRefreshIntervals = defaults.object(forKey: "usePerProviderRefreshIntervals") as? Bool ?? false
        self.claudeRefreshInterval = defaults.object(forKey: "claudeRefreshInterval") as? TimeInterval ?? 30.0
        self.codexRefreshInterval = defaults.object(forKey: "codexRefreshInterval") as? TimeInterval ?? 60.0
        self.geminiRefreshInterval = defaults.object(forKey: "geminiRefreshInterval") as? TimeInterval ?? 60.0
        self.antigravityRefreshInterval = defaults.object(forKey: "antigravityRefreshInterval") as? TimeInterval ?? 120.0
        self.autoRefresh = defaults.object(forKey: "autoRefresh") as? Bool ?? true
        self.notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        let storedAlertRemainingMode = defaults.object(forKey: "alertRemainingMode") as? Bool ?? false
        self.alertRemainingMode = storedAlertRemainingMode
        self.notificationPresets = Self.migrateNotificationPresets(from: defaults, commonRemainingMode: storedAlertRemainingMode)
        self.reducedRefreshOnBattery = defaults.object(forKey: "reducedRefreshOnBattery") as? Bool ?? true
        let cdm = defaults.string(forKey: "circularDisplayMode") ?? CircularDisplayMode.usage.rawValue
        self.circularDisplayMode = CircularDisplayMode(rawValue: cdm) ?? .usage
        let iconMetricRaw = defaults.string(forKey: "iconMetric") ?? IconMetric.fiveHour.rawValue
        self.iconMetric = IconMetric(rawValue: iconMetricRaw) ?? .fiveHour
        self.showClaudeIcon = defaults.object(forKey: "showClaudeIcon") as? Bool ?? true
        let storedClaudeEnabled = defaults.object(forKey: "claudeEnabled") as? Bool ?? true
        self.menuBarTextHighContrast = defaults.object(forKey: "menuBarTextHighContrast") as? Bool ?? false
        let uci = defaults.string(forKey: "updateCheckInterval") ?? UpdateCheckInterval.hourly.rawValue
        self.updateCheckInterval = UpdateCheckInterval(rawValue: uci) ?? .hourly
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
        let legacyPinned = defaults.object(forKey: "popoverPinned") as? Bool ?? false
        let normalizedCompact = (defaults.object(forKey: "popoverCompact") as? Bool)
            ?? (defaults.object(forKey: "claudePopoverCompact") as? Bool)
            ?? (defaults.object(forKey: "codexPopoverCompact") as? Bool)
            ?? (defaults.object(forKey: "\(AppProviderKind.gemini.rawValue)PopoverCompact") as? Bool)
            ?? (defaults.object(forKey: "\(AppProviderKind.antigravity.rawValue)PopoverCompact") as? Bool)
            ?? false
        self.popoverPinned = legacyPinned
        self.popoverCompact = normalizedCompact
        self.claudePopoverPinned = defaults.object(forKey: "claudePopoverPinned") as? Bool ?? legacyPinned
        self.codexPopoverPinned = defaults.object(forKey: "codexPopoverPinned") as? Bool ?? legacyPinned
        self.claudePopoverCompact = defaults.object(forKey: "claudePopoverCompact") as? Bool ?? normalizedCompact
        self.codexPopoverCompact = defaults.object(forKey: "codexPopoverCompact") as? Bool ?? normalizedCompact
        // 시스템 상태에서 실제 등록 여부 확인
        let savedLaunchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? false
        self.launchAtLogin = savedLaunchAtLogin
        self.preferredOrganizationID = defaults.string(forKey: "preferredOrganizationID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedCodexEnabled = defaults.object(forKey: "codexEnabled") as? Bool ?? false
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
        let storedActiveService = defaults.string(forKey: "menuBarActiveService") ?? "claude"
        let normalizedActiveService = PopoverService(
            rawValue: storedActiveService.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )?.rawValue ?? "claude"

        let persistedProviderStatesData = defaults.data(forKey: "providerStates")
        self.loadedProviderStatesFromDisk = persistedProviderStatesData != nil
        let loadedProviderStates: AppProviderStateCatalog
        if let data = persistedProviderStatesData,
           let catalog = try? JSONDecoder().decode(AppProviderStateCatalog.self, from: data) {
            loadedProviderStates = catalog
        } else {
            loadedProviderStates = AppProviderStateCatalog.fromLegacy(
                claudeEnabled: storedClaudeEnabled,
                codexEnabled: storedCodexEnabled,
                activeService: normalizedActiveService
            )
        }
        self.providerStates = loadedProviderStates
        self.menuBarActiveServiceSelectionRawValue = normalizedActiveService
        Self.migrateLegacyProviderFieldsIfNeeded(from: loadedProviderStates, defaults: defaults)
        if let data = try? JSONEncoder().encode(loadedProviderStates) {
            defaults.set(data, forKey: "providerStates")
        }

        // Popover items: V2(dict) 우선, 없으면 V1(provider별 배열) 마이그레이션.
        // 하위버전 다운그레이드 보호를 위해 구 키는 삭제하지 않고 dual-write로 동기화.
        self.separateCompactConfig = defaults.object(forKey: "separateCompactConfig") as? Bool ?? false
        let (loadedFullDict, loadedCompactDict) = Self.loadPopoverItemsByProvider(from: defaults)
        self.popoverItemsByProvider = loadedFullDict
        self.compactPopoverItemsByProvider = loadedCompactDict
        // 마이그레이션 버전 스탬프: 2 = dict 기반 V2로 최소 1회 이주 완료.
        if defaults.integer(forKey: Self.popoverItemsMigrationVersionKey) < Self.currentPopoverItemsMigrationVersion {
            Self.persistPopoverItemsByProvider(loadedFullDict, to: defaults)
            Self.persistCompactPopoverItemsByProvider(loadedCompactDict, to: defaults)
            defaults.set(Self.currentPopoverItemsMigrationVersion, forKey: Self.popoverItemsMigrationVersionKey)
        }

        for kind in AppProviderKind.runtimeKinds where kind == .gemini || kind == .antigravity {
            let key = "\(kind.rawValue)PopoverCompact"
            if defaults.object(forKey: key) == nil {
                defaults.set(normalizedCompact, forKey: key)
            }
        }
    }
}
