//
//  SettingsView.swift
//  ClaudeUsage
//
//  Phase 3: 완전한 설정 창
//

import AppKit
import SwiftUI


struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var updateRuntimeState = UpdateRuntimeState.shared
    @StateObject var settingsViewModel = SettingsViewModel()
    @State var sessionKey: String = ""
    @State var storedSessionKey: String?
    @State var lastVerifiedSessionKey: String?
    @State var testResult: TestResult?
    @State var isTesting: Bool = false
    @State var refreshIntervalText: String = ""
    @State var showKeyHelp: Bool = false
    @State var alertPresetTexts: [String] = []
    @State var sessionKeyPersistTask: Task<Void, Never>?
    @State var organizationPersistTask: Task<Void, Never>?
    @State var compactConfigTab: Int = 0
    @State var codexCompactConfigTab: Int = 0
    @State var selectedOrganizationID: String = ""
    @State var organizations: [ClaudeAPIService.OrganizationSummary] = []
    @State var organizationPreviews: [ClaudeAPIService.OrganizationPreview] = []
    @State var isLoadingOrganizations = false
    @State var isLoadingOrganizationPreviews = false
    @State var organizationMessage: String?
    @State var organizationOAuthFallbackSummary: String?
    @State var usageHealthSnapshot: ClaudeAPIService.UsageHealthSnapshot?
    @State var profileMetadata: ClaudeProfileMetadata?
    @State var selectedPanel: SettingsProviderPanel = .common
    @State var selectedCommonTab: CommonTab = .display
    @State var selectedClaudeTab: ProviderSettingsTab = .overview
    @State var selectedCodexTab: ProviderSettingsTab = .overview
    @State var selectedGeminiTab: ProviderSettingsTab = .overview
    @State var selectedAntigravityTab: ProviderSettingsTab = .overview
    @State var isAdvancedAuthExpanded = false
    @State var isAuthFAQExpanded = false
    @State var isAuthDetailsExpanded = false
    @State var isMessagesFallbackExpanded = false
    @State var isOrganizationAdvancedExpanded = false
    @State var isTestingMessagesFallback = false
    @State var messagesFallbackStatus: String?
    @State var codexAuthStatus: CodexAuthStatus = .checking
    @State var isUpdateGuidanceExpanded = false
    @State var runtimeEnvironmentRefreshTick: Int = 0

    var onOpenLogin: (() -> Void)?
    var onOpenClaudeInChrome: (() -> Void)?
    var onLogout: (() -> Void)?
    var onCodexLogout: (() -> Void)?
    enum TestResult {
        case success(String)
        case failure(String)
    }

    enum CommonTab: String, CaseIterable, Identifiable {
        case display
        case refreshPower
        case alerts
        case app

        var id: String { rawValue }

        var title: String {
            switch self {
            case .display: return "표시"
            case .refreshPower: return "갱신/전원"
            case .alerts: return "알림"
            case .app: return "앱"
            }
        }
    }

    enum CodexAuthStatus {
        case checking
        case authenticated
        case notInstalled
        case notLoggedIn
        case expired
    }

    var isRefreshIntervalValid: Bool {
        guard let val = Int(refreshIntervalText) else { return false }
        return val >= 5 && val <= 120
    }

    var sessionKeyFormatWarning: String? {
        guard !sessionKey.isEmpty else { return nil }
        let normalized = normalizeSessionKey(sessionKey)
        if !normalized.hasPrefix("sk-ant-") {
            return "세션 키는 보통 sk-ant-로 시작합니다"
        }
        return nil
    }
}
