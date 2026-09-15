import Combine
import Foundation

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

    func selectTarget(_ selection: AntigravityUsageTarget) async throws -> AntigravityRuntimeSnapshot

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
        case changingTarget
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
    var lastAttemptAt: Date? = nil
    var publicationRevision: UInt64 = 0

    var usageTarget: AntigravityUsageTarget {
        connection?.usageTarget ?? .unselected
    }

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
/// Repository/settings/migration actors are deliberately not
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
    private let accountCommands:
        AntigravityAccountCommandCoordinator
    private let displayCommands:
        AntigravityDisplaySettingsCommandAdapter
    private var observationTask:
        Task<Void, Never>?
    init(
        runtimeController:
            any AntigravitySettingsRuntimeControlling
    ) {
        self.runtimeController = runtimeController
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
        if apply(snapshot) {
            state.notice = AntigravitySettingsNoticePresenter.notice(for: snapshot)
        }
        state.activity = .idle
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    @discardableResult
    func refresh() async -> Bool {
        guard begin(.loading) else { return false }
        let snapshot = await runtimeController.refresh(
            trigger: .manual
        )
        if apply(snapshot) {
            state.notice = AntigravitySettingsNoticePresenter.notice(for: snapshot)
        }
        state.activity = .idle
        return true
    }

    @discardableResult
    func selectTarget(_ selection: AntigravityUsageTarget) async -> Bool {
        guard state.usageTarget != selection, begin(.changingTarget) else { return false }
        return await performMutation(
            activity: .changingTarget,
            success: AntigravitySettingsNotice(
                tone: .success, title: "조회 대상을 선택했습니다",
                message: "선택한 제품에 로그인된 계정의 사용량을 표시합니다.", action: .dismiss)
        ) {
            try await accountCommands.selectTarget(selection)
        }
    }

    @discardableResult
    func deleteAccount(
        _ accountID: AntigravityAccountID
    ) async -> Bool {
        guard begin(.changingTarget) else {
            return false
        }
        return await performMutation(
            activity: .changingTarget,
            success: AntigravitySettingsNotice(
                tone: .success,
                title: "이전 연결 정보를 삭제했습니다",
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
        guard begin(.changingTarget) else {
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
                title: "이전 연결 정보를 모두 삭제했습니다",
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

        }
    }

    private func startObservationIfNeeded() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self, runtimeController] in
            let stream = await runtimeController.snapshots()
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
            if apply(snapshot) {
                state.notice =
                    AntigravitySettingsNoticePresenter.refreshOutcomeNotice(snapshot.presentationState) ?? success
            }
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

    @discardableResult
    private func apply(
        _ snapshot: AntigravityRuntimeSnapshot
    ) -> Bool {
        guard snapshot.publicationRevision >= state.publicationRevision else { return false }
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
        state.publicationRevision = snapshot.publicationRevision
        state.connection =
            snapshot.settings?.connection
        state.display = snapshot.settings?.display
        state.migrationStatus =
            snapshot.migrationStatus
        state.presentation =
            snapshot.presentationState
        state.lastAttemptAt = snapshot.lastAttemptAt
        state.quotaPresentation =
            snapshot.quotaPresentation
        state.managedRuntimeAvailability =
            snapshot.managedRuntimeAvailability
        state.repositoryRevision =
            snapshot.repositoryRevision
        return true
    }

}
