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

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

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
    @Published var alertThresholds: [Int] {
        didSet { defaults.set(alertThresholds, forKey: "alertThresholds") }
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
    @Published var showClaudeIcon: Bool {
        didSet { defaults.set(showClaudeIcon, forKey: "showClaudeIcon") }
    }
    @Published var menuBarTextHighContrast: Bool {
        didSet { defaults.set(menuBarTextHighContrast, forKey: "menuBarTextHighContrast") }
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
        didSet { defaults.set(codexEnabled, forKey: "codexEnabled") }
    }
    @Published var showCodexIcon: Bool {
        didSet { defaults.set(showCodexIcon, forKey: "showCodexIcon") }
    }
    @Published var codexPercentageDisplay: PercentageDisplay {
        didSet { defaults.set(codexPercentageDisplay.rawValue, forKey: "codexPercentageDisplay") }
    }
    @Published var codexResetTimeDisplay: ResetTimeDisplay {
        didSet { defaults.set(codexResetTimeDisplay.rawValue, forKey: "codexResetTimeDisplay") }
    }
    @Published var codexMenuBarStyle: MenuBarStyle {
        didSet { defaults.set(codexMenuBarStyle.rawValue, forKey: "codexMenuBarStyle") }
    }
    @Published var codexCircularDisplayMode: CircularDisplayMode {
        didSet { defaults.set(codexCircularDisplayMode.rawValue, forKey: "codexCircularDisplayMode") }
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

    // MARK: - Snapshot

    struct Snapshot {
        let menuBarStyle: MenuBarStyle
        let percentageDisplay: PercentageDisplay
        let showBatteryPercent: Bool
        let resetTimeDisplay: ResetTimeDisplay
        let timeFormat: TimeFormatStyle
        let circularDisplayMode: CircularDisplayMode
        let refreshInterval: TimeInterval
        let autoRefresh: Bool
        let alertThresholds: [Int]
        let alertRemainingMode: Bool
        let reducedRefreshOnBattery: Bool
        let showClaudeIcon: Bool
        let menuBarTextHighContrast: Bool
        let updateCheckInterval: UpdateCheckInterval
        let alertFiveHourEnabled: Bool
        let alertWeeklyEnabled: Bool
        let popoverPinned: Bool
        let popoverCompact: Bool
        let launchAtLogin: Bool
        let preferredOrganizationID: String
        let popoverItems: [PopoverItemConfig]
        let separateCompactConfig: Bool
        let compactPopoverItems: [PopoverItemConfig]
        let codexEnabled: Bool
        let showCodexIcon: Bool
        let codexPercentageDisplay: PercentageDisplay
        let codexResetTimeDisplay: ResetTimeDisplay
        let codexMenuBarStyle: MenuBarStyle
        let codexCircularDisplayMode: CircularDisplayMode
        let codexShowBatteryPercent: Bool
        let codexAlertEnabled: Bool
        let codexAlertThresholds: [Int]
        let codexAlertRemainingMode: Bool
        let codexPopoverItems: [PopoverItemConfig]
        let codexCompactPopoverItems: [PopoverItemConfig]
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
            refreshInterval: refreshInterval,
            autoRefresh: autoRefresh,
            alertThresholds: alertThresholds,
            alertRemainingMode: alertRemainingMode,
            reducedRefreshOnBattery: reducedRefreshOnBattery,
            showClaudeIcon: showClaudeIcon,
            menuBarTextHighContrast: menuBarTextHighContrast,
            updateCheckInterval: updateCheckInterval,
            alertFiveHourEnabled: alertFiveHourEnabled,
            alertWeeklyEnabled: alertWeeklyEnabled,
            popoverPinned: popoverPinned,
            popoverCompact: popoverCompact,
            launchAtLogin: launchAtLogin,
            preferredOrganizationID: preferredOrganizationID,
            popoverItems: popoverItems,
            separateCompactConfig: separateCompactConfig,
            compactPopoverItems: compactPopoverItems,
            codexEnabled: codexEnabled,
            showCodexIcon: showCodexIcon,
            codexPercentageDisplay: codexPercentageDisplay,
            codexResetTimeDisplay: codexResetTimeDisplay,
            codexMenuBarStyle: codexMenuBarStyle,
            codexCircularDisplayMode: codexCircularDisplayMode,
            codexShowBatteryPercent: codexShowBatteryPercent,
            codexAlertEnabled: codexAlertEnabled,
            codexAlertThresholds: codexAlertThresholds,
            codexAlertRemainingMode: codexAlertRemainingMode,
            codexPopoverItems: codexPopoverItems,
            codexCompactPopoverItems: codexCompactPopoverItems,
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
        refreshInterval = snapshot.refreshInterval
        autoRefresh = snapshot.autoRefresh
        alertThresholds = snapshot.alertThresholds
        alertRemainingMode = snapshot.alertRemainingMode
        reducedRefreshOnBattery = snapshot.reducedRefreshOnBattery
        showClaudeIcon = snapshot.showClaudeIcon
        menuBarTextHighContrast = snapshot.menuBarTextHighContrast
        updateCheckInterval = snapshot.updateCheckInterval
        alertFiveHourEnabled = snapshot.alertFiveHourEnabled
        alertWeeklyEnabled = snapshot.alertWeeklyEnabled
        popoverPinned = snapshot.popoverPinned
        popoverCompact = snapshot.popoverCompact
        launchAtLogin = snapshot.launchAtLogin
        preferredOrganizationID = snapshot.preferredOrganizationID
        popoverItems = PopoverItemConfig.normalizedClaude(snapshot.popoverItems)
        separateCompactConfig = snapshot.separateCompactConfig
        compactPopoverItems = PopoverItemConfig.normalizedClaude(snapshot.compactPopoverItems)
        codexEnabled = snapshot.codexEnabled
        showCodexIcon = snapshot.showCodexIcon
        codexPercentageDisplay = snapshot.codexPercentageDisplay
        codexResetTimeDisplay = snapshot.codexResetTimeDisplay
        codexMenuBarStyle = snapshot.codexMenuBarStyle
        codexCircularDisplayMode = snapshot.codexCircularDisplayMode
        codexShowBatteryPercent = snapshot.codexShowBatteryPercent
        codexAlertEnabled = snapshot.codexAlertEnabled
        codexAlertThresholds = snapshot.codexAlertThresholds
        codexAlertRemainingMode = snapshot.codexAlertRemainingMode
        codexPopoverItems = PopoverItemConfig.normalizedCodex(snapshot.codexPopoverItems)
        codexCompactPopoverItems = PopoverItemConfig.normalizedCodex(snapshot.codexCompactPopoverItems)
        settingsLastTab = snapshot.settingsLastTab
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

    // MARK: - Actions

    func resetToDefaults() {
        menuBarStyle = .none
        percentageDisplay = .fiveHour
        showBatteryPercent = true
        resetTimeDisplay = .none
        timeFormat = .h24
        circularDisplayMode = .usage
        refreshInterval = 30.0
        autoRefresh = true
        alertThresholds = [75, 90, 95]
        alertRemainingMode = false
        reducedRefreshOnBattery = true
        showClaudeIcon = true
        menuBarTextHighContrast = false
        updateCheckInterval = .hourly
        alertFiveHourEnabled = true
        alertWeeklyEnabled = false
        popoverPinned = false
        popoverCompact = false
        launchAtLogin = false
        preferredOrganizationID = ""
        popoverItems = PopoverItemConfig.defaultClaudeItems
        separateCompactConfig = false
        compactPopoverItems = PopoverItemConfig.defaultClaudeItems
        codexEnabled = false
        showCodexIcon = false
        codexPercentageDisplay = .none
        codexResetTimeDisplay = .none
        codexMenuBarStyle = .none
        codexCircularDisplayMode = .usage
        codexShowBatteryPercent = true
        codexAlertEnabled = false
        codexAlertThresholds = [75, 90, 95]
        codexAlertRemainingMode = false
        codexPopoverItems = PopoverItemConfig.defaultCodexItems
        codexCompactPopoverItems = PopoverItemConfig.defaultCodexItems
        settingsLastTab = "common"
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
        self.timeFormat = TimeFormatStyle(rawValue: tf) ?? .h24
        self.refreshInterval = defaults.object(forKey: "refreshInterval") as? TimeInterval ?? 30.0
        self.autoRefresh = defaults.object(forKey: "autoRefresh") as? Bool ?? true
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
        let cdm = defaults.string(forKey: "circularDisplayMode") ?? CircularDisplayMode.usage.rawValue
        self.circularDisplayMode = CircularDisplayMode(rawValue: cdm) ?? .usage
        self.showClaudeIcon = defaults.object(forKey: "showClaudeIcon") as? Bool ?? true
        self.menuBarTextHighContrast = defaults.object(forKey: "menuBarTextHighContrast") as? Bool ?? false
        let uci = defaults.string(forKey: "updateCheckInterval") ?? UpdateCheckInterval.hourly.rawValue
        self.updateCheckInterval = UpdateCheckInterval(rawValue: uci) ?? .hourly
        self.alertFiveHourEnabled = defaults.object(forKey: "alertFiveHourEnabled") as? Bool ?? true
        self.alertWeeklyEnabled = defaults.object(forKey: "alertWeeklyEnabled") as? Bool ?? false
        self.popoverPinned = defaults.object(forKey: "popoverPinned") as? Bool ?? false
        self.popoverCompact = defaults.object(forKey: "popoverCompact") as? Bool ?? false
        // 시스템 상태에서 실제 등록 여부 확인
        let savedLaunchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? false
        self.launchAtLogin = savedLaunchAtLogin
        self.preferredOrganizationID = defaults.string(forKey: "preferredOrganizationID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.codexEnabled = defaults.object(forKey: "codexEnabled") as? Bool ?? false
        self.showCodexIcon = defaults.object(forKey: "showCodexIcon") as? Bool ?? false
        let cpd = defaults.string(forKey: "codexPercentageDisplay") ?? PercentageDisplay.none.rawValue
        self.codexPercentageDisplay = PercentageDisplay(rawValue: cpd) ?? .none
        let crd = defaults.string(forKey: "codexResetTimeDisplay") ?? ResetTimeDisplay.none.rawValue
        self.codexResetTimeDisplay = ResetTimeDisplay(rawValue: crd) ?? .none
        let cms = defaults.string(forKey: "codexMenuBarStyle") ?? MenuBarStyle.none.rawValue
        self.codexMenuBarStyle = MenuBarStyle(rawValue: cms) ?? .none
        let ccdm = defaults.string(forKey: "codexCircularDisplayMode") ?? CircularDisplayMode.usage.rawValue
        self.codexCircularDisplayMode = CircularDisplayMode(rawValue: ccdm) ?? .usage
        self.codexShowBatteryPercent = defaults.object(forKey: "codexShowBatteryPercent") as? Bool ?? true
        self.codexAlertEnabled = defaults.object(forKey: "codexAlertEnabled") as? Bool ?? false
        self.codexAlertThresholds = defaults.array(forKey: "codexAlertThresholds") as? [Int] ?? [75, 90, 95]
        self.codexAlertRemainingMode = defaults.object(forKey: "codexAlertRemainingMode") as? Bool ?? false
        self.settingsLastTab = defaults.string(forKey: "settingsLastTab") ?? "common"

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
