import Foundation

extension AppDelegate {
    // MARK: - Runtime Presentation

    func syncRuntimePresentation() {
        updateMenuBar()
        updatePopoverViewModel()
    }

    func runtimeProviderSnapshots() -> [RuntimeProviderSnapshot] {
        ServiceSelectionHelper.supportedPopoverServices.map(runtimeProviderSnapshot(for:))
    }

    func runtimeProviderSnapshot(for service: PopoverService) -> RuntimeProviderSnapshot {
        return withRuntimeState {
            $0.snapshot(
                for: service,
                codexAuthenticated:
                    CodexAuthManager.shared
                        .isAuthenticated
            )
        }
    }

    func runtimePresentationState(for service: PopoverService) -> RuntimeProviderPresentationState {
        let snapshot = runtimeProviderSnapshot(for: service)
        let hasContent =
            service == .antigravity
                ? currentAntigravityRuntimeSnapshot
                    .hasQuotaContent
                : snapshot.hasContent
        return RuntimeProviderPresentationState(
            service: service,
            lastUpdated: snapshot.lastUpdated,
            hasContent: hasContent,
            error: snapshot.error,
            lastAttemptState: snapshot.lastAttemptState,
            nextRefreshAllowedAt: snapshot.nextRefreshAllowedAt
        )
    }

    func runtimeActivationState(for service: PopoverService, enabled: Bool) -> RuntimeProviderActivationState {
        let snapshot = runtimeProviderSnapshot(for: service)
        return RuntimeProviderActivationState(
            service: service,
            enabled: enabled,
            hasCredential: snapshot.hasCredential
        )
    }

    // MARK: - Monitoring

    func startMonitoring() {
        isLoading = false
        loadingStartedAt = nil
        updateMenuBar()
        updatePopoverViewModel()
        refreshAll(force: true)
        startTimer()
    }

    func stopRefreshTimer() {
        _ = refreshScheduler.stop()
    }

    func syncRefreshTimerState() {
        let change = refreshScheduler.sync(
            autoRefresh: refreshConfiguration.autoRefresh,
            shouldPoll: shouldPollRuntimeProviders,
            intervals: refreshConfiguration.intervals(for: refreshableServices)
        ) { [weak self] dueServices in
            guard let self, self.refreshConfiguration.autoRefresh, self.shouldPollRuntimeProviders else { return }
            for service in dueServices where self.refreshableServices.contains(service) {
                self.performRuntimeAction(.refresh(service: service, force: false))
            }
        }

        switch change {
        case .started(let interval):
            Logger.info("자동 갱신 타이머 시작 (\(Int(interval))초)")
        case .stopped:
            Logger.info("자동 새로고침 비활성화")
        case .unchanged:
            break
        }
    }

    func startTimer() {
        syncRefreshTimerState()
    }

    // MARK: - Observers

    func bindRuntimeObservers() {
        refreshConfiguration = RuntimeRefreshConfiguration(
            settings: .shared, isOnBattery: PowerMonitor.shared.isOnBattery
        )
        lastObservedProviderSelectionState =
            AppSettings.shared.providerSelectionState
        runtimeObservationCoordinator.bind(
            onRefreshConfigurationChanged: { [weak self] configuration in
                guard let self else { return }
                self.refreshConfiguration = configuration
                self.syncRefreshTimerState()
            },
            onUpdateConfigurationChanged: { [weak self] in
                self?.syncUpdateCheckState(runImmediate: true)
            },
            onMenuBarDisplayChanged: { [weak self] in
                self?.updateMenuBar()
            },
            onProviderSelectionChanged: { [weak self] selectionState in
                guard let self else { return }
                let previous =
                    self.lastObservedProviderSelectionState
                    ?? selectionState
                self.lastObservedProviderSelectionState = selectionState
                self.handleProviderSelectionTransition(from: previous, to: selectionState)
            },
            onClaudeCredentialContextChanged: { [weak self] in
                self?.handleClaudeCredentialContextChanged()
            },
            onUsageDisplayModeChanged: { [weak self] in
                guard let self else { return }
                Task { [weak self] in
                    guard let self else { return }
                    let runtime = await antigravityRuntimeTask.value
                    let basis = AppSettings.shared.usageDisplayMode.basis
                    let revision = AppSettings.shared.usageDisplayModeRevision
                    await runtime.runtimeController.setUsageDisplayBasis(basis, revision: revision)
                }
            }
        )
    }

    @discardableResult
    func handleClaudeCredentialContextChanged(
        refreshOAuthCredentialInventory: Bool = false,
        requireUsageValidation: Bool = false
    ) -> Task<Void, Never> {
        let accountState = ClaudeAccountStore.shared.state()
        let requestedAccountID = accountState.activeAccountID
        NotificationManager.shared.updateAccountBoundary(.claude, accountID: requestedAccountID)
        let previousAccountID = withRuntimeState { $0.activeClaudeAccountID }
        let shouldRefreshOAuthCredentialInventory =
            ClaudeCredentialRefreshRequest.shouldRefreshOAuthInventory(
                explicitlyRequested: refreshOAuthCredentialInventory,
                previousAccountID: previousAccountID,
                activeAccount: accountState.activeAccount
            )
        let request = ClaudeCredentialRefreshRequest(
            accountID: requestedAccountID,
            refreshOAuthCredentialInventory: shouldRefreshOAuthCredentialInventory,
            requireUsageValidation: requireUsageValidation
        )
        if let activeRequest = claudeCredentialRefreshRequest,
           activeRequest.satisfies(request),
           let activeTask = claudeCredentialRefreshTask {
            return activeTask
        }

        claudeCredentialRefreshGeneration &+= 1
        let generation = claudeCredentialRefreshGeneration
        claudeCredentialRefreshTask?.cancel()
        claudeUsageRefreshTask?.cancel()
        claudeCredentialRefreshRequest = request
        resetClaudeRuntimeAfterAccountBoundaryChange(refreshHealthSnapshot: false)

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.claudeCredentialRefreshGeneration {
                    self.claudeCredentialRefreshTask = nil
                    self.claudeCredentialRefreshRequest = nil
                }
            }
            await apiService.reloadActiveAccount()

            async let snapshotTask = apiService.fetchUsageHealthSnapshot(
                refreshOAuthCredentialInventory: shouldRefreshOAuthCredentialInventory
            )
            async let metadataTask = apiService.fetchCachedProfileMetadata()
            let snapshot = await snapshotTask
            let cachedProfileMetadata = await metadataTask
            let responseAccountID = await apiService.currentActiveAccountID()
            guard !Task.isCancelled,
                  requestedAccountID == responseAccountID else {
                return
            }
            let usageTask: Task<Void, Never>? = await MainActor.run {
                guard generation == self.claudeCredentialRefreshGeneration else { return nil }
                if snapshot.runtime.credentialAvailability.hasAnyCredential {
                    self.setupWizardCredentialStepOverride = nil
                }
                self.currentClaudeProfileMetadata = cachedProfileMetadata
                self.currentClaudeNotificationPolicy = cachedProfileMetadata.map(ClaudeNotificationPolicy.init(metadata:))
                self.applyUsageHealthSnapshot(snapshot)

                let providerEnabled = ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared)
                if providerEnabled {
                    self.syncRefreshTimerState()
                }
                if ClaudeCredentialRefreshRequest.shouldAttemptUsage(
                    activeAccount: accountState.activeAccount,
                    providerEnabled: providerEnabled,
                    requireUsageValidation: requireUsageValidation
                ) {
                    return self.refreshUsage(
                        force: true,
                        syncHealthAfterCompletion: false,
                        allowWhenDisabled: requireUsageValidation
                    )
                }

                if !snapshot.runtime.credentialAvailability.hasAnyCredential {
                    self.clearClaudePresentationState(markSetupIncomplete: false)
                }
                self.updateMenuBar()
                self.updatePopoverViewModel()
                self.syncRefreshTimerState()
                return nil
            }
            await usageTask?.value
        }
        claudeCredentialRefreshTask = task
        return task
    }

    func handleProviderSelectionTransition(from previous: ProviderSelectionState, to current: ProviderSelectionState) {
        let resolvedService = resolvedPopoverService()
        popoverViewModel.selectedService = resolvedService
        applyPopoverBehavior()

        for kind in ServiceSelectionHelper.supportedProviderKinds {
            let previousEnabled = previous.runtimeEnabledKinds.contains(kind)
            let currentEnabled = current.runtimeEnabledKinds.contains(kind)
            guard previousEnabled != currentEnabled,
                  let service = ServiceSelectionHelper.service(for: kind) else { continue }
            handleProviderEnabledChange(currentEnabled, for: service)
        }

        updatePopoverViewModel()
        startTimer()
        updateMenuBar()
    }

    func handleProviderEnabledChange(_ enabled: Bool, for service: PopoverService) {
        if enabled {
            resetTransientProviderAuthStateIfNeeded(for: service)
        }
        let action = RefreshOrchestration.actionForEnabledChange(
            state: runtimeActivationState(for: service, enabled: enabled)
        )
        performRuntimeAction(action)
    }

    func resetTransientProviderAuthStateIfNeeded(for service: PopoverService) {
        switch service {
        case .claude:
            return
        case .codex:
            if CodexAuthManager.shared.isAuthenticated {
                codexError = nil
                hasCodexAuthError = false
                nextCodexRefreshAllowedAt = nil
            }
        case .antigravity:
            return
        }
    }

    // MARK: - API

    func refreshAll(force: Bool = false) {
        let actions = RefreshOrchestration.actionsForRefreshAll(
            supportedServices: ServiceSelectionHelper.supportedPopoverServices,
            refreshableServices: refreshableServices,
            settings: AppSettings.shared,
            force: force
        )

        for action in actions {
            performRuntimeAction(action)
        }
    }

    func performRuntimeAction(_ action: ProviderRuntimeAction) {
        switch action {
        case .refresh(let service, let force):
            refresh(service: service, force: force)
        case .clearState(let service):
            clearRuntimeServiceState(service)
        case .clearAndPromptAuth(let service):
            clearStateForAuthPrompt(service)
            showSettingsWindow()
        }
    }

    func refresh(service: PopoverService, force: Bool) {
        runtimeRefreshHandlers[service]?(force)
    }

    func clearRuntimeServiceState(_ service: PopoverService) {
        if service == .codex { codexRefreshController.cancel() }
        if service == .antigravity {
            syncRuntimePresentation()
            return
        }

        if service == .claude {
            withRuntimeState { $0.invalidateClaudeRequestContext() }
            popoverViewModel.nextUsageRetryAt = nil
        }

        setRuntimeProviderState(
            RuntimeProviderRefreshCoordinator.clearedState(
                service: service,
                isCodexAuthenticated: CodexAuthManager.shared.isAuthenticated,
                requiresInteractiveSetup: false
            ),
            for: service
        )
    }

    func clearStateForAuthPrompt(_ service: PopoverService) {
        if service == .codex { codexRefreshController.cancel() }
        if service == .antigravity {
            syncRuntimePresentation()
            return
        }

        if service == .claude {
            withRuntimeState { $0.invalidateClaudeRequestContext() }
            popoverViewModel.nextUsageRetryAt = nil
        }

        setRuntimeProviderState(RuntimeProviderState(), for: service)
    }

    func resetClaudeRuntimeAfterAccountBoundaryChange(refreshHealthSnapshot: Bool = true) {
        withRuntimeState { $0.invalidateClaudeRequestContext() }
        popoverViewModel.nextUsageRetryAt = nil
        setRuntimeProviderState(RuntimeProviderState(), for: .claude)
        syncRuntimePresentation()
        if refreshHealthSnapshot {
            syncUsageHealthSnapshotToUI()
        }
    }

    func prepareRefresh(
        for service: PopoverService,
        force: Bool,
        respectBackoffWithoutPayload: Bool = true
    ) -> Bool {
        var state = runtimeProviderState(for: service)
        let preparation = RuntimeProviderRefreshCoordinator.prepareForRefresh(
            state: &state,
            force: force,
            respectBackoffWithoutPayload: respectBackoffWithoutPayload
        )
        setRuntimeProviderState(state, for: service)

        switch preparation {
        case .start:
            if service == .claude {
                popoverViewModel.nextUsageRetryAt = state.nextRefreshAllowedAt
            }
            syncRuntimePresentation()
            return true
        case .skip(.backoff(let remainingSeconds, let nextAllowedAt)):
            Logger.debug("\(service.displayName) 갱신 스킵: 임시 오류 백오프 \(remainingSeconds)초 남음")
            if service == .claude {
                popoverViewModel.nextUsageRetryAt = nextAllowedAt
            }
            return false
        case .skip(.alreadyInFlight):
            Logger.debug("\(service.displayName) 갱신 스킵: 이미 요청 진행 중")
            return false
        }
    }

    @discardableResult
    func refreshUsage(
        force: Bool = false,
        syncHealthAfterCompletion: Bool = true,
        allowWhenDisabled: Bool = false
    ) -> Task<Void, Never>? {
        guard allowWhenDisabled || ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared) else {
            return nil
        }
        guard prepareRefresh(for: .claude, force: force) else { return nil }

        let requestRevision = withRuntimeState { $0.claudeRequestRevision }
        let task = Task { [weak self] in
            guard let self else { return }
            let requestAccountID = await apiService.currentActiveAccountID()
            do {
                Logger.debug("사용량 갱신 시작")
                let result = try await ClaudeRuntimeRefresher.refresh(
                    apiService: apiService,
                    lastOverageFetchAt: self.lastOverageFetchAt
                )
                let cachedProfileMetadata = await self.apiService.fetchCachedProfileMetadata()
                let responseAccountID = await self.apiService.currentActiveAccountID()

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    guard self.withRuntimeState({ $0.claudeRequestRevision }) == requestRevision,
                        requestAccountID == responseAccountID,
                          requestAccountID == result.provenance.accountID else {
                        Logger.info("Claude 계정 귀속이 다른 조회 결과 무시")
                        return
                    }
                    self.currentClaudeProfileMetadata = cachedProfileMetadata
                    self.currentClaudeNotificationPolicy = cachedProfileMetadata.map(ClaudeNotificationPolicy.init(metadata:))
                    if let accountID = result.provenance.accountID {
                        self.withRuntimeState {
                            $0.applyClaudeSupplementalUsage(result.supplementalUsage, accountID: accountID)
                        }
                    }

                    var state = self.runtimeProviderState(for: .claude)
                    RuntimeProviderRefreshCoordinator.applySuccess(
                        state: &state,
                        payload: .claude(result.usage),
                        metadata: result.metadata
                    )
                    self.setRuntimeProviderState(state, for: .claude)
                    self.popoverViewModel.nextUsageRetryAt = state.nextRefreshAllowedAt
                    self.syncRuntimePresentation()
                    if syncHealthAfterCompletion {
                        self.syncUsageHealthSnapshotToUI()
                    }

                    NotificationManager.shared.checkClaude(
                        result.usage, accountID: result.provenance.accountID ?? requestAccountID,
                        policy: self.currentClaudeNotificationPolicy)

                }
            } catch is CancellationError {
                Logger.debug("Claude credential 변경으로 오래된 사용량 응답 폐기")
                return
            } catch let error as APIError {
                guard !Task.isCancelled else {
                    Logger.debug("Claude 사용량 갱신 취소")
                    return
                }
                Logger.error("API 에러: \(error.errorDescription ?? "")")
                let responseAccountID = await self.apiService.currentActiveAccountID()
                let fetchMetadata = await self.apiService.currentFetchMetadataSnapshot()

                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    guard self.withRuntimeState({ $0.claudeRequestRevision }) == requestRevision,
                        requestAccountID == responseAccountID
                    else {
                        Logger.info("Claude 계정 전환 중 도착한 이전 조회 실패 무시")
                        return
                    }
                    var state = self.runtimeProviderState(for: .claude)
                    let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
                        state: &state,
                        error: error,
                        metadata: fetchMetadata,
                        minimumInterval: PowerMonitor.shared.effectiveRefreshInterval
                    )
                    self.setRuntimeProviderState(state, for: .claude)
                    self.popoverViewModel.nextUsageRetryAt = resolution.nextAllowedAt
                    if let backoffSeconds = resolution.backoffSeconds {
                        Logger.info("임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
                    }
                    self.syncRuntimePresentation()
                    if syncHealthAfterCompletion {
                        self.syncUsageHealthSnapshotToUI()
                    }
                }
            } catch {
                guard !Task.isCancelled else {
                    Logger.debug("Claude 사용량 갱신 취소")
                    return
                }
                Logger.error("예상치 못한 에러: \(error)")

                let apiError = APIError.unknownError(error.localizedDescription)
                let responseAccountID = await self.apiService.currentActiveAccountID()
                let fetchMetadata = await self.apiService.currentFetchMetadataSnapshot()
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    guard self.withRuntimeState({ $0.claudeRequestRevision }) == requestRevision,
                        requestAccountID == responseAccountID
                    else {
                        Logger.info("Claude 계정 전환 중 도착한 이전 조회 실패 무시")
                        return
                    }
                    var state = self.runtimeProviderState(for: .claude)
                    let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
                        state: &state,
                        error: apiError,
                        metadata: fetchMetadata,
                        minimumInterval: PowerMonitor.shared.effectiveRefreshInterval
                    )
                    self.setRuntimeProviderState(state, for: .claude)
                    self.popoverViewModel.nextUsageRetryAt = resolution.nextAllowedAt
                    if let backoffSeconds = resolution.backoffSeconds {
                        Logger.info("임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
                    }
                    self.syncRuntimePresentation()
                    if syncHealthAfterCompletion {
                        self.syncUsageHealthSnapshotToUI()
                    }
                }
            }
        }
        claudeUsageRefreshTask = task
        return task
    }

    func refreshCodexUsage(force: Bool = false) {
        codexRefreshController.refresh(force: force)
    }

    func makeCodexRefreshController() -> CodexRefreshController {
        CodexRefreshController(
            authManager: .shared, apiService: codexAPIService,
            isEnabled: { ServiceSelectionHelper.isEnabled(.codex, settings: .shared) },
            prepare: { [weak self] force in self?.prepareRefresh(for: .codex, force: force) ?? false },
            clearPresentation: { [weak self] in
                guard let self else { return }
                NotificationManager.shared.updateAccountBoundary(
                    .codex,
                    accountID:
                    CodexAuthManager.shared.cachedSnapshot?.token.accountID)
                self.setRuntimeProviderState(RuntimeProviderState(), for: .codex)
                self.syncRuntimePresentation()
            },
            applySuccess: { [weak self] result in self?.applyCodexUsage(result) },
            applyFailure: { [weak self] error in self?.applyCodexFailure(error) }
        )
    }

    private func applyCodexUsage(_ result: CodexUsageSnapshot) {
        let usage = result.usage
        let accountID = usage.accountID ?? result.credential.token.accountID
        NotificationManager.shared.updateAccountBoundary(.codex, accountID: accountID)
        var state = runtimeProviderState(for: .codex)
        RuntimeProviderRefreshCoordinator.applySuccess(
            state: &state, payload: .codex(usage),
            metadata: RuntimeProviderFetchMetadata(
                sourceLabel: "Codex 로그인", accountID: accountID)
        )
        setRuntimeProviderState(state, for: .codex)
        syncRuntimePresentation()
        NotificationManager.shared.checkCodex(usage, accountID: accountID)
    }

    private func applyCodexFailure(_ error: APIError) {
        var state = runtimeProviderState(for: .codex)
        _ = RuntimeProviderRefreshCoordinator.applyFailure(
            state: &state, error: error, minimumInterval: refreshConfiguration.interval(for: .codex)
        )
        setRuntimeProviderState(state, for: .codex)
        syncRuntimePresentation()
    }

    func refreshAntigravityUsage(force: Bool = false) {
        guard ServiceSelectionHelper
            .isEnabled(
                .antigravity,
                settings: AppSettings.shared
            )
        else {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            // The first refresh must wait until startup migration and managed
            // process recovery have completed. Bootstrap itself does not
            // refresh, so launch still produces exactly one transaction.
            await antigravityRuntimeBootstrapTask?
                .value
            let runtime =
                await antigravityRuntimeTask
                    .value
            _ = await runtime
                .runtimeController
                .refresh(
                    trigger:
                        force
                            ? .manual
                            : .scheduled
                )
        }
    }
}
