import Foundation
import XCTest
@testable import ClaudeUsage

@MainActor
final class AntigravitySettingsViewModelTests:
    XCTestCase
{
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
        let viewModel = AntigravitySettingsViewModel(
            runtimeController: controller,
            oauthLogin:
                AntigravitySettingsOAuthLoginDouble(
                    mode: .immediate(
                        .init(outcome: .cancelled)
                    )
                )
        )

        await viewModel.load()

        XCTAssertEqual(
            viewModel.state.activeAccountID,
            Self.firstAccountID
        )
        XCTAssertEqual(
            viewModel.state.accounts.map(\.email),
            ["first@example.com", "second@example.com"]
        )
        XCTAssertEqual(
            viewModel.state.connection,
            .default
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
            viewModel.state.activeAccountID,
            Self.secondAccountID
        )
        XCTAssertEqual(
            viewModel.state.connection,
            localConnection
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
        let viewModel = AntigravitySettingsViewModel(
            runtimeController: controller,
            oauthLogin:
                AntigravitySettingsOAuthLoginDouble(
                    mode: .immediate(
                        .init(outcome: .cancelled)
                    )
                )
        )
        await viewModel.load()

        let changed = await viewModel.selectAccount(
            Self.secondAccountID
        )
        let selectedAccountIDs =
            await controller.selectedAccountIDs()

        XCTAssertTrue(changed)
        XCTAssertEqual(
            selectedAccountIDs,
            [Self.secondAccountID]
        )
        XCTAssertEqual(
            viewModel.state.activeAccountID,
            Self.secondAccountID
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
        let viewModel = AntigravitySettingsViewModel(
            runtimeController: controller,
            oauthLogin:
                AntigravitySettingsOAuthLoginDouble(
                    mode: .immediate(
                        .init(outcome: .cancelled)
                    )
                )
        )
        await viewModel.load()

        let changed = await viewModel.selectAccount(
            Self.secondAccountID
        )

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

    func testSuccessfulLoginHandsCredentialsDirectlyToController()
        async
    {
        let credentials = AntigravityOAuthCredentials(
            accessToken: "access-secret",
            refreshToken: "refresh-secret",
            expiryDate: Date(
                timeIntervalSince1970: 1_900_000_000
            ),
            idToken: "id-secret",
            email: "new@example.com",
            projectID: "project-secret",
            clientID: "client-secret-id",
            clientSecret: "client-secret-value"
        )
        let initial = Self.snapshot(
            activeAccountID: Self.firstAccountID
        )
        let connected = Self.snapshot(
            activeAccountID: Self.secondAccountID,
            revision: 8
        )
        let controller =
            AntigravitySettingsRuntimeControllerDouble(
                snapshot: initial,
                connectResult: connected
            )
        let login =
            AntigravitySettingsOAuthLoginDouble(
                mode: .immediate(
                    .init(outcome: .success(credentials))
                )
            )
        let viewModel = AntigravitySettingsViewModel(
            runtimeController: controller,
            oauthLogin: login
        )
        await viewModel.load()

        let changed = await viewModel.addAccount()
        let calls = await controller.connectCalls()

        XCTAssertTrue(changed)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.credentials, credentials)
        XCTAssertEqual(
            calls.first?.label,
            "new@example.com"
        )
        XCTAssertEqual(
            viewModel.state.activeAccountID,
            Self.secondAccountID
        )
        let publicDescription =
            String(reflecting: viewModel.state)
        XCTAssertFalse(
            publicDescription.contains("access-secret")
        )
        XCTAssertFalse(
            publicDescription.contains("refresh-secret")
        )
        XCTAssertFalse(
            publicDescription.contains("client-secret")
        )
        viewModel.stopObserving()
    }

    func testExplicitLoginCancellationDoesNotConnectAccount()
        async
    {
        let initial = Self.snapshot(
            activeAccountID: Self.firstAccountID
        )
        let controller =
            AntigravitySettingsRuntimeControllerDouble(
                snapshot: initial
            )
        let login =
            AntigravitySettingsOAuthLoginDouble(
                mode: .suspendUntilCancelled
            )
        let viewModel = AntigravitySettingsViewModel(
            runtimeController: controller,
            oauthLogin: login
        )
        await viewModel.load()

        let action = Task {
            await viewModel.addAccount()
        }
        await login.waitUntilStarted()
        XCTAssertEqual(
            viewModel.state.activity,
            .authenticating
        )

        viewModel.cancelOAuthLogin()
        let changed = await action.value
        let connectCalls =
            await controller.connectCalls()
        let cancellationCount =
            await login.cancellationCount()

        XCTAssertFalse(changed)
        XCTAssertTrue(connectCalls.isEmpty)
        XCTAssertEqual(
            cancellationCount,
            1
        )
        XCTAssertEqual(viewModel.state.activity, .idle)
        XCTAssertEqual(
            viewModel.state.notice?.tone,
            .warning
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
            AntigravityConnectionSettings = .default,
        revision: UInt64 = 7
    ) -> AntigravityRuntimeSnapshot {
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
            activeAccountID: activeAccountID,
            settings: AntigravitySettingsSnapshot(
                connection: connection,
                display: .default
            ),
            presentationState: .disabled,
            quotaPresentation:
                .unavailable(.disabled),
            managedRuntimeAvailability: .available(
                displayPath: "~/.local/bin/agy"
            ),
            lastAttemptAt: nil,
            lastSuccessfulAt: nil
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
    struct ConnectCall: Sendable, Equatable {
        let credentials: AntigravityOAuthCredentials
        let label: String?
    }

    private var current: AntigravityRuntimeSnapshot
    private let selectResult:
        AntigravityRuntimeSnapshot?
    private let selectError:
        AntigravityRuntimeControllerError?
    private let connectResult:
        AntigravityRuntimeSnapshot?
    private var bootstrapCalls: [Bool] = []
    private var selections:
        [AntigravityAccountID?] = []
    private var connections: [ConnectCall] = []
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
            AntigravityRuntimeControllerError? = nil,
        connectResult:
            AntigravityRuntimeSnapshot? = nil
    ) {
        current = snapshot
        self.selectResult = selectResult
        self.selectError = selectError
        self.connectResult = connectResult
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

    func selectAccount(
        _ accountID: AntigravityAccountID?
    ) async throws -> AntigravityRuntimeSnapshot {
        selections.append(accountID)
        if let selectError {
            throw selectError
        }
        if let selectResult {
            publish(selectResult)
        }
        return current
    }

    func connectAccount(
        credentials: AntigravityOAuthCredentials,
        label: String?
    ) async throws -> AntigravityRuntimeSnapshot {
        connections.append(
            ConnectCall(
                credentials: credentials,
                label: label
            )
        )
        if let connectResult {
            publish(connectResult)
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

    func connectCalls() -> [ConnectCall] {
        connections
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

private actor AntigravitySettingsOAuthLoginDouble:
    AntigravitySettingsOAuthLoggingIn
{
    enum Mode: Sendable {
        case immediate(
            AntigravityOAuthLoginRunner.Result
        )
        case suspendUntilCancelled
    }

    private let mode: Mode
    private var didStart = false
    private var startWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var cancelledCount = 0

    init(mode: Mode) {
        self.mode = mode
    }

    func login() async
        -> AntigravityOAuthLoginRunner.Result
    {
        didStart = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()

        switch mode {
        case .immediate(let result):
            return result
        case .suspendUntilCancelled:
            do {
                try await Task.sleep(
                    nanoseconds: 60_000_000_000
                )
                return .init(outcome: .timedOut)
            } catch {
                cancelledCount += 1
                return .init(outcome: .cancelled)
            }
        }
    }

    func waitUntilStarted() async {
        if didStart {
            return
        }
        await withCheckedContinuation {
            continuation in
            startWaiters.append(continuation)
        }
    }

    func cancellationCount() -> Int {
        cancelledCount
    }
}
