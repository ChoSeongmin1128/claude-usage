//
//  AppSettings.swift
//  ClaudeUsage
//
//  Phase 3: 앱 설정 모델 (UserDefaults 연동)
//

import Foundation
import Combine
import ServiceManagement

enum MenuBarStyle: String, Codable, CaseIterable, Sendable {
    case none = "none"
    case batteryBar = "battery_bar"
    case circular = "circular"
    case concentricRings = "concentric_rings"
    case dualBattery = "dual_battery"
    case sideBySideBattery = "side_by_side_battery"

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

    static let defaultClaudeItems: [PopoverItemConfig] = [
        .init(id: "currentSession", visible: true),
        .init(id: "weeklyLimit", visible: true),
        .init(id: "modelUsage", visible: true),
        .init(id: "overageUsage", visible: true),
    ]

    // 하위 호환용 별칭 (기존 코드 경로 유지)
    static let defaultItems: [PopoverItemConfig] = defaultClaudeItems

    static let defaultCodexItems: [PopoverItemConfig] = [
        .init(id: "codexPrimary", visible: false),
        .init(id: "codexSecondary", visible: false),
        .init(id: "codexCredits", visible: false),
    ]

    static let supportedClaudeIDs: [String] = defaultClaudeItems.map(\.id)
    static let supportedCodexIDs: [String] = defaultCodexItems.map(\.id)

    private static func normalized(
        _ items: [PopoverItemConfig],
        supportedIDs: [String],
        defaults: [PopoverItemConfig]
    ) -> [PopoverItemConfig] {
        let supported = Set(supportedIDs)
        let defaultVisible = Dictionary(uniqueKeysWithValues: defaults.map { ($0.id, $0.visible) })

        var seen = Set<String>()
        var result: [PopoverItemConfig] = []
        result.reserveCapacity(defaults.count)

        for item in items {
            guard supported.contains(item.id), !seen.contains(item.id) else { continue }
            seen.insert(item.id)
            result.append(item)
        }

        for id in supportedIDs where !seen.contains(id) {
            result.append(.init(id: id, visible: defaultVisible[id] ?? true))
        }

        return result.isEmpty ? defaults : result
    }

    static func normalizedClaude(_ items: [PopoverItemConfig]) -> [PopoverItemConfig] {
        normalized(items, supportedIDs: supportedClaudeIDs, defaults: defaultClaudeItems)
    }

    static func normalizedCodex(_ items: [PopoverItemConfig]) -> [PopoverItemConfig] {
        normalized(items, supportedIDs: supportedCodexIDs, defaults: defaultCodexItems)
    }

    // 하위 호환용 별칭 (기존 코드 경로 유지)
    static func normalized(_ items: [PopoverItemConfig]) -> [PopoverItemConfig] {
        normalizedClaude(items)
    }

    var displayName: String {
        switch id {
        case "currentSession": return "현재 세션"
        case "weeklyLimit": return "주간 한도"
        case "modelUsage": return "모델별 주간 한도"
        case "overageUsage": return "추가 사용량"
        case "codexPrimary": return "Codex 현재"
        case "codexSecondary": return "Codex 주간"
        case "codexCredits": return "Codex 크레딧"
        default: return id
        }
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

    private static func normalizedMessagesFallbackThreshold(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }

    private let defaults = UserDefaults.standard
    private var isSyncingProviderState = false

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
    @Published var autoRefresh: Bool {
        didSet { defaults.set(autoRefresh, forKey: "autoRefresh") }
    }
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    @Published var alertThresholds: [Int] {
        didSet { defaults.set(alertThresholds, forKey: "alertThresholds") }
    }
    @Published var alertRemainingMode: Bool {
        didSet { defaults.set(alertRemainingMode, forKey: "alertRemainingMode") }
    }
    @Published var reducedRefreshOnBattery: Bool {
        didSet { defaults.set(reducedRefreshOnBattery, forKey: "reducedRefreshOnBattery") }
    }
    @Published var hasCompletedSetupWizard: Bool {
        didSet { defaults.set(hasCompletedSetupWizard, forKey: "hasCompletedSetupWizard") }
    }
    @Published var circularDisplayMode: CircularDisplayMode {
        didSet { defaults.set(circularDisplayMode.rawValue, forKey: "circularDisplayMode") }
    }
    @Published var iconMetric: IconMetric {
        didSet { defaults.set(iconMetric.rawValue, forKey: "iconMetric") }
    }
    @Published var showClaudeIcon: Bool {
        didSet { defaults.set(showClaudeIcon, forKey: "showClaudeIcon") }
    }
    @Published var claudeEnabled: Bool {
        didSet {
            defaults.set(claudeEnabled, forKey: "claudeEnabled")
            syncProviderStatesFromLegacyFields()
        }
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
        didSet { defaults.set(popoverCompact, forKey: "popoverCompact") }
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
    @Published var popoverItems: [PopoverItemConfig] {
        didSet {
            if let data = try? JSONEncoder().encode(popoverItems) {
                defaults.set(data, forKey: "popoverItems")
            }
        }
    }
    @Published var separateCompactConfig: Bool {
        didSet {
            defaults.set(separateCompactConfig, forKey: "separateCompactConfig")
            if separateCompactConfig {
                // 분리 모드 전환: 기본 설정을 복사하여 시작
                compactPopoverItems = popoverItems
                codexCompactPopoverItems = codexPopoverItems
            }
        }
    }
    @Published var compactPopoverItems: [PopoverItemConfig] {
        didSet {
            if let data = try? JSONEncoder().encode(compactPopoverItems) {
                defaults.set(data, forKey: "compactPopoverItems")
            }
        }
    }
    @Published var codexEnabled: Bool {
        didSet {
            defaults.set(codexEnabled, forKey: "codexEnabled")
            syncProviderStatesFromLegacyFields()
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
            guard !isSyncingProviderState else { return }
            syncLegacyProviderFields(from: providerStates)
        }
    }
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
    @Published var codexAlertThresholds: [Int] {
        didSet { defaults.set(codexAlertThresholds, forKey: "codexAlertThresholds") }
    }
    @Published var codexAlertRemainingMode: Bool {
        didSet { defaults.set(codexAlertRemainingMode, forKey: "codexAlertRemainingMode") }
    }
    @Published var codexPopoverItems: [PopoverItemConfig] {
        didSet {
            if let data = try? JSONEncoder().encode(codexPopoverItems) {
                defaults.set(data, forKey: "codexPopoverItems")
            }
        }
    }
    @Published var codexCompactPopoverItems: [PopoverItemConfig] {
        didSet {
            if let data = try? JSONEncoder().encode(codexCompactPopoverItems) {
                defaults.set(data, forKey: "codexCompactPopoverItems")
            }
        }
    }
    @Published var settingsLastTab: String {
        didSet { defaults.set(settingsLastTab, forKey: "settingsLastTab") }
    }
    @Published var menuBarActiveService: String {
        didSet {
            defaults.set(menuBarActiveService, forKey: "menuBarActiveService")
            syncProviderStatesFromLegacyFields()
        }
    }
    @Published var claudeSettingsLastTab: String {
        didSet { defaults.set(claudeSettingsLastTab, forKey: "claudeSettingsLastTab") }
    }
    @Published var codexSettingsLastTab: String {
        didSet { defaults.set(codexSettingsLastTab, forKey: "codexSettingsLastTab") }
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
        let autoRefresh: Bool
        let notificationsEnabled: Bool
        let alertThresholds: [Int]
        let alertRemainingMode: Bool
        let reducedRefreshOnBattery: Bool
        let hasCompletedSetupWizard: Bool
        let showClaudeIcon: Bool
        let claudeEnabled: Bool
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
        let popoverItems: [PopoverItemConfig]
        let separateCompactConfig: Bool
        let compactPopoverItems: [PopoverItemConfig]
        let codexEnabled: Bool
        let showCodexIcon: Bool
        let codexPercentageDisplay: PercentageDisplay
        let codexResetTimeDisplay: ResetTimeDisplay
        let codexTimeFormat: TimeFormatStyle
        let codexMenuBarStyle: MenuBarStyle
        let codexCircularDisplayMode: CircularDisplayMode
        let codexIconMetric: IconMetric
        let codexShowBatteryPercent: Bool
        let codexAlertEnabled: Bool
        let codexAlertThresholds: [Int]
        let codexAlertRemainingMode: Bool
        let codexPopoverItems: [PopoverItemConfig]
        let codexCompactPopoverItems: [PopoverItemConfig]
        let providerStates: AppProviderStateCatalog
        let settingsLastTab: String
        let menuBarActiveService: String
        let claudeSettingsLastTab: String
        let codexSettingsLastTab: String
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
            autoRefresh: autoRefresh,
            notificationsEnabled: notificationsEnabled,
            alertThresholds: alertThresholds,
            alertRemainingMode: alertRemainingMode,
            reducedRefreshOnBattery: reducedRefreshOnBattery,
            hasCompletedSetupWizard: hasCompletedSetupWizard,
            showClaudeIcon: showClaudeIcon,
            claudeEnabled: claudeEnabled,
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
            popoverItems: popoverItems,
            separateCompactConfig: separateCompactConfig,
            compactPopoverItems: compactPopoverItems,
            codexEnabled: codexEnabled,
            showCodexIcon: showCodexIcon,
            codexPercentageDisplay: codexPercentageDisplay,
            codexResetTimeDisplay: codexResetTimeDisplay,
            codexTimeFormat: codexTimeFormat,
            codexMenuBarStyle: codexMenuBarStyle,
            codexCircularDisplayMode: codexCircularDisplayMode,
            codexIconMetric: codexIconMetric,
            codexShowBatteryPercent: codexShowBatteryPercent,
            codexAlertEnabled: codexAlertEnabled,
            codexAlertThresholds: codexAlertThresholds,
            codexAlertRemainingMode: codexAlertRemainingMode,
            codexPopoverItems: codexPopoverItems,
            codexCompactPopoverItems: codexCompactPopoverItems,
            providerStates: providerStates,
            settingsLastTab: settingsLastTab,
            menuBarActiveService: menuBarActiveService,
            claudeSettingsLastTab: claudeSettingsLastTab,
            codexSettingsLastTab: codexSettingsLastTab
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
        autoRefresh = snapshot.autoRefresh
        notificationsEnabled = snapshot.notificationsEnabled
        alertThresholds = snapshot.alertThresholds
        alertRemainingMode = snapshot.alertRemainingMode
        reducedRefreshOnBattery = snapshot.reducedRefreshOnBattery
        hasCompletedSetupWizard = snapshot.hasCompletedSetupWizard
        showClaudeIcon = snapshot.showClaudeIcon
        claudeEnabled = snapshot.claudeEnabled
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
        popoverItems = PopoverItemConfig.normalizedClaude(snapshot.popoverItems)
        separateCompactConfig = snapshot.separateCompactConfig
        compactPopoverItems = PopoverItemConfig.normalizedClaude(snapshot.compactPopoverItems)
        codexEnabled = snapshot.codexEnabled
        showCodexIcon = snapshot.showCodexIcon
        codexPercentageDisplay = snapshot.codexPercentageDisplay
        codexResetTimeDisplay = snapshot.codexResetTimeDisplay
        codexTimeFormat = snapshot.codexTimeFormat
        codexMenuBarStyle = snapshot.codexMenuBarStyle
        codexCircularDisplayMode = snapshot.codexCircularDisplayMode
        codexIconMetric = snapshot.codexIconMetric
        codexShowBatteryPercent = snapshot.codexShowBatteryPercent
        codexAlertEnabled = snapshot.codexAlertEnabled
        codexAlertThresholds = snapshot.codexAlertThresholds
        codexAlertRemainingMode = snapshot.codexAlertRemainingMode
        codexPopoverItems = PopoverItemConfig.normalizedCodex(snapshot.codexPopoverItems)
        codexCompactPopoverItems = PopoverItemConfig.normalizedCodex(snapshot.codexCompactPopoverItems)
        settingsLastTab = snapshot.settingsLastTab
        menuBarActiveService = snapshot.menuBarActiveService == "codex" ? "codex" : "claude"
        claudeSettingsLastTab = snapshot.claudeSettingsLastTab
        codexSettingsLastTab = snapshot.codexSettingsLastTab
        providerStates = snapshot.providerStates
    }

    private func syncProviderStatesFromLegacyFields() {
        guard !isSyncingProviderState else { return }
        isSyncingProviderState = true
        providerStates = AppProviderStateCatalog.fromLegacy(
            claudeEnabled: claudeEnabled,
            codexEnabled: codexEnabled,
            activeService: menuBarActiveService
        )
        isSyncingProviderState = false
    }

    private func syncLegacyProviderFields(from catalog: AppProviderStateCatalog) {
        guard !isSyncingProviderState else { return }
        isSyncingProviderState = true

        let claudeState = catalog.state(for: .claude)
        if claudeEnabled != claudeState.isEnabled {
            claudeEnabled = claudeState.isEnabled
        }

        let codexState = catalog.state(for: .codex)
        if codexEnabled != codexState.isEnabled {
            codexEnabled = codexState.isEnabled
        }

        let resolvedService = catalog.legacyMenuBarActiveService(fallback: "claude")
        if menuBarActiveService != resolvedService {
            menuBarActiveService = resolvedService
        }

        isSyncingProviderState = false
    }

    // MARK: - Computed

    /// 실제 사용량 기준 임계값 (NotificationManager에서 사용)
    var enabledAlertThresholds: [Int] {
        if alertRemainingMode {
            return alertThresholds.map { 100 - $0 }.sorted()
        }
        return alertThresholds.sorted()
    }

    var enabledCodexAlertThresholds: [Int] {
        if codexAlertRemainingMode {
            return codexAlertThresholds.map { 100 - $0 }.sorted()
        }
        return codexAlertThresholds.sorted()
    }

    /// 간소화 모드에서 사용할 항목 배열
    var effectiveCompactItems: [PopoverItemConfig] {
        separateCompactConfig ? compactPopoverItems : popoverItems
    }

    var effectiveCompactCodexItems: [PopoverItemConfig] {
        separateCompactConfig ? codexCompactPopoverItems : codexPopoverItems
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

    var activeProviderKind: AppProviderKind? {
        providerStates.activeProviderKind
    }

    var activeRuntimeProviderKind: AppProviderKind? {
        providerStates.activeRuntimeProviderKind
    }

    var activeMenuBarServiceRawValue: String {
        providerStates.legacyMenuBarActiveService(fallback: "claude")
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
        Publishers.MergeMany(
            [
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
        var catalog = providerStates
        catalog.setEnabled(enabled, for: kind)
        providerStates = catalog
    }

    func setActiveProvider(_ kind: AppProviderKind?) {
        var catalog = providerStates
        catalog.setActiveProvider(kind)
        providerStates = catalog
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
            return nil
        }
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
        autoRefresh = true
        notificationsEnabled = true
        alertThresholds = [75, 90, 95]
        alertRemainingMode = false
        reducedRefreshOnBattery = true
        hasCompletedSetupWizard = false
        showClaudeIcon = true
        claudeEnabled = true
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
        popoverItems = PopoverItemConfig.defaultClaudeItems
        separateCompactConfig = false
        compactPopoverItems = PopoverItemConfig.defaultClaudeItems
        codexEnabled = false
        showCodexIcon = false
        codexPercentageDisplay = .none
        codexResetTimeDisplay = .none
        codexTimeFormat = .h24
        codexMenuBarStyle = .none
        codexCircularDisplayMode = .usage
        codexIconMetric = .fiveHour
        codexShowBatteryPercent = true
        codexAlertEnabled = false
        codexAlertThresholds = [75, 90, 95]
        codexAlertRemainingMode = false
        codexPopoverItems = PopoverItemConfig.defaultCodexItems
        codexCompactPopoverItems = PopoverItemConfig.defaultCodexItems
        providerStates = AppProviderStateCatalog.defaultCatalog
        settingsLastTab = "common"
        claudeSettingsLastTab = "auth"
        codexSettingsLastTab = "auth"
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
        self.autoRefresh = defaults.object(forKey: "autoRefresh") as? Bool ?? true
        self.notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        // 마이그레이션: alert1/2/3 → alertThresholds 배열
        if let saved = defaults.array(forKey: "alertThresholds") as? [Int] {
            self.alertThresholds = saved
        } else {
            var migrated: [Int] = []
            let e1 = defaults.object(forKey: "alert1Enabled") as? Bool ?? true
            let e2 = defaults.object(forKey: "alert2Enabled") as? Bool ?? true
            let e3 = defaults.object(forKey: "alert3Enabled") as? Bool ?? true
            if e1 { migrated.append(defaults.object(forKey: "alert1Threshold") as? Int ?? 75) }
            if e2 { migrated.append(defaults.object(forKey: "alert2Threshold") as? Int ?? 90) }
            if e3 { migrated.append(defaults.object(forKey: "alert3Threshold") as? Int ?? 95) }
            self.alertThresholds = migrated.isEmpty ? [75, 90, 95] : migrated
        }
        self.alertRemainingMode = defaults.object(forKey: "alertRemainingMode") as? Bool ?? false
        self.reducedRefreshOnBattery = defaults.object(forKey: "reducedRefreshOnBattery") as? Bool ?? true
        self.hasCompletedSetupWizard = defaults.object(forKey: "hasCompletedSetupWizard") as? Bool ?? KeychainManager.shared.hasSessionKey
        let cdm = defaults.string(forKey: "circularDisplayMode") ?? CircularDisplayMode.usage.rawValue
        self.circularDisplayMode = CircularDisplayMode(rawValue: cdm) ?? .usage
        let iconMetricRaw = defaults.string(forKey: "iconMetric") ?? IconMetric.fiveHour.rawValue
        self.iconMetric = IconMetric(rawValue: iconMetricRaw) ?? .fiveHour
        self.showClaudeIcon = defaults.object(forKey: "showClaudeIcon") as? Bool ?? true
        let storedClaudeEnabled = defaults.object(forKey: "claudeEnabled") as? Bool ?? true
        self.claudeEnabled = storedClaudeEnabled
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
        let legacyCompact = defaults.object(forKey: "popoverCompact") as? Bool ?? false
        self.popoverPinned = legacyPinned
        self.popoverCompact = legacyCompact
        self.claudePopoverPinned = defaults.object(forKey: "claudePopoverPinned") as? Bool ?? legacyPinned
        self.codexPopoverPinned = defaults.object(forKey: "codexPopoverPinned") as? Bool ?? legacyPinned
        self.claudePopoverCompact = defaults.object(forKey: "claudePopoverCompact") as? Bool ?? legacyCompact
        self.codexPopoverCompact = defaults.object(forKey: "codexPopoverCompact") as? Bool ?? legacyCompact
        // 시스템 상태에서 실제 등록 여부 확인
        let savedLaunchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? false
        self.launchAtLogin = savedLaunchAtLogin
        self.preferredOrganizationID = defaults.string(forKey: "preferredOrganizationID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedCodexEnabled = defaults.object(forKey: "codexEnabled") as? Bool ?? false
        self.codexEnabled = storedCodexEnabled
        self.showCodexIcon = defaults.object(forKey: "showCodexIcon") as? Bool ?? false
        let cpd = defaults.string(forKey: "codexPercentageDisplay") ?? PercentageDisplay.none.rawValue
        self.codexPercentageDisplay = PercentageDisplay(rawValue: cpd) ?? .none
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
        self.codexAlertThresholds = defaults.array(forKey: "codexAlertThresholds") as? [Int] ?? [75, 90, 95]
        self.codexAlertRemainingMode = defaults.object(forKey: "codexAlertRemainingMode") as? Bool ?? false
        let legacySettingsLastTab = defaults.string(forKey: "settingsLastTab") ?? "common"
        self.settingsLastTab = legacySettingsLastTab
        let storedActiveService = defaults.string(forKey: "menuBarActiveService") ?? "claude"
        let normalizedActiveService = storedActiveService == "codex" ? "codex" : "claude"
        self.menuBarActiveService = normalizedActiveService
        self.claudeSettingsLastTab = defaults.string(forKey: "claudeSettingsLastTab") ?? "auth"
        self.codexSettingsLastTab = defaults.string(forKey: "codexSettingsLastTab") ?? "auth"

        let loadedProviderStates: AppProviderStateCatalog
        if let data = defaults.data(forKey: "providerStates"),
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
        self.claudeEnabled = loadedProviderStates.state(for: .claude).isEnabled
        self.codexEnabled = loadedProviderStates.state(for: .codex).isEnabled
        self.menuBarActiveService = loadedProviderStates.legacyMenuBarActiveService(fallback: "claude")
        if let data = try? JSONEncoder().encode(loadedProviderStates) {
            defaults.set(data, forKey: "providerStates")
        }

        // Claude popover items: JSON 로드 또는 마이그레이션
        let loadedClaudeItems: [PopoverItemConfig]
        if let data = defaults.data(forKey: "popoverItems"),
           let items = try? JSONDecoder().decode([PopoverItemConfig].self, from: data) {
            loadedClaudeItems = items
        } else {
            // 기존 showModelUsage/showOverageUsage에서 마이그레이션
            let showModel = defaults.object(forKey: "showModelUsage") as? Bool ?? true
            let showOverage = defaults.object(forKey: "showOverageUsage") as? Bool ?? true
            loadedClaudeItems = [
                .init(id: "currentSession", visible: true),
                .init(id: "weeklyLimit", visible: true),
                .init(id: "modelUsage", visible: showModel),
                .init(id: "overageUsage", visible: showOverage),
            ]
        }
        let normalizedClaudeItems = PopoverItemConfig.normalizedClaude(loadedClaudeItems)
        self.popoverItems = normalizedClaudeItems
        self.separateCompactConfig = defaults.object(forKey: "separateCompactConfig") as? Bool ?? false
        if let cData = defaults.data(forKey: "compactPopoverItems"),
           let cItems = try? JSONDecoder().decode([PopoverItemConfig].self, from: cData) {
            self.compactPopoverItems = PopoverItemConfig.normalizedClaude(cItems)
        } else {
            self.compactPopoverItems = normalizedClaudeItems
        }

        // Codex popover items: 없으면 기본 숨김 구성 사용
        let normalizedCodexItems: [PopoverItemConfig]
        if let data = defaults.data(forKey: "codexPopoverItems"),
           let items = try? JSONDecoder().decode([PopoverItemConfig].self, from: data) {
            normalizedCodexItems = PopoverItemConfig.normalizedCodex(items)
        } else {
            normalizedCodexItems = PopoverItemConfig.defaultCodexItems
        }
        self.codexPopoverItems = normalizedCodexItems
        if let cData = defaults.data(forKey: "codexCompactPopoverItems"),
           let cItems = try? JSONDecoder().decode([PopoverItemConfig].self, from: cData) {
            self.codexCompactPopoverItems = PopoverItemConfig.normalizedCodex(cItems)
        } else {
            self.codexCompactPopoverItems = normalizedCodexItems
        }

        // 과거/외부 데이터 정리
        if normalizedClaudeItems != loadedClaudeItems,
           let data = try? JSONEncoder().encode(normalizedClaudeItems) {
            defaults.set(data, forKey: "popoverItems")
        }
        if let cData = defaults.data(forKey: "compactPopoverItems"),
           let cItems = try? JSONDecoder().decode([PopoverItemConfig].self, from: cData),
           PopoverItemConfig.normalizedClaude(cItems) != cItems,
           let normalizedData = try? JSONEncoder().encode(PopoverItemConfig.normalizedClaude(cItems)) {
            defaults.set(normalizedData, forKey: "compactPopoverItems")
        }
        if let data = defaults.data(forKey: "codexPopoverItems"),
           let items = try? JSONDecoder().decode([PopoverItemConfig].self, from: data),
           PopoverItemConfig.normalizedCodex(items) != items,
           let normalizedData = try? JSONEncoder().encode(PopoverItemConfig.normalizedCodex(items)) {
            defaults.set(normalizedData, forKey: "codexPopoverItems")
        }
        if let cData = defaults.data(forKey: "codexCompactPopoverItems"),
           let cItems = try? JSONDecoder().decode([PopoverItemConfig].self, from: cData),
           PopoverItemConfig.normalizedCodex(cItems) != cItems,
           let normalizedData = try? JSONEncoder().encode(PopoverItemConfig.normalizedCodex(cItems)) {
            defaults.set(normalizedData, forKey: "codexCompactPopoverItems")
        }
    }
}
