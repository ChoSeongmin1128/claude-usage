import AppKit

extension AppDelegate {
    // MARK: - Lifecycle

    func applicationWillFinishLaunching(
        _ notification: Notification
    ) {
        if isRunningUnitTests {
            return
        }

        let supportDirectory =
            AntigravityStoragePaths
                .applicationSupportDirectoryURL()
        let instanceGuard = AppSingleInstanceGuard.shared
        // 이동 후 재실행이면 구 프로세스가 종료 절차를 끝낼 때까지 기다린다. 기다리지
        // 않으면 구 프로세스가 아직 잠금을 쥔 채 종료 중이라 양쪽 다 사라진다.
        let waitsForPredecessor =
            ApplicationLaunchIntent
            .parse(arguments: CommandLine.arguments)
            .relaunchAfterMovePredecessor
            .map(
                AppRelaunchHandoffPolicy
                    .predecessorIsRunning
            )
            ?? false
        let result =
            waitsForPredecessor
            ? instanceGuard
                .acquireWaitingForRelocatedPredecessor(
                    applicationSupportDirectoryURL:
                        supportDirectory
                )
            : instanceGuard.acquire(
                applicationSupportDirectoryURL:
                    supportDirectory
            )
        switch result {
        case .acquired:
            ownsSingleInstanceLease = true
        case .alreadyRunning:
            Logger.warning(
                "\(AppDistribution.current.appName) 동일 채널 인스턴스가 이미 실행 중입니다."
            )
            activateExistingChannelInstance()
            NSApplication.shared.terminate(nil)
        case .failed(let code):
            Logger.error(
                "단일 인스턴스 잠금을 만들지 못했습니다: \(code)"
            )
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isRunningUnitTests {
            Logger.info("ClaudeUsage 테스트 런치 감지: 앱 초기화를 건너뜁니다")
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

        bootstrapAntigravityRuntime()
        bootstrapRefreshState()
        syncUpdateCheckState(runImmediate: true)
        refreshSystemStatus()
        startStatusTimer()

        if AppSettings.shared.welcomeState == .pending {
            showSettingsWindow(settingsPanelRawValue: SettingsProviderPanel.welcome.rawValue)
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

        // 자동 업데이트 신뢰성에 대한 권고일 뿐이므로 실행 경로를 막지 않는다.
        // setupStatusItems() 앞에서 모달로 돌던 동안에는 프롬프트에 답하지 않으면
        // 메뉴바 아이템도 팝오버도 타이머도 만들어지지 않았다.
        DispatchQueue.main.async {
            AppLocationChecker.checkAndPromptIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Logger.info(
            "\(AppDistribution.current.appName) 앱 종료"
        )
        refreshScheduler.stop()
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
        AppSingleInstanceGuard.shared.release()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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

        Logger.info("ClaudeUsage 앱 종료 전 Antigravity owned runtime 정리")
        refreshScheduler.stop()
        antigravityTerminationTask = Task { [weak self] in
            guard let self else { return }
            await codexRefreshController.shutdown()
            let runtime =
                await antigravityRuntimeTask.value
            await runtime
                .runtimeController.shutdown()
            finishDeferredTermination(
                timedOut: false
            )
        }
        antigravityTerminationTimeoutTask =
            Task { [weak self] in
                do {
                    try await Task.sleep(
                        for: .seconds(
                            AppRelaunchHandoffPolicy
                                .ownedRuntimeShutdownTimeout
                        )
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

    private func activateExistingChannelInstance() {
        guard let bundleIdentifier =
                Bundle.main.bundleIdentifier
        else {
            return
        }
        let currentProcessIdentifier =
            ProcessInfo.processInfo
                .processIdentifier
        let existing =
            NSRunningApplication
                .runningApplications(
                    withBundleIdentifier:
                        bundleIdentifier
                )
                .first {
                    $0.processIdentifier
                        != currentProcessIdentifier
                    && !$0.isTerminated
                }
        existing?.activate()
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
                if AppSettings.shared.welcomeState != .pending { showInitialClaudeSetupFlow() }
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
            // scheduledTimer was registered on MainActor's main run loop.
            MainActor.assumeIsolated { self?.refreshSystemStatus() }
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
