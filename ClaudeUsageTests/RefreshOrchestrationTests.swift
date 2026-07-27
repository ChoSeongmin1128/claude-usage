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

    func testResolveAntigravitySummaryStateUsesTypedDisabledStateAsRefreshReady() {
        let state = PopoverViewModel.resolveAntigravitySummaryState(
            snapshot: antigravityRuntimeSnapshot(),
            isEnabled: true
        )

        XCTAssertEqual(state.phase, .probingRuntime)
        XCTAssertEqual(state.summary, "사용량 조회 준비")
    }

    func testResolveAntigravitySummaryStateTreatsManagedRecoveryBlockAsBootstrapAttention() {
        let state = PopoverViewModel.resolveAntigravitySummaryState(
            snapshot: antigravityRuntimeSnapshot(
                readiness:
                    .blocked(.managedRuntimeRecovery),
                presentationState:
                    .failed(
                        .sourceUnavailable(.managedCLI)
                    ),
                managedRuntimeAvailability:
                    .recoveryBlocked
            ),
            isEnabled: true
        )

        XCTAssertEqual(state.phase, .temporaryError)
        XCTAssertEqual(state.summary, "초기 설정 확인 필요")
    }

    func testResolveAntigravitySummaryStateDoesNotMergeManagedFailureIntoIdentityOnlySource() {
        let identity = ProviderAccountIdentity(
            stableAccountID: "subject-a",
            email: "nathan@example.com"
        )
        let state = PopoverViewModel.resolveAntigravitySummaryState(
            snapshot: antigravityRuntimeSnapshot(
                presentationState:
                    .identityOnly(
                        AntigravityIdentityOnlyUsage(
                            identity: identity,
                            plan: "Workspace",
                            provenance:
                                antigravityProvenance(
                                    identity: identity
                                ),
                            fetchedAt:
                                Self.referenceDate
                        )
                    ),
                managedRuntimeAvailability:
                    .recoveryBlocked
            ),
            isEnabled: true
        )

        XCTAssertEqual(state.phase, .temporaryError)
        XCTAssertEqual(
            state.summary,
            "계정 확인됨 · 수치 미지원"
        )
        XCTAssertFalse(state.summary.contains("CLI"))
    }

    func testResolveAntigravitySummaryStateDoesNotInventSeparateCLISourceForReadyQuota() {
        let state = PopoverViewModel.resolveAntigravitySummaryState(
            snapshot: antigravityRuntimeSnapshot(
                presentationState:
                    .ready(antigravityQuotaSnapshot())
            ),
            isEnabled: true
        )

        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(state.summary, "2개 사용량 한도")
        XCTAssertFalse(state.summary.contains("CLI"))
    }

    func testResolveAntigravitySummaryStateUsesTypedSetupRequirementForMissingSelection() {
        let state = PopoverViewModel.resolveAntigravitySummaryState(
            snapshot: antigravityRuntimeSnapshot(
                presentationState:
                    .setupRequired(
                        .noSelectedOAuthAccount
                    )
            ),
            isEnabled: true
        )

        XCTAssertEqual(state.phase, .authRequired)
        XCTAssertEqual(state.summary, "연결 설정 필요")
    }

    func testResolveAntigravitySummaryStateUsesTypedRefreshingState() {
        let state = PopoverViewModel.resolveAntigravitySummaryState(
            snapshot: antigravityRuntimeSnapshot(
                presentationState:
                    .refreshing(previous: nil)
            ),
            isEnabled: true
        )

        XCTAssertEqual(state.phase, .loading)
        XCTAssertEqual(state.summary, "사용량 확인 중")
    }

    func testResolveAntigravitySummaryStateShowsReconnectForTypedAuthenticationFailure() {
        let state = PopoverViewModel.resolveAntigravitySummaryState(
            snapshot: antigravityRuntimeSnapshot(
                presentationState:
                    .failed(
                        .authenticationRequired(
                            .googleOAuth
                        )
                    )
            ),
            isEnabled: true
        )

        XCTAssertEqual(state.phase, .authRequired)
        XCTAssertEqual(
            state.summary,
            "Google 계정 다시 연결 필요"
        )
    }

    func testResolveAntigravitySummaryStateDoesNotPromoteAccountMetadataToReady() {
        let accountID = AntigravityAccountID(
            rawValue:
                "00000000-0000-0000-0000-000000000001"
        )
        let identity = ProviderAccountIdentity(
            stableAccountID: "subject-a",
            email: "nathan@example.com"
        )
        let state = PopoverViewModel.resolveAntigravitySummaryState(
            snapshot: antigravityRuntimeSnapshot(
                accounts: [
                    AntigravityRuntimeAccountSummary(
                        id: accountID,
                        label: "Nathan",
                        identity: identity,
                        isActive: true
                    ),
                ],
                activeAccountID: accountID
            ),
            isEnabled: true
        )

        XCTAssertEqual(state.phase, .probingRuntime)
        XCTAssertEqual(state.summary, "사용량 조회 준비")
    }

    private func antigravityRuntimeSnapshot(
        readiness:
            AntigravityRuntimeReadiness = .ready,
        presentationState:
            AntigravityPresentationState = .disabled,
        managedRuntimeAvailability:
            AntigravityManagedRuntimeAvailability =
                .available,
        accounts:
            [AntigravityRuntimeAccountSummary] = [],
        activeAccountID:
            AntigravityAccountID? = nil
    ) -> AntigravityRuntimeSnapshot {
        let settings = AntigravitySettingsSnapshot(
            connection: .default,
            display: .default
        )
        return AntigravityRuntimeSnapshot(
            readiness: readiness,
            migrationStatus: nil,
            repositoryRevision: 7,
            accounts: accounts,
            activeAccountID: activeAccountID,
            settings: settings,
            presentationState: presentationState,
            quotaPresentation:
                AntigravityQuotaPresentationMapper.map(
                    state: presentationState,
                    settings: settings.display,
                    now: Self.referenceDate
                ),
            managedRuntimeAvailability:
                managedRuntimeAvailability,
            lastAttemptAt: Self.referenceDate,
            lastSuccessfulAt: nil
        )
    }

    private func antigravityQuotaSnapshot()
        -> AntigravityQuotaSnapshot
    {
        let identity = ProviderAccountIdentity(
            stableAccountID: "subject-a",
            email: "nathan@example.com"
        )
        return AntigravityQuotaSnapshot(
            identity: identity,
            plan: "Workspace",
            lanes: [
                AntigravityQuotaLane(
                    id: .geminiFiveHour,
                    upstreamGroupID: "gemini",
                    upstreamBucketID: "five-hour",
                    scope: .gemini,
                    cadence: .fiveHour,
                    remainingFraction: 0.7,
                    resetAt:
                        Self.referenceDate
                            .addingTimeInterval(3_600),
                    resetDescription: nil,
                    availability: .available
                ),
                AntigravityQuotaLane(
                    id: .geminiWeekly,
                    upstreamGroupID: "gemini",
                    upstreamBucketID: "weekly",
                    scope: .gemini,
                    cadence: .weekly,
                    remainingFraction: 0.5,
                    resetAt:
                        Self.referenceDate
                            .addingTimeInterval(86_400),
                    resetDescription: nil,
                    availability: .available
                ),
            ],
            decodeIssues: [],
            provenance:
                antigravityProvenance(
                    identity: identity
                ),
            fetchedAt: Self.referenceDate
        )
    }

    private func antigravityProvenance(
        identity: ProviderAccountIdentity
    ) -> AntigravityQuotaProvenance {
        AntigravityQuotaProvenance(
            transport: .googleOAuth,
            endpointOwner: .external,
            accountIdentity: identity,
            capability: .groupedQuotaSummary,
            processIdentity: nil
        )
    }

    private static let referenceDate =
        Date(timeIntervalSince1970: 1_900_000_000)

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

    /// AGY v2는 동적 lane 경로로만 그린다. legacy `UsageItemCatalog`가 AGY 항목을
    /// 되살리면 같은 수치가 두 경로로 중복 렌더링되므로 경계를 고정한다.
    func testAntigravityQuotaNeverProducesLegacyCatalogDisplaySections() {
        let viewModel = PopoverViewModel()
        let identity = ProviderAccountIdentity(
            stableAccountID: "subject-a",
            email: "nathan@example.com"
        )
        let states: [AntigravityPresentationState] = [
            .ready(antigravityQuotaSnapshot()),
            .identityOnly(
                AntigravityIdentityOnlyUsage(
                    identity: identity,
                    plan: "Workspace",
                    provenance: antigravityProvenance(identity: identity),
                    fetchedAt: Self.referenceDate
                )
            ),
        ]

        for state in states {
            viewModel.antigravityRuntimeSnapshot = antigravityRuntimeSnapshot(
                presentationState: state
            )
            for density in [PopoverDensity.standard, .compact] {
                XCTAssertTrue(
                    viewModel.displaySections(
                        for: .antigravity,
                        density: density,
                        settings: .shared
                    ).isEmpty
                )
            }
        }
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

    /// AGY 팝오버 높이는 legacy 섹션 수가 아니라 실제 quota lane 수에서 나온다.
    func testLayoutSpecSizesAntigravityFromQuotaLanesNotLegacySections() {
        let settings = AppSettings.shared
        let snapshot = settings.createSnapshot()
        defer { settings.restore(from: snapshot) }

        settings.popoverCompact = false
        settings.setProviderEnabled(true, for: .antigravity)
        let viewModel = PopoverViewModel()
        viewModel.antigravityRuntimeSnapshot = antigravityRuntimeSnapshot(
            presentationState: .ready(antigravityQuotaSnapshot())
        )

        XCTAssertEqual(
            viewModel.contentPhase(for: .antigravity, settings: settings),
            .content
        )
        XCTAssertTrue(
            viewModel.displaySections(
                for: .antigravity,
                density: .standard,
                settings: settings
            ).isEmpty
        )

        let lanedSize = viewModel.layoutSpec(for: .antigravity, settings: settings).size
        viewModel.antigravityRuntimeSnapshot = antigravityRuntimeSnapshot()
        let quotaFreeSize = viewModel.layoutSpec(for: .antigravity, settings: settings).size

        XCTAssertEqual(lanedSize.width, 368)
        XCTAssertGreaterThan(lanedSize.height, quotaFreeSize.height)
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
