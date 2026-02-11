//
//  AppDelegate.swift
//  ClaudeUsage
//
//  전체 통합: 메뉴바, Popover, 설정, 알림, 키보드 단축키
//

import AppKit
import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var timer: Timer?
    private let apiService = ClaudeAPIService()
    private let popoverViewModel = PopoverViewModel()

    private var currentUsage: ClaudeUsageResponse?
    private var currentError: APIError?
    private var isLoading = false

    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.info("ClaudeUsage 앱 시작")

        // 알림 권한 요청
        NotificationManager.shared.requestPermission()

        // 메뉴바 아이템 생성
        setupStatusItem()

        // Popover 생성
        setupPopover()

        // 키보드 단축키 설정
        setupKeyboardShortcuts()

        // 설정 변경 감지
        observeSettings()

        // 배터리 상태 변경 감지
        observePowerState()

        // 세션 키 확인
        if KeychainManager.shared.hasSessionKey {
            startMonitoring()
        } else {
            updateMenuBar()
            showSettingsWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Logger.info("ClaudeUsage 앱 종료")
        timer?.invalidate()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else {
            Logger.error("StatusItem 버튼 생성 실패")
            return
        }

        button.title = "..."
        button.toolTip = "Claude 사용량"
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self

        Logger.info("메뉴바 아이템 생성 완료")
    }

    // MARK: - Popover

    private func setupPopover() {
        popoverViewModel.onRefresh = { [weak self] in
            self?.refreshUsage()
        }
        popoverViewModel.onOpenSettings = { [weak self] in
            self?.popover?.close()
            self?.showSettingsWindow()
        }

        let popoverView = PopoverView(viewModel: popoverViewModel)
        let hostingController = NSHostingController(rootView: popoverView)

        popover = NSPopover()
        popover?.contentViewController = hostingController
        popover?.behavior = .transient
        popover?.animates = true
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // 우클릭: 컨텍스트 메뉴
            showContextMenu()
        } else if event.modifierFlags.contains(.option) {
            // Option+클릭: 표시 모드 전환
            toggleDisplayMode()
        } else {
            // 일반 클릭: Popover 토글
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let popover = popover, let button = statusItem?.button else { return }

        if popover.isShown {
            popover.close()
        } else {
            popoverViewModel.update(usage: currentUsage, error: currentError, isLoading: isLoading)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "새로고침", action: #selector(refreshClicked), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())

        // 표시 모드
        let styleMenu = NSMenu()
        for style in MenuBarStyle.allCases {
            let item = NSMenuItem(title: style.displayName, action: #selector(changeStyle(_:)), keyEquivalent: "")
            item.representedObject = style
            item.state = AppSettings.shared.menuBarStyle == style ? .on : .off
            styleMenu.addItem(item)
        }
        let styleItem = NSMenuItem(title: "표시 스타일", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "설정...", action: #selector(settingsClicked), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "사용량 상세 보기", action: #selector(openUsagePage), keyEquivalent: "u"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(quitClicked), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil  // 다음 클릭을 위해 메뉴 해제
    }

    // MARK: - Display Modes

    private func toggleDisplayMode() {
        let allStyles = MenuBarStyle.allCases
        guard let currentIndex = allStyles.firstIndex(of: AppSettings.shared.menuBarStyle) else { return }
        let nextIndex = (currentIndex + 1) % allStyles.count
        AppSettings.shared.menuBarStyle = allStyles[nextIndex]
        updateMenuBar()
        Logger.info("표시 모드 전환: \(allStyles[nextIndex].displayName)")
    }

    @objc private func changeStyle(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? MenuBarStyle else { return }
        AppSettings.shared.menuBarStyle = style
        updateMenuBar()
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        isLoading = true
        updateMenuBar()
        refreshUsage()
        startTimer()
    }

    // MARK: - Timer

    private func startTimer() {
        timer?.invalidate()

        let interval = PowerMonitor.shared.effectiveRefreshInterval
        guard AppSettings.shared.autoRefresh else {
            Logger.info("자동 새로고침 비활성화")
            return
        }

        timer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            self?.refreshUsage()
        }

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
                }
            }
            .store(in: &cancellables)

        // 표시 스타일 변경
        AppSettings.shared.$menuBarStyle
            .dropFirst()
            .sink { [weak self] _ in self?.updateMenuBar() }
            .store(in: &cancellables)
    }

    private func observePowerState() {
        PowerMonitor.shared.$isOnBattery
            .dropFirst()
            .sink { [weak self] _ in self?.startTimer() }
            .store(in: &cancellables)
    }

    // MARK: - API

    private func refreshUsage() {
        Task {
            do {
                isLoading = true
                Logger.debug("사용량 갱신 시작")

                let usage = try await apiService.fetchUsageWithRetry()

                await MainActor.run {
                    self.currentUsage = usage
                    self.currentError = nil
                    self.isLoading = false
                    self.updateMenuBar()
                    self.popoverViewModel.update(usage: usage, error: nil, isLoading: false)

                    // 알림 체크
                    NotificationManager.shared.checkThreshold(
                        percentage: usage.fiveHourPercentage,
                        resetAt: usage.fiveHour.resetsAt
                    )
                }

            } catch let error as APIError {
                Logger.error("API 에러: \(error.errorDescription ?? "")")

                await MainActor.run {
                    self.currentError = error
                    self.isLoading = false
                    self.updateMenuBar()
                    self.popoverViewModel.update(usage: self.currentUsage, error: error, isLoading: false)
                }

            } catch {
                Logger.error("예상치 못한 에러: \(error)")

                let apiError = APIError.unknownError(error.localizedDescription)
                await MainActor.run {
                    self.currentError = apiError
                    self.isLoading = false
                    self.updateMenuBar()
                    self.popoverViewModel.update(usage: self.currentUsage, error: apiError, isLoading: false)
                }
            }
        }
    }

    // MARK: - Menu Bar Update

    private func updateMenuBar() {
        guard let button = statusItem?.button else { return }

        if let error = currentError, currentUsage == nil {
            // 에러 (데이터 없음)
            button.attributedTitle = NSAttributedString(string: "⚠️")
            button.toolTip = error.errorDescription ?? "알 수 없는 에러"
            return
        }

        guard let usage = currentUsage else {
            // 로딩 또는 키 미설정
            button.attributedTitle = NSAttributedString(string: "...")
            button.toolTip = KeychainManager.shared.hasSessionKey ? "데이터 로딩 중" : "세션 키를 설정해주세요"
            return
        }

        let percentage = usage.fiveHourPercentage
        let color = ColorProvider.nsStatusColor(for: percentage)
        let settings = AppSettings.shared

        let displayText: String
        switch settings.menuBarStyle {
        case .percentage:
            displayText = String(format: "%.0f%%", percentage)

        case .batteryBar:
            displayText = generateBatteryBar(percentage: percentage)

        case .circular:
            displayText = generateCircularIcon(percentage: percentage)
        }

        let prefix = settings.showIcon ? "☁️ " : ""
        let fullText = prefix + displayText

        button.attributedTitle = NSAttributedString(
            string: fullText,
            attributes: [.foregroundColor: color]
        )

        button.toolTip = "5시간 세션: \(Int(percentage))%\n(Option+클릭: 표시 모드 전환)"
    }

    /// 배터리바 생성 (█▒ 스타일)
    private func generateBatteryBar(percentage: Double) -> String {
        let totalBlocks = 10
        let filledBlocks = Int(percentage / 10.0)
        let emptyBlocks = totalBlocks - filledBlocks

        let filled = String(repeating: "█", count: min(filledBlocks, totalBlocks))
        let empty = String(repeating: "▒", count: max(emptyBlocks, 0))

        return "[\(filled)\(empty)]"
    }

    /// 원형 아이콘 생성
    private func generateCircularIcon(percentage: Double) -> String {
        if percentage >= 100 { return "●" }
        if percentage >= 87.5 { return "◉" }
        if percentage >= 75 { return "◕" }
        if percentage >= 50 { return "◑" }
        if percentage >= 25 { return "◔" }
        if percentage > 0 { return "○" }
        return "○"
    }

    // MARK: - Keyboard Shortcuts

    private func setupKeyboardShortcuts() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command) else { return event }

            switch event.charactersIgnoringModifiers {
            case "r":
                self?.refreshUsage()
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

    private func showSettingsWindow() {
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(
            onSave: { [weak self] in
                guard let self = self else { return }
                self.settingsWindow?.close()

                // 세션 키 업데이트 후 모니터링 시작 (순차 실행)
                Task {
                    if let key = KeychainManager.shared.load() {
                        await self.apiService.updateSessionKey(key)
                    }
                    await MainActor.run {
                        self.startMonitoring()
                    }
                    Logger.info("설정 저장 완료")
                }
            },
            onCancel: { [weak self] in
                self?.settingsWindow?.close()
            }
        )

        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "ClaudeUsage 설정"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating

        self.settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Actions

    @objc private func refreshClicked() {
        if KeychainManager.shared.hasSessionKey {
            refreshUsage()
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
