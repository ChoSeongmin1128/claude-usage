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

    var displayName: String {
        switch self {
        case .none: return "없음"
        case .batteryBar: return "배터리바"
        case .circular: return "원형"
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
    @Published var showResetTime: Bool {
        didSet { defaults.set(showResetTime, forKey: "showResetTime") }
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
    @Published var alertAt75: Bool {
        didSet { defaults.set(alertAt75, forKey: "alertAt75") }
    }
    @Published var alertAt90: Bool {
        didSet { defaults.set(alertAt90, forKey: "alertAt90") }
    }
    @Published var alertAt95: Bool {
        didSet { defaults.set(alertAt95, forKey: "alertAt95") }
    }
    @Published var reducedRefreshOnBattery: Bool {
        didSet { defaults.set(reducedRefreshOnBattery, forKey: "reducedRefreshOnBattery") }
    }

    // MARK: - Init

    private init() {
        let style = defaults.string(forKey: "menuBarStyle") ?? MenuBarStyle.none.rawValue
        self.menuBarStyle = MenuBarStyle(rawValue: style) ?? .none
        self.showPercentage = defaults.object(forKey: "showPercentage") as? Bool ?? true
        self.showBatteryPercent = defaults.object(forKey: "showBatteryPercent") as? Bool ?? true
        self.showResetTime = defaults.object(forKey: "showResetTime") as? Bool ?? false
        let tf = defaults.string(forKey: "timeFormat") ?? TimeFormatStyle.h24.rawValue
        self.timeFormat = TimeFormatStyle(rawValue: tf) ?? .h24
        self.refreshInterval = defaults.object(forKey: "refreshInterval") as? TimeInterval ?? 5.0
        self.autoRefresh = defaults.object(forKey: "autoRefresh") as? Bool ?? true
        self.alertAt75 = defaults.object(forKey: "alertAt75") as? Bool ?? true
        self.alertAt90 = defaults.object(forKey: "alertAt90") as? Bool ?? true
        self.alertAt95 = defaults.object(forKey: "alertAt95") as? Bool ?? true
        self.reducedRefreshOnBattery = defaults.object(forKey: "reducedRefreshOnBattery") as? Bool ?? true
    }
}
