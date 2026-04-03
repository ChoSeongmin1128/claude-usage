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

    func testApplyFailureKeepsPayloadAndHidesTemporaryErrorWhileGraceWindowRemains() {
        var state = RuntimeProviderState(
            payload: .claude(
                ClaudeUsageResponse(
                    fiveHour: UsageWindow(utilization: 24, resetsAt: nil),
                    sevenDay: nil
                )
            ),
            isLoading: true,
            loadingStartedAt: Date(),
            consecutiveErrorCount: 1
        )

        let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
            state: &state,
            error: .networkError("timeout"),
            minimumInterval: 30,
            clearPayloadAfterTemporaryFailures: 3,
            hideTemporaryErrorWhilePayloadAvailable: true
        )

        XCTAssertNotNil(state.payload)
        XCTAssertNil(state.error)
        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(state.consecutiveErrorCount, 2)
        XCTAssertNotNil(resolution.nextAllowedAt)
        XCTAssertNotNil(resolution.backoffSeconds)
    }

    func testApplyFailureClearsPayloadAfterRepeatedTemporaryFailures() {
        var state = RuntimeProviderState(
            payload: .claude(
                ClaudeUsageResponse(
                    fiveHour: UsageWindow(utilization: 24, resetsAt: nil),
                    sevenDay: nil
                )
            ),
            consecutiveErrorCount: 2
        )

        _ = RuntimeProviderRefreshCoordinator.applyFailure(
            state: &state,
            error: .networkError("timeout"),
            minimumInterval: 30,
            clearPayloadAfterTemporaryFailures: 3
        )

        XCTAssertNil(state.payload)
        XCTAssertEqual(state.error?.errorDescription, APIError.networkError("timeout").errorDescription)
    }
}

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
}
