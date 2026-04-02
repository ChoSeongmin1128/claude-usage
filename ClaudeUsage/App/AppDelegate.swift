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
    private var updateCheckTimer: Timer?
    private let refreshScheduler = RefreshScheduler()
    private let apiService = ClaudeAPIService()
    private let codexAPIService = CodexAPIService()
    private let popoverCoordinator = AppPopoverCoordinator()
    private let runtimeObservationCoordinator = AppRuntimeObservationCoordinator()

    private var currentUsage: ClaudeUsageResponse?
    private var currentCodexUsage: CodexUsageResponse?
    private var currentOverage: OverageSpendLimitResponse?
    private var lastOverageFetchAt: Date?
    private var systemStatus: ClaudeSystemStatus?
    private var currentError: APIError?
    private var codexError: APIError?
    private var isLoading = false
    private var isCodexLoading = false
    private var loadingStartedAt: Date?
    private var codexLoadingStartedAt: Date?
    private var nextUsageRefreshAllowedAt: Date?
    private var nextCodexRefreshAllowedAt: Date?
    private var lastUpdated: Date?
    private var codexLastUpdated: Date?
    private var hasAuthError = false
    private var hasCodexAuthError = false
    private var consecutiveErrorCount = 0
    private var codexConsecutiveErrorCount = 0
    private var statusTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?

    private var settingsWindow: NSWindow?
    private var settingsSnapshot: AppSettings.Snapshot?
    private var loginWindow: NSWindow?
    private var lastObservedProviderStates = AppSettings.shared.providerStates
    private var eventMonitor: Any?
    private var globalClickMonitor: Any?
    private var claudeCredentialAvailability = ClaudeCredentialAvailability(
        sessionCredentialAvailable: false,
        oauthCredentialAvailable: false
    )

    private var popover: NSPopover? { popoverCoordinator.popover }
    private var popoverViewModel: PopoverViewModel { popoverCoordinator.viewModel }

    private var refreshableServices: [PopoverService] {
        ServiceSelectionHelper.refreshableServices(
            selectionState: AppSettings.shared.providerSelectionState,
            hasClaudeSessionKey: KeychainManager.shared.hasSessionKey,
            hasClaudeOAuthCredential: claudeCredentialAvailability.oauthCredentialAvailable,
            isCodexAuthenticated: CodexAuthManager.shared.isAuthenticated
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

        bootstrapRefreshState()

        // 업데이트 확인
        let interval = AppSettings.shared.updateCheckInterval
        if interval != .off {
            checkForUpdates()
        }
        if let seconds = interval.timerInterval {
            startUpdateCheckTimer(interval: seconds)
        }

        // Claude 시스템 상태 체크 시작 (5분 간격)
        refreshSystemStatus()
        startStatusTimer()
    }

    private func bootstrapRefreshState() {
        Task {
            await self.apiService.updatePreferredOrganizationID(AppSettings.shared.preferredOrganizationID)
            let snapshot = await self.apiService.fetchUsageHealthSnapshot()
            await MainActor.run {
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
                showSettingsWindow()
            }
        } else {
            if ServiceSelectionHelper.isEnabled(.codex, settings: AppSettings.shared) && !CodexAuthManager.shared.isAuthenticated {
                hasCodexAuthError = true
                codexError = .invalidSessionKey
            }
            updateMenuBar()
        }
    }

    private func startUpdateCheckTimer(interval: TimeInterval) {
        updateCheckTimer?.invalidate()
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkForUpdates()
        }
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


    func applicationWillTerminate(_ notification: Notification) {
        Logger.info("ClaudeUsage 앱 종료")
        refreshScheduler.stop()
        updateCheckTimer?.invalidate()
        statusTimer?.invalidate()
        popoverCoordinator.invalidate()
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
                switch service {
                case .claude:
                    AppSettings.shared.claudePopoverPinned = isPinned
                case .codex:
                    AppSettings.shared.codexPopoverPinned = isPinned
                }
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
            updatePopoverViewModel(
                usage: currentUsage,
                codexUsage: currentCodexUsage,
                error: currentError,
                codexError: codexError,
                isLoading: isLoading,
                lastUpdated: lastUpdated,
                overage: currentOverage
            )
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

    private func updatePopoverViewModel(
        usage: ClaudeUsageResponse?,
        codexUsage: CodexUsageResponse?,
        error: APIError?,
        codexError: APIError?,
        isLoading: Bool,
        lastUpdated: Date? = nil,
        overage: OverageSpendLimitResponse? = nil
    ) {
        popoverViewModel.update(
            usage: usage,
            codexUsage: codexUsage,
            error: error,
            codexError: codexError,
            isClaudeLoading: isLoading,
            isCodexLoading: isCodexLoading,
            claudeLastUpdated: lastUpdated,
            codexLastUpdated: codexLastUpdated,
            overage: overage
        )
        popoverViewModel.systemStatus = systemStatus
        popoverViewModel.nextUsageRetryAt = nextUsageRefreshAllowedAt

        refreshPopoverSizeIfShown(service: popoverViewModel.selectedService)
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
            service: service,
            refreshInterval: AppSettings.shared.refreshInterval,
            claudeLastUpdated: lastUpdated,
            codexLastUpdated: codexLastUpdated,
            hasClaudeUsage: currentUsage != nil,
            hasCodexUsage: currentCodexUsage != nil,
            claudeError: currentError,
            codexError: codexError
        ) else { return }

        performRuntimeAction(action)
    }

    private func openSettingsForAuth(service: PopoverService) {
        AppSettings.shared.settingsLastTab = ServiceSelectionHelper.settingsRootTab(for: service)
        switch service {
        case .claude:
            AppSettings.shared.claudeSettingsLastTab = ServiceSelectionHelper.settingsAuthTab()
        case .codex:
            AppSettings.shared.codexSettingsLastTab = ServiceSelectionHelper.settingsAuthTab()
        }
        showSettingsWindow()
    }

    private func refreshPopoverSizeIfShown(service: PopoverService) {
        let compact: Bool = {
            let claudeCompact = AppSettings.shared.claudePopoverCompact
            let codexCompact = AppSettings.shared.codexPopoverCompact
            if claudeCompact == codexCompact { return claudeCompact }
            return service == .claude ? claudeCompact : codexCompact
        }()
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
                claudeToggle: #selector(toggleClaudeEnabled),
                codexToggle: #selector(toggleCodexEnabled),
                claudeRefresh: #selector(refreshClaudeClicked),
                codexRefresh: #selector(refreshCodexClicked),
                claudeStyleChange: #selector(changeStyle(_:)),
                codexStyleChange: #selector(changeCodexStyle(_:))
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

    @objc private func changeStyle(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? MenuBarStyle else { return }
        AppSettings.shared.menuBarStyle = style
        updateMenuBar()
    }

    @objc private func changeCodexStyle(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? MenuBarStyle else { return }
        AppSettings.shared.codexMenuBarStyle = style
        updateMenuBar()
    }

    @objc private func refreshClaudeClicked() {
        refreshUsage(force: true)
    }

    @objc private func refreshCodexClicked() {
        refreshCodexUsage(force: true)
    }

    @objc private func toggleClaudeEnabled() {
        toggleProviderEnabled(.claude)
    }

    @objc private func toggleCodexEnabled() {
        toggleProviderEnabled(.codex)
    }

    private func toggleProviderEnabled(_ service: PopoverService) {
        let settings = AppSettings.shared
        let kind = ServiceSelectionHelper.providerKind(for: service)
        settings.setProviderEnabled(!settings.isProviderEnabled(kind), for: kind)
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        // refreshUsage()가 로딩 상태를 직접 관리하므로 선행 로딩 플래그를 두지 않는다.
        isLoading = false
        loadingStartedAt = nil
        updateMenuBar()
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
            }
        )
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

        updatePopoverViewModel(
            usage: currentUsage,
            codexUsage: currentCodexUsage,
            error: currentError,
            codexError: codexError,
            isLoading: isLoading,
            lastUpdated: lastUpdated,
            overage: currentOverage
        )
        startTimer()
        updateMenuBar()
    }

    private func handleProviderEnabledChange(_ enabled: Bool, for service: PopoverService) {
        let action = RefreshOrchestration.actionForEnabledChange(
            service: service,
            enabled: enabled,
            hasClaudeSessionKey: KeychainManager.shared.hasSessionKey,
            isCodexAuthenticated: CodexAuthManager.shared.isAuthenticated
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
        let previousOAuthCredential = claudeCredentialAvailability.oauthCredentialAvailable
        claudeCredentialAvailability = snapshot.runtime.credentialAvailability
        popoverViewModel.usageHealthSnapshot = snapshot
        popoverViewModel.nextUsageRetryAt = nextUsageRefreshAllowedAt

        if previousOAuthCredential != claudeCredentialAvailability.oauthCredentialAvailable {
            syncRefreshTimerState()
            updateMenuBar()
        }

        refreshPopoverSizeIfShown()
    }

    private func clearClaudePresentationState(markSetupIncomplete: Bool) {
        if markSetupIncomplete {
            AppSettings.shared.hasCompletedSetupWizard = false
        }
        currentUsage = nil
        currentOverage = nil
        lastOverageFetchAt = nil
        currentError = nil
        hasAuthError = false
        consecutiveErrorCount = 0
        isLoading = false
        loadingStartedAt = nil
        nextUsageRefreshAllowedAt = nil
        popoverViewModel.nextUsageRetryAt = nil
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
        case .refresh(let service, let force, let markSetupComplete):
            if markSetupComplete, service == .claude {
                AppSettings.shared.hasCompletedSetupWizard = true
            }
            refresh(service: service, force: force)
        case .clearState(let service):
            clearRuntimeServiceState(service)
        case .clearAndPromptAuth(let service):
            clearStateForAuthPrompt(service)
            showSettingsWindow()
        }
    }

    private func refresh(service: PopoverService, force: Bool) {
        switch service {
        case .claude:
            refreshUsage(force: force)
        case .codex:
            refreshCodexUsage(force: force)
        }
    }

    private func clearRuntimeServiceState(_ service: PopoverService) {
        switch service {
        case .claude:
            nextUsageRefreshAllowedAt = nil
            currentUsage = nil
            currentError = nil
            hasAuthError = false
            currentOverage = nil
            lastOverageFetchAt = nil
            consecutiveErrorCount = 0
            isLoading = false
            loadingStartedAt = nil
            popoverViewModel.nextUsageRetryAt = nil
        case .codex:
            nextCodexRefreshAllowedAt = nil
            currentCodexUsage = nil
            codexError = CodexAuthManager.shared.isAuthenticated ? nil : .invalidSessionKey
            hasCodexAuthError = !CodexAuthManager.shared.isAuthenticated
            codexConsecutiveErrorCount = 0
            isCodexLoading = false
            codexLoadingStartedAt = nil
        }
    }

    private func clearStateForAuthPrompt(_ service: PopoverService) {
        clearRuntimeServiceState(service)

        switch service {
        case .claude:
            currentError = nil
            hasAuthError = false
        case .codex:
            codexError = nil
            hasCodexAuthError = false
        }
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
            updatePopoverViewModel(
                usage: currentUsage,
                codexUsage: currentCodexUsage,
                error: nil,
                codexError: codexError,
                isLoading: true,
                lastUpdated: lastUpdated,
                overage: currentOverage
            )
        } else {
            Logger.debug("사용량 갱신 스킵: 이미 요청 진행 중")
            return
        }

        Task {
            do {
                Logger.debug("사용량 갱신 시작")

                let usage = try await apiService.fetchUsageWithRetry()

                // overage는 5분 캐시로 요청량 절감
                let shouldFetchOverage: Bool = {
                    guard let last = self.lastOverageFetchAt else { return true }
                    return Date().timeIntervalSince(last) >= 300
                }()
                let fetchedOverage = shouldFetchOverage ? (try? await apiService.fetchOverageSpendLimit()) : nil

                await MainActor.run {
                    AppSettings.shared.hasCompletedSetupWizard = true
                    self.currentUsage = usage
                    if let fetchedOverage {
                        self.currentOverage = fetchedOverage
                        self.lastOverageFetchAt = Date()
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
                    self.updatePopoverViewModel(
                        usage: usage,
                        codexUsage: self.currentCodexUsage,
                        error: nil,
                        codexError: self.codexError,
                        isLoading: false,
                        lastUpdated: self.lastUpdated,
                        overage: self.currentOverage
                    )
                    self.syncUsageHealthSnapshotToUI()

                    // 알림 체크
                    NotificationManager.shared.checkThreshold(
                        session: .fiveHour,
                        percentage: usage.fiveHourPercentage,
                        resetAt: usage.fiveHour.resetsAt
                    )
                    NotificationManager.shared.checkThreshold(
                        session: .weekly,
                        percentage: usage.weeklyPercentage,
                        resetAt: usage.sevenDay?.resetsAt
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
                    self.updatePopoverViewModel(
                        usage: self.currentUsage,
                        codexUsage: self.currentCodexUsage,
                        error: error,
                        codexError: self.codexError,
                        isLoading: false
                    )
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
                    self.updatePopoverViewModel(
                        usage: self.currentUsage,
                        codexUsage: self.currentCodexUsage,
                        error: apiError,
                        codexError: self.codexError,
                        isLoading: false
                    )
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
            updatePopoverViewModel(
                usage: currentUsage,
                codexUsage: nil,
                error: currentError,
                codexError: codexError,
                isLoading: isLoading,
                lastUpdated: lastUpdated,
                overage: currentOverage
            )
            return
        }

        isCodexLoading = true
        codexLoadingStartedAt = Date()

        Task {
            do {
                _ = await codexAPIService.refreshTokenIfNeeded()
                let usage = try await codexAPIService.fetchUsageWithRetry()

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
                    self.updatePopoverViewModel(
                        usage: self.currentUsage,
                        codexUsage: usage,
                        error: self.currentError,
                        codexError: nil,
                        isLoading: self.isLoading,
                        lastUpdated: self.lastUpdated,
                        overage: self.currentOverage
                    )

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
                    self.updatePopoverViewModel(
                        usage: self.currentUsage,
                        codexUsage: self.currentCodexUsage,
                        error: self.currentError,
                        codexError: error,
                        isLoading: self.isLoading,
                        lastUpdated: self.lastUpdated,
                        overage: self.currentOverage
                    )
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
                    self.updatePopoverViewModel(
                        usage: self.currentUsage,
                        codexUsage: self.currentCodexUsage,
                        error: self.currentError,
                        codexError: wrapped,
                        isLoading: self.isLoading,
                        lastUpdated: self.lastUpdated,
                        overage: self.currentOverage
                    )
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

    // MARK: - Menu Bar Update

    private func updateMenuBar() {
        let settings = AppSettings.shared
        guard let button = statusItem?.button else { return }
        let claudeConfig = settings.menuBarDisplayConfig(for: .claude)
        let codexConfig = settings.menuBarDisplayConfig(for: .codex)

        let highContrast = AppSettings.shared.menuBarTextHighContrast
        let secondaryColor = MenuBarIconFactory.secondaryTextColor(highContrast: highContrast)
        let claudeIconTintColor = MenuBarIconFactory.claudeBrandIconTintColor()

        if settings.hasMultipleRuntimeEnabledProviders,
           let claudeConfig,
           let codexConfig
        {
            let content = MenuBarStatusComposer.combinedContent(
                claudeConfig: claudeConfig,
                claudeUsage: currentUsage,
                claudeError: currentError,
                hasClaudeAuthError: hasAuthError,
                hasClaudeCredential: claudeCredentialAvailability.hasAnyCredential,
                claudeIcon: claudeConfig.showIcon ? MenuBarIconFactory.claudeMenuBarIcon(size: NSSize(width: 14, height: 14), tint: claudeIconTintColor) : nil,
                codexConfig: codexConfig,
                codexUsage: currentCodexUsage,
                codexError: codexError,
                hasCodexAuthError: hasCodexAuthError,
                isCodexAuthenticated: CodexAuthManager.shared.isAuthenticated,
                codexIcon: codexConfig.showIcon ? MenuBarIconFactory.codexMenuBarIcon(size: NSSize(width: 14, height: 14)) : nil,
                secondaryColor: secondaryColor,
            )
            applyMenuBarContent(content, to: button)
            return
        }

        guard let activeService = resolvedMenuBarService() else {
            applyMenuBarContent(MenuBarStatusComposer.placeholder(secondaryColor: secondaryColor), to: button)
            return
        }

        if activeService == .codex {
            guard let codexConfig else {
                applyMenuBarContent(MenuBarStatusComposer.placeholder(secondaryColor: secondaryColor), to: button)
                return
            }
            let content = MenuBarStatusComposer.codexOnlyContent(
                config: codexConfig,
                usage: currentCodexUsage,
                error: codexError,
                hasAuthError: hasCodexAuthError,
                isAuthenticated: CodexAuthManager.shared.isAuthenticated,
                secondaryColor: secondaryColor,
                icon: codexConfig.showIcon ? MenuBarIconFactory.codexMenuBarIcon(size: NSSize(width: 18, height: 18)) : nil
            )
            applyMenuBarContent(content, to: button)
            return
        }

        guard let claudeConfig else {
            applyMenuBarContent(MenuBarStatusComposer.placeholder(secondaryColor: secondaryColor), to: button)
            return
        }
        let content = MenuBarStatusComposer.claudeOnlyContent(
            config: claudeConfig,
            usage: currentUsage,
            error: currentError,
            hasAuthError: hasAuthError,
            hasCredential: claudeCredentialAvailability.hasAnyCredential,
            secondaryColor: secondaryColor,
            icon: claudeConfig.showIcon ? MenuBarIconFactory.claudeMenuBarIcon(size: NSSize(width: 18, height: 18), tint: claudeIconTintColor) : nil
        )
        applyMenuBarContent(content, to: button)
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
                if result.shouldStartMonitoring {
                    AppSettings.shared.hasCompletedSetupWizard = result.shouldMarkSetupComplete
                    self.startMonitoring()
                } else {
                    self.clearClaudePresentationState(
                        markSetupIncomplete: ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared)
                    )
                    self.updateMenuBar()
                    self.updatePopoverViewModel(
                        usage: nil,
                        codexUsage: self.currentCodexUsage,
                        error: nil,
                        codexError: self.codexError,
                        isLoading: false,
                        lastUpdated: self.lastUpdated,
                        overage: nil
                    )
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
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if !AppSettings.shared.hasCompletedSetupWizard {
            AppSettings.shared.settingsLastTab = "claude"
            AppSettings.shared.claudeSettingsLastTab = "auth"
        }

        settingsSnapshot = AppSettings.shared.createSnapshot()

        let settingsView = SettingsView(
            onSave: { [weak self] in
                guard let self = self else { return }
                self.settingsSnapshot = nil  // 저장 시 스냅샷 클리어 → 복원 방지
                self.settingsWindow?.close()
                self.applySettingsFromWindow()
            },
            onApply: { [weak self] in
                guard let self = self else { return }
                self.settingsSnapshot = AppSettings.shared.createSnapshot()
                self.applySettingsFromWindow()
            },
            onCancel: { [weak self] in
                self?.settingsWindow?.close()
            },
            onOpenLogin: { [weak self] in
                self?.settingsWindow?.close()
                self?.showLoginWindow(clearCookies: true)
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
                self.updatePopoverViewModel(
                    usage: nil,
                    codexUsage: self.currentCodexUsage,
                    error: nil,
                    codexError: self.codexError,
                    isLoading: false,
                    lastUpdated: self.lastUpdated,
                    overage: nil
                )
                self.settingsSnapshot = AppSettings.shared.createSnapshot()
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
                self.updatePopoverViewModel(
                    usage: self.currentUsage,
                    codexUsage: nil,
                    error: self.currentError,
                    codexError: nil,
                    isLoading: self.isLoading,
                    lastUpdated: self.lastUpdated,
                    overage: self.currentOverage
                )
            }
        )

        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "ClaudeUsage 설정"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Login Window

    func showLoginWindow(clearCookies: Bool = false) {
        if let window = loginWindow, window.isVisible {
            if clearCookies {
                window.close()
                loginWindow = nil
            } else {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
        }

        if clearCookies {
            clearWebSessionData()
        }

        if let window = loginWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let loginView = LoginWindowView(
            clearOnOpen: clearCookies,
            onSessionKeyFound: { [weak self] key in
                guard let self = self else { return }

                // 1.5초 후 창 닫기 및 모니터링 시작
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run {
                        self.loginWindow?.close()
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
                            }
                        }
                        Logger.info("로그인 완료, 모니터링 시작")
                    } catch {
                        Logger.error("세션 키 저장 실패: \(error)")
                    }
                }
            },
            onCancel: { [weak self] in
                self?.loginWindow?.close()
            }
        )

        let hostingController = NSHostingController(rootView: loginView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Claude 로그인"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating

        self.loginWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func clearWebSessionData() {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
            let cookieStorage = HTTPCookieStorage.shared
            cookieStorage.cookies?.forEach { cookieStorage.deleteCookie($0) }
            URLCache.shared.removeAllCachedResponses()
            Logger.info("웹 데이터 삭제 완료")
        }
    }

    // MARK: - Actions

    @objc private func refreshClicked() {
        if hasRefreshableService {
            refreshAll(force: true)
        } else {
            showSettingsWindow()
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

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == settingsWindow {
            window.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == settingsWindow, let snapshot = settingsSnapshot {
            AppSettings.shared.restore(from: snapshot)
            settingsSnapshot = nil
        }
    }
}
