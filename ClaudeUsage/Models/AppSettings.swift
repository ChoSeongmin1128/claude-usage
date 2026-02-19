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

    static let defaultItems: [PopoverItemConfig] = [
        .init(id: "currentSession", visible: true),
        .init(id: "weeklyLimit", visible: true),
        .init(id: "modelUsage", visible: true),
        .init(id: "overageUsage", visible: true),
        .init(id: "codexPrimary", visible: false),
        .init(id: "codexSecondary", visible: false),
        .init(id: "codexCredits", visible: false),
    ]

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

    // MARK: - Codex Properties

    @Published var codexEnabled: Bool {
        didSet {
            defaults.set(codexEnabled, forKey: "codexEnabled")
            // 활성화 시 Codex popover 항목도 자동으로 보이게 설정
            if codexEnabled {
                enableCodexPopoverItems()
            }
        }
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
    @Published var codexAlertEnabled: Bool {
        didSet { defaults.set(codexAlertEnabled, forKey: "codexAlertEnabled") }
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
        let popoverItems: [PopoverItemConfig]
        let separateCompactConfig: Bool
        let compactPopoverItems: [PopoverItemConfig]
        let codexEnabled: Bool
        let showCodexIcon: Bool
        let codexPercentageDisplay: PercentageDisplay
        let codexResetTimeDisplay: ResetTimeDisplay
        let codexAlertEnabled: Bool
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
            popoverItems: popoverItems,
            separateCompactConfig: separateCompactConfig,
            compactPopoverItems: compactPopoverItems,
            codexEnabled: codexEnabled,
            showCodexIcon: showCodexIcon,
            codexPercentageDisplay: codexPercentageDisplay,
            codexResetTimeDisplay: codexResetTimeDisplay,
            codexAlertEnabled: codexAlertEnabled
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
        popoverItems = snapshot.popoverItems
        separateCompactConfig = snapshot.separateCompactConfig
        compactPopoverItems = snapshot.compactPopoverItems
        codexEnabled = snapshot.codexEnabled
        showCodexIcon = snapshot.showCodexIcon
        codexPercentageDisplay = snapshot.codexPercentageDisplay
        codexResetTimeDisplay = snapshot.codexResetTimeDisplay
        codexAlertEnabled = snapshot.codexAlertEnabled
    }

    // MARK: - Computed

    /// 실제 사용량 기준 임계값 (NotificationManager에서 사용)
    var enabledAlertThresholds: [Int] {
        if alertRemainingMode {
            return alertThresholds.map { 100 - $0 }.sorted()
        }
        return alertThresholds.sorted()
    }

    /// 간소화 모드에서 사용할 항목 배열
    var effectiveCompactItems: [PopoverItemConfig] {
        separateCompactConfig ? compactPopoverItems : popoverItems
    }

    // MARK: - Codex Helpers

    /// Codex popover 항목을 visible로 설정 (최초 활성화 시)
    private func enableCodexPopoverItems() {
        let codexIDs: Set<String> = ["codexPrimary", "codexSecondary"]
        // 이미 하나라도 visible이면 사용자가 설정한 것이므로 건드리지 않음
        let alreadyVisible = popoverItems.contains { codexIDs.contains($0.id) && $0.visible }
        guard !alreadyVisible else { return }

        for i in popoverItems.indices {
            if codexIDs.contains(popoverItems[i].id) {
                popoverItems[i].visible = true
            }
        }
        if separateCompactConfig {
            for i in compactPopoverItems.indices {
                if codexIDs.contains(compactPopoverItems[i].id) {
                    compactPopoverItems[i].visible = true
                }
            }
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
        refreshInterval = 5.0
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
        popoverItems = PopoverItemConfig.defaultItems
        separateCompactConfig = false
        compactPopoverItems = PopoverItemConfig.defaultItems
        codexEnabled = false
        showCodexIcon = true
        codexPercentageDisplay = .fiveHour
        codexResetTimeDisplay = .none
        codexAlertEnabled = false
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
        self.refreshInterval = defaults.object(forKey: "refreshInterval") as? TimeInterval ?? 5.0
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
        // popoverItems: JSON 로드 또는 마이그레이션
        let loadedItems: [PopoverItemConfig]
        if let data = defaults.data(forKey: "popoverItems"),
           let items = try? JSONDecoder().decode([PopoverItemConfig].self, from: data) {
            loadedItems = items
        } else {
            // 기존 showModelUsage/showOverageUsage에서 마이그레이션
            let showModel = defaults.object(forKey: "showModelUsage") as? Bool ?? true
            let showOverage = defaults.object(forKey: "showOverageUsage") as? Bool ?? true
            loadedItems = [
                .init(id: "currentSession", visible: true),
                .init(id: "weeklyLimit", visible: true),
                .init(id: "modelUsage", visible: showModel),
                .init(id: "overageUsage", visible: showOverage),
            ]
        }
        // Codex 항목 마이그레이션: 기존 popoverItems에 Codex 항목이 없으면 추가
        var migratedItems = loadedItems
        let existingIDs = Set(migratedItems.map { $0.id })
        for codexID in ["codexPrimary", "codexSecondary", "codexCredits"] {
            if !existingIDs.contains(codexID) {
                migratedItems.append(.init(id: codexID, visible: false))
            }
        }
        self.popoverItems = migratedItems

        self.separateCompactConfig = defaults.object(forKey: "separateCompactConfig") as? Bool ?? false
        if let cData = defaults.data(forKey: "compactPopoverItems"),
           let cItems = try? JSONDecoder().decode([PopoverItemConfig].self, from: cData) {
            var migratedCompact = cItems
            let compactIDs = Set(migratedCompact.map { $0.id })
            for codexID in ["codexPrimary", "codexSecondary", "codexCredits"] {
                if !compactIDs.contains(codexID) {
                    migratedCompact.append(.init(id: codexID, visible: false))
                }
            }
            self.compactPopoverItems = migratedCompact
        } else {
            self.compactPopoverItems = migratedItems
        }

        // Codex 설정 로드
        self.codexEnabled = defaults.object(forKey: "codexEnabled") as? Bool ?? false
        self.showCodexIcon = defaults.object(forKey: "showCodexIcon") as? Bool ?? true
        let cpd = defaults.string(forKey: "codexPercentageDisplay") ?? PercentageDisplay.fiveHour.rawValue
        self.codexPercentageDisplay = PercentageDisplay(rawValue: cpd) ?? .fiveHour
        let crd = defaults.string(forKey: "codexResetTimeDisplay") ?? ResetTimeDisplay.none.rawValue
        self.codexResetTimeDisplay = ResetTimeDisplay(rawValue: crd) ?? .none
        self.codexAlertEnabled = defaults.object(forKey: "codexAlertEnabled") as? Bool ?? false
    }
}
