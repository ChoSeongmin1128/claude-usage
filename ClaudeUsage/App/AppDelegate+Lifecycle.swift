import AppKit

private enum AppShutdownPolicy {
    static let ownedRuntimeTimeout: Duration = .seconds(5)
}

extension AppDelegate {
    // MARK: - Lifecycle

    func applicationWillFinishLaunching(
        _ notification: Notification
    ) {
        ownsSingleInstanceLease = AppLaunchGate.ownsLease
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isRunningUnitTests {
            Logger.info("\(AppDistribution.current.appName) 테스트 런치 감지: 앱 초기화를 건너뜁니다")
            return
        }
        guard ownsSingleInstanceLease else {
            return
        }

        didFinishRuntimeLaunch = true
        Logger.info(
            "\(AppDistribution.current.appName) 앱 시작"
        )

        // 메뉴바 tooltip 표시 지연 단축 (macOS 기본 약 1.5초 → 0.5초).
        // 이 키는 앱 도메인에서만 읽히므로 시스템 전역에는 영향이 없다.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])

        setupStatusItems()
        setupPopovers()
        setupKeyboardShortcuts()
        bindRuntimeObservers()
        startSessionActivityMonitoring()
        bootstrapUsageAccounts()

        let claudeAccountIDs = ClaudeAccountStore.shared.storedAccountIDs()
        Task.detached(priority: .utility) {
            ClaudeAccountLocalData.removeOrphans(keeping: claudeAccountIDs)
            ClaudeEndpoints.removeStoredWebCookies()
        }

        bootstrapAntigravityRuntime()
        bootstrapRefreshState()
        syncUpdateCheckState(runImmediate: true)
        refreshSystemStatus()
        startStatusTimer()

        if AppSettings.shared.welcomeState == .pending {
            showSettingsWindow(settingsPanelRawValue: SettingsProviderPanel.welcome.rawValue)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.presentWhatsNewIfNeeded()
            }
        }

        let launchIntent = ApplicationLaunchIntent.parse(
            arguments: CommandLine.arguments
        )
        if let settingsPanelRawValue =
            launchIntent.settingsPanelRawValue
        {
            DispatchQueue.main.async { [weak self] in
                self?.showSettingsWindow(
                    settingsPanelRawValue:
                    settingsPanelRawValue
                )
            }
        } else if let service =
                    launchIntent
                        .requestedPopoverService
        {
            ServiceSelectionHelper
                .setActivePopoverService(
                    service,
                    settings:
                        AppSettings.shared
                )
            // Background automation launchers hide the process immediately
            // after startup. Opening a transient NSPopover before that hide
            // finishes closes it again, so this diagnostic-only intent waits
            // until the launch handoff has settled.
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 2
            ) { [weak self] in
                self?.toggleUnifiedPopover()
            }
        }

        // 설치 위치 안내는 메뉴바와 런타임을 준비한 뒤에 보여 준다.
        DispatchQueue.main.async {
            AppLocationChecker.checkAndGuideIfNeeded()
        }
    }

    /// 종료를 시작하면 새 조회와 타이머를 받지 않는다. 진행 중인 조회는 각 소유자의 종료가 정리한다.
    func stopAcceptingWork() {
        isTerminating = true
        refreshScheduler.stop()
        stopAdaptiveRefresh()
        usageAccountsTimer?.invalidate()
        usageAccountsTimer = nil
        usageAccountsController.stop()
        claudeCredentialRefreshTask?.cancel()
        claudeRefreshController.cancel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Logger.info(
            "\(AppDistribution.current.appName) 앱 종료"
        )
        stopAcceptingWork()
        updateCoordinator.invalidate()
        statusTimer?.invalidate()
        if let observer = accessibilityDisplayObservation {
            NSWorkspace.shared.notificationCenter
                .removeObserver(observer)
            accessibilityDisplayObservation = nil
        }
        popoverCoordinator.invalidate()
        settingsWindowCoordinator.invalidate()
        loginWindowCoordinator.invalidate()
        runtimeObservationCoordinator.cancelAll()
        codexRefreshController.cancel()
        antigravityRuntimeObservationTask?.cancel()
        antigravityRuntimeBootstrapTask?.cancel()
        antigravityTerminationTimeoutTask?.cancel()
        settingsWindowPresentationTask?.cancel()
        statusItemPlacementCheckTask?.cancel()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        stopGlobalClickMonitor()
        stopAdaptiveRefresh()
        AppSingleInstanceGuard.shared.release()
        if let plan = AppDataResetRequest.pending {
            AppDataReset.production.perform(plan)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        StatusItemDiagnosticsLog.record("termination requested")
        guard ownsSingleInstanceLease,
              didFinishRuntimeLaunch
        else {
            return .terminateNow
        }
        if hasRepliedToTermination {
            return .terminateNow
        }
        guard antigravityTerminationTask == nil else {
            return .terminateLater
        }

        Logger.info("\(AppDistribution.current.appName) 앱 종료 전 외부 프로세스 정리")
        stopAcceptingWork()
        antigravityTerminationTask = Task { [weak self] in
            guard let self else { return }
            // Codex와 AGY 정리는 서로 기다리지 않고 같은 제한 시간 안에서 함께 끝낸다.
            async let codex: Void = self.codexRefreshController.shutdown()
            async let antigravity: Void = self.antigravityRuntimeTask.value.runtimeController.shutdown()
            _ = await (codex, antigravity)
            await recheckPendingDataReset()
            finishDeferredTermination(
                timedOut: false
            )
        }
        antigravityTerminationTimeoutTask =
            Task { [weak self] in
                do {
                    try await Task.sleep(
                        for: AppShutdownPolicy.ownedRuntimeTimeout
                    )
                } catch {
                    return
                }
                await self?.recheckPendingDataReset()
                self?.finishDeferredTermination(
                    timedOut: true
                )
            }
        return .terminateLater
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard ownsSingleInstanceLease,
              didFinishRuntimeLaunch
        else {
            return false
        }

        let placement = captureStatusItemPlacement()
        switch ApplicationReopenPolicy.action(
            hasVisibleWindows: flag,
            placement: placement
        ) {
        case .useDefaultWindowHandling:
            return true
        case .showSettings:
            showSettingsWindow(
                settingsPanelRawValue:
                    SettingsProviderPanel.common.rawValue
            )
        case .showStatusItemRecovery:
            presentStatusItemPlacementGuidance(
                force: true
            )
        case .showPopover:
            toggleUnifiedPopover()
        }
        return false
    }

    @MainActor
    private func recheckPendingDataReset() async {
        guard let plan = AppDataResetRequest.pending else { return }
        AppDataResetRequest.pending = await plan.rechecked()
    }

    private func finishDeferredTermination(
        timedOut: Bool
    ) {
        guard !hasRepliedToTermination else {
            return
        }
        hasRepliedToTermination = true
        if timedOut {
            Logger.warning(
                "외부 프로세스 정리 제한 시간을 초과했습니다. 앱 종료를 계속합니다."
            )
        } else {
            antigravityTerminationTimeoutTask?
                .cancel()
            Logger.info("외부 프로세스 정리 완료")
        }
        StatusItemDiagnosticsLog.record("termination reply timedOut=\(timedOut)")
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
                let runtime =
                    await antigravityRuntimeTask
                        .value
                let stream =
                    await runtime
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
                let runtime =
                    await antigravityRuntimeTask
                        .value
                let basis = AppSettings.shared.usageDisplayMode.basis
                let revision = AppSettings.shared.usageDisplayModeRevision
                await runtime.runtimeController.setUsageDisplayBasis(basis, revision: revision)
                await runtime.runtimeController.setTimeFormat(
                    AppSettings.shared.timeFormat)
                _ = await runtime
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
        guard snapshot.publicationRevision >= currentAntigravityRuntimeSnapshot.publicationRevision else { return }
        currentAntigravityRuntimeSnapshot =
            snapshot
        popoverViewModel
            .antigravityRuntimeSnapshot =
            snapshot
        NotificationManager.shared
            .checkAntigravityThresholds(
                snapshot: snapshot
            )
        syncRuntimePresentation()
        syncRefreshTimerState()
    }

    func bootstrapRefreshState() {
        // 시작 확인 중에 계정 전환 흐름이 시작되면 그쪽 결과가 맞으므로 이 결과는 상태에 쓰지 않는다.
        let generation = claudeCredentialRefreshGeneration
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
                if generation == self.claudeCredentialRefreshGeneration,
                    snapshot.activeAccountID == ClaudeAccountStore.shared.state().activeAccountID
                {
                    self.currentClaudeProfileMetadata = cachedProfileMetadata
                    self.currentClaudeNotificationPolicy = cachedProfileMetadata.map(
                        ClaudeNotificationPolicy.init(metadata:))
                    self.applyUsageHealthSnapshot(snapshot)
                }
                self.finishBootstrap()
            }
        }
    }

    /// 켜진 서비스가 있으면 조회를 시작한다. 서비스가 켜져 있으면 조회 대상이기도 하므로 다른 경우는 메뉴바만 그린다.
    func finishBootstrap() {
        let hasEnabledRuntimeService = AppSettings.shared.providerSelectionState.runtimeEnabledKinds.isEmpty == false
        if hasRefreshableService || hasEnabledRuntimeService {
            startMonitoring()
        } else {
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
        statusTimer = Timer.scheduledOnMainRunLoop(interval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSystemStatus()
            }
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

        updatePopoverViewModel()
    }
}
