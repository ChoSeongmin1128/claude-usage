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

        migrateLegacyAntigravityOAuthCredentialIfNeeded()
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Logger.info("ClaudeUsage 앱 종료 요청 수락")
        return .terminateNow
    }

    func migrateLegacyAntigravityOAuthCredentialIfNeeded() {
        DispatchQueue.global(qos: .utility).async {
            do {
                let store = AntigravityOAuthCredentialsStore()
                let migratedLegacyKeychainCredential = try store.migrateLegacyKeychainCredentialsIfAvailable() != nil
                let accountState = try? AntigravityOAuthAccountStore(activeCredentialStore: store)
                    .syncActiveCredentialIfNeeded()
                guard migratedLegacyKeychainCredential || accountState?.activeAccount != nil else {
                    return
                }

                ProviderEnvironmentDetector.invalidateCache(for: .antigravity)
                ProviderEnvironmentDetector.refreshStatusInBackground(for: .antigravity)
                ProviderEnvironmentDetector.refreshAntigravitySignalsInBackground()
            } catch {
                Logger.warning("[Antigravity] legacy OAuth Keychain 마이그레이션 실패: \(error.localizedDescription)")
            }
        }
    }

    func applyInitialRuntimeProviderDetectionIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.initialRuntimeProviderDetectionKey) == false else { return }
        guard AppSettings.shared.loadedProviderStatesFromDisk == false else {
            defaults.set(true, forKey: Self.initialRuntimeProviderDetectionKey)
            return
        }

        // 초기 감지는 /bin/sh + SQLite + /bin/ps 를 동기로 돌리는데, 이를
        // applicationDidFinishLaunching 중 main thread 에서 수행하면 launch 가
        // 지연된다. 결과는 로그 용도라 순서에 의존하지 않으므로 background 로
        // 옮기고, 실패/미감지 시에도 플래그만 세워 다음 런치에서 반복 시도를 막는다.
        let flagKey = Self.initialRuntimeProviderDetectionKey
        DispatchQueue.global(qos: .utility).async {
            var detectedKinds: [AppProviderKind] = []
            for kind in [AppProviderKind.antigravity] {
                guard ProviderEnvironmentDetector.status(for: kind)?.isDetected == true else { continue }
                detectedKinds.append(kind)
            }

            // UserDefaults 는 thread-safe (Apple 문서화) 이므로 백그라운드에서 직접 기록.
            UserDefaults.standard.set(true, forKey: flagKey)

            if !detectedKinds.isEmpty {
                Logger.info("초기 runtime provider 감지 완료(자동 활성화 없음): \(detectedKinds.map(\.rawValue).joined(separator: ", "))")
            }
        }
    }

    func bootstrapRefreshState() {
        Task {
            await apiService.reloadActiveAccount()
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

        if credentialAvailabilityChanged {
            syncRefreshTimerState()
            updateMenuBar()
        }

        updatePopoverViewModel(overage: currentOverage)
    }
}
