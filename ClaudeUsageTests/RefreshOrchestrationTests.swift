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

    func testActionForEnabledChangeRefreshesGeminiImmediately() {
        let action = RefreshOrchestration.actionForEnabledChange(
            state: RuntimeProviderActivationState(
                service: .gemini,
                enabled: true,
                hasCredential: false
            )
        )

        guard case let .refresh(service, force) = action else {
            return XCTFail("Gemini는 활성화 직후 refreshNow여야 합니다")
        }

        XCTAssertEqual(service, .gemini)
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

    func testApplyFailureClearsPayloadForDefinitiveNonAuthFailure() {
        var state = RuntimeProviderState(
            payload: sampleClaudePayload
        )

        _ = RuntimeProviderRefreshCoordinator.applyFailure(
            state: &state,
            error: .unknownError("boom"),
            minimumInterval: 30
        )

        XCTAssertNil(state.payload)
        XCTAssertEqual(state.lastAttemptState, .definitiveFailure)
        XCTAssertFalse(state.hasAuthError)
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
                        service: .gemini,
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

    func testRequestLayoutRefreshEmitsOnlyExplicitReasons() async {
        let events = await MainActor.run { () -> [(PopoverService, PopoverLayoutRefreshReason)] in
            let recorder = LayoutEventRecorder()
            let viewModel = PopoverViewModel()
            viewModel.onLayoutChanged = { service, reason in
                recorder.events.append((service, reason))
            }

            viewModel.requestLayoutRefresh(reason: .compactToggle)
            viewModel.requestLayoutRefresh(for: .gemini, reason: .serviceSelection)
            return recorder.events
        }

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].0, .claude)
        XCTAssertEqual(events[0].1, .compactToggle)
        XCTAssertEqual(events[1].0, .gemini)
        XCTAssertEqual(events[1].1, .serviceSelection)
    }

    func testResolveGeminiSummaryStateKeepsRefreshOnlyFirstFetchOutOfReady() async {
        let state = await MainActor.run {
            PopoverViewModel.resolveGeminiSummaryState(
                snapshot: RuntimeProviderSnapshot(
                    service: .gemini,
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
                    summary: "Gemini CLI OAuth 감지 · 액세스 토큰은 갱신이 필요합니다"
                ),
                signals: GeminiEnvironmentSignals(
                    hasBinary: true,
                    authType: .oauthPersonal,
                    credentialState: .refreshOnly
                ),
                isEnabled: true,
                isAuthRequired: false
            )
        }
        let (phase, summary) = await MainActor.run { (state.phase, state.summary) }

        XCTAssertEqual(phase, .refreshingCredential)
        XCTAssertEqual(summary, "토큰 갱신 후 연결 확인 중")
    }

    func testResolveGeminiSummaryStatePrefersBackoffBeforeReadyPromotion() async {
        let state = await MainActor.run {
            PopoverViewModel.resolveGeminiSummaryState(
                snapshot: RuntimeProviderSnapshot(
                    service: .gemini,
                    payload: nil,
                    error: nil,
                    isLoading: false,
                    lastUpdated: nil,
                    nextRefreshAllowedAt: Date(timeIntervalSinceNow: 15),
                    credentialState: .refreshable,
                    isDetected: true,
                    canAttemptRefresh: true,
                    hasAuthError: false
                ),
                environmentStatus: ProviderEnvironmentStatus(
                    isDetected: true,
                    credentialState: .refreshable,
                    runtimeReachability: true,
                    summary: "Gemini CLI OAuth 감지 · 액세스 토큰은 갱신이 필요합니다"
                ),
                signals: GeminiEnvironmentSignals(
                    hasBinary: true,
                    authType: .oauthPersonal,
                    credentialState: .refreshOnly
                ),
                isEnabled: true,
                isAuthRequired: false
            )
        }
        let (phase, summary) = await MainActor.run { (state.phase, state.summary) }

        XCTAssertEqual(phase, .backoff)
        XCTAssertTrue(summary.contains("후 다시 시도"))
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
}

private let sampleClaudePayload: RuntimeProviderPayload = .claude(
    ClaudeUsageResponse(
        fiveHour: UsageWindow(utilization: 24, resetsAt: nil),
        sevenDay: UsageWindow(utilization: 35, resetsAt: nil)
    )
)
