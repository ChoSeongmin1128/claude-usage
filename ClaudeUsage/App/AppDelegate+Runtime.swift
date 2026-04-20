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
        // UI 경로에서 호출되므로 blocking 금지. SWR 로 캐시만 참조.
        let environmentStatus: ProviderEnvironmentStatus?
        switch service {
        case .gemini:
            environmentStatus = ProviderEnvironmentDetector.staleWhileRevalidate(for: .gemini)
        case .antigravity:
            environmentStatus = ProviderEnvironmentDetector.staleWhileRevalidate(for: .antigravity)
        case .claude, .codex:
            environmentStatus = nil
        }

        return withRuntimeState {
            $0.snapshot(
                for: service,
                codexAuthenticated: CodexAuthManager.shared.isAuthenticated,
                environmentStatus: environmentStatus
            )
        }
    }

    func runtimePresentationState(for service: PopoverService) -> RuntimeProviderPresentationState {
        let snapshot = runtimeProviderSnapshot(for: service)
        return RuntimeProviderPresentationState(
            service: service,
            lastUpdated: snapshot.lastUpdated,
            hasContent: snapshot.hasContent,
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
        // UI 가 뜨기 전에 env 캐시를 먼저 워밍 — 첫 클릭 지연 최소화
        ProviderEnvironmentDetector.refreshAllInBackground()
        AntigravityStatusProbe.refreshAllInBackground()
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
            onProviderStatesChanged: { [weak self] catalog in
                guard let self else { return }
                let previous = self.lastObservedProviderStates
                self.lastObservedProviderStates = catalog
                self.handleProviderStateTransition(from: previous, to: catalog)
            },
            onPowerStateChanged: { [weak self] in
                self?.syncRefreshTimerState()
            },
            onClaudeSessionKeyChanged: { [weak self] in
                self?.handleClaudeSessionKeyChanged()
            },
            onPreferredOrganizationChanged: { [weak self] in
                self?.handlePreferredOrganizationChanged()
            }
        )
    }

    func handleClaudeSessionKeyChanged() {
        Task {
            let preferredOrganizationID = AppSettings.shared.preferredOrganizationID
            await apiService.updatePreferredOrganizationID(preferredOrganizationID)

            if let sessionKey = KeychainManager.shared.load(), !sessionKey.isEmpty {
                await apiService.updateSessionKey(sessionKey)
            } else {
                await apiService.clearSession()
            }

            async let snapshotTask = apiService.fetchUsageHealthSnapshot()
            async let metadataTask = apiService.fetchCachedProfileMetadata()
            let snapshot = await snapshotTask
            let cachedProfileMetadata = await metadataTask
            await MainActor.run {
                if snapshot.runtime.credentialAvailability.hasAnyCredential {
                    self.setupWizardCredentialStepOverride = nil
                }
                self.currentClaudeProfileMetadata = cachedProfileMetadata
                self.currentClaudeNotificationPolicy = cachedProfileMetadata.map(ClaudeNotificationPolicy.init(metadata:))
                self.applyUsageHealthSnapshot(snapshot)

                if snapshot.runtime.credentialAvailability.hasAnyCredential {
                    if ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared) {
                        self.refreshUsage(force: true)
                    } else {
                        self.updateMenuBar()
                        self.updatePopoverViewModel(overage: self.currentOverage)
                    }
                } else {
                    self.clearClaudePresentationState(markSetupIncomplete: false)
                    self.updateMenuBar()
                    self.updatePopoverViewModel(overage: self.currentOverage)
                    self.syncRefreshTimerState()
                }
            }
        }
    }

    func handlePreferredOrganizationChanged() {
        Task {
            let preferredOrganizationID = AppSettings.shared.preferredOrganizationID
            await apiService.updatePreferredOrganizationID(preferredOrganizationID)

            async let snapshotTask = apiService.fetchUsageHealthSnapshot()
            async let metadataTask = apiService.fetchCachedProfileMetadata()
            let snapshot = await snapshotTask
            let cachedProfileMetadata = await metadataTask

            await MainActor.run {
                self.currentClaudeProfileMetadata = cachedProfileMetadata
                self.currentClaudeNotificationPolicy = cachedProfileMetadata.map(ClaudeNotificationPolicy.init(metadata:))
                self.applyUsageHealthSnapshot(snapshot)

                if snapshot.runtime.credentialAvailability.hasAnyCredential,
                   ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared) {
                    self.refreshUsage(force: true)
                } else {
                    self.updateMenuBar()
                    self.updatePopoverViewModel(overage: self.currentOverage)
                }
            }
        }
    }

    func handleProviderStateTransition(from previous: AppProviderStateCatalog, to current: AppProviderStateCatalog) {
        let resolvedService = resolvedPopoverService()
        popoverViewModel.selectedService = resolvedService
        applyPopoverBehavior(for: resolvedService)

        for kind in ServiceSelectionHelper.supportedProviderKinds {
            let previousEnabled = previous.state(for: kind).isEnabled
            let currentEnabled = current.state(for: kind).isEnabled
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
        case .gemini:
            if hasGeminiCredential {
                geminiError = nil
                hasGeminiAuthError = false
                nextGeminiRefreshAllowedAt = nil
            }
        case .antigravity:
            if hasAntigravityCredential {
                antigravityError = nil
                hasAntigravityAuthError = false
                nextAntigravityRefreshAllowedAt = nil
            }
        }
    }

    // MARK: - API

    func refreshAll(force: Bool = false) {
        // 매 refresh 틱에서 env 상태 캐시도 백그라운드로 갱신.
        // UI 경로는 SWR 로 캐시만 읽어서 클릭 지연 0 ms 를 유지함.
        ProviderEnvironmentDetector.refreshAllInBackground()
        AntigravityStatusProbe.refreshAllInBackground()

        var lastRefreshed: [PopoverService: Date] = [:]
        for service in PopoverService.allCases {
            let state = runtimeProviderState(for: service)
            if let lastAt = state.lastSuccessfulAt {
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
        if service == .claude {
            currentOverage = nil
            lastOverageFetchAt = nil
            popoverViewModel.nextUsageRetryAt = nil
        }

        setRuntimeProviderState(
            RuntimeProviderRefreshCoordinator.clearedState(
                service: service,
                isCodexAuthenticated: CodexAuthManager.shared.isAuthenticated,
                requiresInteractiveSetup: ProviderEnvironmentDetector.requiresInteractiveSetupFromCache(for: service.providerKind)
            ),
            for: service
        )
    }

    func clearStateForAuthPrompt(_ service: PopoverService) {
        if service == .claude {
            currentOverage = nil
            lastOverageFetchAt = nil
            popoverViewModel.nextUsageRetryAt = nil
        }

        setRuntimeProviderState(RuntimeProviderState(), for: service)
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

    func refreshUsage(force: Bool = false) {
        guard ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared) else { return }
        guard prepareRefresh(for: .claude, force: force) else { return }

        Task {
            do {
                Logger.debug("사용량 갱신 시작")
                let result = try await ClaudeRuntimeRefresher.refresh(
                    apiService: apiService,
                    lastOverageFetchAt: self.lastOverageFetchAt
                )
                let cachedProfileMetadata = await self.apiService.fetchCachedProfileMetadata()

                await MainActor.run {
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
                        payload: .claude(result.usage)
                    )
                    self.setRuntimeProviderState(state, for: .claude)
                    self.popoverViewModel.nextUsageRetryAt = state.nextRefreshAllowedAt
                    self.syncRuntimePresentation(overage: self.currentOverage)
                    self.syncUsageHealthSnapshotToUI()

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
            } catch let error as APIError {
                Logger.error("API 에러: \(error.errorDescription ?? "")")

                await MainActor.run {
                    var state = self.runtimeProviderState(for: .claude)
                    let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
                        state: &state,
                        error: error,
                        minimumInterval: PowerMonitor.shared.effectiveRefreshInterval
                    )
                    self.setRuntimeProviderState(state, for: .claude)
                    self.popoverViewModel.nextUsageRetryAt = resolution.nextAllowedAt
                    if let backoffSeconds = resolution.backoffSeconds {
                        Logger.info("임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
                    }
                    self.syncRuntimePresentation(overage: self.currentOverage)
                    self.syncUsageHealthSnapshotToUI()
                }
            } catch {
                Logger.error("예상치 못한 에러: \(error)")

                let apiError = APIError.unknownError(error.localizedDescription)
                await MainActor.run {
                    var state = self.runtimeProviderState(for: .claude)
                    let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
                        state: &state,
                        error: apiError,
                        minimumInterval: PowerMonitor.shared.effectiveRefreshInterval
                    )
                    self.setRuntimeProviderState(state, for: .claude)
                    self.popoverViewModel.nextUsageRetryAt = resolution.nextAllowedAt
                    if let backoffSeconds = resolution.backoffSeconds {
                        Logger.info("임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
                    }
                    self.syncRuntimePresentation(overage: self.currentOverage)
                    self.syncUsageHealthSnapshotToUI()
                }
            }
        }
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
                        payload: .codex(usage)
                    )
                    self.setRuntimeProviderState(state, for: .codex)
                    self.syncRuntimePresentation(overage: self.currentOverage)

                    NotificationManager.shared.checkThreshold(
                        session: .codexPrimary,
                        percentage: usage.primaryPercentage,
                        resetAt: usage.rateLimit?.primaryWindow?.resetAtISO
                    )
                    NotificationManager.shared.checkThreshold(
                        session: .codexSecondary,
                        percentage: usage.secondaryPercentage,
                        resetAt: usage.rateLimit?.secondaryWindow?.resetAtISO
                    )
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

    func refreshGeminiUsage(force: Bool = false) {
        guard ServiceSelectionHelper.isEnabled(.gemini, settings: AppSettings.shared) else { return }
        guard prepareRefresh(for: .gemini, force: force, respectBackoffWithoutPayload: false) else { return }

        Task {
            do {
                let usage = try await GeminiRuntimeRefresher.refresh(apiService: geminiAPIService)
                await MainActor.run {
                    var state = self.runtimeProviderState(for: .gemini)
                    RuntimeProviderRefreshCoordinator.applySuccess(
                        state: &state,
                        payload: .gemini(usage)
                    )
                    self.setRuntimeProviderState(state, for: .gemini)
                    self.syncRuntimePresentation(overage: self.currentOverage)

                    NotificationManager.shared.checkThreshold(
                        session: .geminiPrimary,
                        percentage: usage.primaryPercentage,
                        resetAt: usage.primaryWindow?.resetAtISO
                    )
                    NotificationManager.shared.checkThreshold(
                        session: .geminiSecondary,
                        percentage: usage.secondaryPercentage,
                        resetAt: usage.secondaryWindow?.resetAtISO
                    )
                    if let tertiary = usage.tertiaryWindow {
                        NotificationManager.shared.checkThreshold(
                            session: .geminiTertiary,
                            percentage: tertiary.usedPercent,
                            resetAt: tertiary.resetAtISO
                        )
                    }
                }
            } catch let error as APIError {
                await MainActor.run {
                    var state = self.runtimeProviderState(for: .gemini)
                    let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
                        state: &state,
                        error: error,
                        minimumInterval: PowerMonitor.shared.effectiveRefreshInterval
                    )
                    self.setRuntimeProviderState(state, for: .gemini)
                    if let backoffSeconds = resolution.backoffSeconds {
                        Logger.info("Gemini 임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
                    }
                    self.syncRuntimePresentation(overage: self.currentOverage)
                }
            } catch {
                let wrapped = APIError.unknownError(error.localizedDescription)
                await MainActor.run {
                    var state = self.runtimeProviderState(for: .gemini)
                    let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
                        state: &state,
                        error: wrapped,
                        minimumInterval: PowerMonitor.shared.effectiveRefreshInterval
                    )
                    self.setRuntimeProviderState(state, for: .gemini)
                    if let backoffSeconds = resolution.backoffSeconds {
                        Logger.info("Gemini 임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
                    }
                    self.syncRuntimePresentation(overage: self.currentOverage)
                }
            }
        }
    }

    func refreshAntigravityUsage(force: Bool = false) {
        guard ServiceSelectionHelper.isEnabled(.antigravity, settings: AppSettings.shared) else { return }
        guard prepareRefresh(for: .antigravity, force: force, respectBackoffWithoutPayload: false) else { return }

        Task {
            do {
                let usage = try await AntigravityRuntimeRefresher.refresh(apiService: antigravityAPIService)
                await MainActor.run {
                    var state = self.runtimeProviderState(for: .antigravity)
                    RuntimeProviderRefreshCoordinator.applySuccess(
                        state: &state,
                        payload: .antigravity(usage)
                    )
                    self.setRuntimeProviderState(state, for: .antigravity)
                    self.syncRuntimePresentation(overage: self.currentOverage)

                    NotificationManager.shared.checkThreshold(
                        session: .antigravityPrimary,
                        percentage: usage.primaryPercentage,
                        resetAt: usage.primaryWindow?.resetAtISO
                    )
                    NotificationManager.shared.checkThreshold(
                        session: .antigravitySecondary,
                        percentage: usage.secondaryPercentage,
                        resetAt: usage.secondaryWindow?.resetAtISO
                    )
                    if let tertiary = usage.tertiaryWindow {
                        NotificationManager.shared.checkThreshold(
                            session: .antigravityTertiary,
                            percentage: tertiary.usedPercent,
                            resetAt: tertiary.resetAtISO
                        )
                    }
                }
            } catch let error as APIError {
                await MainActor.run {
                    var state = self.runtimeProviderState(for: .antigravity)
                    let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
                        state: &state,
                        error: error,
                        minimumInterval: PowerMonitor.shared.effectiveRefreshInterval
                    )
                    self.setRuntimeProviderState(state, for: .antigravity)
                    if let backoffSeconds = resolution.backoffSeconds {
                        Logger.info("Antigravity 임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
                    }
                    self.syncRuntimePresentation(overage: self.currentOverage)
                }
            } catch {
                let wrapped = APIError.unknownError(error.localizedDescription)
                await MainActor.run {
                    var state = self.runtimeProviderState(for: .antigravity)
                    let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
                        state: &state,
                        error: wrapped,
                        minimumInterval: PowerMonitor.shared.effectiveRefreshInterval
                    )
                    self.setRuntimeProviderState(state, for: .antigravity)
                    if let backoffSeconds = resolution.backoffSeconds {
                        Logger.info("Antigravity 임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
                    }
                    self.syncRuntimePresentation(overage: self.currentOverage)
                }
            }
        }
    }
}
