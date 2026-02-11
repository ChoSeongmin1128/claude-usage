//
//  AppDelegate.swift
//  ClaudeUsage
//
//  Phase 1+3: 메뉴바 관리, 앱 라이프사이클, 설정 창
//

import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private let apiService = ClaudeAPIService()

    private var currentPercentage: Double?
    private var currentError: APIError?

    private var settingsWindow: NSWindow?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.info("ClaudeUsage 앱 시작")

        // 메뉴바 아이템 생성
        setupStatusItem()

        // 메인 윈도우 숨기기
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows where window !== self.settingsWindow {
                window.orderOut(nil)
            }
        }

        // 세션 키 확인 → 없으면 설정 창 표시
        if KeychainManager.shared.hasSessionKey {
            startMonitoring()
        } else {
            updateMenuBar(percentage: nil, error: nil)
            showSettingsWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Logger.info("ClaudeUsage 앱 종료")
        timer?.invalidate()
    }

    // MARK: - Status Item Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else {
            Logger.error("StatusItem 버튼 생성 실패")
            return
        }

        button.title = "..."
        button.toolTip = "Claude 사용량 로딩 중"

        rebuildMenu()

        Logger.info("메뉴바 아이템 생성 완료")
    }

    /// 메뉴 재구성
    private func rebuildMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "새로고침", action: #selector(refreshClicked), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "세션 키 설정...", action: #selector(settingsClicked), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(quitClicked), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    // MARK: - Monitoring

    /// API 모니터링 시작
    private func startMonitoring() {
        // 초기 로딩 상태
        updateMenuBar(percentage: nil, error: nil)

        // 첫 데이터 로드
        refreshUsage()

        // 타이머 시작 (5초마다 갱신)
        startTimer()
    }

    // MARK: - Timer

    private func startTimer() {
        timer?.invalidate()

        timer = Timer.scheduledTimer(
            withTimeInterval: 5.0,
            repeats: true
        ) { [weak self] _ in
            self?.refreshUsage()
        }

        Logger.info("자동 갱신 타이머 시작 (5초)")
    }

    // MARK: - API

    private func refreshUsage() {
        Task {
            do {
                Logger.debug("사용량 갱신 시작")

                let usage = try await apiService.fetchUsageWithRetry()
                let percentage = usage.fiveHourPercentage

                await MainActor.run {
                    self.currentPercentage = percentage
                    self.currentError = nil
                    self.updateMenuBar(percentage: percentage, error: nil)
                }

            } catch let error as APIError {
                Logger.error("API 에러: \(error.errorDescription ?? "알 수 없는 에러")")

                await MainActor.run {
                    self.currentPercentage = nil
                    self.currentError = error
                    self.updateMenuBar(percentage: nil, error: error)
                }

            } catch {
                Logger.error("예상치 못한 에러: \(error)")

                let apiError = APIError.unknownError(error.localizedDescription)
                await MainActor.run {
                    self.currentPercentage = nil
                    self.currentError = apiError
                    self.updateMenuBar(percentage: nil, error: apiError)
                }
            }
        }
    }

    // MARK: - UI Update

    private func updateMenuBar(percentage: Double?, error: APIError?) {
        guard let button = statusItem?.button else { return }

        if let error = error {
            button.title = "⚠️"
            button.toolTip = error.errorDescription ?? "알 수 없는 에러"
            Logger.warning("메뉴바 업데이트: 에러 표시")

        } else if let percentage = percentage {
            let text = String(format: "%.0f%%", percentage)
            button.toolTip = "5시간 세션: \(Int(percentage))%"

            // 동적 색상 적용
            let color = getStatusColor(percentage: percentage)
            button.attributedTitle = NSAttributedString(
                string: text,
                attributes: [.foregroundColor: color]
            )

            Logger.info("메뉴바 업데이트: \(Int(percentage))%")

        } else {
            button.title = "..."
            button.toolTip = KeychainManager.shared.hasSessionKey
                ? "데이터 로딩 중"
                : "세션 키를 설정해주세요"
            Logger.debug("메뉴바 업데이트: 로딩 중")
        }
    }

    // MARK: - Dynamic Color

    /// 사용률에 따른 동적 색상 (초록 → 노랑 → 빨강)
    private func getStatusColor(percentage: Double) -> NSColor {
        if percentage >= 100 {
            return NSColor.gray
        }

        let hue = (120.0 - (percentage * 1.2)) / 360.0
        let saturation: CGFloat = 0.85
        let brightness: CGFloat = percentage > 50 ? 0.85 : 0.75

        return NSColor(hue: CGFloat(hue), saturation: saturation, brightness: brightness, alpha: 1.0)
    }

    // MARK: - Settings Window

    @objc private func settingsClicked() {
        showSettingsWindow()
    }

    private func showSettingsWindow() {
        // 이미 열려있으면 앞으로 가져오기
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SessionKeyInputView(
            onSave: { [weak self] key in
                guard let self = self else { return }

                // API 서비스에 새 키 전달
                Task {
                    await self.apiService.updateSessionKey(key)
                }

                // 설정 창 닫기
                self.settingsWindow?.close()

                // 모니터링 시작
                self.startMonitoring()

                Logger.info("세션 키 설정 완료, 모니터링 시작")
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
        Logger.debug("수동 새로고침 클릭")

        if KeychainManager.shared.hasSessionKey {
            refreshUsage()
        } else {
            showSettingsWindow()
        }
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }
}
