import XCTest
@testable import ClaudeUsage

private final class LayoutEventRecorder {
    var events: [(PopoverService, PopoverLayoutRefreshReason)] = []
}

final class RefreshOrchestrationTests: XCTestCase {
    func testActionForTabSwitchRefreshesWhenStateIsStale() {
        let state = RuntimeProviderPresentationState(
            service: .claude,
            lastUpdated: Date(timeIntervalSinceNow: -400),
            hasContent: true,
            error: nil
        )

        let action = RefreshOrchestration.actionForTabSwitch(
            state: state,
            refreshInterval: 120
        )

        guard case let .refresh(service, force)? = action else {
            return XCTFail("예상한 refresh action이 아닙니다")
        }

        XCTAssertEqual(service, .claude)
        XCTAssertFalse(force)
    }

    func testActionForEnabledChangePromptsAuthForClaudeWithoutCredential() {
        let action = RefreshOrchestration.actionForEnabledChange(
            state: RuntimeProviderActivationState(
                service: .claude,
                enabled: true,
                hasCredential: false
            )
        )

        guard case let .clearAndPromptAuth(service) = action else {
            return XCTFail("Claude는 자격이 없으면 인증 유도로 가야 합니다")
        }

        XCTAssertEqual(service, .claude)
    }

    func testActionForEnabledChangeRefreshesAntigravityImmediately() {
        let action = RefreshOrchestration.actionForEnabledChange(
            state: RuntimeProviderActivationState(
                service: .antigravity,
                enabled: true,
                hasCredential: false
            )
        )

        guard case let .refresh(service, force) = action else {
            return XCTFail("Antigravity는 활성화 직후 refreshNow여야 합니다")
        }

        XCTAssertEqual(service, .antigravity)
        XCTAssertTrue(force)
    }

    func testPrepareForRefreshSkipsDuringBackoff() {
        var state = RuntimeProviderState(
            nextRefreshAllowedAt: Date(timeIntervalSinceNow: 20)
        )

        let preparation = RuntimeProviderRefreshCoordinator.prepareForRefresh(
            state: &state,
            force: false
        )

        guard case let .skip(reason) = preparation else {
            return XCTFail("백오프 중이면 skip 되어야 합니다")
        }
        guard case .backoff = reason else {
            return XCTFail("skip reason은 backoff여야 합니다")
        }
        XCTAssertFalse(state.isLoading)
    }

    func testApplyFailureKeepsPayloadForTemporaryFailure() {
        var state = RuntimeProviderState(
            payload: sampleClaudePayload,
            isLoading: true,
            loadingStartedAt: Date()
        )

        let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
            state: &state,
            error: .networkError("timeout"),
            minimumInterval: 30
        )

        XCTAssertNotNil(state.payload)
        XCTAssertEqual(state.error?.errorDescription, APIError.networkError("timeout").errorDescription)
        XCTAssertEqual(state.lastAttemptState, .temporaryFailure)
        XCTAssertFalse(state.isLoading)
        XCTAssertNotNil(resolution.nextAllowedAt)
        XCTAssertNotNil(resolution.backoffSeconds)
    }

    func testTemporaryFailureKeepsSuccessfulProvenanceAndRecordsAttempt() {
        let successfulMetadata = RuntimeProviderFetchMetadata(
            sourceLabel: "브라우저 로그인",
            accountID: "account-a",
            attemptedSourceLabels: ["브라우저 로그인"]
        )
        let attemptMetadata = RuntimeProviderFetchMetadata(
            sourceLabel: "브라우저 로그인",
            accountID: "account-a",
            attemptedSourceLabels: ["브라우저 로그인"]
        )
        var state = RuntimeProviderState()

        RuntimeProviderRefreshCoordinator.applySuccess(
            state: &state,
            payload: sampleClaudePayload,
            metadata: successfulMetadata
        )
        XCTAssertEqual(state.lastSuccessfulMetadata, successfulMetadata)

        _ = RuntimeProviderRefreshCoordinator.prepareForRefresh(state: &state, force: true)
        let loadingSnapshot = RuntimeProviderSnapshot(
            service: .claude,
            payload: state.payload,
            error: state.error,
            isLoading: state.isLoading,
            lastUpdated: state.lastUpdated,
            credentialState: .usable,
            isDetected: true,
            canAttemptRefresh: true,
            hasAuthError: false,
            lastAttemptState: state.lastAttemptState,
            lastSuccessfulMetadata: state.lastSuccessfulMetadata,
            lastAttemptMetadata: state.lastAttemptMetadata
        )
        XCTAssertEqual(loadingSnapshot.freshness, .loading)

        _ = RuntimeProviderRefreshCoordinator.applyFailure(
            state: &state,
            error: .networkError("timeout"),
            metadata: attemptMetadata,
            minimumInterval: 30
        )

        XCTAssertNotNil(state.payload)
        XCTAssertEqual(state.lastSuccessfulMetadata, successfulMetadata)
        XCTAssertEqual(state.lastAttemptMetadata, attemptMetadata)

        let staleSnapshot = RuntimeProviderSnapshot(
            service: .claude,
            payload: state.payload,
            error: state.error,
            isLoading: state.isLoading,
            lastUpdated: state.lastUpdated,
            nextRefreshAllowedAt: state.nextRefreshAllowedAt,
            credentialState: .usable,
            isDetected: true,
            canAttemptRefresh: true,
            hasAuthError: state.hasAuthError,
            lastAttemptState: state.lastAttemptState,
            lastSuccessfulMetadata: state.lastSuccessfulMetadata,
            lastAttemptMetadata: state.lastAttemptMetadata
        )
        XCTAssertEqual(staleSnapshot.freshness, .stale)
        XCTAssertEqual(staleSnapshot.fetchState, .temporaryFailure)
    }

    func testApplyFailureClearsPayloadForDefinitiveAuthFailure() {
        var state = RuntimeProviderState(
            payload: sampleClaudePayload
        )

        _ = RuntimeProviderRefreshCoordinator.applyFailure(
            state: &state,
            error: .invalidSessionKey,
            minimumInterval: 30
        )

        XCTAssertNil(state.payload)
        XCTAssertEqual(state.lastAttemptState, .authFailure)
        XCTAssertTrue(state.hasAuthError)
    }

    func testApplyFailureKeepsPayloadForDefinitiveNonAuthFailure() {
        // 비인증 definitive 실패(4xx, 스키마 변경 등)는 마지막 성공 데이터를 유지한다.
        // 메뉴바/팝오버가 갑자기 에러 카드로 뒤집히는 대신 stale 표시 + 갱신 지연 안내.
        var state = RuntimeProviderState(
            payload: sampleClaudePayload
        )

        _ = RuntimeProviderRefreshCoordinator.applyFailure(
            state: &state,
            error: .unknownError("boom"),
            minimumInterval: 30
        )

        XCTAssertNotNil(state.payload)
        XCTAssertEqual(state.lastAttemptState, .definitiveFailure)
        XCTAssertFalse(state.hasAuthError)
    }

    func testClearedStateMarksCodexAuthFailureWhenUnauthenticated() {
        let state = RuntimeProviderRefreshCoordinator.clearedState(
            service: .codex,
            isCodexAuthenticated: false,
            requiresInteractiveSetup: false
        )

        XCTAssertEqual(state.lastAttemptState, .authFailure)
        XCTAssertTrue(state.hasAuthError)
        XCTAssertEqual(state.error?.errorDescription, APIError.invalidSessionKey.errorDescription)
    }

    func testClearedStateMarksLocalProviderAuthFailureWhenInteractiveSetupRequired() {
        let state = RuntimeProviderRefreshCoordinator.clearedState(
            service: .antigravity,
            isCodexAuthenticated: true,
            requiresInteractiveSetup: true
        )

        XCTAssertEqual(state.lastAttemptState, .authFailure)
        XCTAssertTrue(state.hasAuthError)
        XCTAssertEqual(state.error?.errorDescription, APIError.invalidSessionKey.errorDescription)
    }

    func testActionForTabSwitchRefreshesWithCachedPayloadAndRecoverableFailure() {
        let state = RuntimeProviderPresentationState(
            service: .codex,
            lastUpdated: Date(),
            hasContent: true,
            error: .networkError("timeout"),
            lastAttemptState: .temporaryFailure,
            nextRefreshAllowedAt: Date(timeIntervalSinceNow: 20)
        )

        let action = RefreshOrchestration.actionForTabSwitch(
            state: state,
            refreshInterval: 120
        )

        guard case let .refresh(service, force)? = action else {
            return XCTFail("recoverable stale 상태는 refresh 대상이어야 합니다")
        }

        XCTAssertEqual(service, .codex)
        XCTAssertFalse(force)
    }

    func testActionForTabSwitchSkipsFreshSuccessfulPayload() {
        let state = RuntimeProviderPresentationState(
            service: .claude,
            lastUpdated: Date(),
            hasContent: true,
            error: nil,
            lastAttemptState: .idle
        )

        let action = RefreshOrchestration.actionForTabSwitch(
            state: state,
            refreshInterval: 120
        )

        XCTAssertNil(action)
    }
}

@MainActor
final class PopoverViewModelTests: XCTestCase {
    func testUpdateDoesNotRequestLayoutRefreshForDataOnlySnapshotUpdate() async {
        let events = await MainActor.run { () -> [(PopoverService, PopoverLayoutRefreshReason)] in
            let recorder = LayoutEventRecorder()
            let viewModel = PopoverViewModel()
            viewModel.onLayoutChanged = { service, reason in
                recorder.events.append((service, reason))
            }

            viewModel.update(
                snapshots: [
                    RuntimeProviderSnapshot(
                        service: .antigravity,
                        payload: nil,
                        error: nil,
                        isLoading: false,
                        lastUpdated: Date(),
                        nextRefreshAllowedAt: nil,
                        credentialState: .refreshable,
                        isDetected: true,
                        canAttemptRefresh: true,
                        hasAuthError: false
                    )
                ]
            )
            return recorder.events
        }

        XCTAssertTrue(events.isEmpty)
    }

    func testResolveAntigravitySummaryStateTreatsCLIAsUsageSource() {
        let state = PopoverViewModel.resolveAntigravitySummaryState(
            snapshot: RuntimeProviderSnapshot(
                service: .antigravity,
                payload: nil,
                error: nil,
                isLoading: false,
                lastUpdated: nil,
                nextRefreshAllowedAt: nil,
                credentialState: .refreshable,
                isDetected: true,
                canAttemptRefresh: true,
                hasAuthError: false
            ),
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .refreshable,
                runtimeReachability: false,
                refreshReachability: true,
                summary: "Antigravity 사용량 조회 준비"
            ),
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: false,
                hasCLIBinary: true,
                appRunning: false,
                runningProcess: nil,
                hasAuthStatus: false,
                hasOAuthToken: false
            ),
            isEnabled: true,
            isAuthRequired: false
        )

        XCTAssertEqual(state.phase, .probingRuntime)
        XCTAssertEqual(state.summary, "사용량 조회 준비")
    }

    func testResolveAntigravitySummaryStateTreatsBrokenCLIAsRepairNeed() {
        let state = PopoverViewModel.resolveAntigravitySummaryState(
            snapshot: RuntimeProviderSnapshot(
                service: .antigravity,
                payload: nil,
                error: nil,
                isLoading: false,
                lastUpdated: nil,
                nextRefreshAllowedAt: nil,
                credentialState: .missing,
                isDetected: true,
                canAttemptRefresh: false,
                hasAuthError: false
            ),
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .missing,
                runtimeReachability: false,
                summary: "Antigravity CLI 복구 필요"
            ),
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: false,
                cliBinaryStatus: .broken(
                    path: "/opt/homebrew/bin/agy",
                    target: "/Applications/Antigravity.app/Contents/Resources/app/bin/antigravity"
                ),
                appRunning: false,
                runningProcess: nil,
                hasAuthStatus: false,
                hasOAuthToken: false
            ),
            isEnabled: true,
            isAuthRequired: false
        )

        XCTAssertEqual(state.phase, .authRequired)
        XCTAssertEqual(state.summary, "CLI 복구 필요")
    }

    func testResolveAntigravitySummaryStateDoesNotClaimCLIIncludedWhenOAuthReadyButCLIIsBroken() {
        let state = PopoverViewModel.resolveAntigravitySummaryState(
            snapshot: RuntimeProviderSnapshot(
                service: .antigravity,
                payload: nil,
                error: nil,
                isLoading: false,
                lastUpdated: nil,
                nextRefreshAllowedAt: nil,
                credentialState: .usable,
                isDetected: true,
                canAttemptRefresh: true,
                hasAuthError: false
            ),
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .usable,
                runtimeReachability: false,
                refreshReachability: true,
                summary: "Antigravity 계정 연결됨 · CLI 복구 필요"
            ),
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: false,
                cliBinaryStatus: .broken(
                    path: "/opt/homebrew/bin/agy",
                    target: "/Applications/Antigravity.app/Contents/Resources/app/bin/antigravity"
                ),
                appRunning: false,
                runningProcess: nil,
                hasAuthStatus: false,
                hasOAuthToken: false,
                oauthCredentialStatus: AntigravityOAuthCredentialStatus(
                    hasCredential: true,
                    email: "nathan@example.com",
                    sourceDescription: "ClaudeUsage OAuth"
                )
            ),
            isEnabled: true,
            isAuthRequired: false
        )

        XCTAssertEqual(state.phase, .probingRuntime)
        XCTAssertEqual(state.summary, "계정 확인됨 · CLI 복구 필요")
    }

    func testResolveAntigravitySummaryStateDoesNotClaimSeparateCLIUsageSourceWhenOAuthReady() {
        let state = PopoverViewModel.resolveAntigravitySummaryState(
            snapshot: RuntimeProviderSnapshot(
                service: .antigravity,
                payload: nil,
                error: nil,
                isLoading: false,
                lastUpdated: nil,
                nextRefreshAllowedAt: nil,
                credentialState: .usable,
                isDetected: true,
                canAttemptRefresh: true,
                hasAuthError: false
            ),
            environmentStatus: ProviderEnvironmentStatus(
                isDetected: true,
                credentialState: .usable,
                runtimeReachability: false,
                refreshReachability: true,
                summary: "Antigravity 계정 연결됨"
            ),
            signals: AntigravityEnvironmentSignals(
                hasStateDirectory: false,
                hasCLIBinary: true,
                hasCLISettingsFile: true,
                appRunning: false,
                runningProcess: nil,
                hasAuthStatus: false,
                hasOAuthToken: false,
                oauthCredentialStatus: AntigravityOAuthCredentialStatus(
                    hasCredential: true,
                    email: "nathan@example.com",
                    sourceDescription: "ClaudeUsage OAuth"
                )
            ),
            isEnabled: true,
            isAuthRequired: false
        )

        XCTAssertEqual(state.phase, .probingRuntime)
        XCTAssertEqual(state.summary, "계정 확인됨 · 사용량 조회 준비")
        XCTAssertFalse(state.summary.contains("CLI 포함"))
        XCTAssertFalse(state.summary.contains("CLI 사용량 포함"))
    }

    func testResolveAntigravitySummaryStateGoogleOAuthModeIgnoresAppPersistedAuth() async {
        let state = await MainActor.run {
            PopoverViewModel.resolveAntigravitySummaryState(
                snapshot: RuntimeProviderSnapshot(
                    service: .antigravity,
                    payload: nil,
                    error: nil,
                    isLoading: false,
                    lastUpdated: nil,
                    nextRefreshAllowedAt: nil,
                    credentialState: .unknown,
                    isDetected: true,
                    canAttemptRefresh: false,
                    hasAuthError: false
                ),
                environmentStatus: ProviderEnvironmentStatus(
                    isDetected: true,
                    credentialState: .unknown,
                    runtimeReachability: false,
                    summary: "Antigravity 인증 상태 감지 · 앱을 실행하면 조회를 시작합니다"
                ),
                signals: AntigravityEnvironmentSignals(
                    hasStateDirectory: true,
                    appRunning: false,
                    runningProcess: nil,
                    hasAuthStatus: true,
                    hasOAuthToken: false
                ),
                isEnabled: true,
                isAuthRequired: false
            )
        }
        let (phase, summary) = await MainActor.run { (state.phase, state.summary) }

        XCTAssertEqual(phase, .waitingForApp)
        XCTAssertEqual(summary, "앱 실행 후 연결 확인 중")
    }

    func testResolveAntigravitySummaryStateGoogleOAuthModeUsesRuntimeConnectionWhenAvailable() async {
        let state = await MainActor.run {
            PopoverViewModel.resolveAntigravitySummaryState(
                snapshot: RuntimeProviderSnapshot(
                    service: .antigravity,
                    payload: nil,
                    error: nil,
                    isLoading: false,
                    lastUpdated: nil,
                    nextRefreshAllowedAt: nil,
                    credentialState: .refreshable,
                    isDetected: true,
                    canAttemptRefresh: true,
                    hasAuthError: false
                ),
                environmentStatus: ProviderEnvironmentStatus(
                    isDetected: true,
                    credentialState: .refreshable,
                    runtimeReachability: true,
                    summary: "Antigravity 연결 확인됨"
                ),
                signals: AntigravityEnvironmentSignals(
                    hasStateDirectory: true,
                    appRunning: true,
                    runningProcess: AntigravityProcessSnapshot(
                        pid: 42,
                        command: "language_server --csrf_token token",
                        csrfToken: "token",
                        extensionPort: nil,
                        extensionCsrfToken: nil,
                        httpsServerPort: nil,
                        cloudCodeEndpoint: "https://daily-cloudcode-pa.googleapis.com"
                    ),
                    hasAuthStatus: true,
                    hasOAuthToken: false
                ),
                isEnabled: true,
                isAuthRequired: false
            )
        }
        let (phase, summary) = await MainActor.run { (state.phase, state.summary) }

        XCTAssertEqual(phase, .probingRuntime)
        XCTAssertEqual(summary, "앱 연결 확인 중")
    }

    func testResolveAntigravitySummaryStateShowsOAuthReconnectWhenStoredCredentialIsRejected() async {
        let state = await MainActor.run {
            PopoverViewModel.resolveAntigravitySummaryState(
                snapshot: RuntimeProviderSnapshot(
                    service: .antigravity,
                    payload: nil,
                    error: .invalidSessionKey,
                    isLoading: false,
                    lastUpdated: nil,
                    nextRefreshAllowedAt: nil,
                    credentialState: .usable,
                    isDetected: true,
                    canAttemptRefresh: true,
                    hasAuthError: true
                ),
                environmentStatus: ProviderEnvironmentStatus(
                    isDetected: true,
                    credentialState: .usable,
                    runtimeReachability: false,
                    refreshReachability: true,
                    summary: "Antigravity 계정 연결됨"
                ),
                signals: AntigravityEnvironmentSignals(
                    hasStateDirectory: false,
                    hasCLIBinary: true,
                    appRunning: false,
                    runningProcess: nil,
                    hasAuthStatus: false,
                    hasOAuthToken: false,
                    oauthCredentialStatus: AntigravityOAuthCredentialStatus(
                        hasCredential: true,
                        email: "nathan@example.com",
                        sourceDescription: "ClaudeUsage OAuth"
                    )
                ),
                isEnabled: true,
                isAuthRequired: false
            )
        }
        let (phase, summary) = await MainActor.run { (state.phase, state.summary) }

        XCTAssertEqual(phase, .authRequired)
        XCTAssertEqual(summary, "Google 계정 다시 연결 필요")
    }

    func testRequestLayoutRefreshEmitsOnlyExplicitReasons() async {
        let events = await MainActor.run { () -> [(PopoverService, PopoverLayoutRefreshReason)] in
            let recorder = LayoutEventRecorder()
            let viewModel = PopoverViewModel()
            viewModel.onLayoutChanged = { service, reason in
                recorder.events.append((service, reason))
            }

            viewModel.requestLayoutRefresh(reason: .compactToggle)
            viewModel.requestLayoutRefresh(for: .antigravity, reason: .serviceSelection)
            return recorder.events
        }

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].0, .claude)
        XCTAssertEqual(events[0].1, .compactToggle)
        XCTAssertEqual(events[1].0, .antigravity)
        XCTAssertEqual(events[1].1, .serviceSelection)
    }

    func testSelectServiceSkipsDuplicateSelectionCallbacks() async {
        let events = await MainActor.run { () -> [PopoverService] in
            final class SelectionRecorder {
                var events: [PopoverService] = []
            }

            let recorder = SelectionRecorder()
            let viewModel = PopoverViewModel()
            viewModel.onServiceSelected = { service in
                recorder.events.append(service)
            }

            viewModel.selectService(.claude)
            viewModel.selectService(.antigravity)
            viewModel.selectService(.antigravity)
            return recorder.events
        }

        XCTAssertEqual(events, [.antigravity])
    }

    func testResolveAntigravitySummaryStateKeepsPersistedAuthOutOfReady() async {
        let state = await MainActor.run {
            PopoverViewModel.resolveAntigravitySummaryState(
                snapshot: RuntimeProviderSnapshot(
                    service: .antigravity,
                    payload: nil,
                    error: nil,
                    isLoading: false,
                    lastUpdated: nil,
                    nextRefreshAllowedAt: nil,
                    credentialState: .unknown,
                    isDetected: true,
                    canAttemptRefresh: false,
                    hasAuthError: false
                ),
                environmentStatus: ProviderEnvironmentStatus(
                    isDetected: true,
                    credentialState: .unknown,
                    runtimeReachability: false,
                    summary: "Antigravity 인증 상태 감지 · 앱을 실행하면 조회를 시작합니다"
                ),
                signals: AntigravityEnvironmentSignals(
                    hasStateDirectory: true,
                    appRunning: false,
                    runningProcess: nil,
                    hasAuthStatus: true,
                    hasOAuthToken: false
                ),
                isEnabled: true,
                isAuthRequired: false
            )
        }
        let (phase, summary) = await MainActor.run { (state.phase, state.summary) }

        XCTAssertEqual(phase, .waitingForApp)
        XCTAssertEqual(summary, "앱 실행 후 연결 확인 중")
    }

    func testContentPhaseKeepsContentForStalePayloadWithTemporaryFailure() async {
        let result = await MainActor.run { () -> (PopoverContentPhase, PopoverViewModel.RuntimeServiceState) in
            let settings = AppSettings.shared
            let previousEnabled = settings.isProviderEnabled(.claude)
            settings.setProviderEnabled(true, for: .claude)
            defer { settings.setProviderEnabled(previousEnabled, for: .claude) }

            let viewModel = PopoverViewModel()
            viewModel.update(
                snapshots: [
                    RuntimeProviderSnapshot(
                        service: .claude,
                        payload: sampleClaudePayload,
                        error: .networkError("timeout"),
                        isLoading: false,
                        lastUpdated: Date(timeIntervalSinceNow: -180),
                        nextRefreshAllowedAt: Date(timeIntervalSinceNow: 20),
                        credentialState: .usable,
                        isDetected: true,
                        canAttemptRefresh: true,
                        hasAuthError: false,
                        lastAttemptState: .temporaryFailure
                    )
                ]
            )

            return (
                viewModel.contentPhase(for: .claude, settings: settings),
                viewModel.runtimeServiceState(for: .claude, settings: settings)
            )
        }

        XCTAssertEqual(result.0, .content)
        XCTAssertTrue(result.1.summary.contains("현재 24%"))
        XCTAssertEqual(result.1.meta?.contains("재시도 대기"), true)
    }

    func testContentPhaseShowsAuthRequiredWhenNoPayloadAndAuthFailure() async {
        let phase = await MainActor.run { () -> PopoverContentPhase in
            let settings = AppSettings.shared
            let previousEnabled = settings.isProviderEnabled(.claude)
            settings.setProviderEnabled(true, for: .claude)
            defer { settings.setProviderEnabled(previousEnabled, for: .claude) }

            let viewModel = PopoverViewModel()
            viewModel.update(
                snapshots: [
                    RuntimeProviderSnapshot(
                        service: .claude,
                        payload: nil,
                        error: .invalidSessionKey,
                        isLoading: false,
                        lastUpdated: nil,
                        nextRefreshAllowedAt: nil,
                        credentialState: .missing,
                        isDetected: false,
                        canAttemptRefresh: false,
                        hasAuthError: true,
                        lastAttemptState: .authFailure
                    )
                ]
            )

            return viewModel.contentPhase(for: .claude, settings: settings)
        }

        XCTAssertEqual(phase, .authRequired)
    }

    func testContentPhaseShowsErrorWhenNoPayloadAndTemporaryFailure() async {
        let phase = await MainActor.run { () -> PopoverContentPhase in
            let settings = AppSettings.shared
            let previousEnabled = settings.isProviderEnabled(.claude)
            settings.setProviderEnabled(true, for: .claude)
            defer { settings.setProviderEnabled(previousEnabled, for: .claude) }

            let viewModel = PopoverViewModel()
            viewModel.update(
                snapshots: [
                    RuntimeProviderSnapshot(
                        service: .claude,
                        payload: nil,
                        error: .networkError("timeout"),
                        isLoading: false,
                        lastUpdated: nil,
                        nextRefreshAllowedAt: Date(timeIntervalSinceNow: 20),
                        credentialState: .usable,
                        isDetected: true,
                        canAttemptRefresh: true,
                        hasAuthError: false,
                        lastAttemptState: .temporaryFailure
                    )
                ]
            )

            return viewModel.contentPhase(for: .claude, settings: settings)
        }

        XCTAssertEqual(phase, .error)
    }

    func testDisplaySectionsHideAntigravityAccountByDefault() async {
        let result = await MainActor.run { () -> ([PopoverDisplaySection], [PopoverDisplaySection]) in
            let viewModel = PopoverViewModel()
            let payload = AntigravityUsageResponse(
                accountEmail: "user@example.com",
                accountPlan: "Workspace",
                primaryWindow: AntigravityUsageWindow(label: "Gemini 3.1 Pro (Low)", modelID: "gemini-3.1-pro-low", usedPercent: 24, resetAtISO: nil),
                secondaryWindow: AntigravityUsageWindow(label: "Gemini 3.5 Flash (Medium)", modelID: "gemini-3.5-flash-medium", usedPercent: 11, resetAtISO: nil),
                tertiaryWindow: nil
            )
            viewModel.update(
                snapshots: [
                    RuntimeProviderSnapshot(
                        service: .antigravity,
                        payload: .antigravity(payload),
                        error: nil,
                        isLoading: false,
                        lastUpdated: Date(),
                        nextRefreshAllowedAt: nil,
                        credentialState: .usable,
                        isDetected: true,
                        canAttemptRefresh: true,
                        hasAuthError: false
                    )
                ]
            )

            return (
                viewModel.displaySections(for: .antigravity, density: .standard, settings: .shared),
                viewModel.displaySections(for: .antigravity, density: .compact, settings: .shared)
            )
        }

        XCTAssertEqual(result.0.count, 2)
        XCTAssertEqual(result.0.map(\.kind), [.usage, .usage])
        XCTAssertEqual(result.1.count, 2)
        XCTAssertEqual(result.1.map(\.kind), [.usage, .usage])
    }

    func testDisplaySectionsShowAntigravityQuotaMissingStatusForIdentityOnlyUsage() async {
        let result = await MainActor.run { () -> ([PopoverDisplaySection], [PopoverDisplaySection]) in
            let viewModel = PopoverViewModel()
            let payload = AntigravityUsageResponse(
                source: .googleOAuth,
                accountEmail: "user@example.com",
                accountPlan: "Workspace",
                primaryWindow: nil,
                secondaryWindow: nil,
                tertiaryWindow: nil
            )
            viewModel.update(
                snapshots: [
                    RuntimeProviderSnapshot(
                        service: .antigravity,
                        payload: .antigravity(payload),
                        error: nil,
                        isLoading: false,
                        lastUpdated: Date(),
                        nextRefreshAllowedAt: nil,
                        credentialState: .usable,
                        isDetected: true,
                        canAttemptRefresh: true,
                        hasAuthError: false
                    )
                ]
            )

            return (
                viewModel.displaySections(for: .antigravity, density: .standard, settings: .shared),
                viewModel.displaySections(for: .antigravity, density: .compact, settings: .shared)
            )
        }

        XCTAssertEqual(result.0.first?.id, "antigravityQuotaStatus")
        XCTAssertEqual(result.0.first?.kind, .status)
        if case .status(let status)? = result.0.first?.payload {
            XCTAssertEqual(status.title, "계정 확인됨")
            XCTAssertEqual(status.statusText, "수치 미지원")
            XCTAssertTrue(status.message?.contains("계정과 플랜은 확인됐지만") == true)
        } else {
            XCTFail("Expected status payload")
        }
        XCTAssertEqual(result.1.first?.id, "antigravityQuotaStatus")
        XCTAssertEqual(result.1.first?.kind, .status)
    }

    func testDisplaySectionsKeepCodexVisibleItemsAcrossDensitiesWhenCompactConfigShared() async {
        let result = await MainActor.run { () -> ([String], [String], [PopoverDisplaySectionKind]) in
            let settings = AppSettings.shared
            let snapshot = settings.createSnapshot()
            defer { settings.restore(from: snapshot) }

            settings.separateCompactConfig = false
            settings.setPopoverItems(
                makePopoverItems(
                    ("codexPrimary", true),
                    ("codexSecondary", true),
                    ("codexCredits", true)
                ),
                for: .codex
            )
            settings.setCompactPopoverItems(
                makePopoverItems(
                    ("codexPrimary", true),
                    ("codexSecondary", false),
                    ("codexCredits", false)
                ),
                for: .codex
            )

            let viewModel = PopoverViewModel()
            viewModel.update(
                snapshots: [
                    RuntimeProviderSnapshot(
                        service: .codex,
                        payload: .codex(makeCodexUsageResponse(primary: 42, secondary: nil, creditsBalance: nil)),
                        error: nil,
                        isLoading: false,
                        lastUpdated: Date(),
                        nextRefreshAllowedAt: nil,
                        credentialState: .usable,
                        isDetected: true,
                        canAttemptRefresh: true,
                        hasAuthError: false
                    )
                ]
            )

            let standardSections = viewModel.displaySections(for: .codex, density: .standard, settings: settings)
            let compactSections = viewModel.displaySections(for: .codex, density: .compact, settings: settings)
            return (
                standardSections.map(\.id),
                compactSections.map(\.id),
                compactSections.map(\.kind)
            )
        }

        // 사용량 응답이 정상인데 secondary 창·credits 필드가 없으면 해당 행을 숨긴다
        // (데이터 없음 카드 금지)
        XCTAssertEqual(result.0, ["codexPrimary"])
        XCTAssertEqual(result.1, result.0)
        XCTAssertEqual(result.2, [.usage])
    }

    func testDisplaySectionsUseProviderCompactConfigWhenSeparated() async {
        let result = await MainActor.run { () -> ([String], [String]) in
            let settings = AppSettings.shared
            let snapshot = settings.createSnapshot()
            defer { settings.restore(from: snapshot) }

            settings.separateCompactConfig = true
            settings.setPopoverItems(
                makePopoverItems(
                    ("codexPrimary", true),
                    ("codexSecondary", true),
                    ("codexCredits", true)
                ),
                for: .codex
            )
            settings.setCompactPopoverItems(
                makePopoverItems(
                    ("codexPrimary", false),
                    ("codexSecondary", true),
                    ("codexCredits", false)
                ),
                for: .codex
            )

            let viewModel = PopoverViewModel()
            viewModel.update(
                snapshots: [
                    RuntimeProviderSnapshot(
                        service: .codex,
                        payload: .codex(makeCodexUsageResponse(primary: 42, secondary: nil, creditsBalance: nil)),
                        error: nil,
                        isLoading: false,
                        lastUpdated: Date(),
                        nextRefreshAllowedAt: nil,
                        credentialState: .usable,
                        isDetected: true,
                        canAttemptRefresh: true,
                        hasAuthError: false
                    )
                ]
            )

            let standardSections = viewModel.displaySections(for: .codex, density: .standard, settings: settings)
            let compactSections = viewModel.displaySections(for: .codex, density: .compact, settings: settings)
            return (
                standardSections.map(\.id),
                compactSections.map(\.id)
            )
        }

        XCTAssertEqual(result.0, ["codexPrimary"])
        // compact 는 codexSecondary 만 표시하도록 설정했지만 응답에 secondary 창이 없어 숨김
        XCTAssertEqual(result.1, [])
    }

    func testLayoutSpecUsesDisplaySectionsForAntigravitySecondaryWindow() async {
        let size = await MainActor.run { () -> CGSize in
            let settings = AppSettings.shared
            let snapshot = settings.createSnapshot()
            defer { settings.restore(from: snapshot) }

            settings.popoverCompact = false
            let viewModel = PopoverViewModel()
            let payload = AntigravityUsageResponse(
                accountEmail: "user@example.com",
                accountPlan: "Workspace",
                primaryWindow: AntigravityUsageWindow(label: "Gemini 3.1 Pro (Low)", modelID: "gemini-3.1-pro-low", usedPercent: 24, resetAtISO: nil),
                secondaryWindow: AntigravityUsageWindow(label: "Gemini 3.5 Flash (Medium)", modelID: "gemini-3.5-flash-medium", usedPercent: 11, resetAtISO: nil),
                tertiaryWindow: nil
            )
            viewModel.update(
                snapshots: [
                    RuntimeProviderSnapshot(
                        service: .antigravity,
                        payload: .antigravity(payload),
                        error: nil,
                        isLoading: false,
                        lastUpdated: Date(),
                        nextRefreshAllowedAt: nil,
                        credentialState: .usable,
                        isDetected: true,
                        canAttemptRefresh: true,
                        hasAuthError: false
                    )
                ]
            )

            return viewModel.layoutSpec(for: .antigravity, settings: settings).size
        }

        XCTAssertEqual(size.width, 368)
        XCTAssertEqual(size.height, 256)
    }

    func testGlobalCompactSettingDrivesAllProviderLayouts() async {
        let result = await MainActor.run { () -> (PopoverDensity, PopoverDensity) in
            let settings = AppSettings.shared
            let snapshot = settings.createSnapshot()
            defer { settings.restore(from: snapshot) }

            settings.popoverCompact = true
            settings.setProviderEnabled(true, for: .claude)
            settings.setProviderEnabled(true, for: .codex)

            let viewModel = PopoverViewModel()
            return (
                viewModel.layoutSpec(for: .claude, settings: settings).density,
                viewModel.layoutSpec(for: .codex, settings: settings).density
            )
        }

        XCTAssertEqual(result.0, .compact)
        XCTAssertEqual(result.1, .compact)
    }
}

private let sampleClaudePayload: RuntimeProviderPayload = .claude(
    ClaudeUsageResponse(
        fiveHour: UsageWindow(utilization: 24, resetsAt: nil),
        sevenDay: UsageWindow(utilization: 35, resetsAt: nil)
    )
)

private func makeCodexUsageResponse(
    primary: Double?,
    secondary: Double?,
    creditsBalance: Double?
) -> CodexUsageResponse {
    var payload: [String: Any] = [:]
    var rateLimit: [String: Any] = [:]

    if let primary {
        rateLimit["primary_window"] = [
            "used_percent": primary,
            "reset_at": 1_700_000_000,
        ]
    }

    if let secondary {
        rateLimit["secondary_window"] = [
            "used_percent": secondary,
            "reset_at": 1_700_086_400,
        ]
    }

    if !rateLimit.isEmpty {
        payload["rate_limit"] = rateLimit
    }

    if let creditsBalance {
        payload["credits"] = [
            "has_credits": true,
            "unlimited": false,
            "balance": creditsBalance,
        ]
    }

    let data = try! JSONSerialization.data(withJSONObject: payload)
    return try! JSONDecoder().decode(CodexUsageResponse.self, from: data)
}

private func makePopoverItems(_ items: (String, Bool)...) -> [PopoverItemConfig] {
    items.map { PopoverItemConfig(id: $0.0, visible: $0.1) }
}
