//
//  AppSettings.swift
//  ClaudeUsage
//
//  Phase 3: 앱 설정 모델 (UserDefaults 연동)
//

import Foundation
import Combine

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
        case .fiveHour: return "5시간"
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

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Published Properties

    @Published var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
    }
    @Published var showPercentage: Bool {
        didSet { defaults.set(showPercentage, forKey: "showPercentage") }
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
    @Published var alert1Enabled: Bool {
        didSet { defaults.set(alert1Enabled, forKey: "alert1Enabled") }
    }
    @Published var alert1Threshold: Int {
        didSet { defaults.set(alert1Threshold, forKey: "alert1Threshold") }
    }
    @Published var alert2Enabled: Bool {
        didSet { defaults.set(alert2Enabled, forKey: "alert2Enabled") }
    }
    @Published var alert2Threshold: Int {
        didSet { defaults.set(alert2Threshold, forKey: "alert2Threshold") }
    }
    @Published var alert3Enabled: Bool {
        didSet { defaults.set(alert3Enabled, forKey: "alert3Enabled") }
    }
    @Published var alert3Threshold: Int {
        didSet { defaults.set(alert3Threshold, forKey: "alert3Threshold") }
    }
    @Published var reducedRefreshOnBattery: Bool {
        didSet { defaults.set(reducedRefreshOnBattery, forKey: "reducedRefreshOnBattery") }
    }
    @Published var circularDisplayMode: CircularDisplayMode {
        didSet { defaults.set(circularDisplayMode.rawValue, forKey: "circularDisplayMode") }
    }
    @Published var showDualPercentage: Bool {
        didSet { defaults.set(showDualPercentage, forKey: "showDualPercentage") }
    }
    @Published var showClaudeIcon: Bool {
        didSet { defaults.set(showClaudeIcon, forKey: "showClaudeIcon") }
    }
    @Published var alertFiveHourEnabled: Bool {
        didSet { defaults.set(alertFiveHourEnabled, forKey: "alertFiveHourEnabled") }
    }
    @Published var alertWeeklyEnabled: Bool {
        didSet { defaults.set(alertWeeklyEnabled, forKey: "alertWeeklyEnabled") }
    }

    // MARK: - Snapshot

    struct Snapshot {
        let menuBarStyle: MenuBarStyle
        let showPercentage: Bool
        let showBatteryPercent: Bool
        let resetTimeDisplay: ResetTimeDisplay
        let timeFormat: TimeFormatStyle
        let circularDisplayMode: CircularDisplayMode
        let refreshInterval: TimeInterval
        let autoRefresh: Bool
        let alert1Enabled: Bool
        let alert1Threshold: Int
        let alert2Enabled: Bool
        let alert2Threshold: Int
        let alert3Enabled: Bool
        let alert3Threshold: Int
        let reducedRefreshOnBattery: Bool
        let showDualPercentage: Bool
        let showClaudeIcon: Bool
        let alertFiveHourEnabled: Bool
        let alertWeeklyEnabled: Bool
    }

    func createSnapshot() -> Snapshot {
        Snapshot(
            menuBarStyle: menuBarStyle,
            showPercentage: showPercentage,
            showBatteryPercent: showBatteryPercent,
            resetTimeDisplay: resetTimeDisplay,
            timeFormat: timeFormat,
            circularDisplayMode: circularDisplayMode,
            refreshInterval: refreshInterval,
            autoRefresh: autoRefresh,
            alert1Enabled: alert1Enabled,
            alert1Threshold: alert1Threshold,
            alert2Enabled: alert2Enabled,
            alert2Threshold: alert2Threshold,
            alert3Enabled: alert3Enabled,
            alert3Threshold: alert3Threshold,
            reducedRefreshOnBattery: reducedRefreshOnBattery,
            showDualPercentage: showDualPercentage,
            showClaudeIcon: showClaudeIcon,
            alertFiveHourEnabled: alertFiveHourEnabled,
            alertWeeklyEnabled: alertWeeklyEnabled
        )
    }

    func restore(from snapshot: Snapshot) {
        menuBarStyle = snapshot.menuBarStyle
        showPercentage = snapshot.showPercentage
        showBatteryPercent = snapshot.showBatteryPercent
        resetTimeDisplay = snapshot.resetTimeDisplay
        timeFormat = snapshot.timeFormat
        circularDisplayMode = snapshot.circularDisplayMode
        refreshInterval = snapshot.refreshInterval
        autoRefresh = snapshot.autoRefresh
        alert1Enabled = snapshot.alert1Enabled
        alert1Threshold = snapshot.alert1Threshold
        alert2Enabled = snapshot.alert2Enabled
        alert2Threshold = snapshot.alert2Threshold
        alert3Enabled = snapshot.alert3Enabled
        alert3Threshold = snapshot.alert3Threshold
        reducedRefreshOnBattery = snapshot.reducedRefreshOnBattery
        showDualPercentage = snapshot.showDualPercentage
        showClaudeIcon = snapshot.showClaudeIcon
        alertFiveHourEnabled = snapshot.alertFiveHourEnabled
        alertWeeklyEnabled = snapshot.alertWeeklyEnabled
    }

    // MARK: - Computed

    var enabledAlertThresholds: [Int] {
        var result: [Int] = []
        if alert1Enabled { result.append(alert1Threshold) }
        if alert2Enabled { result.append(alert2Threshold) }
        if alert3Enabled { result.append(alert3Threshold) }
        return result.sorted()
    }

    // MARK: - Actions

    func resetToDefaults() {
        menuBarStyle = .none
        showPercentage = true
        showBatteryPercent = true
        resetTimeDisplay = .none
        timeFormat = .h24
        circularDisplayMode = .usage
        refreshInterval = 5.0
        autoRefresh = true
        alert1Enabled = true
        alert1Threshold = 75
        alert2Enabled = true
        alert2Threshold = 90
        alert3Enabled = true
        alert3Threshold = 95
        reducedRefreshOnBattery = true
        showDualPercentage = false
        showClaudeIcon = true
        alertFiveHourEnabled = true
        alertWeeklyEnabled = false
    }

    // MARK: - Init

    private init() {
        let style = defaults.string(forKey: "menuBarStyle") ?? MenuBarStyle.none.rawValue
        self.menuBarStyle = MenuBarStyle(rawValue: style) ?? .none
        self.showPercentage = defaults.object(forKey: "showPercentage") as? Bool ?? true
        self.showBatteryPercent = defaults.object(forKey: "showBatteryPercent") as? Bool ?? true
        let rtd = defaults.string(forKey: "resetTimeDisplay") ?? ResetTimeDisplay.none.rawValue
        self.resetTimeDisplay = ResetTimeDisplay(rawValue: rtd) ?? .none
        let tf = defaults.string(forKey: "timeFormat") ?? TimeFormatStyle.h24.rawValue
        self.timeFormat = TimeFormatStyle(rawValue: tf) ?? .h24
        self.refreshInterval = defaults.object(forKey: "refreshInterval") as? TimeInterval ?? 5.0
        self.autoRefresh = defaults.object(forKey: "autoRefresh") as? Bool ?? true
        self.alert1Enabled = defaults.object(forKey: "alert1Enabled") as? Bool ?? true
        self.alert1Threshold = defaults.object(forKey: "alert1Threshold") as? Int ?? 75
        self.alert2Enabled = defaults.object(forKey: "alert2Enabled") as? Bool ?? true
        self.alert2Threshold = defaults.object(forKey: "alert2Threshold") as? Int ?? 90
        self.alert3Enabled = defaults.object(forKey: "alert3Enabled") as? Bool ?? true
        self.alert3Threshold = defaults.object(forKey: "alert3Threshold") as? Int ?? 95
        self.reducedRefreshOnBattery = defaults.object(forKey: "reducedRefreshOnBattery") as? Bool ?? true
        let cdm = defaults.string(forKey: "circularDisplayMode") ?? CircularDisplayMode.usage.rawValue
        self.circularDisplayMode = CircularDisplayMode(rawValue: cdm) ?? .usage
        self.showDualPercentage = defaults.object(forKey: "showDualPercentage") as? Bool ?? false
        self.showClaudeIcon = defaults.object(forKey: "showClaudeIcon") as? Bool ?? true
        self.alertFiveHourEnabled = defaults.object(forKey: "alertFiveHourEnabled") as? Bool ?? true
        self.alertWeeklyEnabled = defaults.object(forKey: "alertWeeklyEnabled") as? Bool ?? false
    }
}
