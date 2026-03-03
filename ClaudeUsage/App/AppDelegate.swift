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
    private var codexStatusItem: NSStatusItem?
    private var controlStatusItem: NSStatusItem?
    private var popover: NSPopover?
    private var codexPopover: NSPopover?
    private var timer: Timer?
    private var activeTimerInterval: TimeInterval?
    private var updateCheckTimer: Timer?
    private let apiService = ClaudeAPIService()
    private let codexAPIService = CodexAPIService()
    private let popoverViewModel = PopoverViewModel()
    private let codexPopoverViewModel = PopoverViewModel()

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
    private var codexAppearanceObservation: NSKeyValueObservation?
    private var controlAppearanceObservation: NSKeyValueObservation?
    private var claudePopoverResizeWorkItem: DispatchWorkItem?
    private var codexPopoverResizeWorkItem: DispatchWorkItem?
    private var isAdjustingClaudePopoverSize = false
    private var isAdjustingCodexPopoverSize = false

    private var settingsWindow: NSWindow?
    private var settingsSnapshot: AppSettings.Snapshot?
    private var loginWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?
    private var globalClickMonitor: Any?

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

        // 세션 키 확인
        if AppSettings.shared.claudeEnabled && KeychainManager.shared.hasSessionKey {
            Task {
                await self.apiService.updatePreferredOrganizationID(AppSettings.shared.preferredOrganizationID)
                await MainActor.run {
                    self.startMonitoring()
                }
            }
        } else if AppSettings.shared.codexEnabled && CodexAuthManager.shared.isAuthenticated {
            updateMenuBar()
            startTimer()
            refreshCodexUsage(force: true)
        } else if AppSettings.shared.claudeEnabled {
            updateMenuBar()
            showSettingsWindow()
        } else {
            if AppSettings.shared.codexEnabled && !CodexAuthManager.shared.isAuthenticated {
                hasCodexAuthError = true
                codexError = .invalidSessionKey
            }
            updateMenuBar()
        }

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
        syncUsageHealthSnapshotToUI()
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
        if let item = codexStatusItem { NSStatusBar.system.removeStatusItem(item) }
        if let item = controlStatusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
        codexStatusItem = nil
        controlStatusItem = nil
        appearanceObservation = nil
        codexAppearanceObservation = nil
        controlAppearanceObservation = nil

        let settings = AppSettings.shared
        if settings.codexEnabled {
            codexStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = codexStatusItem?.button {
                button.title = "..."
                button.toolTip = "Codex 사용량"
                button.action = #selector(codexStatusItemClicked(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                button.target = self
                codexAppearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.updateMenuBar() }
                }
            }
        }

        if settings.claudeEnabled {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = statusItem?.button {
                button.title = "..."
                button.toolTip = "Claude 사용량"
                button.action = #selector(statusItemClicked(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                button.target = self
                appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.updateMenuBar() }
                }
            }
        }

        if !settings.claudeEnabled && !settings.codexEnabled {
            controlStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = controlStatusItem?.button {
                button.title = "..."
                button.toolTip = "ClaudeUsage"
                button.action = #selector(controlStatusItemClicked(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                button.target = self
                controlAppearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.updateMenuBar() }
                }
            }
        }
    }

    // MARK: - Popover

    private func setupPopovers() {
        setupClaudePopover()
        setupCodexPopover()
    }

    private func setupClaudePopover() {
        popoverViewModel.onRefresh = { [weak self] in
            self?.refreshUsage(force: true)
        }
        popoverViewModel.onOpenSettings = { [weak self] in
            self?.closePopover()
            self?.showSettingsWindow()
        }
        popoverViewModel.onLayoutChanged = { [weak self] in
            self?.refreshPopoverSizeIfShown(service: .claude)
        }
        popoverViewModel.onPinChanged = { [weak self] isPinned in
            guard let self = self else { return }
            if isPinned {
                self.popover?.behavior = .applicationDefined
                self.stopGlobalClickMonitor()
            } else {
                self.popover?.behavior = .transient
                if self.popover?.isShown == true || self.codexPopover?.isShown == true {
                    self.startGlobalClickMonitor()
                }
            }
        }

        let popoverView = PopoverView(viewModel: popoverViewModel, service: .claude)
        let hostingController = NSHostingController(rootView: popoverView)
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = [.preferredContentSize]
        }

        popover = NSPopover()
        popover?.contentViewController = hostingController
        popover?.behavior = AppSettings.shared.claudePopoverPinned ? .applicationDefined : .transient
        popover?.animates = true
    }

    private func setupCodexPopover() {
        codexPopoverViewModel.onRefresh = { [weak self] in
            self?.refreshCodexUsage(force: true)
        }
        codexPopoverViewModel.onOpenSettings = { [weak self] in
            self?.closePopover()
            self?.showSettingsWindow()
        }
        codexPopoverViewModel.onLayoutChanged = { [weak self] in
            self?.refreshPopoverSizeIfShown(service: .codex)
        }
        codexPopoverViewModel.onPinChanged = { [weak self] isPinned in
            guard let self = self else { return }
            if isPinned {
                self.codexPopover?.behavior = .applicationDefined
                self.stopGlobalClickMonitor()
            } else {
                self.codexPopover?.behavior = .transient
                if self.popover?.isShown == true || self.codexPopover?.isShown == true {
                    self.startGlobalClickMonitor()
                }
            }
        }

        let popoverView = PopoverView(viewModel: codexPopoverViewModel, service: .codex)
        let hostingController = NSHostingController(rootView: popoverView)
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = [.preferredContentSize]
        }

        codexPopover = NSPopover()
        codexPopover?.contentViewController = hostingController
        codexPopover?.behavior = AppSettings.shared.codexPopoverPinned ? .applicationDefined : .transient
        codexPopover?.animates = true
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showClaudeContextMenu()
        } else {
            toggleClaudePopover()
        }
    }

    @objc private func codexStatusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showCodexContextMenu()
        } else {
            toggleCodexPopover()
        }
    }

    @objc private func controlStatusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showControlContextMenu()
        } else {
            showSettingsWindow()
        }
    }

    private func toggleClaudePopover() {
        guard let popover = popover, let button = statusItem?.button else { return }

        if popover.isShown {
            closePopover()
        } else {
            codexPopover?.close()
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
            refreshPopoverSizeIfShown(service: .claude)
            NSApp.activate()
            if !AppSettings.shared.claudePopoverPinned {
                startGlobalClickMonitor()
            }
        }
    }

    private func toggleCodexPopover() {
        guard let popover = codexPopover, let button = codexStatusItem?.button else { return }

        if popover.isShown {
            closePopover()
        } else {
            self.popover?.close()
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
            refreshPopoverSizeIfShown(service: .codex)
            NSApp.activate()
            if !AppSettings.shared.codexPopoverPinned {
                startGlobalClickMonitor()
            }
        }
    }

    private func closePopover() {
        popover?.close()
        codexPopover?.close()
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
            codexUsage: nil,
            error: error,
            codexError: nil,
            isLoading: isLoading,
            lastUpdated: lastUpdated,
            overage: overage
        )
        popoverViewModel.systemStatus = systemStatus
        popoverViewModel.nextUsageRetryAt = nextUsageRefreshAllowedAt

        codexPopoverViewModel.update(
            usage: nil,
            codexUsage: codexUsage,
            error: nil,
            codexError: codexError,
            isLoading: isCodexLoading,
            lastUpdated: codexLastUpdated,
            overage: nil
        )
        refreshPopoverSizeIfShown(service: .claude)
        refreshPopoverSizeIfShown(service: .codex)
    }

    private func refreshPopoverSizeIfShown(service: PopoverService) {
        let targetPopover: NSPopover?
        switch service {
        case .claude:
            targetPopover = popover
        case .codex:
            targetPopover = codexPopover
        }
        guard let targetPopover, targetPopover.isShown else { return }

        resizeWorkItem(for: service)?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let popover: NSPopover?
            switch service {
            case .claude:
                popover = self.popover
            case .codex:
                popover = self.codexPopover
            }
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

            let compact = (service == .claude) ? AppSettings.shared.claudePopoverCompact : AppSettings.shared.codexPopoverCompact
            let width: CGFloat = compact ? 300 : 340
            let minHeight: CGFloat = compact ? 170 : 280
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
        refreshPopoverSizeIfShown(service: .claude)
        refreshPopoverSizeIfShown(service: .codex)
    }

    private func showClaudeContextMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Claude 새로고침", action: #selector(refreshClaudeClicked), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())

        let styleMenu = NSMenu()
        for style in MenuBarStyle.allCases {
            let item = NSMenuItem(title: style.displayName, action: #selector(changeStyle(_:)), keyEquivalent: "")
            item.representedObject = style
            item.state = AppSettings.shared.menuBarStyle == style ? .on : .off
            styleMenu.addItem(item)
        }
        let styleItem = NSMenuItem(title: "Claude 아이콘", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "설정...", action: #selector(settingsClicked), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "사용량 상세 보기", action: #selector(openUsagePage), keyEquivalent: "u"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(quitClicked), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func showCodexContextMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Codex 새로고침", action: #selector(refreshCodexClicked), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())

        let styleMenu = NSMenu()
        for style in MenuBarStyle.allCases {
            let item = NSMenuItem(title: style.displayName, action: #selector(changeCodexStyle(_:)), keyEquivalent: "")
            item.representedObject = style
            item.state = AppSettings.shared.codexMenuBarStyle == style ? NSControl.StateValue.on : NSControl.StateValue.off
            styleMenu.addItem(item)
        }
        let styleItem = NSMenuItem(title: "Codex 아이콘", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "설정...", action: #selector(settingsClicked), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(quitClicked), keyEquivalent: "q"))

        codexStatusItem?.menu = menu
        codexStatusItem?.button?.performClick(nil)
        codexStatusItem?.menu = nil
    }

    private func showControlContextMenu() {
        let menu = NSMenu()
        let claudeItem = NSMenuItem(title: "Claude 모니터링 활성화", action: #selector(toggleClaudeEnabled), keyEquivalent: "")
        claudeItem.state = AppSettings.shared.claudeEnabled ? NSControl.StateValue.on : NSControl.StateValue.off
        let codexItem = NSMenuItem(title: "Codex 모니터링 활성화", action: #selector(toggleCodexEnabled), keyEquivalent: "")
        codexItem.state = AppSettings.shared.codexEnabled ? NSControl.StateValue.on : NSControl.StateValue.off
        menu.addItem(claudeItem)
        menu.addItem(codexItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "설정...", action: #selector(settingsClicked), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "종료", action: #selector(quitClicked), keyEquivalent: "q"))

        controlStatusItem?.menu = menu
        controlStatusItem?.button?.performClick(nil)
        controlStatusItem?.menu = nil
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
        AppSettings.shared.claudeEnabled.toggle()
    }

    @objc private func toggleCodexEnabled() {
        AppSettings.shared.codexEnabled.toggle()
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

    // MARK: - Timer

    private func startTimer() {
        let interval = PowerMonitor.shared.effectiveRefreshInterval
        let hasAnyEnabledService = AppSettings.shared.claudeEnabled || AppSettings.shared.codexEnabled
        guard AppSettings.shared.autoRefresh, hasAnyEnabledService else {
            timer?.invalidate()
            timer = nil
            activeTimerInterval = nil
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
                    self?.timer?.invalidate()
                    self?.timer = nil
                    self?.activeTimerInterval = nil
                }
            }
            .store(in: &cancellables)

        // 디스플레이 관련 설정 변경 → 메뉴바 즉시 갱신
        // receive(on: RunLoop.main)으로 값 반영 후 업데이트
        let displayPublishers = [
            AppSettings.shared.$menuBarStyle.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$percentageDisplay.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$resetTimeDisplay.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$timeFormat.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$showBatteryPercent.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$circularDisplayMode.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$claudeEnabled.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$showClaudeIcon.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$menuBarTextHighContrast.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$codexEnabled.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$showCodexIcon.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$codexPercentageDisplay.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$codexResetTimeDisplay.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$codexMenuBarStyle.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$codexCircularDisplayMode.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$codexShowBatteryPercent.map { _ in () }.eraseToAnyPublisher(),
        ]

        for publisher in displayPublishers {
            publisher
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.updateMenuBar() }
                .store(in: &cancellables)
        }

        AppSettings.shared.$claudeEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.rebuildStatusItems()
                self.setupPopovers()
                if enabled {
                    if KeychainManager.shared.hasSessionKey {
                        self.refreshUsage(force: true)
                    } else {
                        self.currentUsage = nil
                        self.currentError = nil
                        self.hasAuthError = false
                        self.showSettingsWindow()
                    }
                } else {
                    self.nextUsageRefreshAllowedAt = nil
                    self.currentUsage = nil
                    self.currentError = nil
                    self.currentOverage = nil
                    self.lastOverageFetchAt = nil
                    self.hasAuthError = false
                    self.consecutiveErrorCount = 0
                    self.isLoading = false
                    self.loadingStartedAt = nil
                }
                self.startTimer()
                self.updatePopoverViewModel(
                    usage: self.currentUsage,
                    codexUsage: self.currentCodexUsage,
                    error: self.currentError,
                    codexError: self.codexError,
                    isLoading: self.isLoading,
                    lastUpdated: self.lastUpdated,
                    overage: self.currentOverage
                )
                self.updateMenuBar()
            }
            .store(in: &cancellables)

        AppSettings.shared.$codexEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.rebuildStatusItems()
                self.setupPopovers()
                if enabled {
                    self.refreshCodexUsage(force: true)
                } else {
                    self.nextCodexRefreshAllowedAt = nil
                    self.currentCodexUsage = nil
                    self.codexError = nil
                    self.hasCodexAuthError = false
                    self.codexConsecutiveErrorCount = 0
                    self.isCodexLoading = false
                    self.codexLoadingStartedAt = nil
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
                self.startTimer()
                self.updateMenuBar()
            }
            .store(in: &cancellables)
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
                self.popoverViewModel.usageHealthSnapshot = snapshot
                self.popoverViewModel.nextUsageRetryAt = self.nextUsageRefreshAllowedAt
                self.refreshPopoverSizeIfShown()
            }
        }
    }

    // MARK: - API

    private func refreshAll(force: Bool = false) {
        if AppSettings.shared.claudeEnabled && KeychainManager.shared.hasSessionKey {
            refreshUsage(force: force)
        } else {
            currentUsage = nil
            currentError = nil
            hasAuthError = false
        }
        if AppSettings.shared.codexEnabled {
            refreshCodexUsage(force: force)
        }
    }

    private func refreshUsage(force: Bool = false) {
        guard AppSettings.shared.claudeEnabled else { return }

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
        guard AppSettings.shared.codexEnabled else { return }

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

        if let controlButton = controlStatusItem?.button {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: secondaryTextColor(for: controlButton)
            ]
            let text = "⋯"
            let size = (text as NSString).size(withAttributes: attrs)
            let image = NSImage(size: NSSize(width: max(14, size.width), height: 22), flipped: false) { _ in
                (text as NSString).draw(at: NSPoint(x: 0, y: (22 - size.height) / 2), withAttributes: attrs)
                return true
            }
            image.isTemplate = false
            controlButton.image = image
            controlButton.imagePosition = .imageOnly
            controlButton.attributedTitle = NSAttributedString(string: "")
            controlButton.toolTip = "ClaudeUsage 설정"
        }

        if let codexButton = codexStatusItem?.button {
            renderCodexOnlyMenuBar(button: codexButton, secondaryColor: secondaryTextColor(for: codexButton))
        }

        guard let button = statusItem?.button else { return }

        // 메뉴바 외관 감지 (배경화면 밝기 반영)
        let secondaryColor = secondaryTextColor(for: button)

        if !KeychainManager.shared.hasSessionKey {
            // 세션 키 미설정
            let claudeIcon = NSImage(named: "ClaudeMenuBarIcon")
            claudeIcon?.size = NSSize(width: 18, height: 18)
            let statusFont = NSFont.systemFont(ofSize: 12)
            let statusAttrs: [NSAttributedString.Key: Any] = [.font: statusFont, .foregroundColor: secondaryColor]
            let statusText = "로그인 필요"
            let textSize = (statusText as NSString).size(withAttributes: statusAttrs)
            let iconW: CGFloat = 18
            let gap: CGFloat = 4
            let totalW = iconW + gap + textSize.width
            let h: CGFloat = 22
            let img = NSImage(size: NSSize(width: totalW, height: h), flipped: false) { _ in
                claudeIcon?.draw(in: NSRect(x: 0, y: (h - iconW) / 2, width: iconW, height: iconW))
                (statusText as NSString).draw(at: NSPoint(x: iconW + gap, y: (h - textSize.height) / 2), withAttributes: statusAttrs)
                return true
            }
            img.isTemplate = false
            button.image = img
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "클릭하여 로그인"
            return
        }

        if let error = currentError, currentUsage == nil {
            // 에러 (데이터 없음)
            let claudeIcon = NSImage(named: "ClaudeMenuBarIcon")
            claudeIcon?.size = NSSize(width: 18, height: 18)
            let statusFont = NSFont.systemFont(ofSize: 12)
            let label = hasAuthError ? "인증 필요" : "⚠"
            let color: NSColor = hasAuthError ? .systemOrange : secondaryColor
            let statusAttrs: [NSAttributedString.Key: Any] = [.font: statusFont, .foregroundColor: color]
            let textSize = (label as NSString).size(withAttributes: statusAttrs)
            let iconW: CGFloat = 18
            let gap: CGFloat = 4
            let totalW = iconW + gap + textSize.width
            let h: CGFloat = 22
            let img = NSImage(size: NSSize(width: totalW, height: h), flipped: false) { _ in
                claudeIcon?.draw(in: NSRect(x: 0, y: (h - iconW) / 2, width: iconW, height: iconW))
                (label as NSString).draw(at: NSPoint(x: iconW + gap, y: (h - textSize.height) / 2), withAttributes: statusAttrs)
                return true
            }
            img.isTemplate = false
            button.image = img
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = error.errorDescription ?? "알 수 없는 에러"
            return
        }

        guard let usage = currentUsage else {
            // 로딩 중
            let claudeIcon = NSImage(named: "ClaudeMenuBarIcon")
            claudeIcon?.size = NSSize(width: 18, height: 18)
            button.image = claudeIcon
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "데이터 로딩 중"
            return
        }

        let fiveHourPct = usage.fiveHourPercentage
        let weeklyPct = usage.sevenDay?.utilization ?? 0
        let primaryPct = fiveHourPct

        let fiveHourColor = ColorProvider.nsStatusColor(for: fiveHourPct)
        let weeklyColor = ColorProvider.nsWeeklyStatusColor(for: weeklyPct)
        let primaryColor = fiveHourColor

        // 모든 요소를 하나의 이미지로 통합 렌더링 (세로 정렬 보장)
        let menuBarHeight: CGFloat = 22
        let spacing: CGFloat = 4
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let smallFont = NSFont.systemFont(ofSize: 11)
        var elements: [(image: NSImage?, text: String?, attrs: [NSAttributedString.Key: Any]?)] = []

        // 1. Claude 아이콘 (설정)
        if settings.showClaudeIcon {
            let claudeIcon = NSImage(named: "ClaudeMenuBarIcon")
            let iconSize: CGFloat = 18
            claudeIcon?.size = NSSize(width: iconSize, height: iconSize)
            elements.append((image: claudeIcon, text: nil, attrs: nil))
        }

        // 2. 퍼센트 (설정) — 배터리 계열: 남은 사용량, 원형/동심원: 표시 기준 설정, 그 외: 사용량
        let showRemaining: Bool = {
            switch settings.menuBarStyle {
            case .batteryBar, .dualBattery, .sideBySideBattery:
                return true
            case .circular, .concentricRings:
                return settings.circularDisplayMode == .remaining
            case .none:
                return false
            }
        }()
        let displayFiveHour = showRemaining ? (100.0 - fiveHourPct) : fiveHourPct
        let displayWeekly = showRemaining ? (100.0 - weeklyPct) : weeklyPct
        switch settings.percentageDisplay {
        case .none:
            break
        case .fiveHour:
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fiveHourColor]
            elements.append((image: nil, text: String(format: "%.0f%%", displayFiveHour), attrs: attrs))
        case .weekly:
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: weeklyColor]
            elements.append((image: nil, text: String(format: "%.0f%%", displayWeekly), attrs: attrs))
        case .dual:
            let t1 = String(format: "%.0f%%", displayFiveHour)
            let t2 = " · "
            let t3 = String(format: "%.0f%%", displayWeekly)
            let a1: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fiveHourColor]
            let a2: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: secondaryColor]
            let a3: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: weeklyColor]
            let w1 = (t1 as NSString).size(withAttributes: a1).width
            let w2 = (t2 as NSString).size(withAttributes: a2).width
            let w3 = (t3 as NSString).size(withAttributes: a3).width
            let textHeight = (t1 as NSString).size(withAttributes: a1).height
            let textImage = NSImage(size: NSSize(width: w1 + w2 + w3, height: textHeight), flipped: false) { _ in
                var x: CGFloat = 0
                (t1 as NSString).draw(at: NSPoint(x: x, y: 0), withAttributes: a1); x += w1
                (t2 as NSString).draw(at: NSPoint(x: x, y: 0), withAttributes: a2); x += w2
                (t3 as NSString).draw(at: NSPoint(x: x, y: 0), withAttributes: a3)
                return true
            }
            elements.append((image: textImage, text: nil, attrs: nil))
        }

        // 3. 추가 아이콘 (설정)
        let isRemainingMode = settings.circularDisplayMode == .remaining
        let circularValue = isRemainingMode ? (100.0 - primaryPct) : primaryPct
        let concentricOuter = isRemainingMode ? (100.0 - fiveHourPct) : fiveHourPct
        let concentricInner = isRemainingMode ? (100.0 - weeklyPct) : weeklyPct
        let extraIcon: NSImage? = switch settings.menuBarStyle {
        case .none: nil
        case .batteryBar: MenuBarIconRenderer.batteryIcon(percentage: primaryPct, color: primaryColor, showPercent: settings.showBatteryPercent)
        case .circular: MenuBarIconRenderer.circularRingIcon(percentage: circularValue, color: primaryColor)
        case .concentricRings: MenuBarIconRenderer.concentricRingsIcon(
            outerPercent: concentricOuter, innerPercent: concentricInner,
            outerColor: fiveHourColor, innerColor: weeklyColor)
        case .dualBattery: MenuBarIconRenderer.dualBatteryIcon(
            topPercent: fiveHourPct, bottomPercent: weeklyPct,
            topColor: fiveHourColor, bottomColor: weeklyColor)
        case .sideBySideBattery: MenuBarIconRenderer.sideBySideBatteryIcon(
            leftPercent: fiveHourPct, rightPercent: weeklyPct,
            leftColor: fiveHourColor, rightColor: weeklyColor,
            showPercent: settings.showBatteryPercent)
        }
        if let extra = extraIcon {
            elements.append((image: extra, text: nil, attrs: nil))
        }

        // 4. 인증 에러 경고
        if hasAuthError {
            let warnFont = NSFont.systemFont(ofSize: 12)
            let warnAttrs: [NSAttributedString.Key: Any] = [.font: warnFont, .foregroundColor: NSColor.systemOrange]
            elements.append((image: nil, text: "⚠", attrs: warnAttrs))
        }

        // 5. 리셋 시간 (설정)
        switch settings.resetTimeDisplay {
        case .none:
            break
        case .fiveHour:
            if let resetAt = usage.fiveHour.resetsAt,
               let clock = TimeFormatter.formatResetTime(from: resetAt, style: settings.timeFormat, includeDateIfNotToday: false) {
                let attrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: secondaryColor]
                elements.append((image: nil, text: clock, attrs: attrs))
            }
        case .weekly:
            if let resetAt = usage.sevenDay?.resetsAt,
               let clock = TimeFormatter.formatResetTimeWeekly(from: resetAt, style: settings.timeFormat, includeDateIfNotToday: false) {
                let attrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: secondaryColor]
                elements.append((image: nil, text: clock, attrs: attrs))
            }
        case .dual:
            let r1 = usage.fiveHour.resetsAt.flatMap { TimeFormatter.formatResetTime(from: $0, style: settings.timeFormat, includeDateIfNotToday: false) }
            let r2 = usage.sevenDay?.resetsAt.flatMap { TimeFormatter.formatResetTimeWeekly(from: $0, style: settings.timeFormat, includeDateIfNotToday: false) }
            let dualText: String?
            if let t1 = r1, let t2 = r2 {
                dualText = "\(t1) · \(t2)"
            } else {
                dualText = r1 ?? r2
            }
            if let text = dualText {
                let attrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: secondaryColor]
                elements.append((image: nil, text: text, attrs: attrs))
            }
        }

        // 총 너비 계산
        if elements.isEmpty {
            let fallbackAttrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: secondaryColor]
            elements.append((image: nil, text: "Claude", attrs: fallbackAttrs))
        }

        var totalWidth: CGFloat = 0
        for (i, el) in elements.enumerated() {
            if i > 0 { totalWidth += spacing }
            if let img = el.image {
                totalWidth += img.size.width
            } else if let txt = el.text, let attrs = el.attrs {
                totalWidth += (txt as NSString).size(withAttributes: attrs).width
            }
        }

        // 통합 이미지 생성
        let compositeImage = NSImage(size: NSSize(width: totalWidth, height: menuBarHeight), flipped: false) { _ in
            var x: CGFloat = 0
            for (i, el) in elements.enumerated() {
                if i > 0 { x += spacing }
                if let img = el.image {
                    let y = (menuBarHeight - img.size.height) / 2
                    img.draw(in: NSRect(x: x, y: y, width: img.size.width, height: img.size.height))
                    x += img.size.width
                } else if let txt = el.text, let attrs = el.attrs {
                    let size = (txt as NSString).size(withAttributes: attrs)
                    let y = (menuBarHeight - size.height) / 2
                    (txt as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
                    x += size.width
                }
            }
            return true
        }
        compositeImage.isTemplate = false

        button.image = compositeImage
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString(string: "")
        let authWarning = hasAuthError ? "\n⚠️ 세션 키가 유효하지 않습니다" : ""
        let tooltip = "현재 세션: \(Int(fiveHourPct))% / 주간: \(Int(weeklyPct))%\(authWarning)"
        button.toolTip = tooltip
    }

    private func secondaryTextColor(for button: NSStatusBarButton) -> NSColor {
        let isDarkMenuBar: Bool = {
            let appearance = button.effectiveAppearance
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
            return match == .darkAqua || match == .vibrantDark
        }()

        if AppSettings.shared.menuBarTextHighContrast {
            return isDarkMenuBar ? .white : .black
        }
        return isDarkMenuBar
            ? NSColor.white.withAlphaComponent(0.55)
            : NSColor.black.withAlphaComponent(0.4)
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

    private func renderCodexOnlyMenuBar(button: NSStatusBarButton, secondaryColor: NSColor) {
        let settings = AppSettings.shared
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let smallFont = NSFont.systemFont(ofSize: 11)
        let spacing: CGFloat = 4
        var elements: [(image: NSImage?, text: String?, attrs: [NSAttributedString.Key: Any]?)] = []

        if settings.showCodexIcon, let codexIcon = NSImage(named: "CodexMenuBarIcon") {
            codexIcon.size = NSSize(width: 15, height: 15)
            elements.append((image: codexIcon, text: nil, attrs: nil))
        }

        if let codex = currentCodexUsage {
            let p = codex.primaryPercentage
            let w = codex.secondaryPercentage
            let primaryColor = ColorProvider.nsStatusColor(for: p)
            let weeklyColor = ColorProvider.nsWeeklyStatusColor(for: w)

            switch settings.codexPercentageDisplay {
            case .none:
                let attrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: secondaryColor]
                elements.append((image: nil, text: "Codex", attrs: attrs))
            case .fiveHour:
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: primaryColor]
                elements.append((image: nil, text: String(format: "%.0f%%", p), attrs: attrs))
            case .weekly:
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: weeklyColor]
                elements.append((image: nil, text: String(format: "%.0f%%", w), attrs: attrs))
            case .dual:
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: primaryColor]
                elements.append((image: nil, text: String(format: "%.0f%%", p), attrs: attrs))
                let dotAttrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: secondaryColor]
                elements.append((image: nil, text: "·", attrs: dotAttrs))
                let secondAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: weeklyColor]
                elements.append((image: nil, text: String(format: "%.0f%%", w), attrs: secondAttrs))
            }
        } else if hasCodexAuthError {
            let attrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: NSColor.systemOrange]
            elements.append((image: nil, text: "Codex 인증 필요", attrs: attrs))
        } else {
            let attrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: NSColor.systemOrange]
            elements.append((image: nil, text: "Codex 오류", attrs: attrs))
        }

        let menuBarHeight: CGFloat = 22
        if elements.isEmpty {
            let fallbackAttrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: secondaryColor]
            elements.append((image: nil, text: "Codex", attrs: fallbackAttrs))
        }

        var totalWidth: CGFloat = 0
        for (i, el) in elements.enumerated() {
            if i > 0 { totalWidth += spacing }
            if let image = el.image {
                totalWidth += image.size.width
            } else if let text = el.text, let attrs = el.attrs {
                totalWidth += (text as NSString).size(withAttributes: attrs).width
            }
        }

        let image = NSImage(size: NSSize(width: totalWidth, height: menuBarHeight), flipped: false) { _ in
            var x: CGFloat = 0
            for (i, el) in elements.enumerated() {
                if i > 0 { x += spacing }
                if let image = el.image {
                    let y = (menuBarHeight - image.size.height) / 2
                    image.draw(in: NSRect(x: x, y: y, width: image.size.width, height: image.size.height))
                    x += image.size.width
                } else if let text = el.text, let attrs = el.attrs {
                    let size = (text as NSString).size(withAttributes: attrs)
                    let y = (menuBarHeight - size.height) / 2
                    (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
                    x += size.width
                }
            }
            return true
        }
        image.isTemplate = false

        button.image = image
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString(string: "")
        if let codex = currentCodexUsage {
            button.toolTip = "Codex 현재: \(Int(codex.primaryPercentage))% / 주간: \(Int(codex.secondaryPercentage))%"
        } else if hasCodexAuthError {
            button.toolTip = "Codex 인증 필요"
        } else {
            button.toolTip = "Codex 조회 오류"
        }
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
            if AppSettings.shared.claudeEnabled, let key = KeychainManager.shared.load(), !key.isEmpty {
                await self.apiService.updateSessionKey(key)
                await MainActor.run {
                    self.rebuildStatusItems()
                    self.setupPopovers()
                    self.startMonitoring()
                }
            } else {
                await self.apiService.clearSession()
                await MainActor.run {
                    self.rebuildStatusItems()
                    self.setupPopovers()
                    self.currentUsage = nil
                    self.currentOverage = nil
                    self.lastOverageFetchAt = nil
                    self.currentError = nil
                    self.hasAuthError = false
                    self.consecutiveErrorCount = 0
                    self.isLoading = false
                    self.nextUsageRefreshAllowedAt = nil
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
                    if AppSettings.shared.codexEnabled {
                        self.startTimer()
                        self.refreshCodexUsage(force: true)
                    } else if AppSettings.shared.claudeEnabled && KeychainManager.shared.hasSessionKey {
                        self.startTimer()
                    } else {
                        self.timer?.invalidate()
                        self.timer = nil
                        self.activeTimerInterval = nil
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
                    await MainActor.run {
                        self.syncUsageHealthSnapshotToUI()
                    }
                }
                self.currentUsage = nil
                self.currentOverage = nil
                self.lastOverageFetchAt = nil
                self.currentError = nil
                self.hasAuthError = false
                self.consecutiveErrorCount = 0
                self.isLoading = false
                self.nextUsageRefreshAllowedAt = nil
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
                if AppSettings.shared.codexEnabled {
                    self.startTimer()
                    self.refreshCodexUsage(force: true)
                } else {
                    self.timer?.invalidate()
                    self.timer = nil
                    self.activeTimerInterval = nil
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
        let canRefreshClaude = AppSettings.shared.claudeEnabled && KeychainManager.shared.hasSessionKey
        let canRefreshCodex = AppSettings.shared.codexEnabled
        if canRefreshClaude || canRefreshCodex {
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
