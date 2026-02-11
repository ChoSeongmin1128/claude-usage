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
        self.refreshInterval = defaults.object(forKey: "refreshInterval") as? TimeInterval ?? 5.0
        self.autoRefresh = defaults.object(forKey: "autoRefresh") as? Bool ?? true
        self.alertAt75 = defaults.object(forKey: "alertAt75") as? Bool ?? true
        self.alertAt90 = defaults.object(forKey: "alertAt90") as? Bool ?? true
        self.alertAt95 = defaults.object(forKey: "alertAt95") as? Bool ?? true
        self.reducedRefreshOnBattery = defaults.object(forKey: "reducedRefreshOnBattery") as? Bool ?? true
    }
}
