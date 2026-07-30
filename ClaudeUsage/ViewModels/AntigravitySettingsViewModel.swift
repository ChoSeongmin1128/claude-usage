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
        _ accountID: AntigravityAccountID?
    ) async throws -> AntigravityRuntimeSnapshot

    func connectAccount(
        credentials: AntigravityOAuthCredentials,
        label: String?
    ) async throws -> AntigravityRuntimeSnapshot

    func deleteAccount(
        _ accountID: AntigravityAccountID
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
        managedRuntimeAvailability: .unavailable(
            reason: .executableNotFound
        ),
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
    let diagnosticTitle: String

    static func resolve(
        _ availability: AntigravityManagedRuntimeAvailability
    ) -> Self {
        switch availability {
        case .available(let displayPath):
            return Self(
                diagnosticTitle:
                    "감지됨 · \(displayPath) · 필요 시 자동 실행"
            )
        case .unavailable(let reason):
            switch reason {
            case .executableNotFound:
                return Self(
                    diagnosticTitle:
                        "미감지 · AGY CLI 설치 필요"
                )
            case .signatureRejected:
                return Self(
                    diagnosticTitle:
                        "감지됐지만 Google 서명 검증 실패"
                )
            }
        case .recoveryBlocked(let displayPath):
            let pathDetail = displayPath.map {
                " · \($0)"
            } ?? ""
            return Self(
                diagnosticTitle:
                    "이전 프로세스 복구 실패\(pathDetail) · 자동 실행 중단"
            )
        }
    }
}

nonisolated extension AntigravitySettingsViewState {
    var managedRuntimePresentation:
        AntigravityManagedRuntimeSettingsPresentation
    {
        .resolve(managedRuntimeAvailability)
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
    private let accountCommands:
        AntigravityAccountCommandCoordinator
    private let displayCommands:
        AntigravityDisplaySettingsCommandAdapter
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
        self.accountCommands =
            AntigravityAccountCommandCoordinator(
                runtime: runtimeController
            )
        self.displayCommands =
            AntigravityDisplaySettingsCommandAdapter(
                runtime: runtimeController
            )
    }

    func load() async {
        guard begin(.loading) else { return }
        startObservationIfNeeded()
        let snapshot = await runtimeController.bootstrap(
            performInitialRefresh: true
        )
        apply(snapshot)
        state.notice =
            AntigravitySettingsNoticePresenter.notice(
                for: snapshot
            )
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
        state.notice =
            AntigravitySettingsNoticePresenter.notice(
                for: snapshot
            )
        state.activity = .idle
        return true
    }

    @discardableResult
    func selectAccount(
        _ accountID: AntigravityAccountID?
    ) async -> Bool {
        guard state.activeAccountID != accountID,
              begin(.changingAccount)
        else {
            return false
        }
        let success = if accountID == nil {
            AntigravitySettingsNotice(
                tone: .success,
                title: "로컬 계정으로 전환했습니다",
                message: "실행 중인 Antigravity 또는 AGY 계정의 사용량을 확인합니다.",
                action: .dismiss
            )
        } else {
            AntigravitySettingsNotice(
                tone: .success,
                title: "Google 계정을 전환했습니다",
                message: "선택한 계정과 일치하는 사용량으로 갱신했습니다.",
                action: .dismiss
            )
        }
        return await performMutation(
            activity: .changingAccount,
            success: success
        ) {
            try await self.accountCommands
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
                try await self.accountCommands
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
        case .failed(let reason):
            // 실제 사유를 버리면 사용자도 로그도 원인을 알 수 없다.
            let detail = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            finishLoginFailure(
                title: "Google 계정을 연결하지 못했습니다",
                message: detail.isEmpty
                    ? "로그인 상태를 확인한 뒤 다시 시도해 주세요."
                    : "\(detail) — 로그인 상태를 확인한 뒤 다시 시도해 주세요."
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
            try await self.accountCommands
                .deleteAccount(accountID)
        }
    }

    @discardableResult
    func deleteAllAccounts() async -> Bool {
        guard begin(.changingAccount) else {
            return false
        }
        let snapshot = await accountCommands
            .removeAllAccounts(interactively: false)
        apply(snapshot)
        state.notice =
            AntigravitySettingsNoticePresenter.notice(
                for: snapshot
            )
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
            try await self.displayCommands
                .update(
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
        state.notice =
            AntigravitySettingsNoticePresenter.notice(
                for: snapshot
            )
        state.activity = .idle
    }

    @discardableResult
    func performInteractiveMigration() async -> Bool {
        guard begin(.migrating) else { return false }
        let snapshot =
            await runtimeController.continueMigration()
        apply(snapshot)
        state.notice =
            AntigravitySettingsNoticePresenter.notice(
                for: snapshot
            )
            ?? AntigravitySettingsNotice(
                tone: .success,
                title: "이전 작업을 완료했습니다",
                message: "Antigravity 계정 정보를 새 저장소로 옮겼습니다.",
                action: .dismiss
            )
        state.activity = .idle
        return AntigravitySettingsNoticePresenter
            .migrationReachedCutover(
                snapshot.migrationStatus
            )
    }

    @discardableResult
    func removeLegacyDataInteractively() async -> Bool {
        guard begin(.migrating) else { return false }
        let snapshot = await runtimeController
            .removeAllAccounts(interactively: true)
        apply(snapshot)
        state.notice =
            AntigravitySettingsNoticePresenter.notice(
                for: snapshot
            )
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
        let snapshot = await displayCommands
            .acknowledgeMigrationNotice()
        apply(snapshot)
        state.notice =
            AntigravitySettingsNoticePresenter.notice(
                for: snapshot
            )
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
                AntigravitySettingsNoticePresenter
                    .refreshOutcomeNotice(
                    snapshot.presentationState
                ) ?? success
            state.activity = .idle
            return true
        } catch {
            state.notice =
                AntigravitySettingsNoticePresenter
                    .mutationFailureNotice(
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
}
