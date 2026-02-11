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
            // Option+클릭: 5시간/주간 세션 전환
            toggleSessionView()
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
        let styleItem = NSMenuItem(title: "추가 아이콘", action: nil, keyEquivalent: "")
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

    // MARK: - Session Toggle

    private var showingWeekly = false

    private func toggleSessionView() {
        showingWeekly.toggle()
        updateMenuBar()
        Logger.info("세션 전환: \(showingWeekly ? "주간" : "5시간")")
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

        // 디스플레이 관련 설정 변경 → 메뉴바 즉시 갱신
        // receive(on: RunLoop.main)으로 값 반영 후 업데이트
        let displayPublishers = [
            AppSettings.shared.$menuBarStyle.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$showPercentage.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$showResetTime.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$timeFormat.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$showBatteryPercent.map { _ in () }.eraseToAnyPublisher(),
        ]

        for publisher in displayPublishers {
            publisher
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.updateMenuBar() }
                .store(in: &cancellables)
        }
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
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = NSAttributedString(string: "⚠️")
            button.toolTip = error.errorDescription ?? "알 수 없는 에러"
            return
        }

        guard let usage = currentUsage else {
            // 로딩 또는 키 미설정
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = NSAttributedString(string: "...")
            button.toolTip = KeychainManager.shared.hasSessionKey ? "데이터 로딩 중" : "세션 키를 설정해주세요"
            return
        }

        let percentage = showingWeekly ? usage.sevenDay.utilization : usage.fiveHourPercentage
        let sessionLabel = showingWeekly ? "주간" : "5시간"
        let color = ColorProvider.nsStatusColor(for: percentage)
        let settings = AppSettings.shared

        // 모든 요소를 하나의 이미지로 통합 렌더링 (세로 정렬 보장)
        let menuBarHeight: CGFloat = 22
        let spacing: CGFloat = 4
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let smallFont = NSFont.systemFont(ofSize: 11)
        var elements: [(image: NSImage?, text: String?, attrs: [NSAttributedString.Key: Any]?)] = []

        // 1. Claude 아이콘 (항상)
        let claudeIcon = NSImage(named: "ClaudeMenuBarIcon")
        let iconSize: CGFloat = 18
        claudeIcon?.size = NSSize(width: iconSize, height: iconSize)
        elements.append((image: claudeIcon, text: nil, attrs: nil))

        // 2. 퍼센트 (설정)
        if settings.showPercentage {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            elements.append((image: nil, text: String(format: "%.0f%%", percentage), attrs: attrs))
        }

        // 3. 추가 아이콘 (설정)
        let extraIcon: NSImage? = switch settings.menuBarStyle {
        case .none: nil
        case .batteryBar: MenuBarIconRenderer.batteryIcon(percentage: percentage, color: color, showPercent: settings.showBatteryPercent)
        case .circular: MenuBarIconRenderer.circularRingIcon(percentage: percentage, color: color)
        }
        if let extra = extraIcon {
            elements.append((image: extra, text: nil, attrs: nil))
        }

        // 4. 리셋 시간 (설정)
        if settings.showResetTime {
            let resetAt = showingWeekly ? usage.sevenDay.resetsAt : usage.fiveHour.resetsAt
            if let clock = TimeFormatter.formatResetTime(from: resetAt, style: settings.timeFormat) {
                let attrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: NSColor.secondaryLabelColor]
                elements.append((image: nil, text: clock, attrs: attrs))
            }
        }

        // 총 너비 계산
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
        button.toolTip = "\(sessionLabel) 세션: \(Int(percentage))%\n(Option+클릭: 5시간/주간 전환)"
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
