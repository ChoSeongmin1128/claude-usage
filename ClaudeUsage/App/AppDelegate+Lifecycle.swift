import AppKit

extension AppDelegate {
    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isRunningUnitTests {
            Logger.info("ClaudeUsage 테스트 런치 감지: 앱 초기화를 건너뜁니다")
            return
        }

        Logger.info("ClaudeUsage 앱 시작")

        // 메뉴바 tooltip 표시 지연 단축 (macOS 기본 약 1.5초 → 0.5초).
        // 이 키는 앱 도메인에서만 읽히므로 시스템 전역에는 영향이 없다.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])

        AppLocationChecker.checkAndPromptIfNeeded()
        setupStatusItems()
        setupPopovers()
        setupKeyboardShortcuts()
        bindRuntimeObservers()

        bootstrapAntigravityRuntime()
        bootstrapRefreshState()
        syncUpdateCheckState(runImmediate: true)
        refreshSystemStatus()
        startStatusTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Logger.info("ClaudeUsage 앱 종료")
        refreshScheduler.stop()
        updateCoordinator.invalidate()
        statusTimer?.invalidate()
        popoverCoordinator.invalidate()
        settingsWindowCoordinator.invalidate()
        loginWindowCoordinator.invalidate()
        runtimeObservationCoordinator.cancelAll()
        antigravityRuntimeObservationTask?.cancel()
        antigravityRuntimeBootstrapTask?.cancel()
        antigravityTerminationTimeoutTask?.cancel()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        stopGlobalClickMonitor()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if hasRepliedToTermination {
            return .terminateNow
        }
        guard antigravityTerminationTask == nil else {
            return .terminateLater
        }

        Logger.info("ClaudeUsage 앱 종료 전 Antigravity owned runtime 정리")
        refreshScheduler.stop()
        antigravityTerminationTask = Task { [weak self] in
            guard let self else { return }
            await antigravityRuntime
                .runtimeController.shutdown()
            finishDeferredTermination(
                timedOut: false
            )
        }
        antigravityTerminationTimeoutTask =
            Task { [weak self] in
                do {
                    try await Task.sleep(
                        for: .seconds(5)
                    )
                } catch {
                    return
                }
                self?.finishDeferredTermination(
                    timedOut: true
                )
            }
        return .terminateLater
    }

    @MainActor
    private func finishDeferredTermination(
        timedOut: Bool
    ) {
        guard !hasRepliedToTermination else {
            return
        }
        hasRepliedToTermination = true
        if timedOut {
            Logger.warning(
                "Antigravity 종료 정리 제한 시간을 초과했습니다. durable ledger를 유지한 채 앱 종료를 계속합니다."
            )
        } else {
            antigravityTerminationTimeoutTask?
                .cancel()
            Logger.info(
                "Antigravity owned runtime 정리 완료"
            )
        }
        NSApplication.shared.reply(
            toApplicationShouldTerminate: true
        )
    }

    func bootstrapAntigravityRuntime() {
        antigravityRuntimeObservationTask?
            .cancel()
        antigravityRuntimeObservationTask =
            Task { [weak self] in
                guard let self else { return }
                let stream =
                    await antigravityRuntime
                        .runtimeController
                        .snapshots()
                for await snapshot in stream {
                    guard !Task.isCancelled else {
                        break
                    }
                    await MainActor.run {
                        self.applyAntigravityRuntimeSnapshot(
                            snapshot
                        )
                    }
                }
            }
        antigravityRuntimeBootstrapTask =
            Task { [weak self] in
                guard let self else { return }
                _ = await antigravityRuntime
                    .runtimeController
                    .bootstrap(
                        performInitialRefresh: false
                    )
            }
    }

    @MainActor
    private func applyAntigravityRuntimeSnapshot(
        _ snapshot: AntigravityRuntimeSnapshot
    ) {
        currentAntigravityRuntimeSnapshot =
            snapshot
        popoverViewModel
            .antigravityRuntimeSnapshot =
            snapshot
        NotificationManager.shared
            .checkAntigravityThresholds(
                snapshot: snapshot
            )
        syncRuntimePresentation(
            overage: currentOverage
        )
        syncRefreshTimerState()
    }

    func bootstrapRefreshState() {
        Task {
            await apiService.reloadActiveAccount()
            let activeAccount = ClaudeAccountStore.shared.state().activeAccount
            let shouldRefreshOAuthCredentialInventory =
                ClaudeCredentialRefreshRequest.shouldRefreshOAuthInventoryAtBootstrap(
                    activeAccount: activeAccount
                )
            let snapshot = await apiService.fetchUsageHealthSnapshot(
                refreshOAuthCredentialInventory: shouldRefreshOAuthCredentialInventory
            )
            let cachedProfileMetadata = await apiService.fetchCachedProfileMetadata()
            await MainActor.run {
                self.currentClaudeProfileMetadata = cachedProfileMetadata
                self.currentClaudeNotificationPolicy = cachedProfileMetadata.map(ClaudeNotificationPolicy.init(metadata:))
                self.applyUsageHealthSnapshot(snapshot)
                self.finishBootstrap(using: snapshot)
            }
        }
    }

    func finishBootstrap(using snapshot: ClaudeAPIService.UsageHealthSnapshot) {
        let hasEnabledRuntimeService = AppSettings.shared.providerSelectionState.runtimeEnabledKinds.isEmpty == false
        if hasRefreshableService || hasEnabledRuntimeService {
            startMonitoring()
        } else if ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared) {
            updateMenuBar()
            if !snapshot.runtime.credentialAvailability.hasAnyCredential {
                showInitialClaudeSetupFlow()
            }
        } else {
            if ServiceSelectionHelper.isEnabled(.codex, settings: AppSettings.shared) && !CodexAuthManager.shared.isAuthenticated {
                hasCodexAuthError = true
                codexError = .invalidSessionKey
            }
            updateMenuBar()
        }
    }

    func checkForUpdates() {
        Task {
            await UpdateService.shared.performScheduledCheck()
        }
    }

    func syncUpdateCheckState(runImmediate: Bool = false) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let usesExternalScheduler = await UpdateService.shared.configureAutomaticChecks(
                interval: .enforced,
                runImmediate: runImmediate
            )

            if usesExternalScheduler {
                self.updateCoordinator.invalidate()
                return
            }

            self.updateCoordinator.apply(
                interval: .enforced,
                runImmediate: runImmediate
            ) { [weak self] in
                self?.checkForUpdates()
            }
        }
    }

    // MARK: - System Status

    func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshSystemStatus()
        }
    }

    func refreshSystemStatus() {
        Task {
            async let claudeStatus = ClaudeStatusService.shared.fetchStatus()
            async let codexStatus = OpenAIStatusService.shared.fetchCodexStatus()
            let statuses = await (claude: claudeStatus, codex: codexStatus)

            await MainActor.run {
                self.setProviderSystemStatus(statuses.claude, for: .claude)
                self.setProviderSystemStatus(statuses.codex, for: .codex)
                self.popoverViewModel.systemStatus = statuses.claude
                self.updateMenuBar()
            }
        }
    }

    func syncUsageHealthSnapshotToUI() {
        Task {
            let snapshot = await apiService.fetchUsageHealthSnapshot()
            await MainActor.run {
                self.applyUsageHealthSnapshot(snapshot)
            }
        }
    }

    func applyUsageHealthSnapshot(_ snapshot: ClaudeAPIService.UsageHealthSnapshot) {
        let credentialAvailabilityChanged = withRuntimeState {
            $0.applyClaudeUsageHealthSnapshot(snapshot)
        }

        popoverViewModel.usageHealthSnapshot = snapshot
        popoverViewModel.nextUsageRetryAt = nextUsageRefreshAllowedAt
        NotificationCenter.default.post(name: .claudeUsageHealthSnapshotDidChange, object: snapshot)

        if credentialAvailabilityChanged {
            syncRefreshTimerState()
            updateMenuBar()
        }

        updatePopoverViewModel(overage: currentOverage)
    }
}
