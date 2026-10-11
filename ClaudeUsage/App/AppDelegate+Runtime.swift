import Foundation

extension AppDelegate {
    // MARK: - Runtime Presentation

    func syncRuntimePresentation() {
        observeResetCredits()
        updateMenuBar()
        updatePopoverViewModel()
        refreshAdaptiveSchedule()
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

    /// 진행 중인 조회는 조회 준비 단계가 겹치지 않게 막으므로 여기서 조회 중 표시를 풀지 않는다.
    func startMonitoring() {
        updateMenuBar()
        updatePopoverViewModel()
        refreshAll(force: true)
        startTimer()
    }

    func syncRefreshTimerState() {
        guard !isTerminating else { return }
        let change = refreshScheduler.sync(
            autoRefresh: refreshConfiguration.autoRefresh,
            shouldPoll: shouldPollRuntimeProviders,
            intervals: adaptiveRefreshIntervals()
        ) { [weak self] dueServices in
            guard let self, self.refreshConfiguration.autoRefresh, self.shouldPollRuntimeProviders else { return }
            for service in dueServices where self.refreshableServices.contains(service) {
                self.performRuntimeAction(.refresh(service: service, force: false))
            }
        }

        switch change {
        case .started(let interval):
            Logger.info("자동 갱신 주기 \(Int(interval))초")
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
        refreshConfiguration = RuntimeRefreshConfiguration(settings: .shared)
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
            },
            onTimeFormatChanged: { [weak self] in
                guard let self else { return }
                Task { [weak self] in
                    guard let self else { return }
                    let runtime = await antigravityRuntimeTask.value
                    await runtime.runtimeController.setTimeFormat(
                        AppSettings.shared.timeFormat)
                }
            },
            onPopoverBehaviorChanged: { [weak self] in
                self?.applyPopoverBehavior()
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
        claudeRefreshController.cancel()
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
        guard enabled, service == .codex else {
            applyProviderEnabledChange(enabled, for: service)
            return
        }
        // 앱이 켜진 뒤 codex login을 했을 수 있어 auth.json을 다시 읽고 판단한다.
        Task { @MainActor [weak self] in
            _ = try? await CodexAuthManager.shared.loadSnapshot()
            guard let self, AppSettings.shared.isProviderEnabled(service.providerKind) else { return }
            self.applyProviderEnabledChange(true, for: service)
        }
    }

    private func applyProviderEnabledChange(_ enabled: Bool, for service: PopoverService) {
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
        guard !isTerminating else { return }
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

        usageAccountsController.bindRuntimeAccount(nil, for: service)
        setRuntimeProviderState(RuntimeProviderState(), for: service)
    }

    func resetClaudeRuntimeAfterAccountBoundaryChange(refreshHealthSnapshot: Bool = true) {
        withRuntimeState { $0.invalidateClaudeRequestContext() }
        popoverViewModel.nextUsageRetryAt = nil
        usageAccountsController.bindRuntimeAccount(nil, for: .claude)
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
        force: Bool = false, syncHealthAfterCompletion: Bool = true, allowWhenDisabled: Bool = false
    ) -> Task<Void, Never>? {
        claudeRefreshController.refresh(
            force: force, syncHealthAfterCompletion: syncHealthAfterCompletion, allowWhenDisabled: allowWhenDisabled)
    }

    func makeClaudeRefreshController() -> ClaudeRefreshController {
        ClaudeRefreshController(
            apiService: apiService,
            host: .init(
                isEnabled: { ServiceSelectionHelper.isEnabled(.claude, settings: .shared) },
                prepare: { [weak self] force in self?.prepareRefresh(for: .claude, force: force) ?? false },
                beginRequest: { [weak self] in self?.withRuntimeState { $0.beginClaudeUsageRequest() } ?? UUID() },
                currentRequest: { [weak self] in self?.withRuntimeState { $0.claudeRequestRevision } ?? UUID() },
                releaseUnfinishedRequest: { [weak self] revision in
                    self?.withRuntimeState { $0.finishCancelledClaudeUsageRequest(revision) } ?? false
                },
                inputs: { [weak self] in
                    ClaudeRefreshController.Inputs(
                        lastOverageAttemptAt: self?.lastOverageAttemptAt,
                        overageOwnerKey: self?.withRuntimeState { $0.overageOwnerKey },
                        knownIdentities: self?.usageAccountsController.preferences.knownIdentities ?? [:])
                },
                applySuccess: { [weak self] result, profile, syncHealth in
                    self?.applyClaudeUsage(result, profile: profile, syncHealth: syncHealth)
                },
                applyFailure: { [weak self] error, metadata, syncHealth in
                    self?.applyClaudeFailure(error, metadata: metadata, syncHealth: syncHealth)
                },
                didReleaseRequest: { [weak self] in
                    guard let self else { return }
                    self.popoverViewModel.nextUsageRetryAt =
                        self.runtimeProviderState(for: .claude).nextRefreshAllowedAt
                    self.syncRuntimePresentation()
                }))
    }

    private func applyClaudeUsage(
        _ result: ClaudeRuntimeRefreshSuccess, profile: ClaudeProfileMetadata?, syncHealth: Bool
    ) {
        let scopedMetadata = result.metadata.withClaudeProfileMetadata(profile)
        usageAccountsController.bindRuntimeAccount(scopedMetadata.account, for: .claude)
        currentClaudeProfileMetadata = scopedMetadata.claudeProfileMetadata
        currentClaudeNotificationPolicy = scopedMetadata.claudeProfileMetadata.map(
            ClaudeNotificationPolicy.init(metadata:))
        if let accountID = result.provenance.accountID {
            withRuntimeState {
                $0.applyClaudeSupplementalUsage(
                    result.supplementalUsage, accountID: accountID, ownerKey: scopedMetadata.supplementalAccountKey)
            }
        }
        var state = runtimeProviderState(for: .claude)
        RuntimeProviderRefreshCoordinator.applySuccess(
            state: &state, payload: .claude(result.usage), metadata: scopedMetadata, updatedAt: result.fetchedAt)
        setRuntimeProviderState(state, for: .claude)
        popoverViewModel.nextUsageRetryAt = state.nextRefreshAllowedAt
        syncRuntimePresentation()
        if syncHealth { syncUsageHealthSnapshotToUI() }
        NotificationManager.shared.checkClaude(
            result.usage, accountID: scopedMetadata.notificationAccountKey(for: .claude),
            policy: currentClaudeNotificationPolicy)
    }

    private func applyClaudeFailure(_ error: APIError, metadata: RuntimeProviderFetchMetadata?, syncHealth: Bool) {
        var state = runtimeProviderState(for: .claude)
        let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
            state: &state, error: error, metadata: metadata, minimumInterval: AdaptiveRefreshPolicy.minimumInterval)
        setRuntimeProviderState(state, for: .claude)
        popoverViewModel.nextUsageRetryAt = resolution.nextAllowedAt
        if let backoffSeconds = resolution.backoffSeconds {
            Logger.info("임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
        }
        syncRuntimePresentation()
        if syncHealth { syncUsageHealthSnapshotToUI() }
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
                self.usageAccountsController.bindRuntimeAccount(nil, for: .codex)
                self.setRuntimeProviderState(RuntimeProviderState(), for: .codex)
                self.syncRuntimePresentation()
            },
            applySuccess: { [weak self] result in self?.applyCodexUsage(result) },
            applyFailure: { [weak self] error in self?.applyCodexFailure(error) },
            applyDetails: { [weak self] result in self?.applyCodexResetCreditDetails(result) }
        )
    }

    private func applyCodexUsage(_ result: CodexUsageSnapshot) {
        let usage = result.usage
        let accountID = usage.accountID ?? result.credential.token.accountID
        let account = CodexUsageAccountProvider.runtimeAccount(for: result)
        usageAccountsController.bindRuntimeAccount(account, for: .codex)
        var state = runtimeProviderState(for: .codex)
        RuntimeProviderRefreshCoordinator.applySuccess(
            state: &state, payload: .codex(usage),
            metadata: RuntimeProviderFetchMetadata(
                sourceLabel: "Codex 로그인", accountID: accountID, account: account)
        )
        setRuntimeProviderState(state, for: .codex)
        syncRuntimePresentation()
        NotificationManager.shared.checkCodex(
            usage, accountID: RuntimeProviderFetchMetadata(account: account).notificationAccountKey(for: .codex))
    }

    private func applyCodexResetCreditDetails(_ result: CodexUsageSnapshot) {
        var state = runtimeProviderState(for: .codex)
        guard case .codex(var usage)? = state.lastSuccessfulPayload,
            state.lastSuccessfulMetadata?.account == CodexUsageAccountProvider.runtimeAccount(for: result)
        else { return }
        usage.resetCredits = result.usage.resetCredits
        usage.resetCreditMetadata = result.usage.resetCreditMetadata
        state.lastSuccessfulPayload = .codex(usage)
        setRuntimeProviderState(state, for: .codex)
        syncRuntimePresentation()
    }

    private func applyCodexFailure(_ error: APIError) {
        var state = runtimeProviderState(for: .codex)
        _ = RuntimeProviderRefreshCoordinator.applyFailure(
            state: &state, error: error, minimumInterval: AdaptiveRefreshPolicy.minimumInterval
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
        // 자동 조회는 2분 하한을 지킨다. 실패 상태에서는 팝오버를 열 때마다 조회가 요청되고, AGY 보고는
        // 로그아웃 상태에서 제한 시간까지 기다리므로 여기서 막는다.
        if !force, let lastAttemptAt = currentAntigravityRuntimeSnapshot.lastAttemptAt,
            Date().timeIntervalSince(lastAttemptAt) < AdaptiveRefreshPolicy.minimumInterval
        {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            // The first refresh must wait until startup migration has
            // completed. Bootstrap itself does not refresh, so launch still
            // produces exactly one transaction.
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
