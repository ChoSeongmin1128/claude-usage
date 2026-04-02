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
        ProviderEnvironmentDetector.status(for: .gemini)?.isDetected == true
    }

    private var hasAntigravityCredential: Bool {
        ProviderEnvironmentDetector.status(for: .antigravity)?.isDetected == true
    }

    private var refreshableServices: [PopoverService] {
        ServiceSelectionHelper.refreshableServices(
            selectionState: AppSettings.shared.providerSelectionState,
            hasClaudeSessionKey: KeychainManager.shared.hasSessionKey,
            hasClaudeOAuthCredential: claudeCredentialAvailability.oauthCredentialAvailable,
            isCodexAuthenticated: CodexAuthManager.shared.isAuthenticated,
            hasGeminiCredential: hasGeminiCredential,
            hasAntigravityCredential: hasAntigravityCredential
        )
    }

    private var hasRefreshableService: Bool {
        !refreshableServices.isEmpty
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        bootstrapRefreshState()

        // 업데이트 확인
        syncUpdateCheckState(runImmediate: true)

        // Claude 시스템 상태 체크 시작 (5분 간격)
        refreshSystemStatus()
        startStatusTimer()
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
        if hasRefreshableService {
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
        SetupCompletionPolicy.shouldShowSetupFlow(
            hasCompletedSetupWizard: AppSettings.shared.hasCompletedSetupWizard,
            hasReadyCredential: hasReadyClaudeCredential,
            hasSuccessfulFetch: hasSuccessfulClaudeFetch,
            preferredOrganizationID: AppSettings.shared.preferredOrganizationID,
            cachedMetadata: currentClaudeProfileMetadata
        )
    }

    private var hasReadyClaudeCredential: Bool {
        KeychainManager.shared.hasSessionKey
        || claudeCredentialAvailability.hasAnyCredential
        || lastUpdated != nil
    }

    private var hasSuccessfulClaudeFetch: Bool {
        lastUpdated != nil
    }

    private var currentSetupWizardStep: SetupWizardView.Step {
        SetupCompletionPolicy.resolveCredentialStep(
            hasReadyCredential: hasReadyClaudeCredential,
            hasChromeApp: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil
        )
    }

    private var setupWizardProgress: SetupCompletionPolicy.WizardProgress {
        SetupCompletionPolicy.resolveWizardProgress(
            hasReadyCredential: hasReadyClaudeCredential,
            hasSuccessfulFetch: hasSuccessfulClaudeFetch,
            preferredOrganizationID: AppSettings.shared.preferredOrganizationID,
            cachedMetadata: currentClaudeProfileMetadata
        )
    }

    private func resolveClaudeSetupCompletion(
        hasSuccessfulFetch: Bool,
        cachedMetadata: ClaudeProfileMetadata?
    ) -> Bool {
        SetupCompletionPolicy.shouldMarkSetupComplete(
            hasSuccessfulFetch: hasSuccessfulFetch,
            preferredOrganizationID: AppSettings.shared.preferredOrganizationID,
            cachedMetadata: cachedMetadata
        )
    }

    private var isSetupWizardOrganizationReady: Bool {
        setupWizardProgress.isOrganizationReady
    }

    private var setupWizardOrganizationSummary: String {
        setupWizardProgress.organizationSummary
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
        updateCoordinator.apply(
            interval: AppSettings.shared.updateCheckInterval,
            runImmediate: runImmediate
        ) { [weak self] in
            self?.checkForUpdates()
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
                switch service {
                case .claude:
                    self?.refreshUsage(force: true)
                case .codex:
                    self?.refreshCodexUsage(force: true)
                case .gemini:
                    self?.refreshGeminiUsage(force: true)
                case .antigravity:
                    self?.refreshAntigravityUsage(force: true)
                }
            },
            onOpenSettingsForService: { [weak self] service in
                self?.closePopover()
                self?.openSettingsForAuth(service: service)
            },
            onServiceSelected: { [weak self] service in
                ServiceSelectionHelper.setActivePopoverService(service, settings: AppSettings.shared)
                self?.updateMenuBar()
                self?.refreshServiceIfNeededOnTabSwitch(service)
                self?.refreshPopoverSizeIfShown(service: service)
            },
            onLayoutChanged: { [weak self] service in
                self?.refreshPopoverSizeIfShown(service: service)
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
            updatePopoverViewModel(overage: currentOverage)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            refreshPopoverSizeIfShown(service: service)
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
            overage: overage
        )
        popoverViewModel.systemStatus = systemStatus
        popoverViewModel.nextUsageRetryAt = nextUsageRefreshAllowedAt

        refreshPopoverSizeIfShown(service: popoverViewModel.selectedService)
    }

    private func runtimeProviderSnapshots() -> [RuntimeProviderSnapshot] {
        ServiceSelectionHelper.supportedPopoverServices.map(runtimeProviderSnapshot(for:))
    }

    private func runtimeProviderSnapshot(for service: PopoverService) -> RuntimeProviderSnapshot {
        switch service {
        case .claude:
            return RuntimeProviderSnapshot(
                service: .claude,
                payload: currentUsage.map(RuntimeProviderPayload.claude),
                error: currentError,
                isLoading: isLoading,
                lastUpdated: lastUpdated,
                hasCredential: claudeCredentialAvailability.hasAnyCredential,
                hasAuthError: hasAuthError
            )
        case .codex:
            return RuntimeProviderSnapshot(
                service: .codex,
                payload: currentCodexUsage.map(RuntimeProviderPayload.codex),
                error: codexError,
                isLoading: isCodexLoading,
                lastUpdated: codexLastUpdated,
                hasCredential: CodexAuthManager.shared.isAuthenticated,
                hasAuthError: hasCodexAuthError
            )
        case .gemini:
            return RuntimeProviderSnapshot(
                service: .gemini,
                payload: currentGeminiUsage.map(RuntimeProviderPayload.gemini),
                error: geminiError,
                isLoading: isGeminiLoading,
                lastUpdated: geminiLastUpdated,
                hasCredential: hasGeminiCredential,
                hasAuthError: hasGeminiAuthError
            )
        case .antigravity:
            return RuntimeProviderSnapshot(
                service: .antigravity,
                payload: currentAntigravityUsage.map(RuntimeProviderPayload.antigravity),
                error: antigravityError,
                isLoading: isAntigravityLoading,
                lastUpdated: antigravityLastUpdated,
                hasCredential: hasAntigravityCredential,
                hasAuthError: hasAntigravityAuthError
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

    private func refreshPopoverSizeIfShown(service: PopoverService) {
        let kind = ServiceSelectionHelper.providerKind(for: service)
        let compact = AppSettings.shared.isPopoverCompact(for: kind)
        popoverCoordinator.refreshSizeIfShown(service: service, compact: compact)
    }

    private func refreshPopoverSizeIfShown() {
        refreshPopoverSizeIfShown(service: popoverViewModel.selectedService)
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
        refreshAll()
        startTimer()
    }

    private func stopRefreshTimer() {
        _ = refreshScheduler.stop()
    }

    private func syncRefreshTimerState() {
        let change = refreshScheduler.sync(
            autoRefresh: AppSettings.shared.autoRefresh,
            hasRefreshableService: hasRefreshableService,
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
            async let snapshotTask = apiService.fetchUsageHealthSnapshot()
            async let metadataTask = apiService.fetchCachedProfileMetadata()
            let snapshot = await snapshotTask
            let cachedProfileMetadata = await metadataTask
            await MainActor.run {
                self.currentClaudeProfileMetadata = cachedProfileMetadata
                self.currentClaudeNotificationPolicy = cachedProfileMetadata.map(ClaudeNotificationPolicy.init(metadata:))
                self.applyUsageHealthSnapshot(snapshot)
                AppSettings.shared.hasCompletedSetupWizard = self.resolveClaudeSetupCompletion(
                    hasSuccessfulFetch: snapshot.lastOverallSuccessAt != nil,
                    cachedMetadata: cachedProfileMetadata
                )

                if snapshot.runtime.credentialAvailability.hasAnyCredential {
                    if ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared) {
                        self.refreshUsage(force: true)
                    } else {
                        self.updateMenuBar()
                        self.updatePopoverViewModel(overage: self.currentOverage)
                    }
                } else {
                    AppSettings.shared.hasCompletedSetupWizard = false
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
        let action = RefreshOrchestration.actionForEnabledChange(
            state: runtimeActivationState(for: service, enabled: enabled)
        )
        performRuntimeAction(action)
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
        refreshPopoverSizeIfShown()
    }

    private func clearClaudePresentationState(markSetupIncomplete: Bool) {
        if markSetupIncomplete {
            AppSettings.shared.hasCompletedSetupWizard = false
        }
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
        var resetState = RuntimeProviderState()
        switch service {
        case .claude:
            currentOverage = nil
            lastOverageFetchAt = nil
            popoverViewModel.nextUsageRetryAt = nil
        case .codex:
            if !CodexAuthManager.shared.isAuthenticated {
                resetState.error = .invalidSessionKey
                resetState.hasAuthError = true
            }
        case .gemini:
            if !hasGeminiCredential {
                resetState.error = .invalidSessionKey
                resetState.hasAuthError = true
            }
        case .antigravity:
            if !hasAntigravityCredential {
                resetState.error = .invalidSessionKey
                resetState.hasAuthError = true
            }
        }
        runtimeStateCatalog[service] = resetState
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

    private func refreshUsage(force: Bool = false) {
        guard ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared) else { return }

        if !force, let remaining = RefreshExecutionPolicy.remainingBackoffSeconds(until: nextUsageRefreshAllowedAt) {
            if let allowedAt = nextUsageRefreshAllowedAt {
                Logger.debug("사용량 갱신 스킵: 임시 오류 백오프 \(remaining)초 남음")
                popoverViewModel.nextUsageRetryAt = allowedAt
                refreshPopoverSizeIfShown()
                return
            }
            nextUsageRefreshAllowedAt = nil
            popoverViewModel.nextUsageRetryAt = nil
            refreshPopoverSizeIfShown()
        }

        // 이미 갱신 중이면 중복 요청을 막아 로딩/회전 애니메이션 과도 지속을 방지
        switch RefreshExecutionPolicy.inFlightDecision(isLoading: isLoading, startedAt: loadingStartedAt) {
        case .start:
            break
        case .recoverStale(let elapsed):
            Logger.warning("사용량 갱신 고착 감지(\(elapsed)초) → 상태 복구 후 재시도")
            isLoading = false
            loadingStartedAt = nil
        case .skip:
            Logger.debug("사용량 갱신 스킵: 이미 요청 진행 중")
            return
        }

        // 고착 복구 케이스에서는 즉시 로딩 상태를 반영해 UI 튐을 줄인다
        if !isLoading {
            isLoading = true
            loadingStartedAt = Date()
            updatePopoverViewModel(overage: currentOverage)
        } else {
            Logger.debug("사용량 갱신 스킵: 이미 요청 진행 중")
            return
        }

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
                    AppSettings.shared.hasCompletedSetupWizard = self.resolveClaudeSetupCompletion(
                        hasSuccessfulFetch: true,
                        cachedMetadata: cachedProfileMetadata
                    )
                    self.currentClaudeNotificationPolicy = cachedProfileMetadata.map(ClaudeNotificationPolicy.init(metadata:))
                    self.currentUsage = result.usage
                    if let fetchedOverage = result.overage {
                        self.currentOverage = fetchedOverage
                    }
                    if let overageFetchedAt = result.overageFetchedAt {
                        self.lastOverageFetchAt = overageFetchedAt
                    }
                    self.currentError = nil
                    self.isLoading = false
                    self.loadingStartedAt = nil
                    self.nextUsageRefreshAllowedAt = nil
                    self.popoverViewModel.nextUsageRetryAt = nil
                    self.refreshPopoverSizeIfShown()
                    self.hasAuthError = false
                    self.consecutiveErrorCount = 0
                    self.lastUpdated = Date()
                    self.updateMenuBar()
                    self.updatePopoverViewModel(overage: self.currentOverage)
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
                    self.isLoading = false
                    self.loadingStartedAt = nil
                    self.consecutiveErrorCount += 1
                    self.applyUsageRefreshBackoff(for: error)

                    if error.isTemporaryFailure {
                        // 임시 장애(Cloudflare/429/네트워크)는 마지막 성공 데이터를 유지
                        self.hasAuthError = false
                        self.currentError = (self.currentUsage == nil) ? error : nil
                    } else {
                        self.currentError = error
                        self.hasAuthError = error.isDefinitiveAuthFailure
                    }

                    self.updateMenuBar()
                    self.updatePopoverViewModel()
                    self.popoverViewModel.nextUsageRetryAt = self.nextUsageRefreshAllowedAt
                    self.refreshPopoverSizeIfShown()
                    self.syncUsageHealthSnapshotToUI()
                }

            } catch {
                Logger.error("예상치 못한 에러: \(error)")

                let apiError = APIError.unknownError(error.localizedDescription)
                await MainActor.run {
                    self.isLoading = false
                    self.loadingStartedAt = nil
                    self.consecutiveErrorCount += 1
                    self.applyUsageRefreshBackoff(for: apiError)
                    self.hasAuthError = false
                    self.currentError = (self.currentUsage == nil) ? apiError : nil
                    self.updateMenuBar()
                    self.updatePopoverViewModel()
                    self.popoverViewModel.nextUsageRetryAt = self.nextUsageRefreshAllowedAt
                    self.refreshPopoverSizeIfShown()
                    self.syncUsageHealthSnapshotToUI()
                }
            }
        }
    }

    private func applyUsageRefreshBackoff(for error: APIError) {
        let result = RefreshExecutionPolicy.nextBackoffDate(
            for: error,
            minimumInterval: PowerMonitor.shared.effectiveRefreshInterval,
            existingAllowedAt: nextUsageRefreshAllowedAt)

        guard let candidate = result.candidate else {
            nextUsageRefreshAllowedAt = nil
            return
        }

        nextUsageRefreshAllowedAt = candidate
        popoverViewModel.nextUsageRetryAt = candidate
        refreshPopoverSizeIfShown()
        if let backoffSeconds = result.seconds {
            Logger.info("임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
        }
    }

    private func refreshCodexUsage(force: Bool = false) {
        guard ServiceSelectionHelper.isEnabled(.codex, settings: AppSettings.shared) else { return }

        if !force, let remaining = RefreshExecutionPolicy.remainingBackoffSeconds(until: nextCodexRefreshAllowedAt) {
            if nextCodexRefreshAllowedAt != nil {
                Logger.debug("Codex 갱신 스킵: 임시 오류 백오프 \(remaining)초 남음")
                return
            }
            nextCodexRefreshAllowedAt = nil
        }

        switch RefreshExecutionPolicy.inFlightDecision(isLoading: isCodexLoading, startedAt: codexLoadingStartedAt) {
        case .start:
            break
        case .recoverStale(let elapsed):
            Logger.warning("Codex 갱신 고착 감지(\(elapsed)초) → 상태 복구")
            isCodexLoading = false
            codexLoadingStartedAt = nil
        case .skip:
            return
        }

        if !CodexAuthManager.shared.isAuthenticated {
            hasCodexAuthError = true
            codexError = .invalidSessionKey
            currentCodexUsage = nil
            updateMenuBar()
            updatePopoverViewModel(overage: currentOverage)
            return
        }

        isCodexLoading = true
        codexLoadingStartedAt = Date()

        Task {
            do {
                let usage = try await CodexRuntimeRefresher.refresh(
                    apiService: codexAPIService
                )

                await MainActor.run {
                    self.currentCodexUsage = usage
                    self.codexError = nil
                    self.hasCodexAuthError = false
                    self.codexConsecutiveErrorCount = 0
                    self.nextCodexRefreshAllowedAt = nil
                    self.codexLastUpdated = Date()
                    self.isCodexLoading = false
                    self.codexLoadingStartedAt = nil
                    self.updateMenuBar()
                    self.updatePopoverViewModel(overage: self.currentOverage)

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
                    self.isCodexLoading = false
                    self.codexLoadingStartedAt = nil
                    self.codexConsecutiveErrorCount += 1
                    self.applyCodexRefreshBackoff(for: error)
                    self.hasCodexAuthError = error.isDefinitiveAuthFailure
                    self.codexError = error
                    if self.codexConsecutiveErrorCount >= 3 && error.isTemporaryFailure {
                        self.currentCodexUsage = nil
                    }
                    self.updateMenuBar()
                    self.updatePopoverViewModel(overage: self.currentOverage)
                }
            } catch {
                let wrapped = APIError.unknownError(error.localizedDescription)
                await MainActor.run {
                    self.isCodexLoading = false
                    self.codexLoadingStartedAt = nil
                    self.codexConsecutiveErrorCount += 1
                    self.applyCodexRefreshBackoff(for: wrapped)
                    self.hasCodexAuthError = false
                    self.codexError = wrapped
                    if self.codexConsecutiveErrorCount >= 3 {
                        self.currentCodexUsage = nil
                    }
                    self.updateMenuBar()
                    self.updatePopoverViewModel(overage: self.currentOverage)
                }
            }
        }
    }

    private func refreshGeminiUsage(force: Bool = false) {
        guard ServiceSelectionHelper.isEnabled(.gemini, settings: AppSettings.shared) else { return }

        if !force, let remaining = RefreshExecutionPolicy.remainingBackoffSeconds(until: nextGeminiRefreshAllowedAt) {
            if nextGeminiRefreshAllowedAt != nil {
                Logger.debug("Gemini 갱신 스킵: 임시 오류 백오프 \(remaining)초 남음")
                return
            }
            nextGeminiRefreshAllowedAt = nil
        }

        switch RefreshExecutionPolicy.inFlightDecision(isLoading: isGeminiLoading, startedAt: geminiLoadingStartedAt) {
        case .start:
            break
        case .recoverStale(let elapsed):
            Logger.warning("Gemini 갱신 고착 감지(\(elapsed)초) → 상태 복구")
            isGeminiLoading = false
            geminiLoadingStartedAt = nil
        case .skip:
            return
        }

        if !hasGeminiCredential {
            hasGeminiAuthError = true
            geminiError = .invalidSessionKey
            currentGeminiUsage = nil
            updateMenuBar()
            updatePopoverViewModel(overage: currentOverage)
            return
        }

        isGeminiLoading = true
        geminiLoadingStartedAt = Date()

        Task {
            do {
                let usage = try await GeminiRuntimeRefresher.refresh(apiService: geminiAPIService)
                await MainActor.run {
                    self.currentGeminiUsage = usage
                    self.geminiError = nil
                    self.hasGeminiAuthError = false
                    self.geminiConsecutiveErrorCount = 0
                    self.nextGeminiRefreshAllowedAt = nil
                    self.geminiLastUpdated = Date()
                    self.isGeminiLoading = false
                    self.geminiLoadingStartedAt = nil
                    self.updateMenuBar()
                    self.updatePopoverViewModel(overage: self.currentOverage)

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
                    self.isGeminiLoading = false
                    self.geminiLoadingStartedAt = nil
                    self.geminiConsecutiveErrorCount += 1
                    self.applyGeminiRefreshBackoff(for: error)
                    self.hasGeminiAuthError = error.isDefinitiveAuthFailure
                    self.geminiError = error
                    if self.geminiConsecutiveErrorCount >= 3 && error.isTemporaryFailure {
                        self.currentGeminiUsage = nil
                    }
                    self.updateMenuBar()
                    self.updatePopoverViewModel(overage: self.currentOverage)
                }
            } catch {
                let wrapped = APIError.unknownError(error.localizedDescription)
                await MainActor.run {
                    self.isGeminiLoading = false
                    self.geminiLoadingStartedAt = nil
                    self.geminiConsecutiveErrorCount += 1
                    self.applyGeminiRefreshBackoff(for: wrapped)
                    self.hasGeminiAuthError = false
                    self.geminiError = wrapped
                    if self.geminiConsecutiveErrorCount >= 3 {
                        self.currentGeminiUsage = nil
                    }
                    self.updateMenuBar()
                    self.updatePopoverViewModel(overage: self.currentOverage)
                }
            }
        }
    }

    private func refreshAntigravityUsage(force: Bool = false) {
        guard ServiceSelectionHelper.isEnabled(.antigravity, settings: AppSettings.shared) else { return }

        if !force, let remaining = RefreshExecutionPolicy.remainingBackoffSeconds(until: nextAntigravityRefreshAllowedAt) {
            if nextAntigravityRefreshAllowedAt != nil {
                Logger.debug("Antigravity 갱신 스킵: 임시 오류 백오프 \(remaining)초 남음")
                return
            }
            nextAntigravityRefreshAllowedAt = nil
        }

        switch RefreshExecutionPolicy.inFlightDecision(isLoading: isAntigravityLoading, startedAt: antigravityLoadingStartedAt) {
        case .start:
            break
        case .recoverStale(let elapsed):
            Logger.warning("Antigravity 갱신 고착 감지(\(elapsed)초) → 상태 복구")
            isAntigravityLoading = false
            antigravityLoadingStartedAt = nil
        case .skip:
            return
        }

        if !hasAntigravityCredential {
            hasAntigravityAuthError = true
            antigravityError = .invalidSessionKey
            currentAntigravityUsage = nil
            updateMenuBar()
            updatePopoverViewModel(overage: currentOverage)
            return
        }

        isAntigravityLoading = true
        antigravityLoadingStartedAt = Date()

        Task {
            do {
                let usage = try await AntigravityRuntimeRefresher.refresh(apiService: antigravityAPIService)
                await MainActor.run {
                    self.currentAntigravityUsage = usage
                    self.antigravityError = nil
                    self.hasAntigravityAuthError = false
                    self.antigravityConsecutiveErrorCount = 0
                    self.nextAntigravityRefreshAllowedAt = nil
                    self.antigravityLastUpdated = Date()
                    self.isAntigravityLoading = false
                    self.antigravityLoadingStartedAt = nil
                    self.updateMenuBar()
                    self.updatePopoverViewModel(overage: self.currentOverage)

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
                    self.isAntigravityLoading = false
                    self.antigravityLoadingStartedAt = nil
                    self.antigravityConsecutiveErrorCount += 1
                    self.applyAntigravityRefreshBackoff(for: error)
                    self.hasAntigravityAuthError = error.isDefinitiveAuthFailure
                    self.antigravityError = error
                    if self.antigravityConsecutiveErrorCount >= 3 && error.isTemporaryFailure {
                        self.currentAntigravityUsage = nil
                    }
                    self.updateMenuBar()
                    self.updatePopoverViewModel(overage: self.currentOverage)
                }
            } catch {
                let wrapped = APIError.unknownError(error.localizedDescription)
                await MainActor.run {
                    self.isAntigravityLoading = false
                    self.antigravityLoadingStartedAt = nil
                    self.antigravityConsecutiveErrorCount += 1
                    self.applyAntigravityRefreshBackoff(for: wrapped)
                    self.hasAntigravityAuthError = false
                    self.antigravityError = wrapped
                    if self.antigravityConsecutiveErrorCount >= 3 {
                        self.currentAntigravityUsage = nil
                    }
                    self.updateMenuBar()
                    self.updatePopoverViewModel(overage: self.currentOverage)
                }
            }
        }
    }

    private func applyCodexRefreshBackoff(for error: APIError) {
        let result = RefreshExecutionPolicy.nextBackoffDate(
            for: error,
            minimumInterval: PowerMonitor.shared.effectiveRefreshInterval,
            existingAllowedAt: nextCodexRefreshAllowedAt)

        guard let candidate = result.candidate else {
            nextCodexRefreshAllowedAt = nil
            return
        }
        nextCodexRefreshAllowedAt = candidate
        if let backoffSeconds = result.seconds {
            Logger.info("Codex 임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
        }
    }

    private func applyGeminiRefreshBackoff(for error: APIError) {
        let result = RefreshExecutionPolicy.nextBackoffDate(
            for: error,
            minimumInterval: PowerMonitor.shared.effectiveRefreshInterval,
            existingAllowedAt: nextGeminiRefreshAllowedAt)

        guard let candidate = result.candidate else {
            nextGeminiRefreshAllowedAt = nil
            return
        }
        nextGeminiRefreshAllowedAt = candidate
        if let backoffSeconds = result.seconds {
            Logger.info("Gemini 임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
        }
    }

    private func applyAntigravityRefreshBackoff(for error: APIError) {
        let result = RefreshExecutionPolicy.nextBackoffDate(
            for: error,
            minimumInterval: PowerMonitor.shared.effectiveRefreshInterval,
            existingAllowedAt: nextAntigravityRefreshAllowedAt
        )

        guard let candidate = result.candidate else {
            nextAntigravityRefreshAllowedAt = nil
            return
        }
        nextAntigravityRefreshAllowedAt = candidate
        if let backoffSeconds = result.seconds {
            Logger.info("Antigravity 임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
        }
    }

    // MARK: - Menu Bar Update

    private func updateMenuBar() {
        let settings = AppSettings.shared
        guard let button = statusItem?.button else { return }
        let highContrast = AppSettings.shared.menuBarTextHighContrast
        let secondaryColor = MenuBarIconFactory.secondaryTextColor(highContrast: highContrast)
        let claudeIconTintColor = MenuBarIconFactory.claudeBrandIconTintColor()

        let runtimeKinds = ServiceSelectionHelper.enabledRuntimeProviderKinds(settings: settings)
        let compactSnapshots = runtimeKinds.compactMap {
            menuBarProviderSnapshot(
                for: $0,
                iconSize: NSSize(width: 14, height: 14),
                secondaryColor: secondaryColor,
                claudeIconTintColor: claudeIconTintColor
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
            secondaryColor: secondaryColor,
            claudeIconTintColor: claudeIconTintColor
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
        secondaryColor: NSColor,
        claudeIconTintColor: NSColor
    ) -> MenuBarProviderSnapshot? {
        switch kind {
        case .claude:
            guard let config = AppSettings.shared.menuBarDisplayConfig(for: .claude) else { return nil }
            return MenuBarStatusComposer.claudeSnapshot(
                config: config,
                usage: currentUsage,
                error: currentError,
                hasAuthError: hasAuthError,
                hasCredential: claudeCredentialAvailability.hasAnyCredential,
                secondaryColor: secondaryColor,
                icon: config.showIcon ? MenuBarIconFactory.claudeMenuBarIcon(size: iconSize, tint: claudeIconTintColor) : nil
            )
        case .codex:
            guard let config = AppSettings.shared.menuBarDisplayConfig(for: .codex) else { return nil }
            return MenuBarStatusComposer.codexSnapshot(
                config: config,
                usage: currentCodexUsage,
                error: codexError,
                hasAuthError: hasCodexAuthError,
                isAuthenticated: CodexAuthManager.shared.isAuthenticated,
                secondaryColor: secondaryColor,
                icon: config.showIcon ? MenuBarIconFactory.codexMenuBarIcon(size: iconSize) : nil
            )
        case .gemini:
            guard let config = AppSettings.shared.menuBarDisplayConfig(for: .gemini) else { return nil }
            return MenuBarStatusComposer.geminiSnapshot(
                config: config,
                usage: currentGeminiUsage,
                error: geminiError,
                hasAuthError: hasGeminiAuthError,
                hasCredential: hasGeminiCredential,
                secondaryColor: secondaryColor,
                icon: config.showIcon ? MenuBarIconFactory.geminiMenuBarIcon(size: iconSize) : nil
            )
        case .antigravity:
            guard let config = AppSettings.shared.menuBarDisplayConfig(for: .antigravity) else { return nil }
            return MenuBarStatusComposer.antigravitySnapshot(
                config: config,
                usage: currentAntigravityUsage,
                error: antigravityError,
                hasAuthError: hasAntigravityAuthError,
                hasCredential: hasAntigravityCredential,
                secondaryColor: secondaryColor,
                icon: config.showIcon ? MenuBarIconFactory.antigravityMenuBarIcon(size: iconSize) : nil
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

    private func applySettingsFromWindow() {
        Task {
            let result = await ClaudeSettingsApplyCoordinator.syncStoredCredential(
                apiService: self.apiService,
                preferredOrganizationID: AppSettings.shared.preferredOrganizationID,
                providerEnabled: ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared)
            )
            await MainActor.run {
                self.applyUsageHealthSnapshot(result.snapshot)
                AppSettings.shared.hasCompletedSetupWizard = result.shouldMarkSetupComplete
                if result.shouldStartMonitoring {
                    self.startMonitoring()
                } else {
                    self.clearClaudePresentationState(
                        markSetupIncomplete: ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared)
                    )
                    self.updateMenuBar()
                    self.updatePopoverViewModel()
                    self.syncRefreshTimerState()
                    if self.hasRefreshableService {
                        self.refreshAll(force: true)
                    }
                }
            }
            Logger.info("설정 적용 완료")
        }
    }

    private func showSettingsWindow() {
        setupWizardWindowCoordinator.close()

        if settingsWindowCoordinator.focusIfVisible() {
            return
        }

        if !AppSettings.shared.hasCompletedSetupWizard {
            AppSettings.shared.settingsLastTab = "claude"
            AppSettings.shared.claudeSettingsLastTab = "auth"
        }

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
                        AppSettings.shared.hasCompletedSetupWizard = result.shouldMarkSetupComplete
                        self.applyUsageHealthSnapshot(result.snapshot)
                    }
                }
                self.clearClaudePresentationState(markSetupIncomplete: false)
                self.updateMenuBar()
                self.updatePopoverViewModel()
                self.settingsWindowCoordinator.refreshSnapshot(AppSettings.shared.createSnapshot())
                self.syncRefreshTimerState()
                if self.hasRefreshableService {
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
            },
            onSessionKeyStored: { [weak self] in
                guard let self else { return }
                self.applySettingsFromWindow()
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
                            AppSettings.shared.hasCompletedSetupWizard = result.shouldMarkSetupComplete
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
                self?.openClaudeUsageInChrome()
            },
            onOpenWebLogin: { [weak self] in
                self?.setupWizardWindowCoordinator.close()
                self?.showLoginWindow(clearCookies: true)
            },
            onOpenAdvancedSettings: { [weak self] in
                AppSettings.shared.settingsLastTab = "claude"
                AppSettings.shared.claudeSettingsLastTab = "auth"
                self?.setupWizardWindowCoordinator.close()
                self?.showSettingsWindow()
            },
            onOpenOrganizations: { [weak self] in
                AppSettings.shared.settingsLastTab = "claude"
                AppSettings.shared.claudeSettingsLastTab = "organizations"
                self?.setupWizardWindowCoordinator.close()
                self?.showSettingsWindow()
            },
            onVerifyFetch: { [weak self] in
                self?.refreshUsage(force: true)
            },
            onComplete: { [weak self] in
                AppSettings.shared.hasCompletedSetupWizard = self?.setupWizardProgress.stage == .complete
                self?.setupWizardWindowCoordinator.close()
            },
            onDismiss: { [weak self] in
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
        if hasRefreshableService {
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
