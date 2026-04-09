import AppKit

extension AppDelegate {
    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isRunningUnitTests {
            Logger.info("ClaudeUsage 테스트 런치 감지: 앱 초기화를 건너뜁니다")
            return
        }

        Logger.info("ClaudeUsage 앱 시작")

        AppLocationChecker.checkAndPromptIfNeeded()
        NotificationManager.shared.requestPermission()
        setupStatusItems()
        setupPopovers()
        setupKeyboardShortcuts()
        bindRuntimeObservers()
        settingsWindowCoordinator.onRestoreSnapshot = { snapshot in
            AppSettings.shared.restore(from: snapshot)
        }

        applyInitialRuntimeProviderDetectionIfNeeded()
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
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        stopGlobalClickMonitor()
    }

    func applyInitialRuntimeProviderDetectionIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.initialRuntimeProviderDetectionKey) == false else { return }
        guard AppSettings.shared.loadedProviderStatesFromDisk == false else {
            defaults.set(true, forKey: Self.initialRuntimeProviderDetectionKey)
            return
        }

        var detectedKinds: [AppProviderKind] = []

        for kind in [AppProviderKind.gemini, .antigravity] {
            guard ProviderEnvironmentDetector.status(for: kind)?.isDetected == true else { continue }
            detectedKinds.append(kind)
        }

        defaults.set(true, forKey: Self.initialRuntimeProviderDetectionKey)

        if !detectedKinds.isEmpty {
            Logger.info("초기 runtime provider 감지 완료(자동 활성화 없음): \(detectedKinds.map(\.rawValue).joined(separator: ", "))")
        }
    }

    func bootstrapRefreshState() {
        Task {
            await apiService.updatePreferredOrganizationID(AppSettings.shared.preferredOrganizationID)
            let snapshot = await apiService.fetchUsageHealthSnapshot()
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
            let result = await UpdateService.shared.checkForUpdates()
            await MainActor.run {
                switch result {
                case .available(let update):
                    AppSettings.shared.availableUpdate = update
                case .upToDate:
                    AppSettings.shared.availableUpdate = nil
                case .error:
                    break
                }
            }
        }
    }

    func syncUpdateCheckState(runImmediate: Bool = false) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let usesExternalScheduler = await UpdateService.shared.usesExternalScheduler()

            if usesExternalScheduler {
                self.updateCoordinator.invalidate()
                return
            }

            self.updateCoordinator.apply(
                interval: AppSettings.shared.updateCheckInterval,
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
            let status = await ClaudeStatusService.shared.fetchStatus()
            await MainActor.run {
                self.systemStatus = status
                self.popoverViewModel.systemStatus = status
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

        if credentialAvailabilityChanged {
            syncRefreshTimerState()
            updateMenuBar()
        }

        updatePopoverViewModel(overage: currentOverage)
    }
}
