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

enum SettingsDestructiveAction: Identifiable, Equatable {
    case resetDefaults
    case clearBrowserSession
    case deleteClaudeAccount(ClaudeAccount)
    case disconnectAntigravityAccount
    case disconnectAllAntigravityAccounts

    var id: String {
        switch self {
        case .resetDefaults: return "reset-defaults"
        case .clearBrowserSession: return "clear-browser-session"
        case .deleteClaudeAccount(let account): return "delete-claude-\(account.id)"
        case .disconnectAntigravityAccount: return "disconnect-antigravity"
        case .disconnectAllAntigravityAccounts: return "disconnect-all-antigravity"
        }
    }

    var title: String {
        switch self {
        case .resetDefaults: return "모든 표시 설정을 기본값으로 복원할까요?"
        case .clearBrowserSession: return "브라우저 로그인 값을 삭제할까요?"
        case .deleteClaudeAccount(let account): return "\(account.displayName) 계정을 삭제할까요?"
        case .disconnectAntigravityAccount: return "선택한 Google 계정 연결을 해제할까요?"
        case .disconnectAllAntigravityAccounts: return "모든 Google 계정 연결을 해제할까요?"
        }
    }

    var detail: String {
        switch self {
        case .resetDefaults:
            return "계정 로그인은 유지되고 메뉴바, 팝오버, 알림 설정만 초기화됩니다."
        case .clearBrowserSession:
            return "선택한 브라우저 계정의 저장된 로그인 값이 제거됩니다. Claude Code 로그인은 유지됩니다."
        case .deleteClaudeAccount:
            return "저장된 브라우저 로그인과 계정 표시 정보가 함께 제거됩니다."
        case .disconnectAntigravityAccount:
            return "해당 계정의 로컬 연결 정보가 제거되며 다시 연결할 수 있습니다."
        case .disconnectAllAntigravityAccounts:
            return "저장된 모든 Antigravity Google 계정 연결이 이 Mac에서 제거됩니다."
        }
    }

    var actionTitle: String {
        switch self {
        case .resetDefaults: return "기본값 복원"
        case .clearBrowserSession: return "로그인 값 삭제"
        case .deleteClaudeAccount: return "계정 삭제"
        case .disconnectAntigravityAccount: return "연결 해제"
        case .disconnectAllAntigravityAccounts: return "모두 연결 해제"
        }
    }
}

enum CodexAuthStatusResolver {
    /// **[C] Refresh 자동 호출 제거**:
    /// 이전에는 만료(또는 만료 추정) 시 status 조회 자체가 `refreshAccessToken` 콜백을 호출했다.
    /// 이로 인해 사용자가 설정 UI 에 들어가는 것만으로도 OAuth refresh_token 을 한 번 소비했고,
    /// 새 토큰이 in-memory 에 머무는 동안 process 가 종료되면 다음 부팅 시 옛 RT 로 재시도 →
    /// `refresh_token_reused` 에러를 사용자에게 노출했다.
    ///
    /// 새 정책: status 는 read-only. 토큰이 만료(명시 expires_at 기준)됐어도 refresh 시도하지 않고
    /// `.expired` 그대로 반환해 사용자에게 `codex login` 안내. refresh 는 명시적 사용자 행동
    /// (사용량 새로고침 등) 의 부산물로만 일어나도록 호출자가 결정.
    static func resolve(
        isProviderEnabled: Bool,
        authJsonExists: Bool,
        token: CodexAuthToken?,
        isCodexInstalled: () -> Bool
    ) -> CodexAuthStatus {
        guard isProviderEnabled else { return .notLoggedIn }

        guard authJsonExists else {
            return isCodexInstalled() ? .notLoggedIn : .notInstalled
        }

        guard let token else { return .notLoggedIn }
        if !token.isExpired { return .authenticated }
        return .expired
    }
}

struct SettingsView: View {
    let claudeAPIService: ClaudeAPIService
    let claudeOAuthMigrationCoordinator: ClaudeOAuthCredentialMigrationCoordinator
    let initialPanel: SettingsProviderPanel?
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var updateRuntimeState = UpdateRuntimeState.shared
    @State var sessionKey: String = ""
    @State var storedSessionKey: String?
    @State var lastVerifiedSessionKey: String?
    @State var testResult: TestResult?
    @State var isTesting: Bool = false
    @State var organizationPersistTask: Task<Void, Never>?
    @State var organizationLoadTask: Task<Void, Never>?
    @State var organizationLoadToken: UUID?
    @State var selectedOrganizationID: String = ""
    @State var organizations: [ClaudeAPIService.OrganizationSummary] = []
    @State var organizationPreviews: [String: ClaudeAPIService.OrganizationPreview] = [:]
    @State var isLoadingOrganizations = false
    @State var claudeAccountMessage: String?
    @State var organizationMessage: String?
    @State var usageHealthSnapshot: ClaudeAPIService.UsageHealthSnapshot?
    @State var usageHealthLoadTask: Task<Void, Never>?
    @State var usageHealthLoadGeneration = 0
    @State var profileMetadata: ClaudeProfileMetadata?
    @State var claudeOAuthMigrationState: ClaudeOAuthCredentialMigrationState = .checking
    @State var claudeOAuthMigrationTask: Task<Void, Never>?
    @State var claudeAccounts: [ClaudeAccount] = []
    @State var activeClaudeAccountID: String?
    @State var selectedPanel: SettingsProviderPanel = .common
    @State var selectedDisplayProvider:
        AppProviderKind = .claude
    @State var isClaudeAccountSwitcherExpanded = false
    @State var isClaudeAccountManagementExpanded = false
    @State var isAdvancedAuthExpanded = false
    @State var isOrganizationAdvancedExpanded = false
    @State var codexAuthStatus: CodexAuthStatus = .checking
    @State var codexAuthCheckTask: Task<Void, Never>?
    @State var runtimeEnvironmentRefreshTick: Int = 0
    @State var expandedCustomMenuBarProviders: Set<AppProviderKind> = []
    @State var pendingDestructiveAction: SettingsDestructiveAction?
    @StateObject var antigravitySettings:
        AntigravitySettingsViewModel

    var onOpenLogin: (() -> Void)?
    var onReconnectClaudeCode: (() -> Void)?
    var onImportClaudeFromChrome: (() -> Void)?
    var onClearBrowserSession: (() -> Void)?
    var onRefreshClaudeUsage: (() -> Void)?
    var onClaudeOAuthMigrationCompleted: (() -> Void)?
    var onCodexLogout: (() -> Void)?
    var claudeLastUsage: (() -> ClaudeUsageResponse?)?
    var claudeLastOverage: (() -> OverageSpendLimitResponse?)?
    var codexLastUsage: (() -> CodexUsageResponse?)?
    var codexLastError: (() -> APIError?)?

    init(
        claudeAPIService: ClaudeAPIService,
        antigravityRuntimeController:
            AntigravityRuntimeController,
        claudeOAuthMigrationCoordinator: ClaudeOAuthCredentialMigrationCoordinator = .shared,
        onOpenLogin: (() -> Void)? = nil,
        onReconnectClaudeCode: (() -> Void)? = nil,
        onImportClaudeFromChrome: (() -> Void)? = nil,
        onClearBrowserSession: (() -> Void)? = nil,
        onRefreshClaudeUsage: (() -> Void)? = nil,
        onClaudeOAuthMigrationCompleted: (() -> Void)? = nil,
        onCodexLogout: (() -> Void)? = nil,
        claudeLastUsage: (() -> ClaudeUsageResponse?)? = nil,
        claudeLastOverage: (() -> OverageSpendLimitResponse?)? = nil,
        codexLastUsage: (() -> CodexUsageResponse?)? = nil,
        codexLastError: (() -> APIError?)? = nil,
        initialPanel: SettingsProviderPanel? = nil
    ) {
        self.claudeAPIService = claudeAPIService
        self.initialPanel = initialPanel
        _selectedPanel = State(
            initialValue:
                initialPanel
                ?? SettingsProviderPanel(
                    rawValue: AppSettings.shared.settingsLastTab
                )
                ?? .common
        )
        _antigravitySettings = StateObject(
            wrappedValue:
                AntigravitySettingsViewModel(
                    runtimeController:
                        antigravityRuntimeController
                )
        )
        self.claudeOAuthMigrationCoordinator = claudeOAuthMigrationCoordinator
        self.onOpenLogin = onOpenLogin
        self.onReconnectClaudeCode = onReconnectClaudeCode
        self.onImportClaudeFromChrome = onImportClaudeFromChrome
        self.onClearBrowserSession = onClearBrowserSession
        self.onRefreshClaudeUsage = onRefreshClaudeUsage
        self.onClaudeOAuthMigrationCompleted = onClaudeOAuthMigrationCompleted
        self.onCodexLogout = onCodexLogout
        self.claudeLastUsage = claudeLastUsage
        self.claudeLastOverage = claudeLastOverage
        self.codexLastUsage = codexLastUsage
        self.codexLastError = codexLastError
    }

    enum TestResult: Equatable {
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
