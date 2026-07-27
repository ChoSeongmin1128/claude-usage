import Combine
import Foundation

nonisolated protocol AntigravitySettingsOAuthLoggingIn:
    Sendable
{
    func login() async
        -> AntigravityOAuthLoginRunner.Result
}

nonisolated struct LiveAntigravitySettingsOAuthLogin:
    AntigravitySettingsOAuthLoggingIn
{
    nonisolated init() {}

    nonisolated func login() async
        -> AntigravityOAuthLoginRunner.Result
    {
        await AntigravityOAuthLoginRunner.run()
    }
}

nonisolated protocol
    AntigravitySettingsRuntimeControlling:
    Sendable
{
    func snapshot() async
        -> AntigravityRuntimeSnapshot
    func snapshots() async
        -> AsyncStream<AntigravityRuntimeSnapshot>

    func bootstrap(
        performInitialRefresh: Bool
    ) async -> AntigravityRuntimeSnapshot

    func refresh(
        trigger: AntigravityRefreshTrigger
    ) async -> AntigravityRuntimeSnapshot

    func selectAccount(
        _ accountID: AntigravityAccountID
    ) async throws -> AntigravityRuntimeSnapshot

    func connectAccount(
        credentials: AntigravityOAuthCredentials,
        label: String?
    ) async throws -> AntigravityRuntimeSnapshot

    func deleteAccount(
        _ accountID: AntigravityAccountID
    ) async throws -> AntigravityRuntimeSnapshot

    func updateConnection(
        _ connection: AntigravityConnectionSettings
    ) async throws -> AntigravityRuntimeSnapshot

    func updateDisplay(
        _ display: AntigravityDisplaySettings,
        replacing expectedDisplay:
            AntigravityDisplaySettings
    ) async throws -> AntigravityRuntimeSnapshot

    func continueMigration() async
        -> AntigravityRuntimeSnapshot

    func removeAllAccounts(
        interactively: Bool
    ) async -> AntigravityRuntimeSnapshot

    func consumePendingSettingsNotice() async
        -> AntigravityRuntimeSnapshot
}

extension AntigravityRuntimeController:
    AntigravitySettingsRuntimeControlling
{}

nonisolated struct AntigravitySettingsAccountSummary:
    Identifiable,
    Equatable,
    Sendable
{
    let id: AntigravityAccountID
    let label: String
    let email: String?
    let lifecycle: AntigravityAccountLifecycle
    let isActive: Bool
}

nonisolated struct AntigravitySettingsNotice:
    Equatable,
    Sendable
{
    enum Tone: String, Equatable, Sendable {
        case progress
        case success
        case warning
        case failure
    }

    enum Action: String, Equatable, Sendable {
        case dismiss
        case retryLoad
        case retryMigrationCheck
        case continueMigration
        case removeLegacyData
        case acknowledgeDisplayMigrationNotice
        case cancelOAuthLogin
    }

    let tone: Tone
    let title: String
    let message: String
    let action: Action?
}

nonisolated struct AntigravitySettingsViewState:
    Equatable,
    Sendable
{
    enum Activity: String, Equatable, Sendable {
        case idle
        case loading
        case checkingMigration
        case authenticating
        case changingAccount
        case changingConnection
        case changingDisplay
        case migrating

        var isBusy: Bool {
            self != .idle
        }
    }

    var activity: Activity
    var accounts: [AntigravitySettingsAccountSummary]
    var activeAccountID: AntigravityAccountID?
    var connection: AntigravityConnectionSettings?
    var display: AntigravityDisplaySettings?
    var migrationStatus: AntigravityMigrationStatus?
    var presentation: AntigravityPresentationState
    var quotaPresentation:
        AntigravityQuotaPresentationMappingResult
    var managedRuntimeAvailability:
        AntigravityManagedRuntimeAvailability
    var repositoryRevision: UInt64?
    var notice: AntigravitySettingsNotice?

    static let initial = AntigravitySettingsViewState(
        activity: .idle,
        accounts: [],
        activeAccountID: nil,
        connection: nil,
        display: nil,
        migrationStatus: nil,
        presentation: .disabled,
        quotaPresentation: .unavailable(.disabled),
        managedRuntimeAvailability: .unavailable,
        repositoryRevision: nil,
        notice: nil
    )
}

/// Settings-only projection for the managed AGY launch capability.
///
/// `managedRuntimeAvailability` describes whether ClaudeUsage may create a
/// process. It does not describe borrowed sessions: a user-started AGY process
/// remains a valid local-session source even when managed launch is unavailable.
nonisolated struct AntigravityManagedRuntimeSettingsPresentation:
    Equatable,
    Sendable
{
    let toggleTitle: String
    let detail: String
    let diagnosticTitle: String
    let isToggleEnabled: Bool
    private let canEnableManagedRuntime: Bool

    static func resolve(
        _ availability: AntigravityManagedRuntimeAvailability,
        currentSelection: Bool
    ) -> Self {
        let toggleTitle =
            "ClaudeUsage의 AGY 직접 실행 허용"
        switch availability {
        case .available:
            return Self(
                toggleTitle: toggleTitle,
                detail: "검증된 AGY 실행 파일이 있을 때만 로컬 세션 조회를 위해 직접 실행합니다. 사용자가 이미 실행한 AGY 세션은 이 설정과 무관하게 조회할 수 있습니다.",
                diagnosticTitle: "직접 실행 가능",
                isToggleEnabled: true,
                canEnableManagedRuntime: true
            )
        case .unavailable:
            return Self(
                toggleTitle: toggleTitle,
                detail: currentSelection
                    ? "현재 공식 AGY CLI는 ClaudeUsage가 안전하게 직접 실행할 수 없습니다. 저장된 직접 실행 허용은 끌 수 있으며, 사용자가 이미 실행한 AGY 세션은 계속 조회할 수 있습니다."
                    : "현재 공식 AGY CLI는 ClaudeUsage가 안전하게 직접 실행할 수 없습니다. 사용자가 이미 실행한 AGY 세션은 로컬 세션 조회에 사용할 수 있습니다.",
                diagnosticTitle:
                    "직접 실행 불가 · 실행 중 세션 조회 가능",
                isToggleEnabled: currentSelection,
                canEnableManagedRuntime: false
            )
        case .recoveryBlocked:
            return Self(
                toggleTitle: toggleTitle,
                detail: currentSelection
                    ? "이전에 ClaudeUsage가 시작한 AGY 정리를 검증할 때까지 새 프로세스를 직접 실행하지 않습니다. 저장된 직접 실행 허용은 끌 수 있으며, 사용자가 이미 실행한 AGY 세션은 계속 조회할 수 있습니다."
                    : "이전에 ClaudeUsage가 시작한 AGY 정리를 검증할 때까지 새 프로세스를 직접 실행하지 않습니다. 사용자가 이미 실행한 AGY 세션은 계속 조회할 수 있습니다.",
                diagnosticTitle:
                    "직접 실행 중단 · 실행 중 세션 조회 가능",
                isToggleEnabled: currentSelection,
                canEnableManagedRuntime: false
            )
        }
    }

    func permitsSelection(_ requestedSelection: Bool) -> Bool {
        !requestedSelection || canEnableManagedRuntime
    }
}

nonisolated extension AntigravitySettingsViewState {
    var managedRuntimePresentation:
        AntigravityManagedRuntimeSettingsPresentation
    {
        .resolve(
            managedRuntimeAvailability,
            currentSelection:
                connection?.allowManagedCLI
                    ?? false
        )
    }
}

/// Settings projection for the shared Antigravity runtime controller.
///
/// OAuth credentials exist only between the browser result and
/// `connectAccount`. Repository/settings/migration actors are deliberately not
/// exposed here, so the settings window cannot interleave its own transaction
/// with AppDelegate refreshes.
@MainActor
final class AntigravitySettingsViewModel:
    ObservableObject
{
    @Published private(set) var state =
        AntigravitySettingsViewState.initial

    private let runtimeController:
        any AntigravitySettingsRuntimeControlling
    private let oauthLogin:
        any AntigravitySettingsOAuthLoggingIn
    private var observationTask:
        Task<Void, Never>?
    private var oauthLoginTask:
        Task<AntigravityOAuthLoginRunner.Result, Never>?
    private var oauthLoginID: UUID?

    init(
        runtimeController:
            any AntigravitySettingsRuntimeControlling,
        oauthLogin:
            any AntigravitySettingsOAuthLoggingIn =
                LiveAntigravitySettingsOAuthLogin()
    ) {
        self.runtimeController = runtimeController
        self.oauthLogin = oauthLogin
    }

    func load() async {
        guard begin(.loading) else { return }
        startObservationIfNeeded()
        let snapshot = await runtimeController.bootstrap(
            performInitialRefresh: true
        )
        apply(snapshot)
        state.notice = notice(for: snapshot)
        state.activity = .idle
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
        cancelOAuthLogin()
    }

    @discardableResult
    func refresh() async -> Bool {
        guard begin(.loading) else { return false }
        let snapshot = await runtimeController.refresh(
            trigger: .manual
        )
        apply(snapshot)
        state.notice = notice(for: snapshot)
        state.activity = .idle
        return true
    }

    @discardableResult
    func selectAccount(
        _ accountID: AntigravityAccountID
    ) async -> Bool {
        guard state.activeAccountID != accountID,
              begin(.changingAccount)
        else {
            return false
        }
        return await performMutation(
            activity: .changingAccount,
            success: AntigravitySettingsNotice(
                tone: .success,
                title: "Google 계정을 전환했습니다",
                message: "선택한 계정과 일치하는 사용량으로 갱신했습니다.",
                action: .dismiss
            )
        ) {
            try await self.runtimeController
                .selectAccount(accountID)
        }
    }

    @discardableResult
    func addAccount() async -> Bool {
        guard begin(.authenticating) else { return false }
        state.notice = AntigravitySettingsNotice(
            tone: .progress,
            title: "Google 로그인 중",
            message: "브라우저에서 로그인을 완료해 주세요.",
            action: .cancelOAuthLogin
        )

        let loginID = UUID()
        oauthLoginID = loginID
        let task = Task { [oauthLogin] in
            await oauthLogin.login()
        }
        oauthLoginTask = task
        let result = await task.value
        guard oauthLoginID == loginID else {
            return false
        }
        oauthLoginID = nil
        oauthLoginTask = nil

        switch result.outcome {
        case .success(let credentials):
            state.activity = .changingAccount
            return await performMutation(
                activity: .changingAccount,
                success: AntigravitySettingsNotice(
                    tone: .success,
                    title: "Google 계정을 연결했습니다",
                    message: "새 계정을 선택하고 사용량을 확인했습니다.",
                    action: .dismiss
                )
            ) {
                try await self.runtimeController
                    .connectAccount(
                        credentials: credentials,
                        label: credentials.email
                    )
            }
        case .cancelled:
            finishLoginFailure(
                title: "Google 로그인을 취소했습니다",
                message: "저장된 계정과 현재 사용량은 변경하지 않았습니다.",
                tone: .warning
            )
        case .timedOut:
            finishLoginFailure(
                title: "Google 로그인 시간이 초과되었습니다",
                message: "계정 추가를 다시 시작해 주세요."
            )
        case .launchFailed:
            finishLoginFailure(
                title: "브라우저를 열지 못했습니다",
                message: "기본 브라우저 설정을 확인한 뒤 다시 시도해 주세요."
            )
        case .failed:
            finishLoginFailure(
                title: "Google 계정을 연결하지 못했습니다",
                message: "로그인 상태를 확인한 뒤 다시 시도해 주세요."
            )
        }
        return false
    }

    func cancelOAuthLogin() {
        guard state.activity == .authenticating else {
            return
        }
        oauthLoginID = nil
        oauthLoginTask?.cancel()
        oauthLoginTask = nil
        state.activity = .idle
        state.notice = AntigravitySettingsNotice(
            tone: .warning,
            title: "Google 로그인을 취소했습니다",
            message: "저장된 계정과 현재 사용량은 변경하지 않았습니다.",
            action: .dismiss
        )
    }

    @discardableResult
    func deleteAccount(
        _ accountID: AntigravityAccountID
    ) async -> Bool {
        guard begin(.changingAccount) else {
            return false
        }
        return await performMutation(
            activity: .changingAccount,
            success: AntigravitySettingsNotice(
                tone: .success,
                title: "Google 계정 연결을 해제했습니다",
                message: "ClaudeUsage가 저장한 계정 자격 정보를 제거했습니다.",
                action: .dismiss
            )
        ) {
            try await self.runtimeController
                .deleteAccount(accountID)
        }
    }

    @discardableResult
    func deleteAllAccounts() async -> Bool {
        guard begin(.changingAccount) else {
            return false
        }
        let snapshot = await runtimeController
            .removeAllAccounts(interactively: false)
        apply(snapshot)
        state.notice = notice(for: snapshot)
            ?? AntigravitySettingsNotice(
                tone: .success,
                title: "모든 Google 계정 연결을 해제했습니다",
                message: "ClaudeUsage가 저장한 Antigravity 계정 정보를 제거했습니다.",
                action: .dismiss
            )
        state.activity = .idle
        return snapshot.accounts.isEmpty
    }

    @discardableResult
    func updateConnection(
        _ connection: AntigravityConnectionSettings
    ) async -> Bool {
        guard connection.isCurrentAndValid,
              state.connection != connection,
              begin(.changingConnection)
        else {
            return false
        }
        return await performMutation(
            activity: .changingConnection,
            success: AntigravitySettingsNotice(
                tone: .success,
                title: "연결 방식을 변경했습니다",
                message: "새 연결 방식으로 사용량을 다시 확인했습니다.",
                action: .dismiss
            )
        ) {
            try await self.runtimeController
                .updateConnection(connection)
        }
    }

    @discardableResult
    func updateDisplay(
        _ display: AntigravityDisplaySettings,
        replacing expectedDisplay:
            AntigravityDisplaySettings
    ) async -> Bool {
        guard display.isCurrentAndValid,
              expectedDisplay.isCurrentAndValid,
              state.display != display,
              begin(.changingDisplay)
        else {
            return false
        }
        return await performMutation(
            activity: .changingDisplay,
            success: AntigravitySettingsNotice(
                tone: .success,
                title: "표시 설정을 저장했습니다",
                message: "모든 Antigravity 화면에 같은 표시 기준을 적용했습니다.",
                action: .dismiss
            )
        ) {
            try await self.runtimeController
                .updateDisplay(
                    display,
                    replacing: expectedDisplay
                )
        }
    }

    func refreshMigrationStatus() async {
        guard begin(.checkingMigration) else { return }
        let snapshot = await runtimeController.refresh(
            trigger: .retry
        )
        apply(snapshot)
        state.notice = notice(for: snapshot)
        state.activity = .idle
    }

    @discardableResult
    func performInteractiveMigration() async -> Bool {
        guard begin(.migrating) else { return false }
        let snapshot =
            await runtimeController.continueMigration()
        apply(snapshot)
        state.notice = notice(for: snapshot)
            ?? AntigravitySettingsNotice(
                tone: .success,
                title: "이전 작업을 완료했습니다",
                message: "Antigravity 계정 정보를 새 저장소로 옮겼습니다.",
                action: .dismiss
            )
        state.activity = .idle
        return Self.migrationReachedCutover(
            snapshot.migrationStatus
        )
    }

    @discardableResult
    func removeLegacyDataInteractively() async -> Bool {
        guard begin(.migrating) else { return false }
        let snapshot = await runtimeController
            .removeAllAccounts(interactively: true)
        apply(snapshot)
        state.notice = notice(for: snapshot)
            ?? AntigravitySettingsNotice(
                tone: .success,
                title: "이전 데이터 정리를 완료했습니다",
                message: "ClaudeUsage가 소유한 기존 Antigravity 데이터를 정리했습니다.",
                action: .dismiss
            )
        state.activity = .idle
        return snapshot.migrationStatus?.phase
            == .complete
    }

    func acknowledgeDisplayMigrationNotice() async {
        guard begin(.changingDisplay) else { return }
        let snapshot = await runtimeController
            .consumePendingSettingsNotice()
        apply(snapshot)
        state.notice = notice(for: snapshot)
        state.activity = .idle
    }

    func performNoticeAction() async {
        guard let action = state.notice?.action else {
            return
        }
        switch action {
        case .dismiss:
            state.notice = nil
        case .retryLoad:
            state.notice = nil
            await load()
        case .retryMigrationCheck:
            state.notice = nil
            await refreshMigrationStatus()
        case .continueMigration:
            state.notice = nil
            _ = await performInteractiveMigration()
        case .removeLegacyData:
            state.notice = nil
            _ = await removeLegacyDataInteractively()
        case .acknowledgeDisplayMigrationNotice:
            await acknowledgeDisplayMigrationNotice()
        case .cancelOAuthLogin:
            cancelOAuthLogin()
        }
    }

    private func startObservationIfNeeded() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self, runtimeController] in
            let stream =
                await runtimeController.snapshots()
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    guard let self else { return }
                    let activity = self.state.activity
                    self.apply(snapshot)
                    self.state.activity = activity
                }
            }
        }
    }

    private func begin(
        _ activity: AntigravitySettingsViewState.Activity
    ) -> Bool {
        guard !state.activity.isBusy else { return false }
        state.activity = activity
        return true
    }

    private func performMutation(
        activity: AntigravitySettingsViewState.Activity,
        success: AntigravitySettingsNotice,
        operation:
            () async throws -> AntigravityRuntimeSnapshot
    ) async -> Bool {
        do {
            let snapshot = try await operation()
            apply(snapshot)
            state.notice =
                Self.refreshOutcomeNotice(
                    snapshot.presentationState
                ) ?? success
            state.activity = .idle
            return true
        } catch {
            state.notice = mutationFailureNotice(
                for: activity,
                error: error
            )
            let snapshot =
                await runtimeController.snapshot()
            apply(snapshot)
            state.activity = .idle
            return false
        }
    }

    private func apply(
        _ snapshot: AntigravityRuntimeSnapshot
    ) {
        if let appliedRevision = state.repositoryRevision,
           let incomingRevision = snapshot.repositoryRevision,
           incomingRevision < appliedRevision
        {
            return
        }
        state.accounts = snapshot.accounts.map {
            AntigravitySettingsAccountSummary(
                id: $0.id,
                label: $0.label,
                email: $0.identity.email,
                lifecycle: .active,
                isActive: $0.isActive
            )
        }
        state.activeAccountID =
            snapshot.activeAccountID
        state.connection =
            snapshot.settings?.connection
        state.display = snapshot.settings?.display
        state.migrationStatus =
            snapshot.migrationStatus
        state.presentation =
            snapshot.presentationState
        state.quotaPresentation =
            snapshot.quotaPresentation
        state.managedRuntimeAvailability =
            snapshot.managedRuntimeAvailability
        state.repositoryRevision =
            snapshot.repositoryRevision
    }

    private func notice(
        for snapshot: AntigravityRuntimeSnapshot
    ) -> AntigravitySettingsNotice? {
        if case .blocked(let blocker) =
            snapshot.readiness
        {
            return Self.blockedNotice(blocker)
        }
        return Self.migrationNotice(
            snapshot.migrationStatus
        )
            ?? Self.displayMigrationNotice(
                snapshot.settings?.display
                    .pendingNotice
            )
            ?? Self.refreshOutcomeNotice(
                snapshot.presentationState
            )
    }

    private func finishLoginFailure(
        title: String,
        message: String,
        tone: AntigravitySettingsNotice.Tone =
            .failure
    ) {
        state.activity = .idle
        state.notice = AntigravitySettingsNotice(
            tone: tone,
            title: title,
            message: message,
            action: .dismiss
        )
    }

    private func mutationFailureNotice(
        for activity: AntigravitySettingsViewState.Activity,
        error: Error
    ) -> AntigravitySettingsNotice {
        let title: String
        switch activity {
        case .changingAccount:
            title = "Google 계정 변경을 저장하지 못했습니다"
        case .changingConnection:
            title = "연결 설정을 저장하지 못했습니다"
        case .changingDisplay:
            title = "표시 설정을 저장하지 못했습니다"
        case .migrating:
            title = "이전 작업을 완료하지 못했습니다"
        case .idle,
             .loading,
             .checkingMigration,
             .authenticating:
            title = "Antigravity 설정을 변경하지 못했습니다"
        }
        let message: String
        let controllerError =
            error as?
                AntigravityRuntimeControllerError
        if controllerError == .appShuttingDown {
            message = "앱이 종료 중이라 변경을 시작하지 않았습니다."
        } else if controllerError
            == .operationSuperseded
        {
            message = "다른 창이나 더 최근 작업에서 설정이 변경되어 이 결과는 적용하지 않았습니다. 현재 상태를 확인해 주세요."
        } else {
            message = "저장 상태를 다시 읽어 화면을 동기화했습니다. 상태를 확인한 뒤 다시 시도해 주세요."
        }
        return AntigravitySettingsNotice(
            tone: .failure,
            title: title,
            message: message,
            action: .retryLoad
        )
    }

    private nonisolated static func
        migrationReachedCutover(
            _ status: AntigravityMigrationStatus?
        ) -> Bool
    {
        guard let status,
              !status.authorizationCancelledThisSession
        else {
            return false
        }
        switch status.phase {
        case .canonicalVerified,
             .cleanupPending,
             .complete:
            return true
        case .notStarted,
             .preflight,
             .blockedBeforeCutover,
             .awaitingImportAuthorization,
             .writingCanonical:
            return false
        }
    }

    private nonisolated static func migrationNotice(
        _ status: AntigravityMigrationStatus?
    ) -> AntigravitySettingsNotice? {
        guard let status else { return nil }
        if status.authorizationCancelledThisSession {
            return AntigravitySettingsNotice(
                tone: .warning,
                title: "이전 인증을 취소했습니다",
                message: "이번 앱 실행에서는 Keychain 인증을 다시 요청하지 않습니다.",
                action: .dismiss
            )
        }
        switch status.phase {
        case .complete:
            return nil
        case .notStarted:
            return AntigravitySettingsNotice(
                tone: .warning,
                title: "계정 이전 상태를 확인하지 못했습니다",
                message: "저장된 계정을 변경하기 전에 이전 상태를 다시 확인해 주세요.",
                action: .retryMigrationCheck
            )
        case .preflight,
             .writingCanonical,
             .canonicalVerified:
            return AntigravitySettingsNotice(
                tone: .progress,
                title: "Antigravity 계정 이전 중",
                message: "기존 계정 데이터를 검증하고 있습니다.",
                action: nil
            )
        case .awaitingImportAuthorization:
            return AntigravitySettingsNotice(
                tone: .warning,
                title: "기존 계정 이전이 필요합니다",
                message: "계정을 새 저장소로 옮길 때 Keychain 인증을 한 번 요청할 수 있습니다.",
                action: .continueMigration
            )
        case .cleanupPending:
            let action:
                AntigravitySettingsNotice.Action =
                    status.requiredAction
                        == .removeLegacyCredential
                        ? .removeLegacyData
                        : .continueMigration
            return AntigravitySettingsNotice(
                tone: .warning,
                title: "이전 데이터 정리가 남아 있습니다",
                message: "새 계정 저장은 유지됩니다. 기존 ClaudeUsage 데이터 정리를 다시 진행해 주세요.",
                action: action
            )
        case .blockedBeforeCutover:
            return AntigravitySettingsNotice(
                tone: .failure,
                title: "계정 이전을 시작할 수 없습니다",
                message: "기존 데이터는 삭제하지 않았습니다. 상태를 다시 확인해 주세요.",
                action: .retryMigrationCheck
            )
        }
    }

    private nonisolated static func
        displayMigrationNotice(
            _ notice:
                AntigravitySettingsMigrationNotice?
        ) -> AntigravitySettingsNotice? {
        guard let notice else { return nil }
        return AntigravitySettingsNotice(
            tone: .success,
            title: notice.title,
            message: notice.message,
            action:
                .acknowledgeDisplayMigrationNotice
        )
    }

    private nonisolated static func
        refreshOutcomeNotice(
            _ presentation:
                AntigravityPresentationState
        ) -> AntigravitySettingsNotice? {
        switch presentation {
        case .ready:
            return nil
        case .partial:
            return AntigravitySettingsNotice(
                tone: .warning,
                title: "일부 한도를 읽지 못했습니다",
                message: "확인된 사용량은 유지하고 읽지 못한 항목은 비워 두었습니다.",
                action: .dismiss
            )
        case .limited:
            return AntigravitySettingsNotice(
                tone: .warning,
                title: "수치형 사용량을 제공하지 않는 연결입니다",
                message: "계정과 연결은 확인했지만 이 경로에서는 quota 수치를 제공하지 않습니다.",
                action: .dismiss
            )
        case .identityOnly:
            return AntigravitySettingsNotice(
                tone: .warning,
                title: "확인 가능한 사용량 한도가 없습니다",
                message: "계정 정보는 확인했지만 표시할 수 있는 사용량 한도를 받지 못했습니다.",
                action: .dismiss
            )
        case .stale:
            return AntigravitySettingsNotice(
                tone: .warning,
                title: "새 사용량을 확인하지 못했습니다",
                message: "마지막 확인 데이터는 유지했습니다. 연결 상태를 확인해 주세요.",
                action: .dismiss
            )
        case .refreshing:
            return nil
        case .setupRequired:
            return AntigravitySettingsNotice(
                tone: .warning,
                title: "사용량 조회 방법을 선택해 주세요",
                message: "Google 계정을 연결하거나 로그인된 Antigravity/AGY 세션을 사용하세요.",
                action: .dismiss
            )
        case .accountMismatch:
            return AntigravitySettingsNotice(
                tone: .failure,
                title: "선택한 계정과 실행 중인 계정이 다릅니다",
                message: "이전 계정의 수치는 표시하지 않았습니다. Google 계정 또는 Antigravity 로그인을 확인해 주세요.",
                action: .dismiss
            )
        case .failed:
            return AntigravitySettingsNotice(
                tone: .failure,
                title: "사용량 조회에 실패했습니다",
                message: "계정과 연결 상태를 확인한 뒤 다시 새로고침해 주세요.",
                action: .dismiss
            )
        case .disabled:
            return nil
        }
    }

    private nonisolated static func blockedNotice(
        _ blocker: AntigravityRuntimeBlocker
    ) -> AntigravitySettingsNotice {
        let detail: String
        switch blocker {
        case .settingsMigration:
            detail = "기존 표시 설정을 안전하게 이전하지 못해 새 설정 쓰기를 중단했습니다."
        case .canonicalAccountState:
            detail = "계정 저장 상태를 검증하지 못했습니다. 기존 데이터는 삭제하지 않았습니다."
        case .typedSettings:
            detail = "현재 Antigravity 설정을 읽을 수 없어 자동 초기화하지 않았습니다."
        case .managedRuntimeRecovery:
            detail = "ClaudeUsage가 시작한 이전 AGY 프로세스 정리를 확인하지 못했습니다."
        }
        return AntigravitySettingsNotice(
            tone: .failure,
            title: "Antigravity 준비를 완료하지 못했습니다",
            message: detail,
            action: .retryLoad
        )
    }
}
