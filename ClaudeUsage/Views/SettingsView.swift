//
//  SettingsView.swift
//  ClaudeUsage
//
//  Phase 3: 완전한 설정 창
//

import AppKit
import SwiftUI

nonisolated enum CodexAuthStatus: Equatable, Sendable {
    case checking
    case authenticated
    case notInstalled
    case notLoggedIn
    case expired
}

struct CodexAuthPresentation: Equatable {
    let statusBadgeTitle: String
    /// 사용자가 할 일. 연결됐거나 확인 중이면 없다.
    let actionDetail: String?
    let command: String?

    static func resolve(for status: CodexAuthStatus) -> CodexAuthPresentation {
        let loginDetail = "터미널에서 `codex login`을 실행한 뒤 다시 확인을 누르세요."
        switch status {
        case .checking:
            return CodexAuthPresentation(statusBadgeTitle: "확인 중", actionDetail: nil, command: nil)
        case .authenticated:
            return CodexAuthPresentation(statusBadgeTitle: "연결됨", actionDetail: nil, command: nil)
        case .notInstalled:
            return CodexAuthPresentation(
                statusBadgeTitle: "설치 필요",
                actionDetail: "ChatGPT 앱이나 Codex CLI를 설치한 뒤 `codex login`을 실행하세요.",
                command: "codex login")
        case .notLoggedIn:
            return CodexAuthPresentation(statusBadgeTitle: "로그인 필요", actionDetail: loginDetail, command: "codex login")
        case .expired:
            return CodexAuthPresentation(statusBadgeTitle: "로그인 만료", actionDetail: loginDetail, command: "codex login")
        }
    }
}

/// 설정 화면의 동작 결과 한 줄. 색은 문구가 아니라 isWarning으로 정한다.
struct SettingsNotice: Equatable {
    let text: String
    var isWarning = false

    init(_ text: String, isWarning: Bool = false) {
        self.text = text
        self.isWarning = isWarning
    }
}

enum SettingsDestructiveAction: Identifiable, Equatable {
    case resetDefaults
    case resetAllData(AppDataResetPlan)

    var id: String {
        switch self {
        case .resetDefaults: return "reset-defaults"
        case .resetAllData: return "reset-all-data"
        }
    }

    var title: String {
        switch self {
        case .resetDefaults: return "앱 설정을 기본값으로 되돌릴까요?"
        case .resetAllData: return "모든 데이터를 초기화할까요?"
        }
    }

    var detail: String {
        switch self {
        case .resetDefaults:
            return "표시, 알림과 앱 동작 설정을 되돌립니다. 계정 연결, 서비스 사용 여부, 로그인 시 자동 시작과 Antigravity의 개별 표시 설정은 유지합니다."
        case .resetAllData(let plan):
            let detail =
                "설정과 이 앱에 저장한 로그인을 모두 지우고 앱을 종료합니다. Claude Code, Codex, AGY CLI의 기본 로그인은 그대로입니다."
            return plan.keepsClaudeCodeTokenCopy ? detail + " Claude Code 로그인 사본 하나는 남깁니다." : detail
        }
    }

    var actionTitle: String {
        switch self {
        case .resetDefaults: return "앱 설정 기본값 복원"
        case .resetAllData: return "초기화 후 종료"
        }
    }
}

nonisolated enum CodexAuthStatusResolver {
    @MainActor
    static func readStoredStatus(isProviderEnabled: Bool) async -> CodexAuthStatus {
        guard isProviderEnabled else { return .notLoggedIn }
        _ = try? await CodexAuthManager.shared.loadSnapshot()
        return resolve(
            isProviderEnabled: isProviderEnabled,
            authJsonExists: CodexAuthManager.shared.authJsonExists,
            token: CodexAuthManager.shared.getToken(),
            isCodexInstalled: { CodexOwnerCLI.isAvailable() })
    }

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
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let claudeAPIService: ClaudeAPIService
    let claudeOAuthMigrationCoordinator: ClaudeOAuthCredentialMigrationCoordinator
    let initialPanel: SettingsProviderPanel?
    let initialSection: SettingsSection?
    let onboardingDetector: () async -> OnboardingDetection
    let claudeAccountStore: ClaudeAccountStore
    let sessionKeyLoader: @Sendable (String) -> String?
    let codexAuthStatusReader: @MainActor (Bool) async -> CodexAuthStatus
    @ObservedObject var settings: AppSettings
    @ObservedObject var notificationManager = NotificationManager.shared
    @ObservedObject var updateRuntimeState: UpdateRuntimeState
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
    @State var claudeAccountMessage: SettingsNotice?
    @State var organizationMessage: SettingsNotice?
    @State var usageHealthSnapshot: ClaudeAPIService.UsageHealthSnapshot?
    @State var usageHealthLoadTask: Task<Void, Never>?
    @State var usageHealthLoadGeneration = 0
    @State var profileMetadata: ClaudeProfileMetadata?
    @State var claudeOAuthMigrationState: ClaudeOAuthCredentialMigrationState = .checking
    @State var claudeOAuthMigrationTask: Task<Void, Never>?
    @State var claudeAccounts: [ClaudeAccount] = []
    @State var activeClaudeAccountID: String?
    @State var selectedPanel: SettingsProviderPanel = .common
    @State var selectedProvider: AppProviderKind = .claude
    @State var requestedSection: SettingsSection?
    @State var sectionScrollPosition: SettingsSection?
    @State var preparedSettingsDataRequest: SettingsDataPreparationRequest?
    @State var navigationRevision = 0
    @State var isPopoverSettingsExpanded = false
    @State var isAdvancedAuthExpanded = false
    @State var isOrganizationAdvancedExpanded = false
    @State var codexAuthStatus: CodexAuthStatus = .checking
    @State var codexAuthCheckTask: Task<Void, Never>?
    @State var runtimeEnvironmentRefreshTick: Int = 0
    @State var expandedCustomMenuBarProviders: Set<AppProviderKind> = []
    @State var pendingDestructiveAction: SettingsDestructiveAction?
    @StateObject var antigravitySettings:
        AntigravitySettingsViewModel

    @State var onboardingDetection = OnboardingDetection()
    @State var browserLoginWatch: Task<Void, Never>?
    @State var installGuide: AppProviderKind?
    var onImportClaudeFromBrowser: ((ClaudeBrowserFamily?) -> Void)?
    var usageAccounts: UsageAccountsController?
    var onOpenEmbeddedLogin: (() -> Void)?
    var welcomeStatuses: (() -> [AppProviderKind: WelcomeServiceStatus])?
    var onVerifyService: ((PopoverService) -> Void)?
    var onShowWhatsNew: (() -> Void)?

    var onOpenLogin: (() -> Void)?
    var onReconnectClaudeCode: (() -> Void)?
    var onImportClaudeFromChrome: (() -> Void)?
    var onRefreshClaudeUsage: (() -> Void)?
    var onClaudeOAuthMigrationCompleted: (() -> Void)?
    var onCodexLogout: (() -> Void)?
    var claudeLastUsage: (() -> ClaudeUsageResponse?)?
    var claudeLastOverage: (() -> OverageSpendLimitResponse?)?
    var codexLastUsage: (() -> CodexUsageResponse?)?
    var codexLastError: (() -> APIError?)?

    init(
        claudeAPIService: ClaudeAPIService,
        antigravitySettings: AntigravitySettingsViewModel,
        settings: AppSettings = .shared,
        updateRuntimeState: UpdateRuntimeState = .shared,
        claudeAccountStore: ClaudeAccountStore = .shared,
        sessionKeyLoader: @escaping @Sendable (String) -> String? = { KeychainManager.shared.load(for: $0) },
        codexAuthStatusReader: @escaping @MainActor (Bool) async -> CodexAuthStatus = CodexAuthStatusResolver
            .readStoredStatus,
        claudeOAuthMigrationCoordinator: ClaudeOAuthCredentialMigrationCoordinator = .shared,
        onOpenLogin: (() -> Void)? = nil,
        onReconnectClaudeCode: (() -> Void)? = nil,
        onImportClaudeFromChrome: (() -> Void)? = nil,
        onRefreshClaudeUsage: (() -> Void)? = nil,
        onClaudeOAuthMigrationCompleted: (() -> Void)? = nil,
        onCodexLogout: (() -> Void)? = nil,
        claudeLastUsage: (() -> ClaudeUsageResponse?)? = nil,
        claudeLastOverage: (() -> OverageSpendLimitResponse?)? = nil,
        codexLastUsage: (() -> CodexUsageResponse?)? = nil,
        codexLastError: (() -> APIError?)? = nil,
        initialPanel: SettingsProviderPanel? = nil,
        initialSection: SettingsSection? = nil,
        welcomeStatuses: (() -> [AppProviderKind: WelcomeServiceStatus])? = nil,
        onboardingDetector: @escaping () async -> OnboardingDetection = OnboardingDetection.detect,
        onVerifyService: ((PopoverService) -> Void)? = nil,
        onShowWhatsNew: (() -> Void)? = nil,
        onImportClaudeFromBrowser: ((ClaudeBrowserFamily?) -> Void)? = nil,
        onOpenEmbeddedLogin: (() -> Void)? = nil,
        usageAccounts: UsageAccountsController? = nil
    ) {
        self.claudeAPIService = claudeAPIService
        self.initialPanel = initialPanel
        self.initialSection = initialSection
        self.settings = settings
        self.updateRuntimeState = updateRuntimeState
        self.claudeAccountStore = claudeAccountStore
        self.sessionKeyLoader = sessionKeyLoader
        self.codexAuthStatusReader = codexAuthStatusReader
        self.welcomeStatuses = welcomeStatuses
        self.onboardingDetector = onboardingDetector
        self.onVerifyService = onVerifyService
        self.onShowWhatsNew = onShowWhatsNew
        self.onImportClaudeFromBrowser = onImportClaudeFromBrowser
        self.onOpenEmbeddedLogin = onOpenEmbeddedLogin
        self.usageAccounts = usageAccounts
        let fallbackProvider = settings.activeProviderKind ?? .claude
        let storedPanel = SettingsProviderPanel.resolve(
            storedValue: settings.settingsLastTab, fallbackProvider: fallbackProvider)
        let panel = initialPanel ?? storedPanel?.panel ?? .common
        _selectedPanel = State(initialValue: panel)
        _selectedProvider = State(initialValue: panel.providerKind ?? fallbackProvider)
        _requestedSection = State(initialValue: initialSection)
        _isPopoverSettingsExpanded = State(initialValue: initialSection == .popover)
        _antigravitySettings = StateObject(wrappedValue: antigravitySettings)
        self.claudeOAuthMigrationCoordinator = claudeOAuthMigrationCoordinator
        self.onOpenLogin = onOpenLogin
        self.onReconnectClaudeCode = onReconnectClaudeCode
        self.onImportClaudeFromChrome = onImportClaudeFromChrome
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
            return "세션 키는 보통 sk-ant-로 시작합니다"
        }
        return nil
    }
}
