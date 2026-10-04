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

    func updateDisplay(
        _ display: AntigravityDisplaySettings,
        replacing expectedDisplay:
            AntigravityDisplaySettings
    ) async throws -> AntigravityRuntimeSnapshot

    func consumePendingSettingsNotice() async
        -> AntigravityRuntimeSnapshot
}

extension AntigravityRuntimeController:
    AntigravitySettingsRuntimeControlling
{}

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
        case changingConnection
        case changingDisplay

        var isBusy: Bool {
            self != .idle
        }
    }

    var activity: Activity
    var connection: AntigravityConnectionSettings?
    var display: AntigravityDisplaySettings?
    var presentation: AntigravityPresentationState
    var quotaPresentation:
        AntigravityQuotaPresentationMappingResult
    var managedRuntimeAvailability:
        AntigravityManagedRuntimeAvailability
    var notice: AntigravitySettingsNotice?
    var lastAttemptAt: Date? = nil
    var publicationRevision: UInt64 = 0

    var usageTarget: AntigravityUsageTarget {
        connection?.usageTarget ?? .unselected
    }

    static let initial = AntigravitySettingsViewState(
        activity: .idle,
        connection: nil,
        display: nil,
        presentation: .disabled,
        quotaPresentation: .unavailable(.disabled),
        managedRuntimeAvailability: .unavailable(
            reason: .executableNotFound
        ),
        notice: nil
    )
}

/// Settings-only projection of whether ClaudeUsage may run the verified AGY
/// CLI for usage reports.
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
                    "설치됨 (\(displayPath))"
            )
        case .unavailable(let reason):
            switch reason {
            case .executableNotFound:
                return Self(
                    diagnosticTitle:
                        "설치 안 됨"
                )
            case .signatureRejected:
                return Self(
                    diagnosticTitle:
                        "서명 확인 실패"
                )
            }
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
/// Settings and refresh actors are deliberately not exposed here, so the
/// settings window cannot interleave its own transaction with AppDelegate
/// refreshes.
@MainActor
final class AntigravitySettingsViewModel:
    ObservableObject
{
    @Published private(set) var state =
        AntigravitySettingsViewState.initial

    private let runtimeController:
        any AntigravitySettingsRuntimeControlling
    private let displayCommands:
        AntigravityDisplaySettingsCommandAdapter
    private var observationTask:
        Task<Void, Never>?
    init(
        runtimeController:
            any AntigravitySettingsRuntimeControlling
    ) {
        self.runtimeController = runtimeController
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
        state.publicationRevision = snapshot.publicationRevision
        state.connection =
            snapshot.settings?.connection
        state.display = snapshot.settings?.display
        state.presentation =
            snapshot.presentationState
        state.lastAttemptAt = snapshot.lastAttemptAt
        state.quotaPresentation =
            snapshot.quotaPresentation
        state.managedRuntimeAvailability =
            snapshot.managedRuntimeAvailability
        return true
    }

}
