import Foundation

extension AppDelegate {
    // MARK: - Runtime Presentation

    func syncRuntimePresentation(overage: OverageSpendLimitResponse? = nil) {
        updateMenuBar()
        updatePopoverViewModel(overage: overage ?? currentOverage)
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
        updatePopoverViewModel(overage: currentOverage)
        refreshAll(force: true)
        startTimer()
    }

    func stopRefreshTimer() {
        _ = refreshScheduler.stop()
    }

    func syncRefreshTimerState() {
        let change = refreshScheduler.sync(
            autoRefresh: AppSettings.shared.autoRefresh,
            shouldPoll: shouldPollRuntimeProviders,
            interval: PowerMonitor.shared.effectiveRefreshInterval
        ) { [weak self] in
            self?.refreshAll(force: false)
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
        lastObservedProviderSelectionState =
            AppSettings.shared.providerSelectionState
        runtimeObservationCoordinator.bind(
            onRefreshConfigurationChanged: { [weak self] in
                self?.syncRefreshTimerState()
            },
            onUpdateConfigurationChanged: { [weak self] in
                self?.syncUpdateCheckState(runImmediate: true)
            },
            onMenuBarDisplayChanged: { [weak self] in
                self?.updateMenuBar(force: true)
            },
            onProviderSelectionChanged: { [weak self] selectionState in
                guard let self else { return }
                let previous =
                    self.lastObservedProviderSelectionState
                    ?? selectionState
                self.lastObservedProviderSelectionState = selectionState
                self.handleProviderSelectionTransition(from: previous, to: selectionState)
            },
            onPowerStateChanged: { [weak self] in
                self?.syncRefreshTimerState()
            },
            onClaudeCredentialContextChanged: { [weak self] in
                self?.handleClaudeCredentialContextChanged()
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
                self.updatePopoverViewModel(overage: self.currentOverage)
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

        updatePopoverViewModel(overage: currentOverage)
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
        var lastRefreshed: [PopoverService: Date] = [:]
        for service in PopoverService.allCases {
            let lastAt =
                service == .antigravity
                    ? currentAntigravityRuntimeSnapshot
                        .lastSuccessfulAt
                    : runtimeProviderState(
                        for: service
                    ).lastSuccessfulAt
            if let lastAt {
                lastRefreshed[service] = lastAt
            }
        }

        let actions = RefreshOrchestration.actionsForRefreshAll(
            supportedServices: ServiceSelectionHelper.supportedPopoverServices,
            refreshableServices: refreshableServices,
            settings: AppSettings.shared,
            force: force,
            lastRefreshedAt: lastRefreshed
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
        if service == .antigravity {
            syncRuntimePresentation(
                overage: currentOverage
            )
            return
        }

        if service == .claude {
            currentOverage = nil
            lastOverageFetchAt = nil
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
        if service == .antigravity {
            syncRuntimePresentation(
                overage: currentOverage
            )
            return
        }

        if service == .claude {
            currentOverage = nil
            lastOverageFetchAt = nil
            popoverViewModel.nextUsageRetryAt = nil
        }

        setRuntimeProviderState(RuntimeProviderState(), for: service)
    }

    func resetClaudeRuntimeAfterAccountBoundaryChange(refreshHealthSnapshot: Bool = true) {
        currentOverage = nil
        lastOverageFetchAt = nil
        popoverViewModel.nextUsageRetryAt = nil
        setRuntimeProviderState(RuntimeProviderState(), for: .claude)
        syncRuntimePresentation(overage: nil)
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
            syncRuntimePresentation(overage: currentOverage)
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
                    guard requestAccountID == responseAccountID,
                          requestAccountID == result.provenance.accountID else {
                        Logger.info("Claude 계정 귀속이 다른 조회 결과 무시")
                        return
                    }
                    self.currentClaudeProfileMetadata = cachedProfileMetadata
                    self.currentClaudeNotificationPolicy = cachedProfileMetadata.map(ClaudeNotificationPolicy.init(metadata:))
                    if let fetchedOverage = result.overage {
                        self.currentOverage = fetchedOverage
                    }
                    if let overageFetchedAt = result.overageFetchedAt {
                        self.lastOverageFetchAt = overageFetchedAt
                    }

                    var state = self.runtimeProviderState(for: .claude)
                    RuntimeProviderRefreshCoordinator.applySuccess(
                        state: &state,
                        payload: .claude(result.usage),
                        metadata: result.metadata
                    )
                    self.setRuntimeProviderState(state, for: .claude)
                    self.popoverViewModel.nextUsageRetryAt = state.nextRefreshAllowedAt
                    self.syncRuntimePresentation(overage: self.currentOverage)
                    if syncHealthAfterCompletion {
                        self.syncUsageHealthSnapshotToUI()
                    }

                    NotificationManager.shared.checkThreshold(
                        session: .fiveHour,
                        percentage: result.usage.fiveHourPercentage,
                        resetAt: result.usage.fiveHour.resetsAt,
                        claudePolicy: self.currentClaudeNotificationPolicy
                    )
                    NotificationManager.shared.checkThreshold(
                        session: .weekly,
                        percentage: result.usage.weeklyPercentage,
                        resetAt: result.usage.sevenDay?.resetsAt,
                        claudePolicy: self.currentClaudeNotificationPolicy
                    )
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
                    guard requestAccountID == responseAccountID else {
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
                    self.syncRuntimePresentation(overage: self.currentOverage)
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
                    guard requestAccountID == responseAccountID else {
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
                    self.syncRuntimePresentation(overage: self.currentOverage)
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
        guard ServiceSelectionHelper.isEnabled(.codex, settings: AppSettings.shared) else { return }

        if !CodexAuthManager.shared.isAuthenticated {
            var state = runtimeProviderState(for: .codex)
            _ = RuntimeProviderRefreshCoordinator.applyFailure(
                state: &state,
                error: .invalidSessionKey,
                minimumInterval: PowerMonitor.shared.effectiveRefreshInterval
            )
            setRuntimeProviderState(state, for: .codex)
            syncRuntimePresentation(overage: currentOverage)
            return
        }
        guard prepareRefresh(for: .codex, force: force) else { return }

        Task {
            do {
                let usage = try await CodexRuntimeRefresher.refresh(apiService: codexAPIService)

                await MainActor.run {
                    var state = self.runtimeProviderState(for: .codex)
                    RuntimeProviderRefreshCoordinator.applySuccess(
                        state: &state,
                        payload: .codex(usage),
                        metadata: RuntimeProviderFetchMetadata(sourceLabel: "Codex 로그인")
                    )
                    self.setRuntimeProviderState(state, for: .codex)
                    self.syncRuntimePresentation(overage: self.currentOverage)

                    // 창이 없는 세션/주간 축은 0%로 오인된 임계값 상태 전이를 막기 위해 건너뛴다.
                    // (2026-07 개편: 주간 창이 primary 자리에 오므로 위치가 아닌 의미 기반 접근)
                    if let sessionWindow = usage.sessionWindow {
                        NotificationManager.shared.checkThreshold(
                            session: .codexPrimary,
                            percentage: sessionWindow.utilization,
                            resetAt: sessionWindow.resetAtISO
                        )
                    }
                    if let weeklyWindow = usage.weeklyWindow {
                        NotificationManager.shared.checkThreshold(
                            session: .codexSecondary,
                            percentage: weeklyWindow.utilization,
                            resetAt: weeklyWindow.resetAtISO
                        )
                    }
                }
            } catch let error as APIError {
                await MainActor.run {
                    var state = self.runtimeProviderState(for: .codex)
                    let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
                        state: &state,
                        error: error,
                        minimumInterval: PowerMonitor.shared.effectiveRefreshInterval
                    )
                    self.setRuntimeProviderState(state, for: .codex)
                    if let backoffSeconds = resolution.backoffSeconds {
                        Logger.info("Codex 임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
                    }
                    self.syncRuntimePresentation(overage: self.currentOverage)
                }
            } catch {
                let wrapped = APIError.unknownError(error.localizedDescription)
                await MainActor.run {
                    var state = self.runtimeProviderState(for: .codex)
                    let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
                        state: &state,
                        error: wrapped,
                        minimumInterval: PowerMonitor.shared.effectiveRefreshInterval
                    )
                    self.setRuntimeProviderState(state, for: .codex)
                    if let backoffSeconds = resolution.backoffSeconds {
                        Logger.info("Codex 임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
                    }
                    self.syncRuntimePresentation(overage: self.currentOverage)
                }
            }
        }
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
