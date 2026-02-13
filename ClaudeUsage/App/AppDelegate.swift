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
    private var updateCheckTimer: Timer?
    private let apiService = ClaudeAPIService()
    private let popoverViewModel = PopoverViewModel()

    private var currentUsage: ClaudeUsageResponse?
    private var currentOverage: OverageSpendLimitResponse?
    private var systemStatus: ClaudeSystemStatus?
    private var currentError: APIError?
    private var isLoading = false
    private var lastUpdated: Date?
    private var hasAuthError = false
    private var consecutiveErrorCount = 0
    private var statusTimer: Timer?

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
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        stopGlobalClickMonitor()
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
            self?.closePopover()
            self?.showSettingsWindow()
        }
        popoverViewModel.onPinChanged = { [weak self] isPinned in
            guard let self = self else { return }
            if isPinned {
                self.popover?.behavior = .applicationDefined
                self.stopGlobalClickMonitor()
            } else {
                self.popover?.behavior = .transient
                if self.popover?.isShown == true {
                    self.startGlobalClickMonitor()
                }
            }
        }

        let popoverView = PopoverView(viewModel: popoverViewModel)
        let hostingController = NSHostingController(rootView: popoverView)

        let isPinned = AppSettings.shared.popoverPinned
        popover = NSPopover()
        popover?.contentViewController = hostingController
        popover?.behavior = isPinned ? .applicationDefined : .transient
        popover?.animates = true
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // 우클릭: 컨텍스트 메뉴
            showContextMenu()
        } else {
            // 클릭: Popover 토글
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let popover = popover, let button = statusItem?.button else { return }

        if popover.isShown {
            closePopover()
        } else {
            popoverViewModel.update(usage: currentUsage, error: currentError, isLoading: isLoading, lastUpdated: lastUpdated, overage: currentOverage)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
            if !AppSettings.shared.popoverPinned {
                startGlobalClickMonitor()
            }
        }
    }

    private func closePopover() {
        popover?.close()
        stopGlobalClickMonitor()
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
            AppSettings.shared.$percentageDisplay.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$resetTimeDisplay.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$timeFormat.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$showBatteryPercent.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$circularDisplayMode.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$showClaudeIcon.map { _ in () }.eraseToAnyPublisher(),
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

    // MARK: - API

    private func refreshUsage() {
        Task {
            do {
                isLoading = true
                popoverViewModel.update(usage: currentUsage, error: nil, isLoading: true, lastUpdated: lastUpdated, overage: currentOverage)
                Logger.debug("사용량 갱신 시작")

                let usage = try await apiService.fetchUsageWithRetry()

                // 추가 사용량은 독립적으로 호출 (실패해도 무시)
                let overage = try? await apiService.fetchOverageSpendLimit()

                await MainActor.run {
                    self.currentUsage = usage
                    self.currentOverage = overage
                    self.currentError = nil
                    self.isLoading = false
                    self.hasAuthError = false
                    self.consecutiveErrorCount = 0
                    self.lastUpdated = Date()
                    self.updateMenuBar()
                    self.popoverViewModel.update(usage: usage, error: nil, isLoading: false, lastUpdated: self.lastUpdated, overage: overage)

                    // 알림 체크
                    NotificationManager.shared.checkThreshold(
                        session: .fiveHour,
                        percentage: usage.fiveHourPercentage,
                        resetAt: usage.fiveHour.resetsAt
                    )
                    NotificationManager.shared.checkThreshold(
                        session: .weekly,
                        percentage: usage.weeklyPercentage,
                        resetAt: usage.sevenDay.resetsAt
                    )
                }

            } catch let error as APIError {
                Logger.error("API 에러: \(error.errorDescription ?? "")")

                await MainActor.run {
                    self.currentError = error
                    self.isLoading = false
                    self.consecutiveErrorCount += 1
                    if case .invalidSessionKey = error {
                        self.hasAuthError = true
                    }
                    if self.consecutiveErrorCount >= 3 {
                        self.currentUsage = nil
                    }
                    self.updateMenuBar()
                    self.popoverViewModel.update(usage: self.currentUsage, error: error, isLoading: false)
                }

            } catch {
                Logger.error("예상치 못한 에러: \(error)")

                let apiError = APIError.unknownError(error.localizedDescription)
                await MainActor.run {
                    self.currentError = apiError
                    self.isLoading = false
                    self.consecutiveErrorCount += 1
                    if self.consecutiveErrorCount >= 3 {
                        self.currentUsage = nil
                    }
                    self.updateMenuBar()
                    self.popoverViewModel.update(usage: self.currentUsage, error: apiError, isLoading: false)
                }
            }
        }
    }

    // MARK: - Menu Bar Update

    private func updateMenuBar() {
        guard let button = statusItem?.button else { return }

        let buttonAppearance = button.effectiveAppearance

        if !KeychainManager.shared.hasSessionKey {
            // 세션 키 미설정
            let claudeIcon = NSImage(named: "ClaudeMenuBarIcon")
            claudeIcon?.size = NSSize(width: 18, height: 18)
            let statusFont = NSFont.systemFont(ofSize: 12)
            let statusAttrs: [NSAttributedString.Key: Any] = [.font: statusFont, .foregroundColor: NSColor.secondaryLabelColor]
            let statusText = "로그인 필요"
            let textSize = (statusText as NSString).size(withAttributes: statusAttrs)
            let iconW: CGFloat = 18
            let gap: CGFloat = 4
            let totalW = iconW + gap + textSize.width
            let h: CGFloat = 22
            let img = NSImage(size: NSSize(width: totalW, height: h), flipped: false) { _ in
                NSAppearance.current = buttonAppearance
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
            let color: NSColor = hasAuthError ? .systemOrange : .secondaryLabelColor
            let statusAttrs: [NSAttributedString.Key: Any] = [.font: statusFont, .foregroundColor: color]
            let textSize = (label as NSString).size(withAttributes: statusAttrs)
            let iconW: CGFloat = 18
            let gap: CGFloat = 4
            let totalW = iconW + gap + textSize.width
            let h: CGFloat = 22
            let img = NSImage(size: NSSize(width: totalW, height: h), flipped: false) { _ in
                NSAppearance.current = buttonAppearance
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

        let settings = AppSettings.shared
        let fiveHourPct = usage.fiveHourPercentage
        let weeklyPct = usage.sevenDay.utilization
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
            let a2: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
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
                let attrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: NSColor.secondaryLabelColor]
                elements.append((image: nil, text: clock, attrs: attrs))
            }
        case .weekly:
            if let resetAt = usage.sevenDay.resetsAt,
               let clock = TimeFormatter.formatResetTimeWeekly(from: resetAt, style: settings.timeFormat, includeDateIfNotToday: false) {
                let attrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: NSColor.secondaryLabelColor]
                elements.append((image: nil, text: clock, attrs: attrs))
            }
        case .dual:
            let r1 = usage.fiveHour.resetsAt.flatMap { TimeFormatter.formatResetTime(from: $0, style: settings.timeFormat, includeDateIfNotToday: false) }
            let r2 = usage.sevenDay.resetsAt.flatMap { TimeFormatter.formatResetTimeWeekly(from: $0, style: settings.timeFormat, includeDateIfNotToday: false) }
            let dualText: String?
            if let t1 = r1, let t2 = r2 {
                dualText = "\(t1) · \(t2)"
            } else {
                dualText = r1 ?? r2
            }
            if let text = dualText {
                let attrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: NSColor.secondaryLabelColor]
                elements.append((image: nil, text: text, attrs: attrs))
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
            NSAppearance.current = buttonAppearance
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
        button.toolTip = "현재 세션: \(Int(fiveHourPct))% / 주간: \(Int(weeklyPct))%\(authWarning)"
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

        settingsSnapshot = AppSettings.shared.createSnapshot()

        let settingsView = SettingsView(
            onSave: { [weak self] in
                guard let self = self else { return }
                self.settingsSnapshot = nil  // 저장 시 스냅샷 클리어 → 복원 방지
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
            },
            onOpenLogin: { [weak self] in
                self?.settingsWindow?.close()
                self?.showLoginWindow()
            },
            onLogout: { [weak self] in
                guard let self = self else { return }
                try? KeychainManager.shared.delete()
                self.timer?.invalidate()
                self.timer = nil
                self.currentUsage = nil
                self.currentOverage = nil
                self.currentError = nil
                self.hasAuthError = false
                self.consecutiveErrorCount = 0
                self.isLoading = false
                self.updateMenuBar()
                self.popoverViewModel.update(usage: nil, error: nil, isLoading: false, overage: nil)
                self.settingsSnapshot = nil
                self.settingsWindow?.close()

                // 내장 브라우저 쿠키/캐시 삭제
                let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
                WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
                    Logger.info("웹 데이터 삭제 완료")
                }
                Logger.info("로그아웃 완료")
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
