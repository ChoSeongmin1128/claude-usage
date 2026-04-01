//
//  AppDelegate.swift
//  ClaudeUsage
//
//  전체 통합: 메뉴바, Popover, 설정, 알림, 키보드 단축키
//

import AppKit
import SwiftUI
import Combine
import WebKit

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var timer: Timer?
    private var activeTimerInterval: TimeInterval?
    private var updateCheckTimer: Timer?
    private let apiService = ClaudeAPIService()
    private let codexAPIService = CodexAPIService()
    private let popoverViewModel = PopoverViewModel()

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
    private var claudePopoverResizeWorkItem: DispatchWorkItem?
    private var codexPopoverResizeWorkItem: DispatchWorkItem?
    private var isAdjustingClaudePopoverSize = false
    private var isAdjustingCodexPopoverSize = false

    private var settingsWindow: NSWindow?
    private var settingsSnapshot: AppSettings.Snapshot?
    private var loginWindow: NSWindow?
    private var didLogMissingClaudeIconAsset = false
    private var didLogMissingCodexIconAsset = false
    private var lastObservedProviderStates = AppSettings.shared.providerStates
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?
    private var globalClickMonitor: Any?
    private var claudeCredentialAvailability = ClaudeCredentialAvailability(
        sessionCredentialAvailable: false,
        oauthCredentialAvailable: false
    )

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
        observeSettings()

        // 배터리 상태 변경 감지
        observePowerState()

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
        timer?.invalidate()
        updateCheckTimer?.invalidate()
        statusTimer?.invalidate()
        claudePopoverResizeWorkItem?.cancel()
        codexPopoverResizeWorkItem?.cancel()
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
        popoverViewModel.onRefreshService = { [weak self] service in
            switch service {
            case .claude:
                self?.refreshUsage(force: true)
            case .codex:
                self?.refreshCodexUsage(force: true)
            }
        }
        popoverViewModel.onOpenSettingsForService = { [weak self] service in
            self?.closePopover()
            self?.openSettingsForAuth(service: service)
        }
        popoverViewModel.onServiceSelected = { [weak self] service in
            ServiceSelectionHelper.setActivePopoverService(service, settings: AppSettings.shared)
            self?.updateMenuBar()
            self?.refreshServiceIfNeededOnTabSwitch(service)
            self?.refreshPopoverSizeIfShown(service: service)
        }
        popoverViewModel.onLayoutChanged = { [weak self] service in
            self?.refreshPopoverSizeIfShown(service: service)
        }
        popoverViewModel.onPinChanged = { [weak self] service, isPinned in
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

        popoverViewModel.selectedService = resolvedPopoverService()
        let popoverView = PopoverView(viewModel: popoverViewModel)
        let hostingController = NSHostingController(rootView: popoverView)
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = [.preferredContentSize]
        }

        popover = NSPopover()
        popover?.contentViewController = hostingController
        applyPopoverBehavior(for: popoverViewModel.selectedService)
        popover?.animates = true
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
        popover?.close()
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
        let threshold = max(AppSettings.shared.refreshInterval * 2, 60)
        switch service {
        case .claude:
            let stale = lastUpdated.map { Date().timeIntervalSince($0) >= threshold } ?? true
            if currentUsage == nil || currentError != nil || stale {
                refreshUsage(force: false)
            }
        case .codex:
            let stale = codexLastUpdated.map { Date().timeIntervalSince($0) >= threshold } ?? true
            if currentCodexUsage == nil || codexError != nil || stale {
                refreshCodexUsage(force: false)
            }
        }
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
        guard let targetPopover = popover, targetPopover.isShown else { return }

        resizeWorkItem(for: service)?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let popover: NSPopover? = self.popover
            guard let popover,
                  popover.isShown,
                  let hosting = popover.contentViewController as? NSHostingController<PopoverView> else {
                return
            }
            if self.isAdjustingPopoverSize(for: service) {
                return
            }
            self.setAdjustingPopoverSize(true, for: service)
            defer { self.setAdjustingPopoverSize(false, for: service) }

            let fitting = hosting.view.fittingSize
            guard fitting.width > 0, fitting.height > 0 else { return }

            let compact: Bool = {
                let claudeCompact = AppSettings.shared.claudePopoverCompact
                let codexCompact = AppSettings.shared.codexPopoverCompact
                if claudeCompact == codexCompact { return claudeCompact }
                return service == .claude ? claudeCompact : codexCompact
            }()
            let width: CGFloat = compact ? 300 : 340
            let minHeight: CGFloat = compact ? 104 : 280
            let maxHeight = max(minHeight, (NSScreen.main?.visibleFrame.height ?? 900) - 100)
            let height = min(max(fitting.height, minHeight), maxHeight)
            let targetSize = NSSize(width: width, height: height)

            let changed = abs(popover.contentSize.width - targetSize.width) > 0.5 ||
                          abs(popover.contentSize.height - targetSize.height) > 0.5
            if changed {
                popover.contentSize = targetSize
            }
        }
        setResizeWorkItem(workItem, for: service)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func refreshPopoverSizeIfShown() {
        refreshPopoverSizeIfShown(service: popoverViewModel.selectedService)
    }

    private func showUnifiedContextMenu() {
        let menu = NSMenu()
        let runtimeServices = ServiceSelectionHelper.supportedPopoverServices
        let refreshableServiceSet = Set(refreshableServices)

        let refreshAll = NSMenuItem(title: "전체 새로고침", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshAll.isEnabled = !refreshableServiceSet.isEmpty
        menu.addItem(refreshAll)
        menu.addItem(NSMenuItem.separator())

        for (index, service) in runtimeServices.enumerated() {
            if index > 0 {
                menu.addItem(NSMenuItem.separator())
            }
            addRuntimeServiceContextMenuSection(
                service,
                canRefresh: refreshableServiceSet.contains(service),
                to: menu
            )
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "설정...", action: #selector(settingsClicked), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "사용량 상세 보기", action: #selector(openUsagePage), keyEquivalent: "u"))
        menu.addItem(NSMenuItem(title: "종료", action: #selector(quitClicked), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func addRuntimeServiceContextMenuSection(
        _ service: PopoverService,
        canRefresh: Bool,
        to menu: NSMenu
    ) {
        let settings = AppSettings.shared
        let serviceName = service.displayName
        switch service {
        case .claude:
            menu.addItem(makeServiceToggleMenuItem(
                title: "\(serviceName) 모니터링 활성화",
                isEnabled: settings.isProviderEnabled(.claude),
                action: #selector(toggleClaudeEnabled)
            ))
            menu.addItem(makeServiceRefreshMenuItem(title: "\(serviceName) 새로고침", isEnabled: canRefresh, action: #selector(refreshClaudeClicked)))
            menu.addItem(makeStyleMenuItem(
                title: "\(serviceName) 아이콘 스타일",
                currentStyle: settings.menuBarStyle,
                action: #selector(changeStyle(_:))
            ))
        case .codex:
            menu.addItem(makeServiceToggleMenuItem(
                title: "\(serviceName) 모니터링 활성화",
                isEnabled: settings.isProviderEnabled(.codex),
                action: #selector(toggleCodexEnabled)
            ))
            menu.addItem(makeServiceRefreshMenuItem(title: "\(serviceName) 새로고침", isEnabled: canRefresh, action: #selector(refreshCodexClicked)))
            menu.addItem(makeStyleMenuItem(
                title: "\(serviceName) 아이콘 스타일",
                currentStyle: settings.codexMenuBarStyle,
                action: #selector(changeCodexStyle(_:))
            ))
        }
    }

    private func makeServiceToggleMenuItem(title: String, isEnabled: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.state = isEnabled ? .on : .off
        return item
    }

    private func makeServiceRefreshMenuItem(title: String, isEnabled: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.isEnabled = isEnabled
        return item
    }

    private func makeStyleMenuItem(title: String, currentStyle: MenuBarStyle, action: Selector) -> NSMenuItem {
        let submenu = NSMenu()
        for style in MenuBarStyle.allCases {
            let item = NSMenuItem(title: style.displayName, action: action, keyEquivalent: "")
            item.representedObject = style
            item.state = currentStyle == style ? .on : .off
            submenu.addItem(item)
        }

        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
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
        timer?.invalidate()
        timer = nil
        activeTimerInterval = nil
    }

    private func syncRefreshTimerState() {
        if AppSettings.shared.autoRefresh, hasRefreshableService {
            startTimer()
        } else {
            stopRefreshTimer()
        }
    }

    // MARK: - Timer

    private func startTimer() {
        let interval = PowerMonitor.shared.effectiveRefreshInterval
        guard AppSettings.shared.autoRefresh, hasRefreshableService else {
            stopRefreshTimer()
            Logger.info("자동 새로고침 비활성화")
            return
        }

        if timer != nil, activeTimerInterval == interval {
            return
        }

        timer?.invalidate()

        timer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            self?.refreshAll(force: false)
        }
        activeTimerInterval = interval

        Logger.info("자동 갱신 타이머 시작 (\(Int(interval))초)")
    }

    // MARK: - Settings Observer

    private func observeSettings() {
        // 새로고침 간격 변경 감지
        AppSettings.shared.$refreshInterval
            .dropFirst()
            .sink { [weak self] _ in self?.startTimer() }
            .store(in: &cancellables)

        // 자동 새로고침 토글
        AppSettings.shared.$autoRefresh
            .dropFirst()
            .sink { [weak self] enabled in
                if enabled {
                    self?.startTimer()
                } else {
                    self?.stopRefreshTimer()
                }
            }
            .store(in: &cancellables)

        // 디스플레이 관련 설정 변경 → 메뉴바 즉시 갱신
        // receive(on: RunLoop.main)으로 값 반영 후 업데이트
        let displayPublishers: [AnyPublisher<Void, Never>] = [
            AppSettings.shared.$menuBarStyle.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$percentageDisplay.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$resetTimeDisplay.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$timeFormat.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$showBatteryPercent.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$circularDisplayMode.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$showClaudeIcon.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$menuBarTextHighContrast.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$showCodexIcon.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$codexPercentageDisplay.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$codexResetTimeDisplay.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$codexTimeFormat.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$codexMenuBarStyle.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$codexCircularDisplayMode.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$codexShowBatteryPercent.map { _ in () }.eraseToAnyPublisher()
        ]

        for publisher in displayPublishers {
            publisher
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.updateMenuBar() }
                .store(in: &cancellables)
        }

        AppSettings.shared.$providerStates
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] catalog in
                guard let self else { return }
                let previous = self.lastObservedProviderStates
                self.lastObservedProviderStates = catalog
                self.handleProviderStateTransition(from: previous, to: catalog)
            }
            .store(in: &cancellables)
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
        switch service {
        case .claude:
            if enabled {
                if KeychainManager.shared.hasSessionKey {
                    AppSettings.shared.hasCompletedSetupWizard = true
                    refreshUsage(force: true)
                } else {
                    currentUsage = nil
                    currentError = nil
                    hasAuthError = false
                    showSettingsWindow()
                }
                return
            }

            nextUsageRefreshAllowedAt = nil
            currentUsage = nil
            currentError = nil
            currentOverage = nil
            lastOverageFetchAt = nil
            hasAuthError = false
            consecutiveErrorCount = 0
            isLoading = false
            loadingStartedAt = nil

        case .codex:
            if enabled {
                refreshCodexUsage(force: true)
                return
            }

            nextCodexRefreshAllowedAt = nil
            currentCodexUsage = nil
            codexError = nil
            hasCodexAuthError = false
            codexConsecutiveErrorCount = 0
            isCodexLoading = false
            codexLoadingStartedAt = nil
        }
    }

    private func observePowerState() {
        PowerMonitor.shared.$isOnBattery
            .dropFirst()
            .sink { [weak self] _ in self?.startTimer() }
            .store(in: &cancellables)
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
        for service in ServiceSelectionHelper.supportedPopoverServices {
            if refreshableServices.contains(service) {
                refresh(service: service, force: force)
            } else if ServiceSelectionHelper.isEnabled(service, settings: AppSettings.shared) {
                clearRuntimeServiceState(service)
            }
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
            currentUsage = nil
            currentError = nil
            hasAuthError = false
        case .codex:
            currentCodexUsage = nil
            codexError = CodexAuthManager.shared.isAuthenticated ? nil : .invalidSessionKey
            hasCodexAuthError = !CodexAuthManager.shared.isAuthenticated
        }
    }

    private func refreshUsage(force: Bool = false) {
        guard ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared) else { return }

        if !force, let allowedAt = nextUsageRefreshAllowedAt {
            let remaining = Int(ceil(allowedAt.timeIntervalSinceNow))
            if remaining > 0 {
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
        if isLoading {
            if let startedAt = loadingStartedAt {
                let elapsed = Date().timeIntervalSince(startedAt)
                if elapsed >= 90 {
                    Logger.warning("사용량 갱신 고착 감지(\(Int(elapsed))초) → 상태 복구 후 재시도")
                    isLoading = false
                    loadingStartedAt = nil
                } else {
                    Logger.debug("사용량 갱신 스킵: 이미 요청 진행 중")
                    return
                }
            } else {
                Logger.debug("사용량 갱신 스킵: 이미 요청 진행 중")
                return
            }
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
        guard error.isTemporaryFailure else {
            nextUsageRefreshAllowedAt = nil
            return
        }

        let retryAfterSeconds: Int = {
            switch error {
            case .rateLimited(let retryAfter), .cloudflareBlocked(let retryAfter):
                return retryAfter ?? 0
            case .networkError:
                return 10
            case .serverError(let statusCode):
                return statusCode >= 500 ? 20 : 10
            case .invalidSessionKey, .parseError, .unknownError:
                return 0
            }
        }()

        let floor = Int(max(15, PowerMonitor.shared.effectiveRefreshInterval))
        let backoffSeconds = max(floor, retryAfterSeconds)
        let candidate = Date().addingTimeInterval(TimeInterval(backoffSeconds))

        if let current = nextUsageRefreshAllowedAt, current > candidate {
            return
        }

        nextUsageRefreshAllowedAt = candidate
        popoverViewModel.nextUsageRetryAt = candidate
        refreshPopoverSizeIfShown()
        Logger.info("임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
    }

    private func refreshCodexUsage(force: Bool = false) {
        guard ServiceSelectionHelper.isEnabled(.codex, settings: AppSettings.shared) else { return }

        if !force, let allowedAt = nextCodexRefreshAllowedAt {
            let remaining = Int(ceil(allowedAt.timeIntervalSinceNow))
            if remaining > 0 {
                Logger.debug("Codex 갱신 스킵: 임시 오류 백오프 \(remaining)초 남음")
                return
            }
            nextCodexRefreshAllowedAt = nil
        }

        if isCodexLoading {
            if let startedAt = codexLoadingStartedAt {
                let elapsed = Date().timeIntervalSince(startedAt)
                if elapsed >= 90 {
                    Logger.warning("Codex 갱신 고착 감지(\(Int(elapsed))초) → 상태 복구")
                    isCodexLoading = false
                    codexLoadingStartedAt = nil
                } else {
                    return
                }
            } else {
                return
            }
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
        guard error.isTemporaryFailure else {
            nextCodexRefreshAllowedAt = nil
            return
        }

        let retryAfterSeconds: Int = {
            switch error {
            case .rateLimited(let retryAfter), .cloudflareBlocked(let retryAfter):
                return retryAfter ?? 0
            case .networkError:
                return 10
            case .serverError(let statusCode):
                return statusCode >= 500 ? 20 : 10
            case .invalidSessionKey, .parseError, .unknownError:
                return 0
            }
        }()

        let floor = Int(max(15, PowerMonitor.shared.effectiveRefreshInterval))
        let backoffSeconds = max(floor, retryAfterSeconds)
        let candidate = Date().addingTimeInterval(TimeInterval(backoffSeconds))

        if let current = nextCodexRefreshAllowedAt, current > candidate {
            return
        }
        nextCodexRefreshAllowedAt = candidate
        Logger.info("Codex 임시 오류 백오프 적용: 다음 자동 시도까지 약 \(backoffSeconds)초")
    }

    // MARK: - Menu Bar Update

    private func updateMenuBar() {
        let settings = AppSettings.shared
        guard let button = statusItem?.button else { return }
        let claudeConfig = settings.menuBarDisplayConfig(for: .claude)
        let codexConfig = settings.menuBarDisplayConfig(for: .codex)

        let secondaryColor = secondaryTextColor(for: button)
        let codexIconTintColor = menuBarIconTintColor(for: button)
        let claudeIconTintColor = claudeBrandIconTintColor(for: button)

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
                claudeIcon: claudeConfig.showIcon ? claudeMenuBarIcon(size: NSSize(width: 14, height: 14), tint: claudeIconTintColor) : nil,
                codexConfig: codexConfig,
                codexUsage: currentCodexUsage,
                codexError: codexError,
                hasCodexAuthError: hasCodexAuthError,
                isCodexAuthenticated: CodexAuthManager.shared.isAuthenticated,
                codexIcon: codexConfig.showIcon ? codexMenuBarIcon(size: NSSize(width: 14, height: 14), tint: codexIconTintColor) : nil,
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
                icon: codexConfig.showIcon ? codexMenuBarIcon(size: NSSize(width: 18, height: 18), tint: codexIconTintColor) : nil
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
            icon: claudeConfig.showIcon ? claudeMenuBarIcon(size: NSSize(width: 18, height: 18), tint: claudeIconTintColor) : nil
        )
        applyMenuBarContent(content, to: button)
    }

    private func applyMenuBarContent(_ content: MenuBarRenderedContent, to button: NSStatusBarButton) {
        button.image = content.image
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString(string: "")
        button.toolTip = content.tooltip
    }

    private func secondaryTextColor(for button: NSStatusBarButton) -> NSColor {
        if AppSettings.shared.menuBarTextHighContrast {
            return NSColor.labelColor
        }
        return NSColor.secondaryLabelColor.withAlphaComponent(0.95)
    }

    private func menuBarIconTintColor(for button: NSStatusBarButton) -> NSColor {
        if AppSettings.shared.menuBarTextHighContrast {
            _ = button
            return NSColor.labelColor
        }
        let match = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let base: NSColor = (match == .darkAqua) ? .white : .black
        return base.withAlphaComponent(0.92)
    }

    private func claudeBrandIconTintColor(for button: NSStatusBarButton) -> NSColor {
        _ = button
        return NSColor.systemOrange
    }

    private func resizeWorkItem(for service: PopoverService) -> DispatchWorkItem? {
        switch service {
        case .claude:
            return claudePopoverResizeWorkItem
        case .codex:
            return codexPopoverResizeWorkItem
        }
    }

    private func setResizeWorkItem(_ workItem: DispatchWorkItem?, for service: PopoverService) {
        switch service {
        case .claude:
            claudePopoverResizeWorkItem = workItem
        case .codex:
            codexPopoverResizeWorkItem = workItem
        }
    }

    private func isAdjustingPopoverSize(for service: PopoverService) -> Bool {
        switch service {
        case .claude:
            return isAdjustingClaudePopoverSize
        case .codex:
            return isAdjustingCodexPopoverSize
        }
    }

    private func setAdjustingPopoverSize(_ isAdjusting: Bool, for service: PopoverService) {
        switch service {
        case .claude:
            isAdjustingClaudePopoverSize = isAdjusting
        case .codex:
            isAdjustingCodexPopoverSize = isAdjusting
        }
    }

    private func codexMenuBarIcon(size: NSSize, tint: NSColor) -> NSImage? {
        _ = tint
        if let base = NSImage(named: "CodexMenuBarIcon") {
            return twoToneIcon(base, size: size)
        }
        if !didLogMissingCodexIconAsset {
            didLogMissingCodexIconAsset = true
            Logger.warning("CodexMenuBarIcon 에셋 로드 실패, SF Symbol 폴백 사용")
        }
        if let fallback = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "Codex") {
            return twoToneIcon(fallback, size: size)
        }
        Logger.error("Codex 메뉴바 아이콘 생성 실패(에셋/SF Symbol 모두 실패)")
        return nil
    }

    private func claudeMenuBarIcon(size: NSSize, tint: NSColor) -> NSImage? {
        if let base = NSImage(named: "ClaudeMenuBarIcon") {
            let cropped = imageByTrimmingTransparentPadding(base)
            return tintedIcon(cropped, size: size, tint: tint)
        }
        if !didLogMissingClaudeIconAsset {
            didLogMissingClaudeIconAsset = true
            Logger.warning("ClaudeMenuBarIcon 에셋 로드 실패, SF Symbol 폴백 사용")
        }
        if let fallback = NSImage(systemSymbolName: "brain", accessibilityDescription: "Claude") {
            return tintedIcon(fallback, size: size, tint: tint)
        }
        Logger.error("Claude 메뉴바 아이콘 생성 실패(에셋/SF Symbol 모두 실패)")
        return nil
    }

    private func tintedIcon(_ source: NSImage, size: NSSize, tint: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        tint.setFill()
        // sourceIn: 원본 알파를 마스크로 사용해 단색 아이콘을 안정적으로 생성
        rect.fill(using: .sourceIn)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func twoToneIcon(_ source: NSImage, size: NSSize) -> NSImage {
        let borderWidth: CGFloat = size.width >= 14 ? 0.7 : 0.55
        let glyphSize = NSSize(
            width: max(1, size.width - borderWidth * 2),
            height: max(1, size.height - borderWidth * 2)
        )
        let baseRect = NSRect(
            x: borderWidth,
            y: borderWidth,
            width: glyphSize.width,
            height: glyphSize.height
        )
        let outline = tintedIcon(source, size: glyphSize, tint: NSColor(calibratedWhite: 0.96, alpha: 1.0))
        let fill = tintedIcon(source, size: glyphSize, tint: NSColor(calibratedWhite: 0.06, alpha: 1.0))
        let offsets: [NSPoint] = [
            NSPoint(x: -borderWidth, y: 0),
            NSPoint(x: borderWidth, y: 0),
            NSPoint(x: 0, y: -borderWidth),
            NSPoint(x: 0, y: borderWidth),
            NSPoint(x: -borderWidth, y: -borderWidth),
            NSPoint(x: borderWidth, y: -borderWidth),
            NSPoint(x: -borderWidth, y: borderWidth),
            NSPoint(x: borderWidth, y: borderWidth)
        ]

        let image = NSImage(size: size)
        image.lockFocus()
        for offset in offsets {
            let rect = baseRect.offsetBy(dx: offset.x, dy: offset.y)
            outline.draw(in: rect)
        }
        fill.draw(in: baseRect)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func imageByTrimmingTransparentPadding(_ source: NSImage) -> NSImage {
        guard
            let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let alphaBounds = alphaBoundingBox(in: cg)
        else {
            return source
        }

        let fullBounds = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        if alphaBounds.equalTo(fullBounds) {
            return source
        }

        guard let croppedCG = cg.cropping(to: alphaBounds) else { return source }
        let trimmed = NSImage(cgImage: croppedCG, size: NSSize(width: alphaBounds.width, height: alphaBounds.height))
        trimmed.isTemplate = false
        return trimmed
    }

    private func alphaBoundingBox(in image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = bytesPerRow * height
        var raw = [UInt8](repeating: 0, count: totalBytes)

        guard let ctx = CGContext(
            data: &raw,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let alpha = raw[row + (x * bytesPerPixel) + 3]
                if alpha > 0 {
                    if x < minX { minX = x }
                    if y < minY { minY = y }
                    if x > maxX { maxX = x }
                    if y > maxY { maxY = y }
                }
            }
        }

        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: minX,
            y: minY,
            width: (maxX - minX + 1),
            height: (maxY - minY + 1)
        )
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
            await self.apiService.updatePreferredOrganizationID(AppSettings.shared.preferredOrganizationID)
            let credentialAvailability = await self.apiService.fetchCredentialAvailability()

            if credentialAvailability.sessionCredentialAvailable,
               let key = KeychainManager.shared.load(),
               !key.isEmpty {
                await self.apiService.updateSessionKey(key)
            } else {
                await self.apiService.clearSession()
            }
            let snapshot = await self.apiService.fetchUsageHealthSnapshot()
            await MainActor.run {
                self.applyUsageHealthSnapshot(snapshot)
                if ServiceSelectionHelper.isEnabled(.claude, settings: AppSettings.shared),
                   snapshot.runtime.credentialAvailability.hasAnyCredential {
                    AppSettings.shared.hasCompletedSetupWizard = true
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
                try? KeychainManager.shared.delete()
                Task {
                    await self.apiService.clearSession()
                    let snapshot = await self.apiService.fetchUsageHealthSnapshot()
                    await MainActor.run {
                        AppSettings.shared.hasCompletedSetupWizard = snapshot.runtime.credentialAvailability.hasAnyCredential
                        self.applyUsageHealthSnapshot(snapshot)
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

                // 세션 키 저장
                do {
                    try KeychainManager.shared.save(key)
                } catch {
                    Logger.error("세션 키 저장 실패: \(error)")
                }

                // 1.5초 후 창 닫기 및 모니터링 시작
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run {
                        self.loginWindow?.close()
                    }
                    await self.apiService.updatePreferredOrganizationID(AppSettings.shared.preferredOrganizationID)
                    await self.apiService.updateSessionKey(key)
                    await MainActor.run {
                        AppSettings.shared.hasCompletedSetupWizard = true
                        self.hasAuthError = false
                        self.startMonitoring()
                    }
                    Logger.info("로그인 완료, 모니터링 시작")
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
