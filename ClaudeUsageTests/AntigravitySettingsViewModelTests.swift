import Foundation
import XCTest
@testable import ClaudeUsage

@MainActor
final class AntigravitySettingsViewModelTests:
    XCTestCase
{
    func testLateLocalSnapshotCannotOverwriteNewSelectionWithSameOAuthRepositoryRevision() async {
        var connection = AntigravityConnectionSettings.default
        connection.usageTarget = .cli
        var initial = Self.snapshot(activeAccountID: Self.firstAccountID, connection: connection)
        initial.publicationRevision = 10
        let controller = AntigravitySettingsRuntimeControllerDouble(snapshot: initial)
        let viewModel = AntigravitySettingsViewModel(runtimeController: controller)
        await viewModel.load()
        connection.usageTarget = .app
        var newer = Self.snapshot(activeAccountID: Self.firstAccountID, connection: connection)
        newer.publicationRevision = 12
        await controller.publish(newer)
        await waitUntil { viewModel.state.publicationRevision == 12 }
        initial.publicationRevision = 11
        await controller.publish(initial)
        _ = await viewModel.refresh()
        XCTAssertEqual(viewModel.state.usageTarget, .app)
        XCTAssertEqual(viewModel.state.publicationRevision, 12)
        viewModel.stopObserving()
    }

    func testLoadProjectsBootstrapSnapshotAndSubsequentStreamSnapshot()
        async
    {
        let initial = Self.snapshot(
            activeAccountID: Self.firstAccountID,
            connection: .default
        )
        let controller =
            AntigravitySettingsRuntimeControllerDouble(
                snapshot: initial
            )
        let viewModel = AntigravitySettingsViewModel(runtimeController: controller)

        await viewModel.load()

        XCTAssertEqual(
            viewModel.state.usageTarget,
            .cli
        )
        XCTAssertEqual(
            viewModel.state.accounts.map(\.email),
            ["first@example.com", "second@example.com"]
        )
        XCTAssertEqual(
            viewModel.state.connection,
            initial.settings?.connection
        )
        XCTAssertEqual(viewModel.state.activity, .idle)
        let bootstrapArguments =
            await controller.bootstrapArguments()
        XCTAssertEqual(
            bootstrapArguments,
            [true]
        )

        var localConnection =
            AntigravityConnectionSettings.default
        localConnection.usageTarget = .app
        localConnection.managedSession
            .idleTimeoutSeconds = 240
        let streamed = Self.snapshot(
            activeAccountID: Self.secondAccountID,
            connection: localConnection,
            revision: 9
        )
        await controller.publish(streamed)
        await waitUntil {
            viewModel.state.repositoryRevision == 9
        }

        XCTAssertEqual(
            viewModel.state.usageTarget,
            .app
        )
        XCTAssertEqual(
            viewModel.state.connection,
            streamed.settings?.connection
        )
        viewModel.stopObserving()
    }

    func testSelectDelegatesOnceAndProjectsReturnedSnapshot()
        async
    {
        let initial = Self.snapshot(
            activeAccountID: Self.firstAccountID
        )
        let selected = Self.snapshot(
            activeAccountID: Self.secondAccountID,
            revision: 8
        )
        let controller =
            AntigravitySettingsRuntimeControllerDouble(
                snapshot: initial,
                selectResult: selected
            )
        let viewModel = AntigravitySettingsViewModel(runtimeController: controller)
        await viewModel.load()

        let changed = await viewModel.selectTarget(.app)
        let selectedAccountIDs =
            await controller.selectedTargets()

        XCTAssertTrue(changed)
        XCTAssertEqual(
            selectedAccountIDs,
            [.app]
        )
        XCTAssertEqual(
            viewModel.state.usageTarget,
            .app
        )
        XCTAssertEqual(
            viewModel.state.repositoryRevision,
            8
        )
        XCTAssertEqual(
            viewModel.state.notice?.tone,
            .success
        )
        viewModel.stopObserving()
    }

    func testSupersededSelectionDoesNotReportSuccess()
        async
    {
        let controller =
            AntigravitySettingsRuntimeControllerDouble(
                snapshot: Self.snapshot(
                    activeAccountID:
                        Self.firstAccountID
                ),
                selectError: .operationSuperseded
            )
        let viewModel = AntigravitySettingsViewModel(runtimeController: controller)
        await viewModel.load()

        let changed = await viewModel.selectTarget(.app)

        XCTAssertFalse(changed)
        XCTAssertEqual(
            viewModel.state.notice?.tone,
            .failure
        )
        XCTAssertTrue(
            viewModel.state.notice?.message
                .contains("더 최근 작업")
                == true
        )
        XCTAssertNotEqual(
            viewModel.state.notice?.title,
            "Google 계정을 전환했습니다"
        )
        viewModel.stopObserving()
    }

    func testManagedRuntimeNotFoundExplainsInstallationRequirement() {
        let presentation =
            AntigravityManagedRuntimeSettingsPresentation
                .resolve(
                    .unavailable(
                        reason:
                            .executableNotFound
                    )
                )

        XCTAssertEqual(
            presentation.diagnosticTitle,
            "미감지 · AGY CLI 설치 필요"
        )
    }

    func testVerifiedManagedRuntimeShowsExactDetectedPath() {
        let presentation =
            AntigravityManagedRuntimeSettingsPresentation
                .resolve(
                    .available(
                        displayPath:
                            "~/.local/bin/agy"
                    )
                )

        XCTAssertEqual(
            presentation.diagnosticTitle,
            "감지됨 · ~/.local/bin/agy · 필요 시 자동 실행"
        )
    }

    func testRejectedAndRecoveryBlockedStatesRemainDistinct() {
        let rejected =
            AntigravityManagedRuntimeSettingsPresentation
                .resolve(
                    .unavailable(
                        reason:
                            .signatureRejected
                    )
                )
        let recoveryBlocked =
            AntigravityManagedRuntimeSettingsPresentation
                .resolve(
                    .recoveryBlocked(
                        displayPath:
                            "~/.local/bin/agy"
                    )
                )

        XCTAssertEqual(
            rejected.diagnosticTitle,
            "감지됐지만 Google 서명 검증 실패"
        )
        XCTAssertEqual(
            recoveryBlocked.diagnosticTitle,
            "이전 프로세스 복구 실패 · ~/.local/bin/agy · 자동 실행 중단"
        )
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<50 {
            if predicate() {
                return
            }
            await Task.yield()
        }
        XCTFail(
            "Timed out waiting for settings projection",
            file: file,
            line: line
        )
    }

    private static let firstIdentity = ProviderAccountIdentity(
        stableAccountID: "subject-first", email: "first@example.com")
    private static let secondIdentity = ProviderAccountIdentity(
        stableAccountID: "subject-second", email: "second@example.com")

    private static let firstAccountID =
        AntigravityAccountID(
            rawValue:
                "00000000-0000-0000-0000-000000000001"
        )
    private static let secondAccountID =
        AntigravityAccountID(
            rawValue:
                "00000000-0000-0000-0000-000000000002"
        )

    private static func snapshot(
        activeAccountID: AntigravityAccountID,
        connection:
            AntigravityConnectionSettings? = nil,
        revision: UInt64 = 7
    ) -> AntigravityRuntimeSnapshot {
        var resolvedConnection = connection ?? .default
        if connection == nil { resolvedConnection.usageTarget = activeAccountID == firstAccountID ? .cli : .app }
        let accounts = [
            AntigravityRuntimeAccountSummary(
                id: firstAccountID,
                label: "First",
                identity: ProviderAccountIdentity(
                    stableAccountID: "subject-first",
                    email: "first@example.com"
                ),
                isActive:
                    activeAccountID == firstAccountID
            ),
            AntigravityRuntimeAccountSummary(
                id: secondAccountID,
                label: "Second",
                identity: ProviderAccountIdentity(
                    stableAccountID: "subject-second",
                    email: "second@example.com"
                ),
                isActive:
                    activeAccountID == secondAccountID
            ),
        ]
        return AntigravityRuntimeSnapshot(
            readiness: .ready,
            migrationStatus: migrationStatus(),
            repositoryRevision: revision,
            accounts: accounts,
            activeAccountID: nil,
            settings: AntigravitySettingsSnapshot(
                connection: resolvedConnection,
                display: .default
            ),
            presentationState: .disabled,
            quotaPresentation:
                .unavailable(.disabled),
            managedRuntimeAvailability: .available(
                displayPath: "~/.local/bin/agy"
            ),
            lastAttemptAt: nil,
            lastSuccessfulAt: nil,
            publicationRevision: revision
        )
    }

    private static func migrationStatus()
        -> AntigravityMigrationStatus
    {
        AntigravityMigrationStatus(
            phase: .complete,
            sourceOutcomes: [:],
            plannedAccountCount: 0,
            blocker: nil,
            requiredAction: nil,
            authorizationCancelledThisSession: false
        )
    }
}

private actor
    AntigravitySettingsRuntimeControllerDouble:
    AntigravitySettingsRuntimeControlling
{
    private var current: AntigravityRuntimeSnapshot
    private let selectResult:
        AntigravityRuntimeSnapshot?
    private let selectError:
        AntigravityRuntimeControllerError?
    private var bootstrapCalls: [Bool] = []
    private var targetSelections: [AntigravityUsageTarget] = []

    func selectedTargets() -> [AntigravityUsageTarget] { targetSelections }

    private var selections:
        [AntigravityAccountID?] = []
    private var continuations:
        [
            UUID:
                AsyncStream<
                    AntigravityRuntimeSnapshot
                >.Continuation
        ] = [:]

    init(
        snapshot: AntigravityRuntimeSnapshot,
        selectResult:
            AntigravityRuntimeSnapshot? = nil,
        selectError:
            AntigravityRuntimeControllerError? = nil
    ) {
        current = snapshot
        self.selectResult = selectResult
        self.selectError = selectError
    }

    func snapshot() async
        -> AntigravityRuntimeSnapshot
    {
        current
    }

    func snapshots() async
        -> AsyncStream<AntigravityRuntimeSnapshot>
    {
        let id = UUID()
        return AsyncStream(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            continuations[id] = continuation
            continuation.yield(current)
            continuation.onTermination = {
                @Sendable [weak self] _ in
                Task {
                    await self?.removeContinuation(id)
                }
            }
        }
    }

    func bootstrap(
        performInitialRefresh: Bool
    ) async -> AntigravityRuntimeSnapshot {
        bootstrapCalls.append(performInitialRefresh)
        return current
    }

    func refresh(
        trigger: AntigravityRefreshTrigger
    ) async -> AntigravityRuntimeSnapshot {
        current
    }

    func selectTarget(_ selection: AntigravityUsageTarget) async throws -> AntigravityRuntimeSnapshot {
        targetSelections.append(selection)
        if let selectError {
            throw selectError
        }
        if let selectResult {
            publish(selectResult)
        }
        return current
    }

    func deleteAccount(
        _ accountID: AntigravityAccountID
    ) async throws -> AntigravityRuntimeSnapshot {
        current
    }

    func updateDisplay(
        _ display: AntigravityDisplaySettings,
        replacing expectedDisplay:
            AntigravityDisplaySettings
    ) async throws -> AntigravityRuntimeSnapshot {
        current
    }

    func continueMigration() async
        -> AntigravityRuntimeSnapshot
    {
        current
    }

    func removeAllAccounts(
        interactively: Bool
    ) async -> AntigravityRuntimeSnapshot {
        current
    }

    func consumePendingSettingsNotice() async
        -> AntigravityRuntimeSnapshot
    {
        current
    }

    func publish(
        _ snapshot: AntigravityRuntimeSnapshot
    ) {
        current = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    func bootstrapArguments() -> [Bool] {
        bootstrapCalls
    }

    func selectedAccountIDs()
        -> [AntigravityAccountID?]
    {
        selections
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
