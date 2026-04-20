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
    @State var sessionKey: String = ""
    @State var storedSessionKey: String?
    @State var lastVerifiedSessionKey: String?
    @State var testResult: TestResult?
    @State var isTesting: Bool = false
    @State var refreshIntervalText: String = ""
    @State var sessionKeyPersistTask: Task<Void, Never>?
    @State var organizationPersistTask: Task<Void, Never>?
    @State var selectedOrganizationID: String = ""
    @State var organizations: [ClaudeAPIService.OrganizationSummary] = []
    @State var isLoadingOrganizations = false
    @State var organizationMessage: String?
    @State var organizationOAuthFallbackSummary: String?
    @State var usageHealthSnapshot: ClaudeAPIService.UsageHealthSnapshot?
    @State var profileMetadata: ClaudeProfileMetadata?
    @State var selectedPanel: SettingsProviderPanel = .common
    @State var selectedCommonTab: CommonTab = .services
    @State var selectedClaudeTab: ProviderSettingsTab = .overview
    @State var selectedCodexTab: ProviderSettingsTab = .overview
    @State var selectedGeminiTab: ProviderSettingsTab = .overview
    @State var selectedAntigravityTab: ProviderSettingsTab = .overview
    @State var isAdvancedAuthExpanded = false
    @State var isOrganizationAdvancedExpanded = false
    @State var codexAuthStatus: CodexAuthStatus = .checking
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
        case services
        case display
        case alerts
        case app

        var id: String { rawValue }

        var title: String {
            switch self {
            case .services: return "서비스"
            case .display: return "표시"
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
    var sessionKeyFormatWarning: String? {
        guard !sessionKey.isEmpty else { return nil }
        let normalized = normalizeSessionKey(sessionKey)
        if !normalized.hasPrefix("sk-ant-") {
            return "브라우저 로그인 값은 보통 sk-ant-로 시작합니다"
        }
        return nil
    }
}
