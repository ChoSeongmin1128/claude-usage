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
    @State var sessionKeyPersistTask: Task<Void, Never>?
    @State var organizationPersistTask: Task<Void, Never>?
    @State var selectedOrganizationID: String = ""
    @State var organizations: [ClaudeAPIService.OrganizationSummary] = []
    @State var organizationPreviews: [String: ClaudeAPIService.OrganizationPreview] = [:]
    @State var isLoadingOrganizations = false
    @State var organizationMessage: String?
    @State var organizationOAuthFallbackSummary: String?
    @State var usageHealthSnapshot: ClaudeAPIService.UsageHealthSnapshot?
    @State var profileMetadata: ClaudeProfileMetadata?
    @State var selectedPanel: SettingsProviderPanel = .common
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
