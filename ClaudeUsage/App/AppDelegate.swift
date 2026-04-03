//
//  AppDelegate.swift
//  ClaudeUsage
//
//  전체 통합: 메뉴바, Popover, 설정, 알림, 키보드 단축키
//

import AppKit
import SwiftUI
import WebKit

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties

    private static let initialRuntimeProviderDetectionKey = "initialRuntimeProviderDetectionCompleted"

    private var statusItem: NSStatusItem?
    private let refreshScheduler = RefreshScheduler()
    private let updateCoordinator = AppUpdateCoordinator()
    private let apiService = ClaudeAPIService()
    private let codexAPIService = CodexAPIService()
    private let geminiAPIService = GeminiAPIService()
    private let antigravityAPIService = AntigravityAPIService()
    private let popoverCoordinator = AppPopoverCoordinator()
    private let runtimeObservationCoordinator = AppRuntimeObservationCoordinator()
    private let settingsWindowCoordinator = SettingsWindowCoordinator()
    private let loginWindowCoordinator = LoginWindowCoordinator()
    private let setupWizardWindowCoordinator = SetupWizardWindowCoordinator()

    private var runtimeStateCatalog = RuntimeProviderStateCatalog()
    private var currentOverage: OverageSpendLimitResponse?
    private var currentClaudeNotificationPolicy: ClaudeNotificationPolicy?
    private var currentClaudeProfileMetadata: ClaudeProfileMetadata?
    private var lastOverageFetchAt: Date?
    private var systemStatus: ClaudeSystemStatus?
    private var statusTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?
    private var setupWizardCredentialStepOverride: SetupWizardView.Step?

    private var lastObservedProviderStates = AppSettings.shared.providerStates
    private var eventMonitor: Any?
    private var globalClickMonitor: Any?
    private var claudeCredentialAvailability = ClaudeCredentialAvailability(
        sessionCredentialAvailable: false,
        oauthCredentialAvailable: false
    )

    private var popover: NSPopover? { popoverCoordinator.popover }
    private var popoverViewModel: PopoverViewModel { popoverCoordinator.viewModel }
    private lazy var runtimeRefreshHandlers: [PopoverService: (Bool) -> Void] =
        RuntimeRefreshHandlerRegistry.makeHandlers(
            refreshClaude: { [weak self] force in self?.refreshUsage(force: force) },
            refreshCodex: { [weak self] force in self?.refreshCodexUsage(force: force) },
            refreshGemini: { [weak self] force in self?.refreshGeminiUsage(force: force) },
            refreshAntigravity: { [weak self] force in self?.refreshAntigravityUsage(force: force) }
        )

    private var currentUsage: ClaudeUsageResponse? {
        get { runtimeStateCatalog[.claude].claudeUsage }
        set {
            var state = runtimeStateCatalog[.claude]
            state.payload = newValue.map(RuntimeProviderPayload.claude)
            runtimeStateCatalog[.claude] = state
        }
    }

    private var currentCodexUsage: CodexUsageResponse? {
        get { runtimeStateCatalog[.codex].codexUsage }
        set {
            var state = runtimeStateCatalog[.codex]
            state.payload = newValue.map(RuntimeProviderPayload.codex)
            runtimeStateCatalog[.codex] = state
        }
    }

    private var currentGeminiUsage: GeminiUsageResponse? {
        get { runtimeStateCatalog[.gemini].geminiUsage }
        set {
            var state = runtimeStateCatalog[.gemini]
            state.payload = newValue.map(RuntimeProviderPayload.gemini)
            runtimeStateCatalog[.gemini] = state
        }
    }

    private var currentAntigravityUsage: AntigravityUsageResponse? {
        get { runtimeStateCatalog[.antigravity].antigravityUsage }
        set {
            var state = runtimeStateCatalog[.antigravity]
            state.payload = newValue.map(RuntimeProviderPayload.antigravity)
            runtimeStateCatalog[.antigravity] = state
        }
    }

    private var currentError: APIError? {
        get { runtimeStateCatalog[.claude].error }
        set {
            var state = runtimeStateCatalog[.claude]
            state.error = newValue
            runtimeStateCatalog[.claude] = state
        }
    }

    private var codexError: APIError? {
        get { runtimeStateCatalog[.codex].error }
        set {
            var state = runtimeStateCatalog[.codex]
            state.error = newValue
            runtimeStateCatalog[.codex] = state
        }
    }

    private var geminiError: APIError? {
        get { runtimeStateCatalog[.gemini].error }
        set {
            var state = runtimeStateCatalog[.gemini]
            state.error = newValue
            runtimeStateCatalog[.gemini] = state
        }
    }

    private var antigravityError: APIError? {
        get { runtimeStateCatalog[.antigravity].error }
        set {
            var state = runtimeStateCatalog[.antigravity]
            state.error = newValue
            runtimeStateCatalog[.antigravity] = state
        }
    }

    private var isLoading: Bool {
        get { runtimeStateCatalog[.claude].isLoading }
        set {
            var state = runtimeStateCatalog[.claude]
            state.isLoading = newValue
            runtimeStateCatalog[.claude] = state
        }
    }

    private var isCodexLoading: Bool {
        get { runtimeStateCatalog[.codex].isLoading }
        set {
            var state = runtimeStateCatalog[.codex]
            state.isLoading = newValue
            runtimeStateCatalog[.codex] = state
        }
    }

    private var isGeminiLoading: Bool {
        get { runtimeStateCatalog[.gemini].isLoading }
        set {
            var state = runtimeStateCatalog[.gemini]
            state.isLoading = newValue
            runtimeStateCatalog[.gemini] = state
        }
    }

    private var isAntigravityLoading: Bool {
        get { runtimeStateCatalog[.antigravity].isLoading }
        set {
            var state = runtimeStateCatalog[.antigravity]
            state.isLoading = newValue
            runtimeStateCatalog[.antigravity] = state
        }
    }

    private var loadingStartedAt: Date? {
        get { runtimeStateCatalog[.claude].loadingStartedAt }
        set {
            var state = runtimeStateCatalog[.claude]
            state.loadingStartedAt = newValue
            runtimeStateCatalog[.claude] = state
        }
    }

    private var codexLoadingStartedAt: Date? {
        get { runtimeStateCatalog[.codex].loadingStartedAt }
        set {
            var state = runtimeStateCatalog[.codex]
            state.loadingStartedAt = newValue
            runtimeStateCatalog[.codex] = state
        }
    }

    private var geminiLoadingStartedAt: Date? {
        get { runtimeStateCatalog[.gemini].loadingStartedAt }
        set {
            var state = runtimeStateCatalog[.gemini]
            state.loadingStartedAt = newValue
            runtimeStateCatalog[.gemini] = state
        }
    }

    private var antigravityLoadingStartedAt: Date? {
        get { runtimeStateCatalog[.antigravity].loadingStartedAt }
        set {
            var state = runtimeStateCatalog[.antigravity]
            state.loadingStartedAt = newValue
            runtimeStateCatalog[.antigravity] = state
        }
    }

    private var nextUsageRefreshAllowedAt: Date? {
        get { runtimeStateCatalog[.claude].nextRefreshAllowedAt }
        set {
            var state = runtimeStateCatalog[.claude]
            state.nextRefreshAllowedAt = newValue
            runtimeStateCatalog[.claude] = state
        }
    }

    private var nextCodexRefreshAllowedAt: Date? {
        get { runtimeStateCatalog[.codex].nextRefreshAllowedAt }
        set {
            var state = runtimeStateCatalog[.codex]
            state.nextRefreshAllowedAt = newValue
            runtimeStateCatalog[.codex] = state
        }
    }

    private var nextGeminiRefreshAllowedAt: Date? {
        get { runtimeStateCatalog[.gemini].nextRefreshAllowedAt }
        set {
            var state = runtimeStateCatalog[.gemini]
            state.nextRefreshAllowedAt = newValue
            runtimeStateCatalog[.gemini] = state
        }
    }

    private var nextAntigravityRefreshAllowedAt: Date? {
        get { runtimeStateCatalog[.antigravity].nextRefreshAllowedAt }
        set {
            var state = runtimeStateCatalog[.antigravity]
            state.nextRefreshAllowedAt = newValue
            runtimeStateCatalog[.antigravity] = state
        }
    }

    private var lastUpdated: Date? {
        get { runtimeStateCatalog[.claude].lastUpdated }
        set {
            var state = runtimeStateCatalog[.claude]
            state.lastUpdated = newValue
            runtimeStateCatalog[.claude] = state
        }
    }

    private var codexLastUpdated: Date? {
        get { runtimeStateCatalog[.codex].lastUpdated }
        set {
            var state = runtimeStateCatalog[.codex]
            state.lastUpdated = newValue
            runtimeStateCatalog[.codex] = state
        }
    }

    private var geminiLastUpdated: Date? {
        get { runtimeStateCatalog[.gemini].lastUpdated }
        set {
            var state = runtimeStateCatalog[.gemini]
            state.lastUpdated = newValue
            runtimeStateCatalog[.gemini] = state
        }
    }

    private var antigravityLastUpdated: Date? {
        get { runtimeStateCatalog[.antigravity].lastUpdated }
        set {
            var state = runtimeStateCatalog[.antigravity]
            state.lastUpdated = newValue
            runtimeStateCatalog[.antigravity] = state
        }
    }

    private var hasAuthError: Bool {
        get { runtimeStateCatalog[.claude].hasAuthError }
        set {
            var state = runtimeStateCatalog[.claude]
            state.hasAuthError = newValue
            runtimeStateCatalog[.claude] = state
        }
    }

    private var hasCodexAuthError: Bool {
        get { runtimeStateCatalog[.codex].hasAuthError }
        set {
            var state = runtimeStateCatalog[.codex]
            state.hasAuthError = newValue
            runtimeStateCatalog[.codex] = state
        }
    }

    private var hasGeminiAuthError: Bool {
        get { runtimeStateCatalog[.gemini].hasAuthError }
        set {
            var state = runtimeStateCatalog[.gemini]
            state.hasAuthError = newValue
            runtimeStateCatalog[.gemini] = state
        }
    }

    private var hasAntigravityAuthError: Bool {
        get { runtimeStateCatalog[.antigravity].hasAuthError }
        set {
            var state = runtimeStateCatalog[.antigravity]
            state.hasAuthError = newValue
            runtimeStateCatalog[.antigravity] = state
        }
    }

    private var consecutiveErrorCount: Int {
        get { runtimeStateCatalog[.claude].consecutiveErrorCount }
        set {
            var state = runtimeStateCatalog[.claude]
            state.consecutiveErrorCount = newValue
            runtimeStateCatalog[.claude] = state
        }
    }

    private var codexConsecutiveErrorCount: Int {
        get { runtimeStateCatalog[.codex].consecutiveErrorCount }
        set {
            var state = runtimeStateCatalog[.codex]
            state.consecutiveErrorCount = newValue
            runtimeStateCatalog[.codex] = state
        }
    }

    private var geminiConsecutiveErrorCount: Int {
        get { runtimeStateCatalog[.gemini].consecutiveErrorCount }
        set {
            var state = runtimeStateCatalog[.gemini]
            state.consecutiveErrorCount = newValue
            runtimeStateCatalog[.gemini] = state
        }
    }

    private var antigravityConsecutiveErrorCount: Int {
        get { runtimeStateCatalog[.antigravity].consecutiveErrorCount }
        set {
            var state = runtimeStateCatalog[.antigravity]
            state.consecutiveErrorCount = newValue
            runtimeStateCatalog[.antigravity] = state
        }
    }

    private var hasGeminiCredential: Bool {
        let status = ProviderEnvironmentDetector.status(for: .gemini)
        return status?.credentialState.hasAnyCredential ?? false
    }

    private var hasAntigravityCredential: Bool {
        let status = ProviderEnvironmentDetector.status(for: .antigravity)
        return status?.credentialState.hasAnyCredential ?? false
    }

    private var geminiRuntimeReachability: Bool {
        let status = ProviderEnvironmentDetector.status(for: .gemini)
        return status?.runtimeReachability ?? false
    }

    private var antigravityRuntimeReachability: Bool {
        let status = ProviderEnvironmentDetector.status(for: .antigravity)
        return status?.runtimeReachability ?? false
    }

    private var refreshableServices: [PopoverService] {
        ServiceSelectionHelper.refreshableServices(
            selectionState: AppSettings.shared.providerSelectionState,
            hasClaudeSessionKey: KeychainManager.shared.hasSessionKey,
            hasClaudeOAuthCredential: claudeCredentialAvailability.oauthCredentialAvailable,
            isCodexAuthenticated: CodexAuthManager.shared.isAuthenticated,
            geminiRuntimeReachability: geminiRuntimeReachability,
            antigravityRuntimeReachability: antigravityRuntimeReachability
        )
    }

    private var hasRefreshableService: Bool {
        !refreshableServices.isEmpty
    }

    private var shouldPollRuntimeProviders: Bool {
        hasRefreshableService || ServiceSelectionHelper.hasAnyEnabledService(settings: AppSettings.shared)
    }

    private var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isRunningUnitTests {
            Logger.info("ClaudeUsage 테스트 런치 감지: 앱 초기화를 건너뜁니다")
            return
        }

        Logger.info("ClaudeUsage 앱 시작")

        // 알림 권한 요청
        NotificationManager.shared.requestPermission()

        // 메뉴바 아이템 생성
        setupStatusItems()

        // Popover 생성
        setupPopovers()

        // 키보드 단축키 설정
        setupKeyboardShortcuts()

        // 설정 변경 감지
        bindRuntimeObservers()
        settingsWindowCoordinator.onRestoreSnapshot = { snapshot in
            AppSettings.shared.restore(from: snapshot)
        }

        applyInitialRuntimeProviderDetectionIfNeeded()

        bootstrapRefreshState()

        // 업데이트 확인
        syncUpdateCheckState(runImmediate: true)

        // Claude 시스템 상태 체크 시작 (5분 간격)
        refreshSystemStatus()
        startStatusTimer()
    }

    private func applyInitialRuntimeProviderDetectionIfNeeded() {
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

        if detectedKinds.isEmpty == false {
            Logger.info("초기 runtime provider 감지 완료(자동 활성화 없음): \(detectedKinds.map(\.rawValue).joined(separator: ", "))")
        }
    }

    private func bootstrapRefreshState() {
        Task {
            await self.apiService.updatePreferredOrganizationID(AppSettings.shared.preferredOrganizationID)
            let snapshot = await self.apiService.fetchUsageHealthSnapshot()
            let cachedProfileMetadata = await self.apiService.fetchCachedProfileMetadata()
            await MainActor.run {
                self.currentClaudeProfileMetadata = cachedProfileMetadata
                self.currentClaudeNotificationPolicy = cachedProfileMetadata.map(ClaudeNotificationPolicy.init(metadata:))
                self.applyUsageHealthSnapshot(snapshot)
                self.finishBootstrap(using: snapshot)
            }
        }
    }

    private func finishBootstrap(using snapshot: ClaudeAPIService.UsageHealthSnapshot) {
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

    private func showInitialClaudeSetupFlow() {
        if shouldShowStandaloneSetupWizard {
            showSetupWizardWindow()
        } else {
            showSettingsWindow()
        }
    }

    private var shouldShowStandaloneSetupWizard: Bool {
        claudeSetupPresentation.shouldShowWizard
    }

    private var hasReadyClaudeCredential: Bool {
        SetupCompletionPolicy.hasReadyCredential(
            sessionCredentialAvailable: KeychainManager.shared.hasSessionKey || claudeCredentialAvailability.sessionCredentialAvailable,
            oauthCredentialAvailable: claudeCredentialAvailability.oauthCredentialAvailable
        )
    }

    private var hasSuccessfulClaudeFetch: Bool {
        lastUpdated != nil
    }

    private var hasChromeApp: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil
    }

    private var currentSetupWizardStep: SetupWizardView.Step {
        claudeSetupPresentation.credentialStep
    }

    private var setupWizardProgress: SetupCompletionPolicy.WizardProgress {
        claudeSetupPresentation.progress
    }

    private var claudeSetupPresentation: ClaudeSetupPresentation {
        SetupCompletionPolicy.resolvePresentation(
            hasReadyCredential: hasReadyClaudeCredential,
            hasSuccessfulFetch: hasSuccessfulClaudeFetch,
            preferredOrganizationID: AppSettings.shared.preferredOrganizationID,
            cachedMetadata: currentClaudeProfileMetadata,
            hasChromeApp: hasChromeApp,
            credentialStepOverride: setupWizardCredentialStepOverride
        )
    }

    private var isSetupWizardOrganizationReady: Bool {
        setupWizardProgress.isOrganizationReady
    }

    private var setupWizardOrganizationSummary: String {
        claudeSetupPresentation.organizationSummary
    }

    private func applyClaudeSetupLandingTabsIfNeeded() {
        guard shouldShowStandaloneSetupWizard else { return }

        AppSettings.shared.settingsLastTab = "claude"
        AppSettings.shared.claudeSettingsLastTab = claudeSetupPresentation.landingSettingsTab.rawValue
    }

    private func checkForUpdates() {
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

    private func syncUpdateCheckState(runImmediate: Bool = false) {
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

    // MARK: - Status Item

    private func setupStatusItems() {
        rebuildStatusItems()
        Logger.info("메뉴바 아이템 생성 완료")
    }

    private func rebuildStatusItems() {
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
        appearanceObservation = nil

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = "..."
            button.toolTip = "ClaudeUsage"
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateMenuBar() }
            }
        }
    }

    // MARK: - Popover

    private func setupPopovers() {
        popoverCoordinator.configure(
            initialService: resolvedPopoverService(),
            onRefreshService: { [weak self] service in
                self?.refresh(service: service, force: true)
            },
            onOpenSettingsForService: { [weak self] service in
                self?.closePopover()
                self?.openSettingsForAuth(service: service)
            },
            onServiceSelected: { [weak self] service in
                ServiceSelectionHelper.setActivePopoverService(service, settings: AppSettings.shared)
                self?.updateMenuBar()
                self?.refreshServiceIfNeededOnTabSwitch(service)
            },
            onLayoutChanged: { [weak self] service, reason in
                self?.refreshPopoverSizeIfShown(service: service, reason: reason)
            },
            onPinChanged: { [weak self] service, isPinned in
                guard let self else { return }
                AppSettings.shared.setPopoverPinned(isPinned, for: ServiceSelectionHelper.providerKind(for: service))
                self.applyPopoverBehavior(for: service)
                if isPinned {
                    self.stopGlobalClickMonitor()
                } else if self.popover?.isShown == true {
                    self.startGlobalClickMonitor()
                }
            }
        )

        applyPopoverBehavior(for: popoverViewModel.selectedService)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showUnifiedContextMenu()
        } else {
            toggleUnifiedPopover()
        }
    }

    private func toggleUnifiedPopover() {
        guard let popover = popover, let button = statusItem?.button else { return }

        if !ServiceSelectionHelper.hasAnyEnabledService(settings: AppSettings.shared) {
            showSettingsWindow()
            return
        }

        if popover.isShown {
            closePopover()
        } else {
            let service = resolvedPopoverService()
            popoverViewModel.selectService(service)
            applyPopoverBehavior(for: service)
            let compact = AppSettings.shared.isPopoverCompact(for: ServiceSelectionHelper.providerKind(for: service))
            popoverCoordinator.prepareSizeForPresentation(compact: compact)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            updatePopoverViewModel(overage: currentOverage)
            NSApp.activate()
            if !isPopoverPinned(for: service) {
                startGlobalClickMonitor()
            }
        }
    }

    private func closePopover() {
        popoverCoordinator.close()
        stopGlobalClickMonitor()
    }

    private func updatePopoverViewModel(overage: OverageSpendLimitResponse? = nil) {
        popoverViewModel.update(
            snapshots: runtimeProviderSnapshots(),
            overage: overage,
            setupPresentation: claudeSetupPresentation
        )
        popoverViewModel.systemStatus = systemStatus
        popoverViewModel.nextUsageRetryAt = nextUsageRefreshAllowedAt
    }

    private func syncRuntimePresentation(overage: OverageSpendLimitResponse? = nil) {
        updateMenuBar()
        updatePopoverViewModel(overage: overage ?? currentOverage)
    }

    private func runtimeProviderSnapshots() -> [RuntimeProviderSnapshot] {
        ServiceSelectionHelper.supportedPopoverServices.map(runtimeProviderSnapshot(for:))
    }

    private func runtimeProviderSnapshot(for service: PopoverService) -> RuntimeProviderSnapshot {
        let state = runtimeStateCatalog[service]
        switch service {
        case .claude:
            return RuntimeProviderSnapshot(
                service: .claude,
                payload: state.payload,
                error: state.error,
                isLoading: state.isLoading,
                lastUpdated: state.lastUpdated,
                nextRefreshAllowedAt: state.nextRefreshAllowedAt,
                credentialState: claudeCredentialAvailability.hasAnyCredential ? .usable : .missing,
                isDetected: claudeCredentialAvailability.hasAnyCredential,
                canAttemptRefresh: claudeCredentialAvailability.hasAnyCredential,
                hasAuthError: state.hasAuthError
            )
        case .codex:
            return RuntimeProviderSnapshot(
                service: .codex,
                payload: state.payload,
                error: state.error,
                isLoading: state.isLoading,
                lastUpdated: state.lastUpdated,
                nextRefreshAllowedAt: state.nextRefreshAllowedAt,
                credentialState: CodexAuthManager.shared.isAuthenticated ? .usable : .missing,
                isDetected: CodexAuthManager.shared.isAuthenticated,
                canAttemptRefresh: CodexAuthManager.shared.isAuthenticated,
                hasAuthError: state.hasAuthError
            )
        case .gemini:
            let status = ProviderEnvironmentDetector.status(for: .gemini)
            return RuntimeProviderSnapshot(
                service: .gemini,
                payload: state.payload,
                error: state.error,
                isLoading: state.isLoading,
                lastUpdated: state.lastUpdated,
                nextRefreshAllowedAt: state.nextRefreshAllowedAt,
                credentialState: status?.credentialState ?? .unknown,
                isDetected: status?.isDetected ?? false,
                canAttemptRefresh: status?.canAttemptRefresh ?? false,
                hasAuthError: state.hasAuthError
            )
        case .antigravity:
            let status = ProviderEnvironmentDetector.status(for: .antigravity)
            return RuntimeProviderSnapshot(
                service: .antigravity,
                payload: state.payload,
                error: state.error,
                isLoading: state.isLoading,
                lastUpdated: state.lastUpdated,
                nextRefreshAllowedAt: state.nextRefreshAllowedAt,
                credentialState: status?.credentialState ?? .unknown,
                isDetected: status?.isDetected ?? false,
                canAttemptRefresh: status?.canAttemptRefresh ?? false,
                hasAuthError: state.hasAuthError
            )
        }
    }

    private func resolvedPopoverService() -> PopoverService {
        ServiceSelectionHelper.resolvedPopoverService(settings: AppSettings.shared)
    }

    private func resolvedMenuBarService() -> PopoverService? {
        ServiceSelectionHelper.resolvedMenuBarService(settings: AppSettings.shared)
    }

    private func isPopoverPinned(for service: PopoverService) -> Bool {
        ServiceSelectionHelper.isPinned(service, settings: AppSettings.shared)
    }

    private func applyPopoverBehavior(for service: PopoverService) {
        popover?.behavior = isPopoverPinned(for: service) ? .applicationDefined : .transient
    }

    private func refreshServiceIfNeededOnTabSwitch(_ service: PopoverService) {
        guard let action = RefreshOrchestration.actionForTabSwitch(
            state: runtimePresentationState(for: service),
            refreshInterval: AppSettings.shared.refreshInterval
        ) else { return }

        performRuntimeAction(action)
    }

    private func openSettingsForAuth(service: PopoverService) {
        let kind = ServiceSelectionHelper.providerKind(for: service)
        AppSettings.shared.settingsLastTab = ServiceSelectionHelper.settingsRootTab(for: service)
        AppSettings.shared.setProviderSettingsLastTab(ServiceSelectionHelper.settingsAuthTab(), for: kind)
        showSettingsWindow()
    }

    private func refreshPopoverSizeIfShown(service: PopoverService, reason: PopoverLayoutRefreshReason) {
        switch reason {
        case .serviceSelection, .compactToggle:
            break
        }
        let kind = ServiceSelectionHelper.providerKind(for: service)
        let compact = AppSettings.shared.isPopoverCompact(for: kind)
        popoverCoordinator.refreshSizeIfShown(service: service, compact: compact)
    }

    private func showUnifiedContextMenu() {
        let menu = StatusContextMenuBuilder.build(
            settings: AppSettings.shared,
            runtimeServices: ServiceSelectionHelper.supportedPopoverServices,
            refreshableServiceSet: Set(refreshableServices),
            actions: StatusContextMenuActions(
                target: self,
                refreshAll: #selector(refreshClicked),
                settings: #selector(settingsClicked),
                openUsage: #selector(openUsagePage),
                quit: #selector(quitClicked),
                toggleProvider: #selector(toggleProviderClicked(_:)),
                refreshProvider: #selector(refreshProviderClicked(_:)),
                changeProviderStyle: #selector(changeProviderStyleClicked(_:))
            )
        )

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func startGlobalClickMonitor() {
        stopGlobalClickMonitor()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func stopGlobalClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }

    @objc private func changeProviderStyleClicked(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ProviderStyleMenuSelection else { return }
        applyMenuBarStyle(payload.style, for: payload.service.providerKind)
    }

    private func applyMenuBarStyle(_ style: MenuBarStyle, for kind: AppProviderKind) {
        AppSettings.shared.setMenuBarStyle(style, for: kind)
        updateMenuBar()
    }

    @objc private func refreshProviderClicked(_ sender: NSMenuItem) {
        guard let service = menuService(from: sender) else { return }
        refresh(service: service, force: true)
    }

    @objc private func toggleProviderClicked(_ sender: NSMenuItem) {
        guard let service = menuService(from: sender) else { return }
        toggleProviderEnabled(service)
    }

    private func toggleProviderEnabled(_ service: PopoverService) {
        let settings = AppSettings.shared
        let kind = ServiceSelectionHelper.providerKind(for: service)
        settings.setProviderEnabled(!settings.isProviderEnabled(kind), for: kind)
    }

    private func menuService(from item: NSMenuItem) -> PopoverService? {
        guard let rawValue = item.representedObject as? String else { return nil }
        return PopoverService(rawValue: rawValue)
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        // refreshUsage()가 로딩 상태를 직접 관리하므로 선행 로딩 플래그를 두지 않는다.
        isLoading = false
        loadingStartedAt = nil
        updateMenuBar()
        updatePopoverViewModel(overage: currentOverage)
        refreshAll(force: true)
        startTimer()
    }

    private func stopRefreshTimer() {
        _ = refreshScheduler.stop()
    }

    private func syncRefreshTimerState() {
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

    // MARK: - Timer

    private func startTimer() {
        syncRefreshTimerState()
    }

    // MARK: - Settings Observer

    private func bindRuntimeObservers() {
        runtimeObservationCoordinator.bind(
            onRefreshConfigurationChanged: { [weak self] in
                self?.syncRefreshTimerState()
            },
            onUpdateConfigurationChanged: { [weak self] in
                self?.syncUpdateCheckState(runImmediate: true)
            },
            onMenuBarDisplayChanged: { [weak self] in
                self?.updateMenuBar()
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
            }
        )
    }

    private func handleClaudeSessionKeyChanged() {
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

    private func handleProviderStateTransition(from previous: AppProviderStateCatalog, to current: AppProviderStateCatalog) {
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

    private func handleProviderEnabledChange(_ enabled: Bool, for service: PopoverService) {
        if enabled {
            resetTransientProviderAuthStateIfNeeded(for: service)
        }
        let action = RefreshOrchestration.actionForEnabledChange(
            state: runtimeActivationState(for: service, enabled: enabled)
        )
        performRuntimeAction(action)
    }

    private func resetTransientProviderAuthStateIfNeeded(for service: PopoverService) {
        switch service {
        case .claude:
            return
        case .codex:
            if CodexAuthManager.shared.isAuthenticated {
                codexError = nil
                hasCodexAuthError = false
                codexConsecutiveErrorCount = 0
                nextCodexRefreshAllowedAt = nil
            }
        case .gemini:
            if hasGeminiCredential {
                geminiError = nil
                hasGeminiAuthError = false
                geminiConsecutiveErrorCount = 0
                nextGeminiRefreshAllowedAt = nil
            }
        case .antigravity:
            if hasAntigravityCredential {
                antigravityError = nil
                hasAntigravityAuthError = false
                antigravityConsecutiveErrorCount = 0
                nextAntigravityRefreshAllowedAt = nil
            }
        }
    }

    // MARK: - System Status

    private func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshSystemStatus()
        }
    }

    private func refreshSystemStatus() {
        Task {
            let status = await ClaudeStatusService.shared.fetchStatus()
            await MainActor.run {
                self.systemStatus = status
                self.popoverViewModel.systemStatus = status
            }
        }
    }

    private func syncUsageHealthSnapshotToUI() {
        Task {
            let snapshot = await apiService.fetchUsageHealthSnapshot()
            await MainActor.run {
                self.applyUsageHealthSnapshot(snapshot)
            }
        }
    }

    private func applyUsageHealthSnapshot(_ snapshot: ClaudeAPIService.UsageHealthSnapshot) {
        let previousCredentialAvailability = claudeCredentialAvailability.hasAnyCredential
        claudeCredentialAvailability = snapshot.runtime.credentialAvailability
        popoverViewModel.usageHealthSnapshot = snapshot
        popoverViewModel.nextUsageRetryAt = nextUsageRefreshAllowedAt

        if previousCredentialAvailability != claudeCredentialAvailability.hasAnyCredential {
            syncRefreshTimerState()
            updateMenuBar()
        }

        updatePopoverViewModel(overage: currentOverage)
    }

    private func clearClaudePresentationState(markSetupIncomplete: Bool) {
        currentUsage = nil
        currentOverage = nil
        currentClaudeProfileMetadata = nil
        currentClaudeNotificationPolicy = nil
        lastOverageFetchAt = nil
        lastUpdated = nil
        currentError = nil
        hasAuthError = false
        consecutiveErrorCount = 0
        isLoading = false
        loadingStartedAt = nil
        nextUsageRefreshAllowedAt = nil
        popoverViewModel.nextUsageRetryAt = nil
    }

    private func runtimePresentationState(for service: PopoverService) -> RuntimeProviderPresentationState {
        let snapshot = runtimeProviderSnapshot(for: service)
        return RuntimeProviderPresentationState(
            service: service,
            lastUpdated: snapshot.lastUpdated,
            hasContent: snapshot.hasContent,
            error: snapshot.error
        )
    }

    private func runtimeActivationState(for service: PopoverService, enabled: Bool) -> RuntimeProviderActivationState {
        let snapshot = runtimeProviderSnapshot(for: service)
        return RuntimeProviderActivationState(
            service: service,
            enabled: enabled,
            hasCredential: snapshot.hasCredential
        )
    }

    // MARK: - API

    private func refreshAll(force: Bool = false) {
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

    private func performRuntimeAction(_ action: ProviderRuntimeAction) {
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

    private func refresh(service: PopoverService, force: Bool) {
        runtimeRefreshHandlers[service]?(force)
    }

    private func clearRuntimeServiceState(_ service: PopoverService) {
        if service == .claude {
            currentOverage = nil
            lastOverageFetchAt = nil
            popoverViewModel.nextUsageRetryAt = nil
        }
        runtimeStateCatalog[service] = RuntimeProviderRefreshCoordinator.clearedState(
            service: service,
            isCodexAuthenticated: CodexAuthManager.shared.isAuthenticated,
            requiresInteractiveSetup: ProviderEnvironmentDetector.requiresInteractiveSetup(for: service.providerKind)
        )
    }

    private func clearStateForAuthPrompt(_ service: PopoverService) {
        switch service {
        case .claude:
            currentOverage = nil
            lastOverageFetchAt = nil
            popoverViewModel.nextUsageRetryAt = nil
        case .codex:
            break
        case .gemini:
            break
        case .antigravity:
            break
        }
        runtimeStateCatalog[service] = RuntimeProviderState()
    }

    private func prepareRefresh(
        for service: PopoverService,
        force: Bool,
        respectBackoffWithoutPayload: Bool = true
    ) -> Bool {
        var state = runtimeStateCatalog[service]
        let preparation = RuntimeProviderRefreshCoordinator.prepareForRefresh(
            state: &state,
            force: force,
            respectBackoffWithoutPayload: respectBackoffWithoutPayload
        )
        runtimeStateCatalog[service] = state

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

    private func refreshUsage(force: Bool = false) {
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
                    var state = self.runtimeStateCatalog[.claude]
                    RuntimeProviderRefreshCoordinator.applySuccess(
                        state: &state,
                        payload: .claude(result.usage)
                    )
                    self.runtimeStateCatalog[.claude] = state
                    self.popoverViewModel.nextUsageRetryAt = state.nextRefreshAllowedAt
                    self.syncRuntimePresentation(overage: self.currentOverage)
                    self.syncUsageHealthSnapshotToUI()

                    // 알림 체크
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
                    var state = self.runtimeStateCatalog[.claude]
                    let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
                        state: &state,
                        error: error,
                        minimumInterval: PowerMonitor.shared.effectiveRefreshInterval,
                        hideTemporaryErrorWhilePayloadAvailable: true
                    )
                    self.runtimeStateCatalog[.claude] = state
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
                    var state = self.runtimeStateCatalog[.claude]
                    let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
                        state: &state,
                        error: apiError,
                        minimumInterval: PowerMonitor.shared.effectiveRefreshInterval,
                        hideTemporaryErrorWhilePayloadAvailable: true
                    )
                    self.runtimeStateCatalog[.claude] = state
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

    private func refreshCodexUsage(force: Bool = false) {
        guard ServiceSelectionHelper.isEnabled(.codex, settings: AppSettings.shared) else { return }

        if !CodexAuthManager.shared.isAuthenticated {
            hasCodexAuthError = true
            codexError = .invalidSessionKey
            currentCodexUsage = nil
            syncRuntimePresentation(overage: currentOverage)
            return
        }
        guard prepareRefresh(for: .codex, force: force) else { return }

        Task {
            do {
                let usage = try await CodexRuntimeRefresher.refresh(
                    apiService: codexAPIService
                )

                await MainActor.run {
                    var state = self.runtimeStateCatalog[.codex]
                    RuntimeProviderRefreshCoordinator.applySuccess(
                        state: &state,
                        payload: .codex(usage)
                    )
                    self.runtimeStateCatalog[.codex] = state
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
                    var state = self.runtimeStateCatalog[.codex]
                    let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
                        state: &state,
                        error: error,
                        minimumInterval: PowerMonitor.shared.effectiveRefreshInterval,
                        clearPayloadAfterTemporaryFailures: 3
                    )
                    self.runtimeStateCatalog[.codex] = state
                    if let backoffSeconds = resolution.backoffSeconds {
                        Logger.info("Codex 임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
                    }
                    self.syncRuntimePresentation(overage: self.currentOverage)
                }
            } catch {
                let wrapped = APIError.unknownError(error.localizedDescription)
                await MainActor.run {
                    var state = self.runtimeStateCatalog[.codex]
                    let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
                        state: &state,
                        error: wrapped,
                        minimumInterval: PowerMonitor.shared.effectiveRefreshInterval,
                        clearPayloadAfterTemporaryFailures: 3
                    )
                    self.runtimeStateCatalog[.codex] = state
                    if let backoffSeconds = resolution.backoffSeconds {
                        Logger.info("Codex 임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
                    }
                    self.syncRuntimePresentation(overage: self.currentOverage)
                }
            }
        }
    }

    private func refreshGeminiUsage(force: Bool = false) {
        guard ServiceSelectionHelper.isEnabled(.gemini, settings: AppSettings.shared) else { return }
        guard prepareRefresh(for: .gemini, force: force, respectBackoffWithoutPayload: false) else { return }
        geminiError = nil
        hasGeminiAuthError = false

        Task {
            do {
                let usage = try await GeminiRuntimeRefresher.refresh(apiService: geminiAPIService)
                await MainActor.run {
                    var state = self.runtimeStateCatalog[.gemini]
                    RuntimeProviderRefreshCoordinator.applySuccess(
                        state: &state,
                        payload: .gemini(usage)
                    )
                    self.runtimeStateCatalog[.gemini] = state
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
                    var state = self.runtimeStateCatalog[.gemini]
                    let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
                        state: &state,
                        error: error,
                        minimumInterval: PowerMonitor.shared.effectiveRefreshInterval,
                        clearPayloadAfterTemporaryFailures: 3
                    )
                    self.runtimeStateCatalog[.gemini] = state
                    if let backoffSeconds = resolution.backoffSeconds {
                        Logger.info("Gemini 임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
                    }
                    self.syncRuntimePresentation(overage: self.currentOverage)
                }
            } catch {
                let wrapped = APIError.unknownError(error.localizedDescription)
                await MainActor.run {
                    var state = self.runtimeStateCatalog[.gemini]
                    let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
                        state: &state,
                        error: wrapped,
                        minimumInterval: PowerMonitor.shared.effectiveRefreshInterval,
                        clearPayloadAfterTemporaryFailures: 3
                    )
                    self.runtimeStateCatalog[.gemini] = state
                    if let backoffSeconds = resolution.backoffSeconds {
                        Logger.info("Gemini 임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
                    }
                    self.syncRuntimePresentation(overage: self.currentOverage)
                }
            }
        }
    }

    private func refreshAntigravityUsage(force: Bool = false) {
        guard ServiceSelectionHelper.isEnabled(.antigravity, settings: AppSettings.shared) else { return }
        guard prepareRefresh(for: .antigravity, force: force, respectBackoffWithoutPayload: false) else { return }
        antigravityError = nil
        hasAntigravityAuthError = false

        Task {
            do {
                let usage = try await AntigravityRuntimeRefresher.refresh(apiService: antigravityAPIService)
                await MainActor.run {
                    var state = self.runtimeStateCatalog[.antigravity]
                    RuntimeProviderRefreshCoordinator.applySuccess(
                        state: &state,
                        payload: .antigravity(usage)
                    )
                    self.runtimeStateCatalog[.antigravity] = state
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
                    var state = self.runtimeStateCatalog[.antigravity]
                    let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
                        state: &state,
                        error: error,
                        minimumInterval: PowerMonitor.shared.effectiveRefreshInterval,
                        clearPayloadAfterTemporaryFailures: 3
                    )
                    self.runtimeStateCatalog[.antigravity] = state
                    if let backoffSeconds = resolution.backoffSeconds {
                        Logger.info("Antigravity 임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
                    }
                    self.syncRuntimePresentation(overage: self.currentOverage)
                }
            } catch {
                let wrapped = APIError.unknownError(error.localizedDescription)
                await MainActor.run {
                    var state = self.runtimeStateCatalog[.antigravity]
                    let resolution = RuntimeProviderRefreshCoordinator.applyFailure(
                        state: &state,
                        error: wrapped,
                        minimumInterval: PowerMonitor.shared.effectiveRefreshInterval,
                        clearPayloadAfterTemporaryFailures: 3
                    )
                    self.runtimeStateCatalog[.antigravity] = state
                    if let backoffSeconds = resolution.backoffSeconds {
                        Logger.info("Antigravity 임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
                    }
                    self.syncRuntimePresentation(overage: self.currentOverage)
                }
            }
        }
    }

    // MARK: - Menu Bar Update

    private func updateMenuBar() {
        let settings = AppSettings.shared
        guard let button = statusItem?.button else { return }
        let highContrast = AppSettings.shared.menuBarTextHighContrast
        let secondaryColor = MenuBarIconFactory.secondaryTextColor(highContrast: highContrast)

        let runtimeKinds = ServiceSelectionHelper
            .enabledRuntimeProviderKinds(settings: settings)
            .filter { settings.isProviderVisibleInMenuBar($0) }
        let compactSnapshots = runtimeKinds.compactMap {
            menuBarProviderSnapshot(
                for: $0,
                iconSize: NSSize(width: 14, height: 14),
                secondaryColor: secondaryColor
            )
        }

        if compactSnapshots.count > 1 {
            let content = MenuBarStatusComposer.multipleProviderContent(
                snapshots: compactSnapshots,
                secondaryColor: secondaryColor
            )
            applyMenuBarContent(content, to: button)
            return
        }

        guard let activeService = resolvedMenuBarService() else {
            applyMenuBarContent(MenuBarStatusComposer.placeholder(secondaryColor: secondaryColor), to: button)
            return
        }

        guard let snapshot = menuBarProviderSnapshot(
            for: activeService.providerKind,
            iconSize: NSSize(width: 18, height: 18),
            secondaryColor: secondaryColor
        ) else {
            applyMenuBarContent(MenuBarStatusComposer.placeholder(secondaryColor: secondaryColor), to: button)
            return
        }
        let content = MenuBarStatusComposer.singleProviderContent(
            snapshot: snapshot,
            secondaryColor: secondaryColor
        )
        applyMenuBarContent(content, to: button)
    }

    private func menuBarProviderSnapshot(
        for kind: AppProviderKind,
        iconSize: NSSize,
        secondaryColor: NSColor
    ) -> MenuBarProviderSnapshot? {
        guard AppSettings.shared.isProviderVisibleInMenuBar(kind) else { return nil }
        guard let service = kind.runtimeService else { return nil }
        let runtimeSnapshot = runtimeProviderSnapshot(for: service)
        switch kind {
        case .claude:
            guard let config = AppSettings.shared.menuBarDisplayConfig(for: .claude) else { return nil }
            return MenuBarStatusComposer.claudeSnapshot(
                config: config,
                usage: runtimeSnapshot.claudeUsage,
                error: runtimeSnapshot.error,
                hasAuthError: runtimeSnapshot.hasAuthError,
                hasCredential: runtimeSnapshot.hasCredential,
                secondaryColor: secondaryColor,
                icon: config.showIcon ? MenuBarIconFactory.providerMenuBarIcon(for: .claude, size: iconSize) : nil
            )
        case .codex:
            guard let config = AppSettings.shared.menuBarDisplayConfig(for: .codex) else { return nil }
            return MenuBarStatusComposer.codexSnapshot(
                config: config,
                usage: runtimeSnapshot.codexUsage,
                error: runtimeSnapshot.error,
                hasAuthError: runtimeSnapshot.hasAuthError,
                isAuthenticated: runtimeSnapshot.hasCredential,
                secondaryColor: secondaryColor,
                icon: config.showIcon ? MenuBarIconFactory.providerMenuBarIcon(for: .codex, size: iconSize) : nil
            )
        case .gemini:
            guard let config = AppSettings.shared.menuBarDisplayConfig(for: .gemini) else { return nil }
            return MenuBarStatusComposer.geminiSnapshot(
                config: config,
                usage: runtimeSnapshot.geminiUsage,
                error: runtimeSnapshot.error,
                hasAuthError: runtimeSnapshot.hasAuthError,
                hasCredential: runtimeSnapshot.hasCredential,
                secondaryColor: secondaryColor,
                icon: config.showIcon ? MenuBarIconFactory.providerMenuBarIcon(for: .gemini, size: iconSize) : nil
            )
        case .antigravity:
            guard let config = AppSettings.shared.menuBarDisplayConfig(for: .antigravity) else { return nil }
            return MenuBarStatusComposer.antigravitySnapshot(
                config: config,
                usage: runtimeSnapshot.antigravityUsage,
                error: runtimeSnapshot.error,
                hasAuthError: runtimeSnapshot.hasAuthError,
                hasCredential: runtimeSnapshot.hasCredential,
                secondaryColor: secondaryColor,
                icon: config.showIcon ? MenuBarIconFactory.providerMenuBarIcon(for: .antigravity, size: iconSize) : nil
            )
        }
    }

    private func applyMenuBarContent(_ content: MenuBarRenderedContent, to button: NSStatusBarButton) {
        button.image = content.image
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString(string: "")
        button.toolTip = content.tooltip
    }

    // MARK: - Keyboard Shortcuts

    private func setupKeyboardShortcuts() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command) else { return event }

            switch event.charactersIgnoringModifiers {
            case "r":
                self?.refreshAll(force: true)
                return nil
            case ",":
                self?.showSettingsWindow()
                return nil
            case "u":
                self?.openUsagePageAction()
                return nil
            default:
                return event
            }
        }
    }

    // MARK: - Settings Window

    @objc private func settingsClicked() {
        showSettingsWindow()
    }

    private func syncClaudeSettingsFromWindow() async {
        let result = await ClaudeSettingsApplyCoordinator.syncStoredCredential(
            apiService: self.apiService,
            preferredOrganizationID: AppSettings.shared.preferredOrganizationID,
            providerEnabled: ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared)
        )
        await MainActor.run {
            self.applyUsageHealthSnapshot(result.snapshot)
            if result.shouldStartMonitoring {
                self.startMonitoring()
            } else {
                self.clearClaudePresentationState(
                    markSetupIncomplete: ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared)
                )
                self.updateMenuBar()
                self.updatePopoverViewModel()
                self.syncRefreshTimerState()
                if self.shouldPollRuntimeProviders {
                    self.refreshAll(force: true)
                }
            }
        }
        Logger.info("설정 적용 완료")
    }

    private func applySettingsFromWindow() {
        Task {
            await self.syncClaudeSettingsFromWindow()
        }
    }

    private func showSettingsWindow() {
        setupWizardWindowCoordinator.close()
        if setupWizardCredentialStepOverride == .manualSessionKey {
            setupWizardCredentialStepOverride = nil
        }

        if settingsWindowCoordinator.focusIfVisible() {
            return
        }

        applyClaudeSetupLandingTabsIfNeeded()

        let snapshot = AppSettings.shared.createSnapshot()

        let settingsView = SettingsView(
            onSave: { [weak self] in
                guard let self = self else { return }
                self.settingsWindowCoordinator.close(clearSnapshot: true)
                self.applySettingsFromWindow()
            },
            onApply: { [weak self] in
                guard let self = self else { return }
                self.settingsWindowCoordinator.refreshSnapshot(AppSettings.shared.createSnapshot())
                self.applySettingsFromWindow()
            },
            onCancel: { [weak self] in
                self?.settingsWindowCoordinator.close()
            },
            onOpenLogin: { [weak self] in
                self?.settingsWindowCoordinator.close()
                self?.showLoginWindow(clearCookies: true)
            },
            onOpenClaudeInChrome: { [weak self] in
                self?.openClaudeUsageInChrome()
            },
            onLogout: { [weak self] in
                guard let self = self else { return }
                Task {
                    let result = await ClaudeSettingsApplyCoordinator.logout(
                        apiService: self.apiService,
                        preferredOrganizationID: AppSettings.shared.preferredOrganizationID,
                        providerEnabled: ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared)
                    )
                    await MainActor.run {
                        self.applyUsageHealthSnapshot(result.snapshot)
                    }
                }
                self.clearClaudePresentationState(markSetupIncomplete: false)
                self.updateMenuBar()
                self.updatePopoverViewModel()
                self.settingsWindowCoordinator.refreshSnapshot(AppSettings.shared.createSnapshot())
                self.syncRefreshTimerState()
                if self.shouldPollRuntimeProviders {
                    self.refreshAll(force: true)
                }
                self.clearWebSessionData()
                Logger.info("로그아웃 완료")
            },
            onCodexLogout: { [weak self] in
                guard let self else { return }
                CodexAuthManager.shared.clearCache()
                self.currentCodexUsage = nil
                self.codexError = nil
                self.hasCodexAuthError = false
                self.codexConsecutiveErrorCount = 0
                self.nextCodexRefreshAllowedAt = nil
                self.updateMenuBar()
                self.updatePopoverViewModel(overage: self.currentOverage)
            }
        )
        settingsWindowCoordinator.present(rootView: settingsView, snapshot: snapshot)
    }

    // MARK: - Login Window

    func showLoginWindow(clearCookies: Bool = false) {
        setupWizardWindowCoordinator.close()

        if loginWindowCoordinator.focusIfVisible() {
            if clearCookies {
                loginWindowCoordinator.close()
            } else {
                return
            }
        }

        let presentLoginWindow = { [weak self] in
            guard let self else { return }

            if self.loginWindowCoordinator.focusIfVisible() {
                return
            }

            let loginView = LoginWindowView(
                clearOnOpen: clearCookies,
                onSessionKeyFound: { [weak self] key in
                    guard let self = self else { return }

                    await MainActor.run {
                        self.currentError = nil
                        self.hasAuthError = false
                        if ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared) {
                            self.isLoading = true
                            self.loadingStartedAt = Date()
                        }
                        self.updateMenuBar()
                        self.updatePopoverViewModel(overage: self.currentOverage)
                    }

                    do {
                        let result = try await ClaudeSettingsApplyCoordinator.activateSessionKey(
                            key,
                            apiService: self.apiService,
                            preferredOrganizationID: AppSettings.shared.preferredOrganizationID,
                            providerEnabled: ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared)
                        )
                        await MainActor.run {
                            self.applyUsageHealthSnapshot(result.snapshot)
                            self.hasAuthError = false
                            if result.shouldStartMonitoring {
                                self.startMonitoring()
                            } else {
                                self.updateMenuBar()
                                self.updatePopoverViewModel(overage: self.currentOverage)
                            }
                            self.loginWindowCoordinator.close()
                        }
                        Logger.info("로그인 완료, 모니터링 시작")
                    } catch {
                        await MainActor.run {
                            self.isLoading = false
                            self.loadingStartedAt = nil
                            self.updateMenuBar()
                            self.updatePopoverViewModel(overage: self.currentOverage)
                        }
                        throw error
                    }
                },
                onOpenAdvancedSettings: { [weak self] in
                    AppSettings.shared.settingsLastTab = "claude"
                    AppSettings.shared.claudeSettingsLastTab = "auth"
                    self?.loginWindowCoordinator.close()
                    self?.showSettingsWindow()
                },
                onCancel: { [weak self] in
                    self?.loginWindowCoordinator.close()
                }
            )
            self.loginWindowCoordinator.present(rootView: loginView)
        }

        if clearCookies {
            clearWebSessionData(completion: presentLoginWindow)
        } else {
            presentLoginWindow()
        }
    }

    private func showSetupWizardWindow() {
        if setupWizardWindowCoordinator.focusIfVisible() {
            return
        }

        let rootView = SetupWizardWindowView(
            currentStep: currentSetupWizardStep,
            progress: setupWizardProgress,
            isVerifyingFetch: isLoading,
            onOpenChrome: { [weak self] in
                self?.setupWizardCredentialStepOverride = .chromeImport
                self?.openClaudeUsageInChrome()
            },
            onOpenWebLogin: { [weak self] in
                self?.setupWizardCredentialStepOverride = .webLogin
                self?.setupWizardWindowCoordinator.close()
                self?.showLoginWindow(clearCookies: true)
            },
            onOpenAdvancedSettings: { [weak self] in
                self?.setupWizardCredentialStepOverride = nil
                AppSettings.shared.settingsLastTab = "claude"
                AppSettings.shared.claudeSettingsLastTab = "auth"
                AppSettings.shared.shouldRevealClaudeAdvancedAuth = true
                self?.setupWizardWindowCoordinator.close()
                self?.showSettingsWindow()
            },
            onOpenOrganizations: { [weak self] in
                AppSettings.shared.settingsLastTab = "claude"
                AppSettings.shared.claudeSettingsLastTab = "organizations"
                self?.setupWizardWindowCoordinator.close()
                self?.showSettingsWindow()
            },
            onUseAutomaticOrganization: { [weak self] in
                guard let self else { return }
                AppSettings.shared.preferredOrganizationID = ""
                Task {
                    await self.apiService.updatePreferredOrganizationID("")
                    let snapshot = await self.apiService.fetchUsageHealthSnapshot()
                    let cachedMetadata = await self.apiService.fetchCachedProfileMetadata()
                    await MainActor.run {
                        self.setupWizardCredentialStepOverride = nil
                        self.currentClaudeProfileMetadata = cachedMetadata
                        self.applyUsageHealthSnapshot(snapshot)
                        if ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared),
                           self.hasRefreshableService {
                            self.refreshUsage(force: true)
                        } else {
                            self.updateMenuBar()
                            self.updatePopoverViewModel(overage: self.currentOverage)
                        }
                        self.setupWizardWindowCoordinator.close()
                    }
                }
            },
            onVerifyFetch: { [weak self] in
                self?.refreshUsage(force: true)
            },
            onComplete: { [weak self] in
                self?.setupWizardCredentialStepOverride = nil
                self?.setupWizardWindowCoordinator.close()
            },
            onDismiss: { [weak self] in
                self?.setupWizardCredentialStepOverride = nil
                self?.setupWizardWindowCoordinator.close()
            }
        )
        setupWizardWindowCoordinator.present(rootView: rootView)
    }

    private func clearWebSessionData(completion: (() -> Void)? = nil) {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
            let cookieStorage = HTTPCookieStorage.shared
            cookieStorage.cookies?.forEach { cookieStorage.deleteCookie($0) }
            URLCache.shared.removeAllCachedResponses()
            Logger.info("웹 데이터 삭제 완료")
            completion?()
        }
    }

    // MARK: - Actions

    @objc private func refreshClicked() {
        if shouldPollRuntimeProviders {
            refreshAll(force: true)
        } else {
            showInitialClaudeSetupFlow()
        }
    }

    @objc private func openUsagePage() {
        openUsagePageAction()
    }

    private func openUsagePageAction() {
        if let url = URL(string: "https://claude.ai/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openClaudeUsageInChrome() {
        let targetURL = URL(string: "https://claude.ai/settings/usage")!
        if let chromeAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([targetURL], withApplicationAt: chromeAppURL, configuration: configuration)
            return
        }

        NSWorkspace.shared.open(targetURL)
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }
}
