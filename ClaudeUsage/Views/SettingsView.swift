//
//  SettingsView.swift
//  ClaudeUsage
//
//  Phase 3: 완전한 설정 창
//

import AppKit
import SwiftUI

enum CodexAuthStatus: Equatable {
    case checking
    case authenticated
    case notInstalled
    case notLoggedIn
    case expired
}

struct CodexAuthPresentation: Equatable {
    let statusTitle: String
    let statusBadgeTitle: String
    let actionTitle: String
    let actionDetail: String?
    let command: String?

    static func resolve(for status: CodexAuthStatus) -> CodexAuthPresentation {
        switch status {
        case .checking:
            return CodexAuthPresentation(
                statusTitle: "상태를 확인하는 중입니다",
                statusBadgeTitle: "확인 중",
                actionTitle: "확인 중",
                actionDetail: nil,
                command: nil
            )
        case .authenticated:
            return CodexAuthPresentation(
                statusTitle: "로그인되어 바로 사용할 수 있습니다",
                statusBadgeTitle: "로그인됨",
                actionTitle: "로그인 완료",
                actionDetail: nil,
                command: nil
            )
        case .notInstalled:
            return CodexAuthPresentation(
                statusTitle: "Codex CLI를 먼저 설치해야 합니다",
                statusBadgeTitle: "설치 필요",
                actionTitle: "Codex CLI 설치 후 로그인",
                actionDetail: "터미널에서 codex 명령이 인식되는지 확인한 뒤 `codex login`을 실행하세요.",
                command: "codex login"
            )
        case .notLoggedIn:
            return CodexAuthPresentation(
                statusTitle: "터미널에서 Codex 로그인이 필요합니다",
                statusBadgeTitle: "로그인 필요",
                actionTitle: "Codex 로그인",
                actionDetail: "터미널을 열고 `codex login`을 실행한 뒤 다시 확인하세요.",
                command: "codex login"
            )
        case .expired:
            return CodexAuthPresentation(
                statusTitle: "Codex 로그인을 갱신하지 못했습니다",
                statusBadgeTitle: "다시 로그인",
                actionTitle: "Codex 다시 로그인",
                actionDetail: "터미널에서 `codex login`을 다시 실행한 뒤 다시 확인하세요.",
                command: "codex login"
            )
        }
    }
}

enum CodexAuthStatusResolver {
    static func resolve(
        isProviderEnabled: Bool,
        authJsonExists: Bool,
        token: CodexAuthToken?,
        isCodexInstalled: () -> Bool,
        refreshAccessToken: (String) async -> CodexAuthToken?
    ) async -> CodexAuthStatus {
        guard isProviderEnabled else { return .notLoggedIn }

        guard authJsonExists else {
            return isCodexInstalled() ? .notLoggedIn : .notInstalled
        }

        guard let token else { return .notLoggedIn }
        guard token.isExpired else { return .authenticated }

        guard let refreshToken = token.refreshToken, token.hasRefreshToken else {
            return .expired
        }

        if let refreshedToken = await refreshAccessToken(refreshToken),
           !refreshedToken.isExpired {
            return .authenticated
        }

        return .expired
    }
}

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
    @State var codexAuthCheckTask: Task<Void, Never>?
    @State var runtimeEnvironmentRefreshTick: Int = 0

    var onOpenLogin: (() -> Void)?
    var onOpenClaudeInChrome: (() -> Void)?
    var onLogout: (() -> Void)?
    var onCodexLogout: (() -> Void)?
    enum TestResult {
        case success(String)
        case failure(String)
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
