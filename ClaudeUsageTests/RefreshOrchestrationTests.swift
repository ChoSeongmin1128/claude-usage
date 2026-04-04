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
            service: .gemini,
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

    func testDisplaySectionsHideSecondaryGeminiAccountInCompact() async {
        let result = await MainActor.run { () -> ([PopoverDisplaySection], [PopoverDisplaySection]) in
            let viewModel = PopoverViewModel()
            let payload = GeminiUsageResponse(
                accountEmail: "user@example.com",
                accountPlan: "Gemini Advanced",
                primaryWindow: GeminiUsageWindow(label: "Pro", modelID: "gemini-pro", usedPercent: 24, resetAtISO: nil),
                secondaryWindow: GeminiUsageWindow(label: "Flash", modelID: "gemini-flash", usedPercent: 11, resetAtISO: nil),
                tertiaryWindow: nil
            )
            viewModel.update(
                snapshots: [
                    RuntimeProviderSnapshot(
                        service: .gemini,
                        payload: .gemini(payload),
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
                viewModel.displaySections(for: .gemini, density: .standard, settings: .shared),
                viewModel.displaySections(for: .gemini, density: .compact, settings: .shared)
            )
        }

        XCTAssertEqual(result.0.count, 3)
        XCTAssertEqual(result.0.map(\.kind), [.usage, .usage, .account])
        XCTAssertEqual(result.1.count, 2)
        XCTAssertEqual(result.1.map(\.kind), [.usage, .usage])
    }

    func testDisplaySectionsKeepCodexVisibleItemsAcrossDensitiesWhenCompactConfigShared() async {
        let result = await MainActor.run { () -> ([String], [PopoverDisplaySectionKind]) in
            let settings = AppSettings.shared
            let snapshot = settings.createSnapshot()
            defer { settings.restore(from: snapshot) }

            settings.separateCompactConfig = false
            settings.codexPopoverItems = PopoverItemConfig.normalizedCodex([
                .init(id: "codexPrimary", visible: true),
                .init(id: "codexSecondary", visible: true),
                .init(id: "codexCredits", visible: true),
            ])

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
                compactSections.map(\.kind)
            )
        }

        XCTAssertEqual(
            result.0,
            ["codexPrimary", "codexSecondary-status", "codexCredits-status"]
        )
        XCTAssertEqual(result.1, [.usage, .status, .status])
    }

    func testPreferredPopoverSizeUsesDisplaySectionsForGeminiSecondaryAccount() async {
        let size = await MainActor.run { () -> CGSize in
            let settings = AppSettings.shared
            let snapshot = settings.createSnapshot()
            defer { settings.restore(from: snapshot) }

            settings.popoverCompact = false
            let viewModel = PopoverViewModel()
            let payload = GeminiUsageResponse(
                accountEmail: "user@example.com",
                accountPlan: "Gemini Advanced",
                primaryWindow: GeminiUsageWindow(label: "Pro", modelID: "gemini-pro", usedPercent: 24, resetAtISO: nil),
                secondaryWindow: GeminiUsageWindow(label: "Flash", modelID: "gemini-flash", usedPercent: 11, resetAtISO: nil),
                tertiaryWindow: nil
            )
            viewModel.update(
                snapshots: [
                    RuntimeProviderSnapshot(
                        service: .gemini,
                        payload: .gemini(payload),
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

            return viewModel.preferredPopoverSize(for: .gemini, settings: settings)
        }

        XCTAssertEqual(size.width, 368)
        XCTAssertEqual(size.height, 300)
    }

    func testGlobalCompactSettingIgnoresProviderSpecificCompactValues() async {
        let result = await MainActor.run { () -> (Bool, Bool, Bool, Bool, Bool, Bool, Bool) in
            let settings = AppSettings.shared
            let snapshot = settings.createSnapshot()
            defer { settings.restore(from: snapshot) }

            settings.popoverCompact = false
            settings.claudePopoverCompact = true
            settings.codexPopoverCompact = true
            UserDefaults.standard.set(true, forKey: "geminiPopoverCompact")
            UserDefaults.standard.set(true, forKey: "antigravityPopoverCompact")

            let before = (
                settings.isPopoverCompact(for: .claude),
                settings.isPopoverCompact(for: .codex),
                settings.isPopoverCompact(for: .gemini),
                settings.isPopoverCompact(for: .antigravity)
            )

            settings.setPopoverCompact(true, for: .codex)

            return (
                before.0,
                before.1,
                before.2,
                before.3,
                settings.popoverCompact,
                settings.claudePopoverCompact,
                settings.codexPopoverCompact
            )
        }

        XCTAssertEqual(result.0, false)
        XCTAssertEqual(result.1, false)
        XCTAssertEqual(result.2, false)
        XCTAssertEqual(result.3, false)
        XCTAssertEqual(result.4, true)
        XCTAssertEqual(result.5, true)
        XCTAssertEqual(result.6, true)
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
